# H3 + H4 Fix Design — coupled-edit gate fail-opens (READ-ONLY design, no code written)

**Findings:** H3 + H4 (HIGH, from FRAMEWORK-SCRUTINY-FINDINGS.md). The flagship coupling guard
(`hooks/coupled-edit-gate`, "the #1 cascade cause" mechanism) silently **ALLOWs** an edit to a coupled file
with unresolved findings under two input-shape variations:
- **H3** — the incoming `file_path` is **absolute** (`/repo/Services/Token.cs`) or **`./`-prefixed**, but the
  stored group paths are repo-**relative** (`Services/Token.cs`); the exact-string comparator misses → allow.
  *The real Edit tool sends absolute paths, so every coupled block fails open on the live path.*
- **H4** — a group object **omits the `acknowledged` field**; the jq selector `select(.acknowledged ==
  false)` treats a missing field as `null` (and `null == false` is false) → the group isn't counted as
  unacknowledged → allow.

**This is a DESIGN ONLY.** Nothing was edited, nothing committed. HEAD after the H1+H2 commit; v0.9.0 =
`1651ecc` untouched. H3/H4 are deliberately NOT implemented here — same discipline as the H2 design: a
fix to a fail-open safety gate is built rested, from a vetted completeness argument, not blind at end of
session.

**Why H3+H4 are designed together:** same gate, same class — *input-shape variance defeating an exact
comparator* (the dominant pattern across the whole audit). H3 is path-shape variance; H4 is
object-schema-shape variance. Both are "the comparator only handles one shape; any other shape silently
passes." The fix is one coherent hardening of the membership/acknowledgement computation.

---

## 1. Confirmed bugs (read-only reproduction, /tmp copy of the real gate)

Group: `[{"files":["Services/TokenProvider.cs","Clients/AccountClient.cs"],"findings":["x"],"acknowledged":false}]`
driven with the real PreToolUse Edit JSON (`{"tool_name":"Edit","tool_input":{"file_path":"<FP>",…}}`):

### H3 — path-form variance
| Incoming `file_path` | Result | Correct? |
|---|---|---|
| `Services/TokenProvider.cs` (relative) | **exit 2 BLOCK** | ✓ (happy path) |
| `<abs>/Services/TokenProvider.cs` (absolute — the real Edit-tool form) | **exit 0 ALLOW** | ✗ **fail-open** |
| `./Services/TokenProvider.cs` (`./`-prefixed) | **exit 0 ALLOW** | ✗ **fail-open** |
| `Services\TokenProvider.cs` (backslash) | exit 2 BLOCK | ✓ (the gate's `gsub("\\\\";"/")` handles this one form) |

Root cause: `coupled-edit-gate:126-128` compares `.files[] | gsub("\\\\";"/") == ($fp | gsub("\\\\";"/"))` —
backslash→slash normalization only, **no path canonicalization**. `<abs>/Services/TokenProvider.cs` !=
`Services/TokenProvider.cs` → `UNACKED=0` → exit 0. The basename grep fast-path at `:117`
(`grep -q "$(basename "$FILE_PATH")"`) still MATCHES the absolute path (basename is a substring), so the gate
does **not** take the benign "untracked file" early-exit — it proceeds and *looks* active while silently
allowing. The python fallback (`:131-137`) uses the identical exact-string equality and is equally buggy.

### H4 — missing `acknowledged` field
| Group object | edit a member | Correct? |
|---|---|---|
| `{"files":["A.cs"],"findings":["x"]}` (no `acknowledged`) | **exit 0 ALLOW** | ✗ **fail-open** |
| `{"files":["A.cs"],"findings":["x"],"acknowledged":false}` | exit 2 BLOCK | ✓ |

Root cause: `coupled-edit-gate:127` `select(.acknowledged == false)`. A missing field is jq `null`;
`null == false` is **false**, so the group is not selected → `UNACKED=0` → allow. `write-active-groups` (the
writer/canonicalization chokepoint) validates only JSON *well-formedness* (`jq empty`), **never the group
schema**, so a group missing `acknowledged` is written verbatim.

### The backend divergence (both bugs) — jq & grep fail OPEN, python fails CLOSED
Verified read-only on the H4 selector against `[{"files":["A.cs"]}]` (missing field):
| Backend | current selector | missing-field result | direction |
|---|---|---|---|
| **jq** (the live path here) | `select(.acknowledged == false)` | 0 (not counted) | **fail-OPEN** |
| **grep** last-resort | greps literal `"acknowledged": false` | 0 (literal absent) | **fail-OPEN** |
| **python** fallback | `g.get('acknowledged', False)` | 1 (counted) | fail-CLOSED ✓ |

So the python path *already* handles H4 correctly; jq (preferred, and present on this box) and grep do not.
**The fix must make all three backends consistent and fail-closed** — the framework's "fail-closed,
evidence-keyed gate authoring" + "matcher/normalization robustness" conventions require parity across the
jq/node/python/grep ladder (a gate that's fail-closed only on the backend you don't have is the dual-source
defect class).

---

## 2. H3 — robust path-form membership (the design)

### Options
- **(A) Canonicalize both sides to repo-relative, then exact-compare.** Resolve the incoming `file_path` and
  each stored group path to a path relative to the repo root (`git rev-parse --show-toplevel`), normalizing
  `\`→`/`, stripping a leading `./`, collapsing `../` and duplicate `/`. Compare the canonical forms.
  - *Completeness:* covers absolute, `./`, `../`, mixed separators. Symlinks: a `realpath`-based canonicalize
    would also resolve symlinks, but `realpath` requires the file to exist on disk (an Edit may target a
    not-yet-created file) and adds a subprocess per path on a spawn-taxed box — so prefer **lexical**
    canonicalization (string normalization, no filesystem), which covers the reproduced forms (absolute/`./`)
    without the existence dependency. Symlinked paths are the honest residual (rare for source edits; note it).
  - *Risk:* requires resolving the repo root reliably (the gate already computes `FRAMEWORK_ROOT` via
    `git rev-parse --show-toplevel`); an absolute path outside the repo root canonicalizes to itself and
    simply won't match a relative stored path (correct — it's not a tracked group file).
- **(B) Basename + relative-suffix match (the sibling `bootstrap-write-gate` pattern).** Match iff
  `basename(incoming) == basename(stored)` **AND** the incoming path **ends with** the stored relative path
  (suffix match on a `/`-boundary). `bootstrap-write-gate:77` uses basename equality + a path-anchored regex
  for exactly this absolute-vs-relative problem.
  - *Completeness:* covers absolute, `./` (after `\`→`/` + `./`-strip), and any deeper-prefixed form, because
    the stored relative path is a `/`-boundary suffix of the absolute incoming path. No filesystem access.
  - *No-false-positive (the load-bearing H3 constraint):* a basename-ONLY match would **false-block** a
    *different* file sharing the basename (`OtherDir/TokenProvider.cs` vs the coupled `Services/TokenProvider.cs`)
    — verified this is the danger. Requiring the full stored relative path to be a **`/`-anchored suffix** of
    the incoming path (not a bare substring) prevents that: `Services/TokenProvider.cs` is a suffix of
    `/repo/Services/TokenProvider.cs` but NOT of `/repo/OtherDir/TokenProvider.cs`. The `/`-boundary anchor
    also prevents `…/XServices/TokenProvider.cs` from matching `Services/TokenProvider.cs`.

### Recommendation: **(A) lexical-canonicalize-to-relative, with (B)'s suffix match as the comparison.**
Canonicalize the incoming path (strip the repo-root prefix if absolute, strip a leading `./`, normalize
separators) → then require **exact equality OR `/`-anchored-suffix equality** against each stored path
(itself canonicalized the same way). This is the union that covers every reproduced form **and** rejects the
shared-basename false positive.

**Completeness argument:**
- **absolute** `/repo/Services/Token.cs` → strip repo-root → `Services/Token.cs` → exact match. ✓
- **absolute outside repo root** `/elsewhere/Services/Token.cs` → can't strip root → falls to suffix match:
  `Services/Token.cs` is a `/`-anchored suffix → match. ✓ (covers a session rooted elsewhere)
- **`./`-prefixed** `./Services/Token.cs` → strip `./` → exact. ✓
- **`../` / `//` / mixed `\`** → lexical normalize handles. ✓
- **shared-basename non-coupled** `/repo/OtherDir/Token.cs` → canonical `OtherDir/Token.cs` → neither exact
  nor `/`-anchored-suffix of `Services/Token.cs` → **NOT blocked.** ✓ (the critical no-false-positive)
- **Residual:** a symlink whose real path differs from the lexical path (lexical canonicalization can't
  resolve it without `realpath` + on-disk existence). Rare for source edits; state it honestly.

### Don't let the basename fast-path mask the comparator (a subtlety the bug exposed)
The `:117` basename grep fast-path exists to early-allow a genuinely-untracked file. But it currently matches
the *absolute path's basename as a substring* and lets the buggy comparator decide — so it doesn't actually
fast-exit, it just precedes a broken check. The fix should keep a fast-path ONLY as a true negative filter
(if no stored basename appears at all → allow), and make the **canonical suffix comparator** the sole
membership decision. Membership must not be decided by a comparator the basename fast-path already
(substring-)matched.

---

## 3. H4 — every malformed-group shape fails CLOSED (the design)

### Two seams; harden BOTH (defense-in-depth + single-source)
- **Seam 1 — the writer (`write-active-groups`): validate the group SCHEMA, not just JSON well-formedness.**
  Each array element must be an object with `files` (a non-empty array of strings) and `acknowledged` (a
  boolean). On a missing/non-boolean `acknowledged`, **default it to `false`** (the safe direction) and write
  the normalized object — OR reject with a schema error (exit 1, gate state not corrupted). Defaulting-to-false
  is preferable: it canonicalizes the state at the chokepoint so every downstream reader is correct
  regardless of backend, matching the installer/manifest "one source canonicalizes" discipline.
- **Seam 2 — the consumer (`coupled-edit-gate`): treat missing/non-true as unacknowledged.** Change the jq
  selector from `select(.acknowledged == false)` to `select(.acknowledged != true)`, the grep fallback to
  also count a group whose `acknowledged` is absent/not-`true`, and keep the python `.get('acknowledged',
  False)` (already correct). Verified: `select(.acknowledged != true)` returns 1 (fail-closed) on the missing
  field.

### Why both seams (completeness)
- Hardening only the writer leaves a *hand-authored or legacy* groups file (one not produced by the current
  writer) fail-open at the consumer — and the consumer is the actual enforcement point.
- Hardening only the consumer leaves the writer silently accepting malformed state that other future readers
  might mis-handle.
- Both → **every malformed-group shape fails closed at the point of use AND is normalized at the point of
  write.** The selector `!= true` is the key: it treats `false`, missing, `null`, `"false"` (string), `0`,
  and any non-`true` value as unacknowledged — the only thing that clears a group is an explicit boolean
  `true`. That is the correct fail-closed semantics (only an affirmative acknowledgement allows the edit).

### Completeness argument (every shape → fail closed)
| `acknowledged` value | `== false` (current) | `!= true` (fixed) | direction |
|---|---|---|---|
| `false` (boolean) | counted (block) | counted (block) | ✓ both |
| absent / `null` | NOT counted (allow) ✗ | counted (block) | **fixed** |
| `"false"` / `"no"` (string) | NOT counted (allow) ✗ | counted (block) | **fixed** |
| `0` / other non-true | NOT counted (allow) ✗ | counted (block) | **fixed** |
| `true` (boolean) | NOT counted (allow) ✓ | NOT counted (allow) ✓ | ✓ both (the only clear) |

Plus the writer defaulting missing→false means a stored group always carries an explicit boolean, so even a
backend that didn't get the `!= true` fix reads correctly.

---

## 4. The jq/grep/python parity requirement (both bugs)

The fix must touch all comparison backends so the verdict is backend-independent:
- **jq path** (`:126-128`): canonical-suffix membership (H3) + `select(.acknowledged != true)` (H4).
- **python path** (`:131-137`): canonical-suffix membership (H3); the `.get('acknowledged', False)` is
  already H4-correct — keep it, and make its path comparison match jq's canonical-suffix logic.
- **grep last-resort** (`:141-145`): the weakest path. It already errs toward extra blocks (the comment says
  so), but for H4 it greps the literal `"acknowledged": false` and so fails OPEN on a missing field — change
  it to block when a group mentions the file and does NOT carry an explicit `"acknowledged": true` (invert to
  the fail-closed default). For H3, the grep path matches on basename already (imprecise-but-safe), acceptable
  as the last resort.
- The `:117` basename fast-path and the `:100` shape-validation (`type=="array"`) are unchanged in intent;
  only the membership + acknowledgement computations change.

---

## 5. RED→GREEN tests the implementation must ship (certification is behavioral)

A new `tests/behavioral/coupled-edit-pathform-test.sh` (or extend `coupled-gate-failclosed-test.sh`), each
driving the real gate with PreToolUse Edit JSON, RED against current code → GREEN after:

**H3 — path form (group with `acknowledged:false`, member edited):**
- `Services/TokenProvider.cs` (relative) → BLOCK (regression baseline, already green).
- `<abs>/Services/TokenProvider.cs` (absolute) → BLOCK *(RED now: allow)*.
- `./Services/TokenProvider.cs` (`./`-prefixed) → BLOCK *(RED now: allow)*.
- `Services\TokenProvider.cs` (backslash) → BLOCK (already green; keep).
- **No-false-positive:** `<abs>/OtherDir/TokenProvider.cs` (shared basename, NOT in any group) → **ALLOW**
  (must not start false-blocking) — the critical H3 anti-regression.
- **No-false-positive:** `<abs>/Services/TokenProviderTests.cs` (basename superstring) → ALLOW.

**H4 — malformed group shape (member edited):**
- group missing `acknowledged` → BLOCK *(RED now: allow)*.
- `acknowledged:"false"` (string) → BLOCK *(RED now: allow)*.
- `acknowledged:null` → BLOCK *(RED now: allow)*.
- `acknowledged:true` → ALLOW (the only clear; regression baseline).
- writer test: `write-active-groups '[{"files":["A.cs"],"findings":["x"]}]'` then read back → the stored
  group carries `acknowledged:false` (normalized), OR the writer rejects it (whichever the impl chooses).

**Backend parity:** run the H3+H4 assertions with jq present (live), and with jq removed from PATH (python
path) — both must reach the same BLOCK/ALLOW verdict. (Drop only jq's dir from PATH, the proven isolation
from the G5 test.)

**No regression:** `tests/behavioral/coupled-gate-failclosed-test.sh` (C1-C7) and
`run-coupled-group-test.sh` stay green.

---

## 6. Honest residual + scope

- **Symlinked coupled paths** whose real path differs from the lexical path are not resolved by lexical
  canonicalization (avoiding a `realpath`/on-disk dependency for a not-yet-created edit target). Rare for
  source edits; state it in the gate comment.
- **Scope unchanged:** coupled-edit-gate is a *process/review-quality* guard (prevents cascade regressions),
  fail-open by design when no `active-groups.json` exists (no enforcement opted in). This fix closes the
  silent-allow on the *active* path; it does not change the no-groups-file posture.
- **Adjacent (out of scope for H3/H4, noted):** the audit's M13 found coupling is registered only under the
  `Edit` matcher, so a whole-file `Write` or `sed -i` to a coupled file bypasses the gate entirely. That is a
  *matcher-registration* fix (`hooks.json` `Write|Edit`), separate from this comparator hardening — flagged
  so the implementer fixes them in concert if desired, but it is M13, not H3/H4.

**Read-only design. No code written, nothing changed, nothing committed. v0.9.0 = `1651ecc` untouched.**

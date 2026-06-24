# Framework-Wide Adversarial Scrutiny — Ranked Findings

**Scope:** the WHOLE preflight framework — all 14 `hooks/`, 24 `lib/*.sh`, 8 `tools/*.sh`, and the gating
`skills/` (45 files read in full). **READ-ONLY**: every reproduction ran against a *copy* in `/tmp` or
drove the unmodified file with crafted stdin; **no repo file was changed, nothing was committed, nothing
pushed/tagged/cut.** HEAD `b8b294d`, branch `feature/preflight-framework`, v0.9.0 = `1651ecc` (untouched).

**Bug classes hunted** (the 5 the self-review found in 6 session files, now hunted everywhere):
(1) fail-open · (2) false-green · (3) CRLF fragility · (4) self-cert / integrity-gap ·
(5) silent-absence-looks-like-success · (6) unwired mechanism.

**Method:** 8 adversarial readers (one per file-group, seeded with mechanical grep leads) → each candidate
**adversarially verified** by an independent agent that tried to *reproduce the wrong behavior read-only*
or refute it → status CONFIRMED / SUSPECTED / REJECTED. **I then independently re-reproduced the top 4 HIGH
findings by my own hand** (shown inline) — all 4 confirmed.

**Tally: 30 CONFIRMED (7 HIGH · 15 MEDIUM · 8 LOW), 0 SUSPECTED, 3 REJECTED.** The 3 REJECTED were all
correct-by-design with a load-bearing honest label (listed at the end so the owner sees they were checked).

> **Reproduction caveat (this box):** the push-gate hooks were driven body-direct (`_PFG_WATCHDOG_CHILD=1`)
> — the exact code that runs *as* the watchdog child on a normal sub-second-spawn production host. On THIS
> Git-Bash box the full watchdog path times out at 8s and fails *closed* by the documented G17 spawn-tax
> artifact; that masks these fail-opens locally but they are real where the framework ships (the watchdog
> faithfully relays the child's exit-0/allow on a fast host). All non-push reproductions are direct.

---

# CONFIRMED — HIGH (7) — the next G1-class holes, ranked

### H1 · Force-push to a protected branch via `+`-refspec is silently AUTO-allowed
`hooks/pre-push-gate-check:578-582, 651-667, 712-719` · class 1 (fail-open) · **independently re-reproduced**
- **Why:** `HAS_FORCE` only matches `--force`/`-f`/`--force-with-lease`. A force-update written as
  `git push poc +main` (git's documented shorthand for refspec `+main:main`, a non-fast-forward rewrite of
  remote `main`) leaves `HAS_FORCE=false`, so the force-to-protected **HARD BLOCK never fires**. And
  `TARGET_BRANCH="${ARG_REFSPEC##*:}"` = `+main` (the `+` is never stripped) ≠ `main`, so the
  protected-branch **CONFIRM also never fires**. Net: classified **AUTO**, `permissionDecision:allow`.
- **Proof (my own /tmp repo, real hook, body-direct):**
  `git push poc +main` → **exit 0, `"permissionDecision":"allow"`**. Control `git push poc --force main`
  (same repo) → **exit 2, "BLOCKED: force-push … to protected branch 'main'."** The `+`-form is silently
  allowed where the `--force` form is hard-blocked. Variant: `+refs/heads/main` → also AUTO-allow;
  `+feature:main` → CONFIRM (the `+` is on the src side) but still NOT the BLOCK tier it must be.
- **Fix direction:** treat a leading `+` on any pushed refspec as a force signal (`HAS_FORCE=true`) AND
  strip a leading `+` from `ARG_REFSPEC`/`TARGET_BRANCH` before the protected-branch comparisons.

### H2 · `git -C <dir> push …` evades push detection entirely — fully ungated
`hooks/pre-push-gate-check:531-533` · class 1 (fail-open) · **independently re-reproduced**
- **Why:** the sole push detector requires the regex `…git\s+push` (git immediately followed by push). The
  idiomatic `git -C <dir> push …` has `-C <dir>` between them, so it does **not** match → the hook hits
  `exit 0` **before every guard** (forbidden-destination, force-to-protected, bare/wrong-remote/protected
  CONFIRM, and the evidence gate). The hook's own body uses `git -C` throughout — this is a natural agent
  form, not obfuscation.
- **Proof (my own /tmp repo, forbidden remote `poc`):**
  `git -C <dir> push --force poc main` → **exit 0, no output (fully ungated)**, even though `poc` is on
  `forbiddenRemotes` AND it's a force-push to `main`. Control `cd <dir> && git push poc --force main` →
  **exit 2, "BLOCKED: … FORBIDDEN destination 'poc'."** Regex check: `git -C . push …` → no match;
  `git push …` → match. Same miss for `git -c k=v push`, `(git push …)`, `{ git push …; }`.
- **Fix direction:** broaden the matcher to tolerate intervening global git options (`git`, optional
  `-C <path>`/`-c k=v`/`--git-dir=…` tokens, then `push`); add `(`/`{` to the prefix anchor set; parse
  `PFG_TARGET_CWD` from a `-C` arg too.

### H3 · Coupled-edit gate fails open on absolute / `./`-prefixed paths (the real Edit-tool path)
`hooks/coupled-edit-gate:117, 126-128` · class 1 (fail-open) · **independently re-reproduced**
- **Why:** group membership is decided by **exact-string equality** (only `\`→`/` normalization) of the
  incoming `file_path` against the stored group files. Claude Code's `tool_input.file_path` is **absolute**
  (the sibling `bootstrap-write-gate:72` states this and adds a relative-form fallback for exactly this
  reason); `active-groups.json` stores **repo-relative** paths (SKILL.md + the behavioral test). Absolute ≠
  relative → `UNACKED=0` → **exit 0 ALLOWED**. The basename grep fast-path (line 117) still matches the
  absolute path, so the gate *looks* active but its core comparator is defeated. The jq path AND the python
  fallback both fail open; only the no-jq-no-python grep last-resort would block.
- **Proof (my own /tmp, group with `acknowledged:false`):** relative `Services/TokenProvider.cs` → **exit 2
  BLOCKED**; absolute `<abs>/Services/TokenProvider.cs` → **exit 0 ALLOWED**; `./Services/TokenProvider.cs`
  → **exit 0 ALLOWED**. In a real run the implementer sub-agent edits via the actual Edit tool with an
  absolute path, so **every coupled-group block silently fails open.** The behavioral suite only feeds
  relative paths, so the green suite *masks* the defeat (false-green on the suite).
- **Fix direction:** compare on a canonicalized/relative-suffix form (resolve both sides to repo-relative,
  or basename + relative-suffix), not raw full-path equality.

### H4 · Coupled-edit gate fails open when a group omits the `acknowledged` field
`hooks/write-active-groups:19-37` (writer) → `hooks/coupled-edit-gate:126-128` (consumer) · class 1 · **independently re-reproduced**
- **Why:** `write-active-groups` validates only JSON well-formedness, **not** the group schema; a group
  missing `acknowledged` is written verbatim. The consumer counts unack groups with jq
  `select(.acknowledged == false)` — a missing field is jq `null`, and `null == false` is **false**, so the
  group isn't selected → `UNACKED=0` → **exit 0 ALLOWED**. (The grep fallback looks for the literal
  `"acknowledged": false` — also absent → same. Only the python fallback's `.get('acknowledged',False)`
  fails closed; jq is the live path.)
- **Proof (my own /tmp):** group `[{"files":["A.cs"],"findings":["x"]}]` (no `acknowledged`), edit `A.cs` →
  **exit 0 ALLOWED**. Same group with explicit `"acknowledged":false` → exit 2 BLOCKED. The fail-open is a
  single missing field on agent-authored state. No behavioral case covers missing-acknowledged (the suite
  jumps from wrong-shape to explicit-false).
- **Fix direction:** `write-active-groups` should validate per-element schema (object with `files[]` + a
  boolean `acknowledged`, defaulting missing → false); and/or the consumer's jq selector should treat
  missing/non-true as unacknowledged (`select(.acknowledged != true)`).

### H5 · Spec-integrity forge-catch is disabled by an empty (or empty-category) spec
`lib/spec-integrity-check.sh:110-131, 157-174, 191-208, 226-260` · class 1 (fail-open)
- **Why:** the source→spec forge-catch (the script's stated purpose: "an agent that strips a behavior from
  the spec to avoid a parity failure is caught") inner-guards each block on `[ -n "$SPEC_CODES" ]` /
  `SPEC_FIELDS` / `SPEC_PROCS` / `SPEC_ROUTES`. So when the migrated spec has **zero anchors of a category,
  the forge-catch for that category is SKIPPED** — the most aggressive forge (drop the whole category /
  emit an empty spec) is exactly the one that passes GREEN. A behavior that exists only in migrated source
  is invisible to parity-check (not in baseline → no MISSING), so spec-integrity is its *only* guard.
- **Proof (verifier, /tmp):** source emits `E0001`+`E9999`; spec `{"codes":["E0001"]}` → FAILED (catches
  E9999); spec `{}` → **PASSED exit 0**. Realistic: fully-populated spec with `result_codes:[]` against a
  source emitting `S0001`+`E9999` → **PASSED exit 0**. Runs as a CI gate (migrate SKILL.md:555) where
  exit-0 = pass.
- **Fix direction:** the source→spec direction must fire whenever SOURCE has anchors regardless of whether
  SPEC has any — drop the inner `[ -n "$SPEC_*" ]` guard (empty SPEC_* means "every source anchor is
  missing", not "skip").

### H6 · `preflight-eval-gate.sh` never applies the proposed rubric — always green
`tools/preflight-eval-gate.sh:32, 38, 98-126` · class 2 (false-green)
- **Why:** the tool's stated job is to test a *proposed* rubric change and auto-reject it if it drops the
  golden-task pass rate. But `--proposal <dir>` only sets `PROPOSAL_DIR` (line 38) which is **never read
  again** — no rubric/config swap, no `cd`, no copy. The golden tasks hardcode `REPO_ROOT` and invoke the
  **current** hooks. So a proposal that would break the rubric is scored against the live rubric and reports
  GREEN (exit 0); the "AUTO-REJECTED" branch can never fire on the proposal's own merits.
- **Proof (verifier, /tmp, real script logic):** a *broken* proposed-rubric dir + a golden task → "1/1
  passed (100%)", **exit 0 GREEN**; swapping the *live* hook to broken + a *good* proposal → "0% …
  AUTO-REJECTED" exit 1. Result tracks only the live hooks; `--proposal` has **zero effect** on what runs
  (`grep PROPOSAL_DIR` → assigned at 32/38, never read). Not auto-invoked by any shipped hook/skill (bounds
  blast radius to manual/pipeline use).
- **Fix direction:** actually stage `PROPOSAL_DIR` (run golden tasks against the proposed rubric/hooks,
  compare to a baseline run of the current rubric); validate `--baseline` is a bare integer before the
  numeric compare.

### H7 · `preflight-verify.sh` never content-checks a skill — tampered SKILL.md passes as intact
`tools/preflight-verify.sh:86-94, 144, 170` · class 2 (false-green)
- **Why:** skills are the framework's only invocable surface, yet verify only tests `[ -f SKILL.md ]` and
  prints OK — the manifest tree-SHA is **never compared**. A deleted SKILL.md is a non-blocking WARN that
  does **not** increment `DRIFT_COUNT`. So a tampered SKILL.md (arbitrary content), added/removed siblings,
  or a hollowed skill all pass with exit 0 and the false attestation "Integrity: PASS — all installed
  artifacts match manifest blobs." (agents + lib/hooks/examples/docs/defaults *do* get a hash compare;
  skills are the hole.)
- **Proof (verifier, /tmp consumer):** manifest `skills.migrate=<sha>` + SKILL.md = "TAMPERED CONTENT" →
  "OK: migrate/ … SKILL.md present", "Integrity: PASS", **exit 0**. `rm SKILL.md` + junk sibling → "WARN …
  missing", still "Integrity: PASS", **exit 0**. `EXPECTED_SHA` is only ever echoed, never the RHS of a
  compare.
- **Fix direction:** compute the installed skill subtree SHA (or per-file blob compare every tracked file);
  any mismatch/missing = DRIFT (exit 1); a missing SKILL.md must be DRIFT, not WARN.

---

# CONFIRMED — MEDIUM (15)

> Each verified-real with a read-only reproduction; blast radius bounded (limited reachability, a noisy
> failure rather than a silent one, or an internal-quality vs safety-accountability surface).

### M1 · `behavioral-contract-gate` header says "NOT registered / does not fire" but it IS live
`hooks/behavioral-contract-gate:4-10` vs `hooks/hooks.json:83-88` · class 6 (stale honesty label)
- The boxed header claims the gate is awaiting-owner, prompt-level, not wired — but commit `611a6e0`
  registered it under the `Agent|Task` matcher and it ships live (install reads hooks.json as the single
  source). Reproduced: a spec-analyst spawn with no `## Behavioral Contract` → **exit 2 BLOCKED**. The
  enforcement is correct (fails closed); the defect is purely a stale in-file honesty label that misleads
  an auditor about whether the guard is mechanical. (The canonical `docs/parity-gate-limitations.md` is
  already reconciled — blast radius is the comment.) **Fix:** replace the header box with "LIVE — registered
  in hooks.json under Agent|Task (611a6e0)".

### M2 · Adjudication "citation" check passes on an incidental `word:digit` token in prose
`hooks/adjudication-output-gate:135, 153-159` · class 2 (false-green)
- The `CITES` regex `\.[A-Za-z0-9]+:[0-9]+|§[0-9]+|…` is `.test()`-ed against the whole string, so a DEFENDED
  verdict whose `citedEvidence` is bare prose containing a version (`v1.2:3`), ratio (`2.5:1`), or timestamp
  (`2024.10:00`) satisfies the "concrete citation required" check with no real file:line. Reproduced
  end-to-end: `"…same 2.5:1 retry ratio…"` → **gate exit 0 (write allowed)**; genuine pure prose
  ("verified manually") → exit 2. Makes an evidence-less DEFENDED representable. **Fix:** anchor the
  file:line form to a real source-extension list and/or require the citation to be the dominant token.

### M3 · Dependency-map validator reports FRESH (and re-stamps) on empty/incomplete `mapFiles`
`hooks/dependency-map-validator:53-56, 74-93` · class 2 (false-green)
- When `mapFiles` is empty/missing/incomplete, the `comm -12` overlap can never fire, so the hook declares
  FRESH (exit 0) **and re-stamps `validAtHEAD` to current HEAD** — making the staleness permanent (every
  future HEAD move re-stamps fresh). An incomplete `mapFiles` omitting the file that actually changed is the
  exact miss the mechanism exists to catch. Reproduced: empty/`[]`/incomplete `mapFiles` → FRESH exit 0 +
  re-stamp; correct single-entry list → STALE exit 1; bad JSON → STALE exit 1 (so the hole is specific to
  empty/incomplete). **Fix:** empty/missing `mapFiles` → non-validatable → STALE (exit 1), do not re-stamp.

### M4 · Spec-integrity reports PASS when the source dir has zero `.cs` files
`lib/spec-integrity-check.sh:78, 147, 185, 220` · class 5 (silent-absence)
- All anchor extraction is gated on `find … -name '*.cs' -print -quit | grep -q .`. A source dir that exists
  but holds no `.cs` (wrong/mistyped-but-real path, partial/shallow checkout, non-.NET target) → all SOURCE_*
  empty → both directions skipped → "PASSED (all mechanical anchors consistent)" exit 0. "Nothing to compare"
  reads as "verified". Reproduced: same spec → real `.cs` source FAILS correctly; empty dir PASSES exit 0;
  a fully-nonexistent path is the only guarded case (exit 2). **Fix:** when SPEC declares anchors but the
  source scan finds zero `.cs`, emit a distinct could-not-verify FAIL, never PASS.

### M5 · `rubric-source-check --added` swallows git failure → reports CLEAN
`lib/rubric-source-check.sh:70-76` · class 1 (fail-open)
- In `--added` mode the file list is `git diff … 2>/dev/null | grep … || true`; the `2>/dev/null` + `|| true`
  swallow any git failure (bad base-ref, non-repo, shallow clone, detached) → empty list → "no changed rubric
  files … (CLEAN)" exit 0. Reproduced: non-git dir and bad base-ref both → CLEAN exit 0 while raw git exits
  128/129. **No live caller today** (CI uses `files` mode, which fails closed), but `--added` is the
  documented future-promotion-to-blocking path — promoting per the docs would arm a broken check green on any
  shallow/detached CI runner. **Fix:** capture git's real `$?` before the pipe; on git failure exit 2 (a
  could-not-run error), distinguishing "git failed" from "diff empty".

### M6 · Parity-check reports CLEAN on a wrong-keyed or zero-behavior baseline
`lib/parity-check.sh:134, 144, 240-251` · class 2 (false-green)
- `base_map`/`curr_map` come from `.get("behaviors", [])`. A baseline that parses fine but stores its array
  under a typo'd/different key (`behaviour`, any non-`behaviors` schema), or an empty `{}`/`{"behaviors":[]}`,
  yields an empty map → `blocking_count=0` → verdict CLEAN exit 0. The drift verdict (exit 2) and clean
  verdict (exit 0) share the empty-map path. Reproduced: typo'd baseline holding 2 real behaviors vs a
  current that dropped+changed one → **CLEAN exit 0** (the blocking drift masked as informational). A *type*
  error fails closed (exit 3) but a missing/renamed key fails OPEN. The `behaviors` key is only
  prompt-enforced (spec-analyst self-check); no mechanical schema gate exists upstream. **Fix:** require the
  top-level `behaviors` key present and a list; absent/both-empty-when-a-file-is-nontrivial → exit 3.

### M7 · Spec-integrity false-FAILs on a `public class Foo {` (K&R brace) line
`lib/spec-integrity-check.sh:150-152, 167-174` · class 2 (false direction — over-block)
- The MODEL_FIELDS regex matches `public class TokenResponse {` (treating `class` as the type token,
  `TokenResponse` as a "field") and then flags `TokenResponse` as a property MISSING from the spec ("possible
  forge"). This is fail-*closed* (a spurious FAIL, not a pass) but it **deterministically blocks a legitimate
  migration PR** (CI RED) for any `*Response*.cs`/`*Model*.cs` using same-line braces — eroding trust and
  pressuring a bypass. Reproduced: a fully-honest spec with all real fields still FAILS purely on the class
  name. (Allman brace style doesn't trip it; the framework's own generation spec uses Allman — bounds
  real-world blast radius.) **Fix:** negative-match `public\s+(class|interface|struct|enum|record)\b` before
  capturing field names.

### M8 · `detector.sh` exits 0 on a failed state-file write
`lib/detector.sh:199-201` · class 2 (false-green)
- `generate_json > "$OUT.tmp" && mv …` then unconditional `exit 0`. Under `set -euo pipefail` (no aborting
  `&&`-left-operand), a failed write continues to `exit 0` while leaving a **stale** prior state.json in
  place — violating the docstring's "exit 0 on success, exit 1 on critical failure". Reproduced: redirect
  target made a directory → "Is a directory" on stderr, **exit 0**, no state written, stale file retained.
  (Consumer is the prompt-level bootstrap skill, bounding blast radius.) **Fix:** capture the `&&` chain
  status and exit 1 on failure.

### M9 · `--check-blob-syntax` is blind to the `N|` corruption it exists to catch (for minimal scripts)
`lib/pre-branch-cut-check.sh:58-93` · class 2 (false-green, latent)
- The gate validates each shipped blob with `git show HEAD:$f | bash -n` — grammar only. A blob line-prefixed
  `1|#!/usr/bin/env bash`, `2|…` parses as valid bash (`1` is a command piped into a comment), so `bash -n`
  returns 0 and the gate prints "all shipped executables pass" exit 0 — the precise `N|` corruption it was
  built (commit `1515b29`) to catch. **Today the blast radius is empty:** the *real* `c0e01a4` blobs ARE
  caught (multi-line control flow orphans the prefix → exit 2), and a full scan of all ~47 currently-shipped
  executables found zero slip-throughs. But the gate's effectiveness rests on an unenforced empirical
  invariant ("every shipped script has control flow `bash -n` chokes on"); the gate's own test C9 fixture
  comment documents this exact gap. One future minimal control-flow-free shipped script reopens it. **Fix:**
  add a structural check (head-1 is a clean shebang and/or scan for `^[0-9]+\|`), don't rely on `bash -n`.

### M10 · `generate-wire-golden-test.sh` emits an assertion-less test (exit 0) on a `|` in sample/golden
`lib/generate-wire-golden-test.sh:157, 186` · class 2 (false-green)
- Per-case substitution uses `sed -e "s|{{SAMPLE}}|$SAMPLE|g"`; a `|` in a sample/golden value (enum flags
  `"Read|Write"`, delimited IDs) breaks the `s|…|` expression, sed emits nothing for that case (swallowed
  under `set -uo pipefail`, no `-e`), and the generated `.cs` gets the case scaffold **without** the
  serialize/compare body — yet the generator prints "Generated … N case(s)." exit 0. Reproduced: flags value
  → `sed: unknown option to 's'`, "Generated … 1 case(s)." exit 0, `grep string.Equals` = 0; multi-case →
  claims 2 wired, 1 assertion-less. (The broken `.cs` fails to *compile* downstream, bounding it to a noisy
  failure — but the generator's own contract says exit 2 on a problem.) **Fix:** check `${PIPESTATUS[*]}`
  after the sed pipeline and exit 2; or substitute placeholders delimiter-safely.

### M11 · `preflight-verify.sh` reports PASS on an empty/null/missing-`artifacts` manifest
`tools/preflight-verify.sh:41-67, 100-131, 134-144` · class 5 (silent-absence)
- Drift detection is a loop over manifest keys with no lower-bound assertion. An all-empty `artifacts.*={}`
  (truncated/partial manifest) → `CHECKED_COUNT=0`, `DRIFT_COUNT=0` → "Integrity: PASS" exit 0 even with
  **zero framework files on disk**. An `artifacts.agents=null` makes the un-guarded `to_entries[]` jq-error
  inside a process substitution (set -e can't abort) → iterate nothing → same PASS. Reproduced all three
  (empty, null-surface, missing-artifacts-key-with-a-real-file-present) → PASS exit 0. "Nothing checked" =
  "everything matched". (Requires a degenerate manifest — bounds it.) **Fix:** assert `CHECKED_COUNT>0` and
  per-known-surface non-empty; treat a null/non-object `artifacts` as FAIL.

### M12 · `preflight-selftest.sh` reports SKIP+green on a deleted/renamed shipping gate
`tools/preflight-selftest.sh:31-36, 119-130` · class 5 (silent-absence + overstated self-description)
- The tool advertises catching the "registered-but-dead" gate, but `test_gate` treats a **missing** hook
  file as SKIP (not DEAD/FAIL); SKIP doesn't increment FAIL, so a deleted/renamed/pruned gate → SKIP, exit 0
  green. Its sibling `preflight-selfcheck.sh` correctly reports a missing hook as DEAD exit 1 — selftest
  diverges. `LESSON-ADJUDICATION.md:51` cites selftest's central coverage to justify rejecting per-gate
  tests, so the overstatement is load-bearing. (The deleted-gate class IS caught by registration-check +
  selfcheck if run — bounds blast radius.) **Fix:** treat a missing hook file as DEAD/FAIL; reserve SKIP for
  genuinely-optional hooks.

### M13 · Coupling "mechanical enforcement" is Edit-only — Write/Bash mutations to coupled files are ungated
`skills/fix-and-close/SKILL.md:131-135` + `hooks/hooks.json:34-73` · class 4 (overstated mechanism)
- SKILL.md says writing active groups "activates the coupled-edit-gate … the mechanical enforcement of
  read-ALL-before-fixing-ANY", but `coupled-edit-gate` is registered **only under the `Edit` matcher**. A
  whole-file `Write`, or a `sed -i`/`>`/`tee` via Bash, to a coupled file is never passed to the gate. The
  implementer sub-agent's tools include Write and Bash — exactly how a large coupled fix mutates files.
  Reproduced: the gate WOULD block a Write if invoked (exit 2) — so the gap is the registration, not the
  logic; and `grep` confirms it's registered only under Edit. This is the `Write|Edit` matcher-robustness
  class CLAUDE.md's Conventions warn about. (Process-quality guard, fail-open by design without a groups
  file — bounds it below safety-gate severity.) **Fix:** register under a `Write|Edit` matcher (consider a
  Bash-seam guard); or relabel as Edit-tool-only and drop "mechanical enforcement".

### M14 · fix-and-close "Artifact rejection gate (pre-commit)" is prose, not a hook
`skills/fix-and-close/SKILL.md:176-182` · class 4 (overstated mechanism)
- Described with hook-grade language ("the commit is BLOCKED", "the gate fires BEFORE the commit") but it's a
  shell snippet the agent runs in its own session — the `exit 1` only exits that subshell. **No PreToolUse
  Bash hook intercepts `git commit`** (the only Bash-matcher hook is pre-push-gate-check, which guards push).
  Reproduced: the snippet printed "BLOCKED: artifact staged" and exited the subshell 1, then the very next
  `git commit` **succeeded** with the artifact committed. The sibling migrate skill has an explicit "A note
  on enforcement" honesty label; fix-and-close has none here. (Harm ceiling = a committed build artifact —
  recoverable — bounds it.) **Fix:** add a prompt-level honesty label, or wire a real `git commit` PreToolUse
  Bash hook.

### M15 · migrate Check-3 silently passes a genuinely-missing short-named REACHABLE proc
`skills/migrate/SKILL.md:810-880` · class 5 (silent-absence)
- Check 3 (spec-vs-implementation fidelity) does `[ ${#PROC} -lt 5 ] && continue` — silently dropping any
  contracted identifier shorter than 5 chars from the existence check, so a genuinely-absent short-named
  REACHABLE proc (`usp`, `sp_x`, `cp`) → "CHECK 3 PASS: all REACHABLE identifiers found verbatim". (It also
  over-flags chain words as phantom MISSING — the safe direction.) Reproduced both: a 3-char `usp` absent
  from the source → "[skip <5 chars]" → CHECK 3 PASS. The `<5` guard exists only in the proc loop, not the
  param loop — an unjustified asymmetric filter contradicting the "byte-for-byte fidelity" claim. **Fix:**
  extract proc/param names from a structured single column; drop/justify the `<5`-char skip.

---

# CONFIRMED — LOW (8)

> Robustness/quality gaps; real and reproduced, but advisory-only, trusted-input-gated, or self-correcting.

- **L1 · Parity gate skipped if a behavior-spec is nested deeper than depth 3.** `hooks/pre-push-gate:118-125`
  — `find -maxdepth 3` misses a depth-4 baseline → BASELINE_FOUND empty → parity requirement silently
  skipped (push allowed with no parity-clean). Reproduced (depth-4 → exit 0; canonical depth-3 → exit 2). **No
  framework code ever writes the depth-4 layout** (every writer uses the canonical depth-3 path) — empty
  blast radius. **Fix:** derive the spec path from config, or drop/raise `-maxdepth`.
- **L2 · bootstrap-write-gate coverage uses `grep -F` substring match.** `:187-195` — a sentinel approving
  `CLAUDE.md.backup` also clears an overwrite of the real `CLAUDE.md` (substring). Reproduced. Gated behind
  trusted human-minted sentinel + fixed 2-literal PROTECTED_NAME — LOW. **Fix:** exact line/basename equality.
- **L3 · adjudication-output-gate validator is node-only despite "node fallback" label.** `:50-56, 163-167` —
  on a jq-only/node-less host every adjudication write is hard-blocked (RC 127→exit 2). Fail-*closed* (safe
  direction) but a mislabeled robustness gap. Reproduced. **Fix:** add a jq/python schema walk, or relabel
  node as required.
- **L4 · write-group-ack jq branch corrupts on out-of-range index.** `:28-44` — `jq '.[$idx].acknowledged=true'`
  null-pads + appends a phantom group for an OOB index → "Group N acknowledged" exit 0 (false success +
  corrupted state); the python branch correctly raises IndexError. Reproduced. **Not** a coupling bypass
  (real groups stay unacked) — LOW. **Fix:** bounds-check the jq branch.
- **L5 · drift-detector silently overwrites the baseline when no parser is available.** `:213-234` — jq absent
  + python failing → no drift reported AND baseline overwritten (sticky loss). Reproduced. Advisory-only hook
  (never blocks) — LOW. **Fix:** emit a "baseline lost" advisory instead of silent overwrite.
- **L6 · session-start gate-liveness probe no-ops when jq is absent.** `:107-122` — the dead-but-registered
  probe is wholly nested under `if command -v jq` with no else; jq absent → no liveness warning, byte-
  indistinguishable from "all gates alive". Reproduced. Advisory-only — LOW. **Fix:** emit a "liveness
  UNVERIFIED (jq missing)" caveat.
- **L7 · wire-golden accepts an empty-string `golden`.** `lib/generate-wire-golden-test.sh:81-85` — jq
  truthiness treats `"golden":""` as present, so the required-field check passes and a test comparing against
  `@""` is generated + "Generated … case(s)" exit 0 (missing/null golden are correctly rejected). Reproduced.
  Self-correcting (the test fails loudly at runtime) — LOW. **Fix:** `select((.golden|type=="string" and
  length>0)|not)`, and apply the same to name/type.
- **L8 · resolve-review-thread trusts a default-true `_RRT_RESOLUTION_AVAILABLE`.** `:28, 196-220` — the only
  in-lib guard before a thread-mutation defaults open; the auth precondition is prompt-level only. A sub-agent
  that sources the lib and skips `check_auth` mutates with the flag still true. Reproduced — BUT it degrades
  *closed* (an actually-unauthorized mutation 403s → exit 2 → skip), so no unauthorized mutation succeeds —
  LOW. **Fix:** default the flag false/unknown; require a successful check_auth to flip it.

---

# SUSPECTED (unverified)

**None.** Every candidate the readers surfaced was either reproduced (CONFIRMED) or refuted (REJECTED). The
verifiers reproduced the wrong behavior read-only in all 30 confirmed cases rather than reasoning about it.

---

# REJECTED (checked, found correct-by-design with a load-bearing honest label)

These were investigated and **dismissed** — listed so the owner sees they were considered, not missed:

- **`write-gate-evidence` has no actor check (agent can mint `parity-clean`).** REJECTED: the mechanical
  facts reproduce (variable-indirected `write-gate-evidence "$GATE"` evades the tripwire; the writer has no
  actor check), but this is **explicitly documented** — `write-gate-evidence:8-10` ("enforces NO actor check
  — the restriction is prompt-level"), `docs/parity-gate-limitations.md:23-29,50-51` states the variable
  bypass *verbatim*, the tripwire is labeled HEURISTIC, and blast radius is bounded (`gate/` is gitignored so
  a minted clearance never reaches CI; the mechanical ceiling is server-side branch protection). A documented
  boundary, not a hidden fail-open.
- **`rubric-resolve.sh` is unwired.** REJECTED as a *bug*: factually unwired (no live/CI caller — confirmed),
  but it carries a prominent STAGED-NOT-WIRED banner + owner WIRE-HERE TODO, no consumer-facing overstatement
  (README/FRAMEWORK.md never claim layered rubrics are live), and the standalone tool is correct (fail-closed
  on a weakening overlay). Disclosed staging, not a silent gap. *(See the unwired inventory below.)*
- **`preflight-agent-scorer.sh` re-judges trusting agent-recorded evidence.** REJECTED: the mechanism
  reproduces (it scores against the agent's recorded `checkEvidence` prose, never re-executes the command),
  but it exits only 0/2, writes only to `track-record/` (never a gate, never `.preflight/gate/`), is not
  registered in hooks.json, no hook reads its output, and the weakness is explicitly labeled in code + the
  on-screen honesty label ("judgment-vs-judgment, NOT judgment-vs-reality; NEVER feeds a gate"). A labeled
  observer, not a trusted gate.

---

# UNWIRED-MECHANISM INVENTORY (class 6)

Callers searched across `skills/ agents/ hooks/ tools/` (live flow) + `.github/` (CI) + `tests/`:

| Lib | Live (skill/hook) | CI | Tests | Status |
|---|---|---|---|---|
| `lib/spec-divergence.sh` | ✅ migrate, scaffold (prompt-level) | — | ✅ | **WIRED** (prompt-level, advisory) |
| `lib/source-of-truth-check.sh` | ✅ migrate, spec-analyst (prompt-level) | — | ✅ | **WIRED** (prompt-level) |
| `lib/rubric-promotion-evaluator.sh` | ✅ 4 callers | — | — | **WIRED** |
| `lib/coverage-gap-detect.sh` | ❌ none | ❌ | ✅ | **UNWIRED** — built+tested, no live/CI caller |
| `lib/capture-finding.sh` | ❌ none | ❌ | ✅ | **UNWIRED** — built+tested, no live/CI caller |
| `lib/rubric-overlay-check.sh` | ❌ none | ✅ CI (advisory) | ✅ | **CI-only** (framework-self, not shipped, not skill-wired) |
| `lib/rubric-source-check.sh` | ❌ none | ✅ CI (advisory) | ✅ | **CI-only** (framework-self, not shipped) |
| `lib/rubric-resolve.sh` | ❌ none | ❌ (in path-filter, never invoked) | ✅ | **UNWIRED** — STAGED-NOT-WIRED (labeled, see REJECTED) |

**The load-bearing gap: `coverage-gap-detect.sh` + `capture-finding.sh` are genuinely unwired.** The
session built the self-learning coverage-gap loop (Layer 1 source-agnostic capture + Layer 2 mechanical gap
classification) and proved it with tests, but **no skill or agent invokes it** — `fix-and-close` and
`external-review-handler` (the adjudication points where a post-merge defect would be captured) contain zero
references to either. The mechanism exists and passes its tests but never runs in any live flow: a
built-but-never-invoked guard is a silent gap (class 6). This is the prompt-level wiring noted as
outstanding in the session's own records — surfaced here as a concrete, owner-triageable item.

The three rubric-governance libs are **CI-wired (advisory) but not shipped to consumers and not skill-wired**
— consistent with their "STAGED, not wired" commit labels; this is disclosed staging, not an accidental gap.

---

# HONEST SUMMARY

**7 HIGH-severity fail-opens / false-greens confirmed and reproduced**, of which I independently re-reproduced
the top 4 by my own hand. **The dominant bug class is class 1 (fail-open) — the same class the self-review
just fixed in 6 files — now found across the push gate, the coupling gate, and spec-integrity.** The single
**riskiest finding is H2** (`git -C <dir> push` evades push detection *entirely* — fully ungated, every guard
bypassed including the forbidden-prod-remote BLOCK), narrowly ahead of **H1** (force-to-protected via
`+`-refspec silently AUTO-allowed) and **H3** (the flagship coupling gate fails open on the *absolute* paths
the real Edit tool actually sends — defeated on the live path while the green test suite, which only feeds
relative paths, masks it). The recurring root pattern is **surface-syntax / shape variance defeating a
string-exact mechanical check**: an equivalent way to express the same operation (`+ref` vs `--force`, `git -C`
vs `cd &&`, absolute vs relative path, missing-vs-explicit field, typo'd-vs-canonical key) slips past a
matcher/comparator that was only hardened for one surface form. Two structural false-greens compound it
(H6: eval-gate never applies the proposal; H7: verify never content-checks a skill — the only invocable
surface). **All findings are reported, not fixed — read-only, nothing changed, nothing committed,** v0.9.0
untouched at `1651ecc`. The owner should triage HIGH→LOW; H1–H4 are the next supervised-fix batch (mirroring
the 5 fail-opens already closed this session), each with a clear one-line fix direction above.

# Gate-4 Live Incident — shell line-continuation parser fail-open (PR #12)

Authoritative record of the live Gate-4 acceptance failure, its two root causes, the fix, and the
corrected network-safe probe design. No credentials/tokens included; legacy-repo content limited to what
the incident requires.

## UPDATE — second live run (runtime af49b18): 23-second deadline timeout (not a clean denylist block)

After the continuation-parser fix, the live candidate
`PATH="…/preflight-gate4-shim:$PATH" git \<LF> push origin HEAD:refs/heads/preflight-live-probe`
was BLOCKED — but via *"pre-push-gate-engine did not reach a decision within its 23s candidate deadline
(rc=124)"*, with the shim marker ABSENT (so the represented command never executed: safe containment). This
proved the continuation fix WORKS (the push was detected + routed), but the engine did **not** reach the
explicit forbidden-remote policy decision within the router's 23s candidate deadline on the real
Windows/Git-Bash host — so the live test did not prove the denylist BLOCK path under that host.

**Root cause (the 23s timeout):** the engine performed expensive work BEFORE the forbidden-remote decision.
Stage timing (PREFLIGHT_ENGINE_TIMING=1, real host) showed the forbidden-`origin` decision landing at
~17.8s, dominated by: heartbeat+overlay sourcing (~3.3s), command extraction (jq), continuation-join (awk)
+ structural parse (greps/seds), then `_pfg_config`'s `git rev-parse` (~2.5s) + a `forbiddenRemotes` jq read
(~2.6s) — and the original B0 forbidden check additionally did `git remote get-url` before deciding. On the
live host (slower still) this brushed/exceeded the 23s deadline.

**Fix — early forbidden-remote NAME fast block:** immediately after structural parse (and before the
gh-pr-create path, B0's `git remote get-url`, config base/remote resolution, protected-branch eval, and the
evidence gate), if the parsed EXPLICIT remote name is on `branch.forbiddenRemotes`, emit the explicit
forbidden-destination diagnostic and `exit 2`. It uses a PURE-SHELL upward FS walk to find
`.preflight/config.json` (NO `git rev-parse`) + one bounded `jq` read of `forbiddenRemotes`. No `git remote
get-url`, no slug resolution, no canonical lookup, no gh, no evidence gate, no network. This cut the
real-host decision from ~17.8s to ~13.7s and, critically, moved it BEFORE the two most expensive stages
(evidence gate + remote-url), proven by markers in the test. The later B0 `forbiddenRepos` (slug/URL) check
is preserved for `git push <url>` and remotes reached under a different name; safe-remote, implicit-remote
(no named remote), unresolved/indirection, protected-branch, sentinel, and PR-create handling are all
unchanged.

**Honest residual (slow-host ceiling):** under an artificial +1s/spawn stress profile the decision still
takes ~44s, because the structural parser's necessary spawns (the security-detection greps/seds) alone
exceed any sub-23s budget on a pathologically slow host. On such a host the candidate still BLOCKS (the
router deadline-blocks — the SAFE direction), it just won't carry the precise FORBIDDEN reason. The early
block buys substantial margin on a real-host-representative speed; it does not (and cannot, without
weakening the parser) guarantee sub-23s on an arbitrarily slow host. Diagnostic stage-timing
(`PREFLIGHT_ENGINE_TIMING`) ships DISABLED by default (no-op when unset).

## Ordering-review correction — overlay sourcing is NOT a prerequisite for the early forbidden-remote decision

The earlier ordering review left an inaccurate impression that the engine's init-time overlay sourcing is
part of the pre-decision critical path. Corrected, with the mechanism stated precisely:

- **The early forbidden-remote decision does not consume the overlay at all.** It reads
  `branch.forbiddenRemotes` *directly* from the committed `.preflight/config.json` (the pure-shell FS-walk
  result `_EB_CFG`), not via `overlay_resolve`. This is correct by policy, not by accident:
  `lib/config-overlay.sh`'s `_OVERLAY_ALLOWLIST` is exactly
  `branch.remote branch.base branch.migrationPrefix migration.legacyRepoPath migration.servicesRoot migration.referenceService`
  — `branch.forbiddenRemotes`/`branch.forbiddenRepos` are **not** on it, and `_overlay_read` returns empty
  for arrays/objects anyway. So a `config.local.json` can never override (loosen) a forbidden list; the
  forbidden lists are committed-config-only by construction. Overlay policy therefore cannot affect the
  forbidden-remote decision, and sourcing it is logically unnecessary for that decision.
- **Is overlay sourcing merely initialized early, or does it materially add latency?** *Merely initialized
  early, and it does NOT materially add latency.* Sourcing `lib/config-overlay.sh` is **pure function
  definitions** — `overlay_key_allowed`/`_overlay_read`/`overlay_resolve` are defined but **not invoked** at
  source time, so the source step runs **zero git/jq spawns**. Measured on this Windows/Git-Bash host
  (N=5 avg): sourcing `config-overlay.sh` ≈ **185 ms**, sourcing `heartbeat.sh` ≈ **160 ms** — both are
  bash-parse cost, no subprocess. For contrast a single `git rev-parse HEAD` spawn ≈ **1,072 ms** on this
  host. So overlay sourcing is ~0.2 s of parse overhead, not a spawn-tax contributor.
- **The init-time spawn that DOES cost is `_write_heartbeat`, not overlay sourcing.** `_write_heartbeat`
  (`lib/heartbeat.sh:19`) spawns `git rev-parse HEAD` + `date` — but only when `.preflight/gate/` exists
  (it `return 0`s early otherwise). In the real consumer cwd that directory exists, so init pays ~1 s there;
  this shows up in the stage timing as part of the `engine-start → heartbeat+overlay-sourced` interval
  (~2.6–3.2 s on this host, the bulk of which is that one git spawn plus bash startup, NOT the overlay).
- **Disposition (no code change made on this ground):** overlay sourcing is cheap (no spawn) and the early
  decision already bypasses it, so there is nothing to move for *latency*. It is retained at init because
  later non-early paths (the full policy path's `branch.base`/`branch.remote` resolution) legitimately use
  the overlay functions. Reordering it would buy ~0 ms and risk the later paths. Per the promotion
  directive, **no additional code change was made for the ordering review** — see the stability-gate result
  below for why the promotion nonetheless halted.

## PHASE 0 — latency stability sample (committed 22d165a, this Windows host) — STABILITY GATE FAILED

10 consecutive serial runs of the EXACT live continuation-shaped candidate
(`PATH="…/preflight-gate4-shim:$PATH" git \<LF> push origin HEAD:…`) driven as crafted tool JSON through the
**full router→engine path** (no Git transport; nothing executed). Decision class was perfect; the latency
gate was not met:

| metric | required | observed |
|---|---|---|
| explicit forbidden-`origin` blocks | 10/10 | **10/10 ✅** |
| timeout / rc=124 results | 0 | **0 ✅** |
| every run rc=2 | yes | **yes ✅** |
| **max elapsed** | **< 20 s** | **25.47 s ✗** |
| **p95** | **< 18 s** | **25.47 s ✗** |
| median | (report) | 19.66 s |
| min / mean | (report) | 16.33 s / 20.09 s |

Per-run wall (s): 17.37, 22.39, 22.21, 25.47, 16.87, 23.58, 20.40, 17.36, 16.33, 18.92 — all rc=2, all
identified `origin` as forbidden, none a timeout. **Decision correctness is solid (10/10, 0 timeouts); the
problem is wall-time variance: 4/10 runs exceeded 20 s and p95/max are ~25.5 s, above the < 20 s max and
< 18 s p95 targets.** The variance is the host's per-spawn scan tax (~1–1.5 s/process, jittery) stacking
across the ~6 pre-decision spawns (bash start, heartbeat `git rev-parse`, jq extraction, awk join, parse
greps/seds, the one `forbiddenRemotes` jq). The candidate is always safely BLOCKED — but not with the
margin the promotion gate requires.

**Decision: STOP. The promotion is halted at Phase 0** per the directive "Stop without pushing if these
conditions fail." No source push (Phase A), no consumer install (Phase B), and no live instructions
(Phase C) were performed. The committed fix is behaviorally correct and a meaningful latency improvement
over af49b18 (which decided at ~31–34 s, past the deadline), but it does not yet clear the < 20 s max /
< 18 s p95 stability bar on this host. Closing the remaining margin needs a further latency reduction
(e.g. removing/most-deferring the init-time `git rev-parse` heartbeat spawn on the candidate path, or
collapsing pre-decision spawns) — a NEW code change, which this directive explicitly disallowed unless the
stability criteria failed. They failed; the next step is that targeted reduction, then a re-sample, in a
follow-up authorized by the user.

## Exact failed command

Run live through Claude Code's Bash tool during Gate-4 acceptance:

```
git -c remote.origin.url=file:///__preflight_no_network_probe__ \
  push origin HEAD:refs/heads/preflight-live-probe
```

It was expected to be **blocked** by the Preflight push gate. **It was not blocked.**

## Exact observed remote write

Git reached the **configured** `origin` destination (the legacy production repo) and **created the remote
branch `preflight-live-probe`** there, *before* later failing against the `file://` URL. The accidental
remote branch was subsequently **deleted by the owner** (confirmed). No other remote write occurred.

## Root cause 1 — engine structural-parser fail-open (security-significant)

- The fast router correctly classified the command as a **candidate** (raw tool JSON contained `push`).
- The heavy engine's structural parser `_pfg_parse_push()` segments the command by reading its normalized
  form **line by line** (`while IFS= read -r seg`). A shell line-continuation (`\` + LF, or `\` + CRLF) is
  ONE logical command to the shell, but the line-by-line read split it into two segments:
  - `git -c remote.origin.url=file:///… \`  → has `git`, **no** `push`
  - `push origin HEAD:refs/heads/…`         → has `push`, **no** `git`
- Neither segment is a `git…push`, so `_PFG_IS_PUSH` stayed **0** → the engine returned **allow**.
- Result: a real push command was waved through ungated.

**Fix (narrow, documented):** `_pfg_parse_push()` now **normalizes shell line-continuations** (`\`+LF and
`\`+CRLF, plus following horizontal whitespace) into a single logical line **before** structural
segmentation, using a one-pass `awk` slurp (`RS="\034"; gsub(/\\\r?\n[ \t]*/," ")`) — `awk` is already a
core engine dependency and avoids the backslash-quoting fragility of a line-by-line `sed`. The join is
**narrow**: it only removes a backslash immediately followed by an (optional CR +) LF; any other backslash
(Windows paths, escaped chars) is untouched. A **fail-closed backstop** then runs: if no push was detected
but the ORIGINAL command carried a `\`+newline AND a best-effort join reveals an ordered `git…push` token
sequence, the push is classed **PRESENT-but-UNRESOLVED → CONFIRM** (never a silent allow), covering the
case where `awk` is unavailable or the continuation is exotic. Over-detection can only escalate to
CONFIRM/fail-closed; it can never reintroduce a fail-open.

**RED→GREEN proof:** `tests/behavioral/pre-push-continuation-failopen-test.sh` — pre-fix, all 8
continuation push forms (incl. the exact incident shape) returned RC=0 (allow); post-fix all 8 BLOCK
(exit 2, FORBIDDEN), and 3 no-false-positive cases (benign multiline, `push` only inside a string,
safe-remote push) remain correctly allowed. `tests/behavioral/pre-push-live-incident-shape-test.sh` proves
the full router→engine path on the exact shape: router→candidate, engine→exit 2, exactly one block, no
execution.

## Root cause 2 — invalid no-network test design

`git -c remote.origin.url=file://…` was wrongly assumed to **replace** all push destinations. The live
output proves the configured HTTPS destination remained active while Git *also* attempted the file URL. A
command-line `remote.<name>.url` (or `pushurl`, credential, or remote-mutation) override **must never again
be treated as network containment** for a push probe.

## Containment + branch-deletion confirmation

- The accidental remote branch `preflight-live-probe` on the legacy repo was **deleted by the owner**
  (confirmed authoritative).
- This corrective work performed **no** CPSL operation (no contact/fetch/push/delete/remote-change).

## Why the new PATH-shim design is mechanically network-safe

`tests/behavioral/lib/preflight-git-execution-shim.sh` contains containment at the **execution layer**, not
the git-config layer: it is installed as an executable named `git` in a temp dir prepended to `PATH`. When
any caller runs `git … push …`, the shim is what executes — it prints `PREFLIGHT_EXECUTION_SHIM_BLOCKED`
and exits nonzero **without ever invoking the real git for a push**, so no transport / remote / network is
possible regardless of any URL or remote config. Non-push git commands are forwarded to the real git
(resolved by absolute path, excluding the shim's own dir, so it never recurses or forwards a push).

**Acceptance semantics:** a passing gate blocks the push **before** execution, so the shim marker must be
**ABSENT** on a passing live run. If the marker **appears**, the gate failed open — but the shim prevented
network access; a shim interception is a **safe failure, not a pass**. Live candidate shape:
`PATH=<shimdir>:$PATH git push origin HEAD:refs/heads/preflight-live-probe`. The shim uses **only** the
execution layer — no `remote.<name>.url`, `pushurl`, credential change, remote mutation, or network
destination as the containment mechanism.

## Audit of "safe push probe" mechanisms (repo-wide)

A repo-wide audit found **no executed script or runbook** relying on `git -c remote.<name>.url=…` for
containment; the unsafe pattern appeared only in the (now-superseded) live-acceptance instructions. The
only in-repo occurrences are as **non-executed strings fed to the engine parser** in the new continuation
test. Documented rule (here and in the PATH-shim header): **`git -c remote.<name>.url=…` does NOT guarantee
replacement or suppression of all configured push destinations and must not be used as network containment.**

## Remaining limitations

- The structural parser remains a **lexical** analyzer; a push assembled by runtime string-building
  (`p=push; git $p`) or full obfuscation still rides the documented eval/indirection → CONFIRM fail-closed
  path, not a precise block. Unchanged enforcement ceiling (see `docs/parity-gate-limitations.md`).
- Continuations **inside quotes** (where the shell would NOT treat `\`+LF as a continuation) are joined by
  the normalizer too; this can only over-detect (→ CONFIRM), never under-detect, so it adds no fail-open.
- The genuine live-platform observation (Claude Code's own dispatch of the pinned consumer hook) still
  requires a human-run Claude Code session rooted in the consumer; this corrective work did not perform it.

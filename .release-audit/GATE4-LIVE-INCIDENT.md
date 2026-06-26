# Gate-4 Live Incident — shell line-continuation parser fail-open (PR #12)

Authoritative record of the live Gate-4 acceptance failure, its two root causes, the fix, and the
corrected network-safe probe design. No credentials/tokens included; legacy-repo content limited to what
the incident requires.

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

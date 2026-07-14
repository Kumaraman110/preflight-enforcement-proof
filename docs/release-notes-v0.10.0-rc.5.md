# Preflight v0.10.0-rc.5 — Release notes

> **A certification-hardening release candidate.** A linear descendant of the rc.4 commit (`0f6660c`); the
> `v0.10.0-rc.1` … `-rc.4` tags are immutable and stay in place. rc.5 exists because a full-suite
> certification of rc.4 on a **quiet ephemeral `windows-latest` runner** (bash 5.3.9-cygwin, jq 1.8.1, gawk
> 5.4.0) — the sanctioned qualification environment — surfaced genuine defects that the primary dev host had
> masked, plus a class of test fixtures that could not run on a Windows/cygwin checkout path. rc.5 fixes them
> and is certified **109/109** on that runner (independent per-shard re-derivation). If rc.5 qualifies with
> no P0/P1 remaining, stable `v0.10.0` is cut from the exact rc.5 product commit with no code changes other
> than version/release metadata.

## Why rc.5 (and not stable straight from rc.4)

rc.4 was qualified against the local sharded runner and individual suites, but the aggregate full suite could
not COMPLETE on the saturated dev host. Running it on a clean `windows-latest` runner exposed real behavior
differences on the **cygwin toolchain** — including a CRLF-continuation push **fail-open** and a multi-push
**fail-open** — that must be closed before a stable release. Per the release discipline, any functional change
after an RC means a new RC, not stable: hence rc.5.

## The headline fixes — wrapper-taxonomy pre-emption (engine)

The rc.4 wrapper-taxonomy (the pre-pass that closed the original command-wrapper fail-open) ran **too early
and too coarsely**, pre-empting the engine's *precise* downstream paths (the robust continuation-join, the
inline-`bash -c` static recovery, the authoritative IR structural parser, the quote-aware gh-pr detectors).
On the cygwin toolchain this produced several wrong decisions:

- **CRLF line-continuation fail-open (severe).** cygwin's stdin translation can DOUBLE the CR, so a
  `git \<CR><LF>push <forbidden>` arrived as `\<CR><CR><LF>`. The taxonomy's single-CR inline join missed it,
  its segmentation then split on the surviving LF, and its passthrough rewrite clobbered `COMMAND` with the
  truncated `git \<CR>` fragment — **dropping the `push …` entirely**, so a forbidden push reached the tool
  UNGATED. Fixed by running the robust CR-run-before-LF squeeze *inside* the taxonomy, before segmentation.

- **Multi-push fail-open.** `git push <safe>; git push <forbidden>` was allowed: the taxonomy recorded the
  first (safe) segment as the "peeled" command and rewrote `COMMAND` to it — even though **no wrapper had
  been peeled** — so the authoritative per-node worst-wins loop never saw the forbidden second push. Fixed by
  rewriting `COMMAND` only when a transparent wrapper was actually stripped; a bare `git`/`gh` segment leaves
  the full multi-statement command intact for the IR to enumerate.

- **BLOCK→CONFIRM downgrades.** `bash -c '…'` / `sh -c` / `bash -lc`, compound `if`/`while`/`for … git push`,
  and `eval`/`xargs` indirection were classified UNKNOWN→CONFIRM, pre-empting the inline-`-c` static recovery
  (BLOCKER-E) and the IR opaque-block that BLOCK a forbidden inner op. Fixed by DEFERRING those shell
  interpreters/keywords/indirection programs to the authoritative path.

- **Over-block.** A benign single-quoted literal `echo '( gh pr merge --repo <forbidden> )'` was wrongly
  BLOCKED (the coarse segmentation split inside the quotes). Grouping/subshell tokens now defer to the
  quote-aware IR + gh-pr detectors, which correctly ALLOW a literal mention.

There is **no fail-open even on a taxonomy bug**: a shell interpreter/keyword/grouping head now defers to a
path that fails closed; the worst case is a CONFIRM, never a silent ALLOW.

## Other product fixes

- **spec-integrity-check** — the wire-contract model-field scan used `echo "$MODEL_FILES" | xargs grep`,
  which word-split a `SOURCE_DIR` path containing a space or backslash (common on Windows), leaving the
  field set empty so the source→spec **forge-catch silently never fired**. Now a NUL-safe per-file iteration.

- **preflight-selfcheck** — the shipped self-check built its bootstrap-write-gate probe by raw-interpolating
  a temp path into JSON, so on **any Windows user's machine** the backslash path made the probe invalid JSON,
  the gate exited 0, and the self-check **falsely reported the gate DEAD**. Now jq-encoded.

## Test-suite portability (no product behavior change)

Thirteen behavioral/protocol tests were fragile to a Windows/cygwin CI checkout path (`D:\a\…` backslashes):
they now build hook stdin with `jq` (or `jq -Rs` on stdin, to avoid MSYS argv path-conversion), normalize
`mktemp` roots to forward slashes, read file hashes over stdin so coreutils cannot escape a filename argument,
emit the canonical `N passed, M failed` result trailer, and replace two PyYAML-dependent workflow-lint
assertions with awk block-scans (PyYAML is absent on stock `windows-latest`). One incompatible assertion —
that a benign `echo "…gh pr create…"` stays on the zero-spawn fast path — was removed, because the router's
structural catch-all **intentionally over-routes** a bare governed word to the engine (safe; latency only).

## Certification

Full suite: **109 shards, 109 PASS, 0 FAIL / 0 TIMEOUT / 0 duplicate / 0 failed assertions**, re-derived
independently from the per-shard result files, on the quiet `windows-latest` runner. The behavioral push-gate
proof (CRLF, wrapper, multi-push, inline-shell, subshell, eval) passes on the same runner.

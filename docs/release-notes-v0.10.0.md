# Preflight v0.10.0 — Release notes (stable)

> **Stable release.** Cut from the exact `v0.10.0-rc.5` product commit (`f8e63ff`) with **no code changes** —
> only version/release metadata (`RELEASE_VERSION` `v0.10.0-rc.5`→`v0.10.0`, the CHANGELOG entry, and this
> doc). The `v0.10.0-rc.1` … `-rc.5` tags are immutable and stay in place.

## What v0.10.0 is

The first stable user-level release of Preflight: a fail-closed, agent-Bash-tool push-safety guard installed
per-user with a single `preflight` command. It classifies every Bash tool call with a fast, zero-external-
spawn router and sends only genuine candidates (a governed `git push` / `gh pr create|merge`, a protected-
sentinel write) to the heavy engine, which decides **ALLOW / CONFIRM / BLOCK** by reversibility tier. An
immutable per-generation runtime (`~/.claude/preflight/runtime/<sha>/` with `ACTIVE`/`PREVIOUS` pointers and
an atomic pointer-swap) makes install, upgrade, and rollback safe and instant.

## The road to stable — every fail-open closed

The release-candidate line existed to find and close fail-opens by adversarial verification, not to bless the
framework. In order:

- **rc.1–rc.3** — the usable user-level CLI, the immutable runtime model, and the deterministic user/project
  hook-ownership rule.
- **rc.4** — the **command-wrapper fail-open** class: a governed push behind `env`/`sudo`/`nice`/`timeout`/…
  (an unbounded wrapper set) bypassed the gate. Closed structurally (router catch-all + engine wrapper
  taxonomy), not by enumeration.
- **rc.5** — defects that only surfaced when the full suite was certified on a **quiet ephemeral
  `windows-latest` runner** (bash 5.3.9-cygwin, jq 1.8.1, gawk 5.4.0), because the primary dev host was too
  saturated to complete it:
  - a **CRLF line-continuation push fail-open** (cygwin CR-doubling truncated the command in the taxonomy
    pre-pass so a forbidden push reached the tool ungated);
  - a **multi-push fail-open** (`git push <safe>; git push <forbidden>` dropped the forbidden second push);
  - `bash -c`/`sh -c`, `if`/`while`/`for`, and `eval`/`xargs` governed ops downgraded BLOCK→CONFIRM;
  - a benign single-quoted `echo '( gh pr merge … )'` over-blocked;
  - a **spec-integrity space-path fail-open** (a `SOURCE_DIR` with a space silently disabled the wire-contract
    forge-catch); and
  - a **false-DEAD** in the shipped self-check on any Windows machine (a raw-interpolated backslash path made
    its probe invalid JSON).

  All are fixed by making the wrapper-taxonomy pre-pass DEFER to the engine's precise paths instead of
  pre-empting them, plus NUL-safe / jq-encoded path handling. There is no fail-open even on a taxonomy bug:
  the worst case is a CONFIRM, never a silent ALLOW.

## Certification

The framework's own full test suite — **109 shards** (102 behavioral tests + 7 in-file suites) — certifies
**109 PASS, 0 FAIL, 0 TIMEOUT, 0 duplicate, 0 failed assertions** on the quiet `windows-latest` runner, with
the shard counts re-derived independently from the per-shard result files (not trusting the runner's own
verdict), against the immutable `v0.10.0-rc.5` tag this stable release is cut from. A dedicated behavioral
push-gate proof (CRLF, wrapper, multi-push, inline-shell, subshell, eval) passes on the same runner.

## Honest boundaries (unchanged)

This is an **agent-Bash-tool guard**, not server-side branch protection: it governs what the coding agent
runs in its own shell. It is fail-closed on the dangerous direction and on unparseable input, but a
determined human with direct shell access is out of scope by design. See `docs/parity-gate-limitations.md`.

## Install

```sh
# from the published artifact (recommended):
#   download preflight-user-v0.10.0.tar.gz + .sha256, verify, then:
preflight install --user --ref v0.10.0 --from-artifact preflight-user-v0.10.0.tar.gz
preflight status && preflight verify
```

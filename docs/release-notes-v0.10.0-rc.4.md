# Preflight v0.10.0-rc.4 — Release notes

> **The final hardening release candidate before stable v0.10.0.** A linear descendant of the rc.3 commit
> (`a3ff584`); the `v0.10.0-rc.1`, `-rc.2`, and `-rc.3` tags are immutable and stay in place. rc.4 adds **no
> new features, protocols, or architecture** — only the security and usability fixes below, their regression
> tests, and version metadata. If rc.4 qualifies with no P0/P1 remaining, stable `v0.10.0` is cut from the
> exact rc.4 commit with no code changes other than version/release metadata.

## The headline fix — command-wrapper fail-open (P0)

A governed `git push` / `gh pr create|merge` prefixed with a **command wrapper** bypassed the push gate
completely: the router classified it a non-candidate, the engine was never invoked, and the push reached the
tool **ungated**. `env git push origin main` sailed through a gate that blocks the identical bare command.
The defect was present since rc.3 and was found by adversarial verification.

The wrapper set is unbounded — `env`, `env -S`/`--split-string`, `exec`, `builtin`, `command`, `sudo`,
`doas`, `nice`, `ionice`, `chrt`, `taskset`, `flock`, `nohup`, `setsid`, `timeout`, `stdbuf`, `setpriority`,
`eatmydata`, `proot`, `catchsegv`, `unbuffer`, `faketime`, `torsocks`, `watch`, and any future wrapper — so
it is closed **structurally**, not by enumeration, at both layers:

- **Router** (`hooks/pre-bash-risk-router`): a structural catch-all — if the leading program is unrecognized
  and a bare `git`/`gh` program *word* appears later in the segment, route it to the engine. Over-routing is
  safe (latency only; a benign `echo git push` reaches the engine, which allows it); under-routing was the
  fail-open. Whole-word match, so `legit`/`ghost` don't trip it. `env -S` routes conservatively.
- **Engine** (`hooks/pre-push-gate-engine`): a wrapper **taxonomy** pre-classifier (bounded, cycle-safe,
  worst-verdict-wins):
  - **TRANSPARENT** wrappers (they exec the wrapped command locally) → recursively peel and rewrite the
    command to the wrapped `git … push`, then apply the **existing** authoritative push policy (a forbidden
    destination still BLOCKs; a protected branch still CONFIRMs).
  - **REMOTE/ISOLATED** executors (`ssh`/`docker`/`podman`/`kubectl`/`nsenter`/`chroot`) with a governed
    token → **CONFIRM** (a human decides; it runs elsewhere, not analyzed as a local push).
  - **DATA-ONLY** commands (`echo`/`printf`/`grep`/…) with a literal `git`/`gh` argument → **ALLOW**.
  - **UNKNOWN** leading program + a governed token → **CONFIRM** interactively; **BLOCK** when
    `PREFLIGHT_HEADLESS=1` (`AMBIGUOUS_WRAPPED_GOVERNED_COMMAND`). Never a silent ALLOW.

**Robustness:** the router catch-all plus the engine's UNKNOWN branch mean there is **no fail-open even when
an enumerated wrapper has a peel bug** — the worst case is CONFIRM instead of BLOCK, never silent-allow.

Regression tests: `tests/behavioral/wrapper-prefix-failopen-test.sh` and `wrapper-taxonomy-test.sh` (drives
the real engine across every taxonomy branch + ordinary commands).

## Two P1 fixes

- **Worktree exclude** — `preflight init --local` in a *linked worktree* wrote `/.preflight/` to the
  per-worktree git-dir's `info/exclude`, which Git does not consult, leaving `.preflight/config.json`
  committable while the CLI claimed it was excluded. Now uses `git rev-parse --git-common-dir`.
- **Artifact version trust** — a from-artifact install re-stamped the runtime with the CLI's compiled
  constant, discarding the artifact's own `RELEASE_VERSION`. The from-artifact path now trusts the
  artifact's staged version; a coupling test asserts the compiled constant equals the CHANGELOG top entry.

## The usable `preflight` CLI

A single `preflight` command on PATH so a user can operate Preflight without knowing about hooks, runtime
SHAs, or `ACTIVE` pointers:

```
preflight init --local     # opt this repo in (gitignored config; NO tracked change)
preflight status           # active/inactive · USER/PROJECT owner · version · policy tier · health · remote
preflight doctor           # deps, duplicate hooks, stale runtime, malformed config, git context — with fixes
preflight verify           # runtime integrity
preflight disable          # deactivate this repo (reversible)
preflight version / rollback --user / uninstall --user / install --user --ref … / doctor --project …
```

`FIRST-USE.md` is the minimal command set for a new user.

## Scan-on-exec performance

The push-gate timeout budget is widened for heavy endpoint-security (scan-on-exec) hosts (platform 35s→60s,
router ceiling 48s; engine internal subprocess 3s→8s and IR-parse 8s→20s), single-sourced and
coupling-tested, so a *correct* verdict is not killed mid-decision and swallowed into a spurious fail-closed
BLOCK. Ordinary and inactive paths add no extra process spawn; consequential paths stay bounded and fail
closed.

## Boundary (unchanged, honest)

Preflight is an **agent-Bash-tool guard**, not server-side branch protection; it is fail-open when
unconfigured. See `docs/parity-gate-limitations.md`. The wrapper taxonomy closes an *agent-side* bypass; it
does not change that boundary.

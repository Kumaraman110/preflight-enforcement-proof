# Changelog

All notable changes to Preflight are recorded here. This project uses annotated tags on the
`feature/preflight-framework` line; releases are cut as tags (see `docs/`).

## v0.10.0-rc.5 — cygwin-toolchain certification hardening

**Release candidate.** Cut after a full-suite certification on a quiet ephemeral `windows-latest` runner
(bash 5.3.9-cygwin, jq 1.8.1, gawk 5.4.0) exposed defects that the primary dev host had masked. Linear
descendant of `v0.10.0-rc.4` (`0f6660c`); rc.1–rc.4 tags remain immutable. Certified **109/109** on that
runner (independent per-shard re-derivation).

### Fixed — wrapper-taxonomy pre-emption (engine)
- The rc.4 wrapper-taxonomy pre-pass ran too early/coarse and PRE-EMPTED the engine's precise paths,
  producing several wrong decisions on the cygwin toolchain:
  - **CRLF line-continuation fail-open**: a `git \<CR><LF>push <forbidden>` (cygwin doubles the CR) was
    truncated by the taxonomy's segmentation and reached the tool UNGATED. Now the robust CR-squeeze runs
    inside the taxonomy before segmentation.
  - **`bash -c`/`sh -c`, `if`/`while`/`for`, `eval`/`xargs`** governed ops were downgraded BLOCK→CONFIRM;
    now DEFERRED to the authoritative inline-`-c` recovery / IR / opaque-block, which BLOCK correctly.
  - **Multi-push fail-open**: `git push <safe>; git push <forbidden>` recorded only the first (safe) push and
    dropped the forbidden one — the taxonomy rewrote `COMMAND` for a BARE git segment (no wrapper peeled).
    Now it rewrites only when a wrapper was actually peeled, so the IR enumerates every push node.
  - **Over-block**: a benign single-quoted `echo '( gh pr merge … )'` was wrongly BLOCKED; grouping tokens
    now defer to the quote-aware IR/gh-pr detectors.
- **spec-integrity-check** wire-contract model scan used `echo "$MODEL_FILES" | xargs grep`, which word-split
  a SOURCE_DIR path containing a space/backslash → the source→spec forge-catch silently never fired. Now a
  NUL-safe per-file iteration.
- **preflight-selfcheck** built the bootstrap-write-gate probe by raw-interpolating a temp path, so on any
  Windows user's machine the backslash path made the probe invalid JSON and the tool FALSELY reported the
  gate DEAD. Now jq-encoded.

### Changed — test-suite portability (no product behavior change)
- Hardened 13 behavioral/protocol tests that were fragile to a Windows/cygwin checkout path (`D:\a\…`
  backslashes): build hook stdin with `jq`, normalize `mktemp` roots to forward slashes, read hashes so
  coreutils can't escape a filename arg, emit the canonical result trailer, and replace two PyYAML-dependent
  assertions with awk block-scans (PyYAML is absent on stock `windows-latest`).

## v0.10.0-rc.4 — final hardening release candidate

**Release candidate — the final hardening RC before stable v0.10.0.** Linear descendant of `v0.10.0-rc.3`
(`a3ff584`); the rc.1/rc.2/rc.3 tags remain immutable and in place. No new features, protocols, or
architecture — rc.4 contains only the security/usability fixes below plus their tests and version metadata.

### Fixed — command-wrapper fail-open (P0)
- A governed `git push` / `gh pr create|merge` prefixed with a command WRAPPER bypassed the push gate
  entirely (the router classified it a non-candidate, the engine was never invoked, and the push reached the
  tool UNGATED). Present since rc.3. The class is unbounded (env, `env -S`/`--split-string`, exec, builtin,
  command, sudo, doas, nice, ionice, chrt, taskset, flock, nohup, setsid, timeout, stdbuf, setpriority,
  eatmydata, proot, catchsegv, unbuffer, faketime, torsocks, watch — plus future wrappers), so it is closed
  STRUCTURALLY, not by enumeration:
  - **Router** (`hooks/pre-bash-risk-router`): a structural catch-all routes any segment with a bare
    `git`/`gh` program WORD behind an unrecognized program to the engine. Over-routing is safe (latency
    only; the engine allows a benign `echo git push`); under-routing was the fail-open.
  - **Engine** (`hooks/pre-push-gate-engine`): a wrapper TAXONOMY pre-classifier — TRANSPARENT wrappers are
    recursively peeled and the wrapped `git … push` is gated by the existing authoritative policy;
    REMOTE/ISOLATED executors (ssh/docker/podman/kubectl/…) → CONFIRM; DATA-ONLY (echo/grep/…) → ALLOW;
    an UNKNOWN leading program + a governed token → CONFIRM interactively, BLOCK when `PREFLIGHT_HEADLESS=1`.
  - There is NO fail-open even on a wrapper-peel bug: the worst case is CONFIRM instead of BLOCK, never a
    silent ALLOW. Regression tests: `wrapper-prefix-failopen-test.sh`, `wrapper-taxonomy-test.sh`.

### Fixed — two P1s
- `preflight init --local` in a LINKED WORKTREE wrote `/.preflight/` to the per-worktree git-dir's
  `info/exclude`, which Git does not read — leaving `.preflight/config.json` committable while the CLI
  claimed it was excluded. Now uses `git rev-parse --git-common-dir`.
- A from-artifact install re-stamped the runtime with the CLI's compiled constant, discarding the artifact's
  own `RELEASE_VERSION`. The from-artifact path now trusts the artifact's staged version; a coupling test
  asserts the compiled constant equals the CHANGELOG top entry so an un-bumped constant fails CI.

### Added — the usable `preflight` CLI
- A single `preflight` command on PATH (stable launcher → versioned runtime): `init --local` (opt a repo in
  with NO tracked change), `status` (active/inactive · USER/PROJECT owner · version · policy tier · runtime
  health · remote-enforcement), `doctor` (deps, duplicate hooks, stale runtime, malformed config, git
  context — with fixes), `verify`, `disable` (reversible), plus the existing install/rollback/uninstall.
  `FIRST-USE.md` documents the minimal command set.

### Fixed — scan-on-exec performance
- The push-gate timeout budget is widened for heavy endpoint-security (scan-on-exec) hosts (platform
  35s→60s, router ceiling 48s; engine internal subprocess 3s→8s and IR-parse 8s→20s), single-sourced and
  coupling-tested, so a CORRECT verdict is not killed mid-decision and swallowed into a spurious fail-closed
  BLOCK. Ordinary/inactive paths add no extra spawn; consequential paths stay bounded and fail closed.

## v0.10.0-rc.3 — hook-arbitration release candidate

**Release candidate — not GA, not `latest`/`stable`.** Supersedes `v0.10.0-rc.2` for evaluation;
the `v0.10.0-rc.1` and `v0.10.0-rc.2` tags remain immutable and in place. rc.3 is cut on top of the
rc.2 commit (`7e30c51`), which is itself on top of the rc.1 commit (`6eaff61`) — a linear descendant.

### Added — deterministic hook arbitration + `doctor --project`
- **One deterministic user/project hook-ownership rule** (`lib/hook-arbitration.sh`, the single source of
  truth for both the user router and `doctor`). Because Claude Code merges PreToolUse hooks as a UNION
  across the user and project scopes, a repo with BOTH a user-level and a project-level Preflight install
  would otherwise adjudicate the same Bash event twice. The rule resolves ownership so **exactly one**
  authoritative runtime decides each event:
  - **PROJECT** — a valid project-level Preflight Bash registration (settings names a project router AND
    the referenced project hook file exists non-empty) owns the repo; the user router yields (exit 0) and
    writes nothing.
  - **USER** — opted-in with no distinct project registration (a config file ALONE is never project
    ownership); the user runtime owns it.
  - **AMBIGUOUS** — a project registration is present but untrustworthy (malformed settings, or a stale
    registration whose hook file is missing/empty); the user runtime owns the decision **safely** (it
    never stands down for an unverifiable or broken project install), and `doctor` reports remediation.
  - A project entry that merely re-invokes the USER runtime (`dispatcher.cmd` / a `~/.claude/preflight`
    path) is a **duplicate**, not a project owner — ownership stays USER, the duplicate is flagged. The
    branch-stable project runtime under `<repo>/.git/preflight/runtime/<sha>/` is a PROJECT owner (not a
    user-runtime duplicate) even though its path contains `preflight/runtime/`.
- **`tools/preflight-user.sh doctor --user --project <path>`** (READ-ONLY): reports the effective owner
  (USER / PROJECT / AMBIGUOUS), the user version + commit, the project registrations found, the project
  runtime, duplicate-execution risk, and remediation. It never writes to or mutates the inspected repo.
- New tests: `tests/behavioral/hook-arbitration-test.sh` (11/0 — the ownership rule incl. the real
  branch-stable pilot shape) and `tests/behavioral/no-duplicate-exec-test.sh` (11/0 — exactly-one
  authoritative runtime per event through the real dispatcher chain with invocation counters, and the
  user dispatcher writes no `.preflight` file while deferring). Both wired into `run-all-tests.sh`.

### Fixed (carried forward from the rc.2 work + this candidate)
- **`verify --user` accepts a legitimately rolled-back older generation** whose recorded `RELEASE_VERSION`
  differs from the CLI's compiled-in version (previously a hard version-equality check failed after a
  rollback). Integrity is still enforced by the manifest sha256 re-check + the registration + a
  well-formed version string. (This fix and the arbitration work are why rc.3 exists — the published
  rc.2 tag is immutable and predates both.)
- Carries the rc.2 fixes: the **alternate git-context push bypass** (`git -C <dir> push` and the other
  alt-context forms are detected as pushes via the shell-structure lexer skipping git's global options,
  then gated or fail-closed — never silently allowed) and **byte-for-byte uninstall settings restore**.

### Known limitations (carried from rc.2/rc.1)
- Local user-level gate is advisory/agent-resistant; the **remote required-check remains the final
  authority** and is not deployed/configured by this release.
- Windows/Git-Bash on-access-AV per-spawn latency is a host cost; the `ir-push-perf` matrix is
  timing-sensitive on such hosts (wall-clock only, functionally correct, reproduces on a pristine
  baseline). No functional failure is waived.

## v0.10.0-rc.2 — burn-in fix release candidate

**Release candidate — not GA, not `latest`/`stable`.** Supersedes `v0.10.0-rc.1` for evaluation;
the `v0.10.0-rc.1` tag remains immutable and in place.

Source: `release/v0.10.0-rc.2`, two commits on top of the `v0.10.0-rc.1` commit (`6eaff61`).

### Fixed (found during rc.1 burn-in)
- **Alternate git-context push bypass (stable blocker).** The shell-structure IR lexer read git's
  global-option run as the subcommand, so `git -C <dir> push` (and `--git-dir[=]`, `--work-tree`,
  `-c`, `GIT_DIR=`, `GIT_WORK_TREE=`, nested `bash -c`, quoted space-paths, multi-push) was classified
  as a NON-push and **silently allowed** — a local-policy bypass. The lexer now skips git's global
  options before reading the subcommand, so these forms are detected as pushes and the normal policy
  applies (or a fail-closed BLOCK when the target repo's config is unreachable) — never a silent allow.
  Non-push commands (`git status`, `grep -C`, `echo -C`) are unaffected. New corpus test
  `tests/behavioral/alt-git-context-push-test.sh` (16/0); regression backstops green (structure-oracle
  29/0, parser-bypass 19/0, router-structural-classify 26/0). The engine (`pre-push-gate-engine`) is
  byte-identical to rc.1 — the fix is confined to `lib/shell-structure-lexer.awk`.
- **Uninstall now restores prior settings byte-for-byte.** When no post-install user change is present,
  `uninstall --user` restores the exact pre-install `settings.json` bytes (previously it preserved all
  keys but re-formatted the file). Post-install user changes are still preserved; an install-created
  file is still removed.

### Known limitations (carried from rc.1)
- Local user-level gate is advisory/agent-resistant; the **remote required-check remains the final
  authority** and is not deployed/configured by this release.
- Windows/Git-Bash on-access-AV per-spawn latency (~3–4s/command) is a host cost, documented; it never
  disables ordinary work (only in-scope consequential candidates can fail-closed).

## v0.10.0-rc.1 — user-level release candidate

**Release candidate — not GA, not `latest`/`stable`.**

Source commit: the `release/v0.10.0-rc.1` head (a linear descendant of PR #13's product head
`d7ba8ee`, which itself contains PR #12's router/engine split `dac97e8`). Stacked-PR dependency:
this release's product content is the completed PR #13 tree; PR #12 and PR #13 remain open and were
**not** merged to construct the release.

### Added — user-level installation
- **Immutable, versioned user-level runtime** under `~/.claude/preflight/`: `runtime/<commit-sha>/`
  generations, `ACTIVE`/`PREVIOUS` pointers, a stable dispatcher referenced by `~/.claude/settings.json`,
  a per-generation `RUNTIME_MANIFEST.json` (SHA-256 of every artifact), and atomic pointer-swap
  activation/rollback with no dependency on the source checkout after install.
- **`tools/preflight-user.sh`** — `install --user --ref` / `verify --user` / `status --user` /
  `version` / `rollback --user` / `uninstall --user` / `doctor --user`. Installs only from committed
  git objects or a release artifact; rejects unresolvable refs; validates checksums before activation;
  backs up and merges `settings.json` without duplicate entries; idempotent; restores prior state on
  failure; uninstall removes only Preflight-owned data.
- **`hooks/user-preflight-router`** — the opt-in PreToolUse Bash router: exits immediately for
  repositories that have not opted in (`.preflight/config.json`), preserves the zero/near-zero
  ordinary-command fast path, fails closed only for in-scope consequential actions, yields to any
  project-level Preflight (no double execution), is git-worktree-safe, and never writes to an
  application repository during passive routing.
- **`tools/user/dispatcher.cmd`** — a stable polyglot (bash/cmd) dispatcher that resolves the active
  generation; the path never changes across upgrades.
- **`tests/user-install/user-install-test.sh`** — a 20-case compatibility + security suite run against
  isolated temporary HOME/config directories.
- **`docs/user-install.md`** — user-install, upgrade, rollback, uninstall, and trust-boundary docs.

### Included from the product line (PR #12 + PR #13)
- Preflight Protocol v0.1 (schemas, verifier, adapter) and the independent **remote decision gate**
  (identity re-resolution, signed attestation, approval path, two-stage fork-safe CI entrypoint).
- The router/engine split and the branch-stable project-level runtime.

### Known limitations
- The local user-level gate is **advisory / agent-resistant**, not a server-side control. The
  **remote required-check remains the final authority**; this release does not deploy or configure it.
- Windows/Git-Bash on-access-AV per-spawn latency makes the `ir-push-perf` host matrix timing-sensitive
  (disclosed as a host-performance limitation; no functional failure is waived).

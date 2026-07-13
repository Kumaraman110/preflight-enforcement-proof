# Changelog

All notable changes to Preflight are recorded here. This project uses annotated tags on the
`feature/preflight-framework` line; releases are cut as tags (see `docs/`).

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

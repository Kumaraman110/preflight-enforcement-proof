# Changelog

All notable changes to Preflight are recorded here. This project uses annotated tags on the
`feature/preflight-framework` line; releases are cut as tags (see `docs/`).

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

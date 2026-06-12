# Skill Bootstrap — Self-Detection Preamble

Every skill MUST self-detect its environment as its first action. Do NOT depend on the SessionStart hook having run — it may not be installed, may fail on some platforms (Windows python3 stub), or the user may launch Claude without the plugin directory.

## Detection Logic (execute as Step 0 before any skill-specific work)

1. Search for config in this order (first match wins):
   - `.preflight/config.json` in working directory
   - `.cpsl/config.json` in working directory
   - `.forge.json` in working directory
   - Walk up parent directories (max 5 levels) repeating the same search

2. If config found, extract:
   - `mode` → determines which rubric and skill set to use
   - `rubric` → path to the project's rubric
   - `branch.base` / `branch.remote` → for diff and push operations
   - `test.command` / `test.coverageBaseline` → for test gates
   - `capture.*` → capture file paths
   - `loop.*` → iteration caps, oscillation settings

2b. **Per-clone topology overlay (issue #6).** After reading config, check for
   `config.local.json` next to it (gitignored, per-clone, never committed). If present,
   resolve topology fields through `lib/config-overlay.sh` (`overlay_resolve <key>`), or
   apply the same rule manually: a local value wins ONLY for the allowlisted topology keys
   — `branch.remote`, `branch.base`, `branch.migrationPrefix`, `migration.legacyRepoPath`,
   `migration.servicesRoot`, `migration.referenceService`. For EVERY other key
   (gates, thresholds, `loop.*`, `review.*`, `rubric`, `mode`, `capture.*`,
   `branch.forbiddenRemotes`/`forbiddenRepos`) the committed value ALWAYS wins and a local
   attempt must be ignored with a warning. A clone may differ on WHERE it pushes — never
   on HOW strictly it is reviewed. **Honesty label:** the allowlist is enforced
   mechanically only at seams that resolve through `lib/config-overlay.sh` (the pre-push
   guard does); for skills that read `config.json` directly it is prose-level — the
   fail-safe direction being that an un-overlaid read sees only committed values, so a
   denied local key is never honored, merely invisible. This overlay exists for inverted
   clones (live SessionToken run: committed `branch.remote=origin` while `origin` was the
   legacy production repo) — the clone declares its true topology locally instead of
   committing a clone-specific value to a shared branch.

3. If no config found:
   - Mode: `generic`
   - Rubric: `${FRAMEWORK_ROOT}/examples/rubrics/rubric-generic-dotnet.md` (resolve `FRAMEWORK_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"`)
   - Branch base: `main`
   - Branch remote: `origin`
   - Test command: auto-detect (`dotnet test` if `.csproj`/`.sln`, `npm test` if `package.json`, skip otherwise)
   - Capture files: `docs/review/{calibration-log,checklist-additions,false-positives}.md`

4. Also check for `CLAUDE.md` at project root — it provides supplementary team conventions.

## Derived State and the Three-Layer Resolution Library

Skills MAY read derived state through `lib/resolve-config.sh` if the three-layer resolution is wired for their field. As of commit 4a66e3c+, `skills/test-driven-development` reads `testCommand` through `resolve_field_with_source`, exercising the full config > CLAUDE.md override > derived precedence. Other skills self-detect inline; they MAY adopt the resolution library in the future when their consumers demand it.

If `.preflight/derived/state.json` exists, it contains pre-computed values with confidence levels produced by the detector module (`lib/detector.sh`).

```bash
# .claude/ is the installed framework root; resolve without CLAUDE_PLUGIN_ROOT
# (empty off-plugin / in sub-agents) — git/pwd fallback resolves in every context.
FRAMEWORK_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
source "${FRAMEWORK_ROOT}/lib/derived-state-reader.sh"
TEST_CMD=$(read_derived "testCommand")
BUILD_CMD=$(read_derived "buildCommand")
STACK=$(read_derived "stack")
```

If derived state is missing or stale, fall back to the detection logic above. Derived state is produced by the detector module (invoked during bootstrap). It is not automatically regenerated at session start; skills self-detect when derived state is absent or stale.

Values from derived state include confidence levels. For high-stakes operations (push, PR creation), skills should surface low-confidence values to the user for verification before acting.

## Why Self-Detection Exists

The SessionStart hook is best-effort. It runs once, at session start, and may not fire if:
- The plugin is loaded via `--plugin-dir` but hooks aren't registered
- The user's Python installation is broken (Windows stub issue)
- The plugin is installed globally but the hook uses a relative path

Self-detection makes skills resilient. They work correctly regardless of how the session was initialized.

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

3. If no config found:
   - Mode: `generic`
   - Rubric: `${CLAUDE_PLUGIN_ROOT}/examples/rubrics/rubric-generic-dotnet.md`
   - Branch base: `main`
   - Branch remote: `origin`
   - Test command: auto-detect (`dotnet test` if `.csproj`/`.sln`, `npm test` if `package.json`, skip otherwise)
   - Capture files: `docs/review/{calibration-log,checklist-additions,false-positives}.md`

4. Also check for `CLAUDE.md` at project root — it provides supplementary team conventions.

## Why Self-Detection Exists

The SessionStart hook is best-effort. It runs once, at session start, and may not fire if:
- The plugin is loaded via `--plugin-dir` but hooks aren't registered
- The user's Python installation is broken (Windows stub issue)
- The plugin is installed globally but the hook uses a relative path

Self-detection makes skills resilient. They work correctly regardless of how the session was initialized.

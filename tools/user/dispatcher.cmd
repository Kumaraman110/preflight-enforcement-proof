:; # ─────────────────────────────────────────────────────────────────────────────
:; # Preflight USER-LEVEL stable dispatcher (polyglot: bash on Unix/Git-Bash, cmd on Windows).
:; #
:; # This file lives at a STABLE path (~/.claude/preflight/dispatcher.cmd) that ~/.claude/settings.json
:; # references. It NEVER changes across generations/upgrades — it only reads the ACTIVE pointer and execs
:; # the hook out of the immutable generation runtime/<ACTIVE-sha>/hooks/<name>. Upgrading Preflight = a
:; # pointer swap of ACTIVE; the dispatcher path stays constant, so settings.json is written exactly once.
:; #
:; # Contract: dispatcher.cmd <hook-name> [args...] ; stdin is the Claude Code tool JSON (passed through).
:; # Resolves ~/.claude/preflight (its own dir) → reads ACTIVE → runtime/<ACTIVE>/hooks/<hook-name>.
:; # FAIL-SAFE for the PASSIVE path: if runtime/ACTIVE/hook cannot be resolved, exit 0 (allow) — a broken
:; # user-level install must NOT block ordinary work. The router fails CLOSED only for in-scope consequential
:; # candidates; a missing dispatcher target is an install fault, not a governed op.
:; HERE="$(cd "$(dirname "$0")" && pwd)"
:; HOOK="$1"
:; ACTIVE_FILE="$HERE/ACTIVE"
:; [ -r "$ACTIVE_FILE" ] || exit 0
:; SHA="$(tr -d ' \t\r\n' < "$ACTIVE_FILE" 2>/dev/null)"
:; case "$SHA" in *[!0-9a-fA-F]*|"") exit 0;; esac
:; TARGET="$HERE/runtime/$SHA/hooks/$HOOK"
:; [ -f "$TARGET" ] || exit 0
:; shift
:; exec bash "$TARGET" "$@"
:; exit $?
@echo off
setlocal enabledelayedexpansion
set "HERE=%~dp0"
set "HOOK=%~1"
set "ACTIVE_FILE=%HERE%ACTIVE"
if not exist "%ACTIVE_FILE%" exit /b 0
set /p SHA=<"%ACTIVE_FILE%"
if "%SHA%"=="" exit /b 0
set "TARGET=%HERE%runtime\%SHA%\hooks\%HOOK%"
if not exist "%TARGET%" exit /b 0
set "GIT_PATH="
where git >nul 2>&1 && (
  for /f "tokens=*" %%G in ('where git') do if not defined GIT_PATH set "GIT_PATH=%%~dpG"
)
:; # NOTE: bash side already exec'd; cmd reaches here only on Windows. Pass the hook name + args through
:; # to the target script as $1.. (matches the bash side, which re-passes "$@" after shifting off HOOK...
:; # actually the bash side shifts then execs TARGET with the REMAINING args; the target reads stdin for
:; # the tool JSON and does not rely on argv, so arg parity is not load-bearing — stdin is the contract).
if defined GIT_PATH (
  "%GIT_PATH%..\bin\bash.exe" "%TARGET%" %2 %3 %4 %5 %6 %7 %8 %9
) else (
  bash "%TARGET%" %2 %3 %4 %5 %6 %7 %8 %9
)

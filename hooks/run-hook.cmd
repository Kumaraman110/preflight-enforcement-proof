:; # Polyglot: runs as bash on Unix, cmd on Windows (finds git-bash). Self-resolving — no CLAUDE_PLUGIN_ROOT.
:; HERE="$(cd "$(dirname "$0")" && pwd)"; exec bash "$HERE/$1" "$@"; exit $?
@echo off
setlocal
set "HOOK=%~1"
set "SCRIPT=%~dp0%HOOK%"
where git >nul 2>&1 && (
  for /f "tokens=*" %%G in ('where git') do set "GIT_PATH=%%~dpG"
)
if defined GIT_PATH (
  "%GIT_PATH%..\bin\bash.exe" "%SCRIPT%" %*
) else (
  bash "%SCRIPT%" %*
)

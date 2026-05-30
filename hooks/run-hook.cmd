:; # Polyglot: runs as bash on Unix, cmd on Windows (finds git-bash)
:; exec bash "${CLAUDE_PLUGIN_ROOT}/hooks/$1" "$@"; exit $?
@echo off
setlocal
set "HOOK=%~1"
set "SCRIPT=%CLAUDE_PLUGIN_ROOT%\hooks\%HOOK%"
where git >nul 2>&1 && (
  for /f "tokens=*" %%G in ('where git') do set "GIT_PATH=%%~dpG"
)
if defined GIT_PATH (
  "%GIT_PATH%..\bin\bash.exe" "%SCRIPT%" %*
) else (
  bash "%SCRIPT%" %*
)

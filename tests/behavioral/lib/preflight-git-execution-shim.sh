#!/usr/bin/env bash
# preflight-git-execution-shim — a NETWORK-SAFE git interceptor for LIVE push-gate acceptance probes.
#
# WHY THIS EXISTS (the live Gate-4 incident): the previous live probe used
#     git -c remote.origin.url=file:///__probe__ push origin HEAD:refs/heads/x
# on the false assumption that a command-line `remote.origin.url` override REPLACES all push destinations.
# It does NOT. Git still consulted the configured HTTPS destination and reached the real (CPSL) remote,
# creating a branch, before failing on the file URL. A `-c remote.<name>.url=` / `pushurl` / credential /
# remote-mutation override is NEVER a sufficient network-containment mechanism for a push probe.
#
# THE SAFE DESIGN: containment at the EXECUTION layer, not the git-config layer. This script is installed as
# an executable named `git` in a TEMP directory that is prepended to PATH. When Claude Code's Bash tool (or
# any caller) runs `git … push …`, THIS shim is what actually executes — it NEVER calls the real git for a
# push, so no transport, no remote, no network is possible regardless of any URL/remote config.
#
# CONTRACT:
#   • A `push` invocation (in any arg position) -> print the distinctive marker PREFLIGHT_EXECUTION_SHIM_BLOCKED
#     to stderr and exit NONZERO (3). NO real git is invoked; no remote is contacted.
#   • Any NON-push git invocation -> forwarded verbatim to the REAL git executable (resolved by absolute path
#     so the shim can never recurse into itself), so the working tree / status / config still behave normally.
#
# ACCEPTANCE SEMANTICS (important — read before interpreting a live run):
#   • The PreToolUse hook is expected to BLOCK a forbidden push BEFORE execution. On a PASSING gate run the
#     push command never executes, so the shim marker MUST NOT appear.
#   • If PREFLIGHT_EXECUTION_SHIM_BLOCKED DOES appear, the gate FAILED OPEN (the command reached execution) —
#     but the shim prevented any network access. A shim interception is a SAFE FAILURE, not an acceptance pass.
#   • Therefore: gate pass  == push blocked by hook  AND  shim marker ABSENT.
#               gate fail-open (contained) == shim marker PRESENT (no network occurred, but the gate let it run).
#
# USAGE (live acceptance, in a Claude-Code session rooted in the consumer):
#   SHIMDIR="$(mktemp -d)/preflight-git-shim"; mkdir -p "$SHIMDIR"
#   cp tests/behavioral/lib/preflight-git-execution-shim.sh "$SHIMDIR/git"; chmod +x "$SHIMDIR/git"
#   PATH="$SHIMDIR:$PATH" git push origin HEAD:refs/heads/preflight-live-probe
#   # expect: the PreToolUse hook blocks it; the shim marker is ABSENT; no network occurred.
#
# This shim uses ONLY the execution layer for containment. It does not touch remote.<name>.url, pushurl,
# credentials, or any remote configuration, and it never resolves to the real git for a push.

# Resolve the REAL git by absolute path, EXCLUDING this shim's own directory, so a push is never forwarded
# and a non-push never recurses. Walk PATH and pick the first `git` that is not this script.
_self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
_real_git=""
_IFS_SAVE="$IFS"; IFS=':'
for _d in $PATH; do
  IFS="$_IFS_SAVE"
  [ -z "$_d" ] && continue
  _cand="$_d/git"
  if [ -x "$_cand" ] && [ "$(cd "$_d" 2>/dev/null && pwd)/git" != "$_self" ]; then _real_git="$_cand"; break; fi
  IFS=':'
done
IFS="$_IFS_SAVE"

# Detect a push subcommand ANYWHERE in the args (after global options): the first non-option-bearing word
# that equals 'push', or any bare 'push' token. Conservative: if 'push' appears as a standalone arg, treat
# the invocation as a push and BLOCK. (Containment must over-include, never under-include.)
_is_push=0
for _a in "$@"; do
  case "$_a" in
    push) _is_push=1; break ;;
  esac
done

if [ "$_is_push" -eq 1 ]; then
  echo "PREFLIGHT_EXECUTION_SHIM_BLOCKED: a 'git push' reached EXECUTION (the PreToolUse gate did not block it)." >&2
  echo "  The shim intercepted it — NO real git ran, NO remote was contacted, NO network occurred." >&2
  echo "  This is a SAFE FAILURE (contained), NOT an acceptance pass. A passing gate blocks before execution," >&2
  echo "  so this marker must be ABSENT on a passing live run." >&2
  exit 3
fi

# Non-push: forward to the real git verbatim (or fail safe if no real git was found).
if [ -n "$_real_git" ]; then
  exec "$_real_git" "$@"
fi
echo "preflight-git-execution-shim: no real git found on PATH (excluding the shim dir) — cannot forward non-push command." >&2
exit 127

#!/usr/bin/env bash
# Behavioral test: SHELL LINE-CONTINUATION parser fail-open (the live Gate-4 incident).
#
# THE INCIDENT (authoritative): a live Claude Code Bash command
#     git -c remote.origin.url=file:///__preflight_no_network_probe__ \
#       push origin HEAD:refs/heads/preflight-live-probe
# was NOT blocked. Git reached the configured (CPSL) destination and created a remote branch before later
# failing on the file URL. (The owner has since deleted that accidental branch.)
#
# ROOT CAUSE — engine structural-parser fail-open: _pfg_parse_push() segments the command by reading
# `$norm` line-by-line (`while IFS= read -r seg`). A shell line-continuation (backslash + LF, or backslash +
# CRLF) is ONE logical command to the shell, but `read` split it at the LF into TWO segments:
#     seg1: `git -c remote.origin.url=file:///probe \`   (has `git`, NO `push`)
#     seg2: `push origin HEAD:refs/heads/...`            (has `push`, NO `git`)
# Neither segment is a `git…push`, so _PFG_IS_PUSH stayed 0 → the engine returned ALLOW. Security-significant.
#
# THE FIX: normalize shell line-continuations (\<LF>, \<CRLF>) into a single logical line BEFORE structural
# segmentation, so `git` and `push` remain one command. An UNRESOLVABLE/suspicious continuation must never
# silently become a non-push ALLOW — it may be classed UNRESOLVED and ride the existing fail-closed/CONFIRM
# path.
#
# This file is BOTH the focused RED (run against the pre-fix engine it must show the bypass) AND the GREEN
# regression (post-fix every continuation form is detected). It drives the engine body directly and builds
# tool JSON with jq so REAL embedded LF/CRLF bytes reach the engine (string interpolation can't carry them).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$ROOT/hooks/pre-push-gate-engine"
[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required to build JSON with embedded newlines."; echo ""; echo "pre-push-continuation-failopen tests: 0 passed, 0 failed (skipped)"; exit 0; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# Repo wired to REACH the guards: forbidden remote 'poc' + 'origin', protected base 'main', fresh evidence,
# on a topic branch. The continuation commands below push to 'poc' (forbidden) so a correctly-detected push
# BLOCKS with FORBIDDEN; that proves the push was both DETECTED and adjudicated, not just "not allowed".
REPO="$(mktemp -d)/repo"; mkdir -p "$REPO"
( cd "$REPO"
  git init -q; git config user.email t@t; git config user.name t
  git remote add poc https://github.com/forbidden-org/prod-repo.git
  git remote add origin https://github.com/forbidden-org/legacy-prod.git
  git remote add safe https://github.com/safe-org/app.git
  mkdir -p .preflight .preflight/gate
  cat > .preflight/config.json <<JSON
{ "branch": { "base": "main", "remote": "safe",
              "forbiddenRemotes": ["poc","origin"], "forbiddenRepos": ["forbidden-org/prod-repo","forbidden-org/legacy-prod"] } }
JSON
  echo x > f; git add -A; git commit -qm init
  git checkout -q -b topic-work
  h="$(git rev-parse HEAD)"
  printf 'HEAD=%s\n' "$h" > .preflight/gate/stage1-clean
  printf 'HEAD=%s\n' "$h" > .preflight/gate/tests-pass
) >/dev/null 2>&1

# run_hook_json <command-string-with-real-newlines> -> sets RC, OUT. Builds tool JSON with jq so embedded
# LF/CRLF survive as real bytes. Drives the engine body directly (G17 watchdog-isolation posture).
run_hook_json() {
  local cmd="$1" json
  json="$(jq -n --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
  OUT="$(cd "$REPO" && printf '%s' "$json" | _PFG_WATCHDOG_CHILD=1 CLAUDE_PROJECT_DIR="$REPO" bash "$HOOK" 2>&1)"; RC=$?
}

LF=$'\n'
CR=$'\r'

# ── assert a continuation-bearing push to a FORBIDDEN remote is BLOCKED (exit 2 + FORBIDDEN) ──
assert_block() {  # $1 = label ; $2 = command (with real newlines), targets a forbidden remote
  run_hook_json "$2"
  if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'FORBIDDEN\|did not reach\|BLOCKED'; then
    if printf '%s' "$OUT" | grep -qi 'FORBIDDEN'; then ok "$1 -> BLOCK (exit 2, FORBIDDEN destination)"
    else ok "$1 -> BLOCK (exit 2, fail-closed)"; fi
  else
    bad "$1 -> expected BLOCK (exit 2), got RC=$RC :: $(printf '%s' "$OUT" | head -1)"
  fi
}

echo "── THE EXACT INCIDENT SHAPE (forbidden 'origin', backslash-LF before push) ──"
assert_block "INCIDENT: git -c remote.origin.url=file:///probe \\<LF> push origin" \
  "git -c remote.origin.url=file:///__probe__ \\${LF}  push origin HEAD:refs/heads/preflight-live-probe"

echo "── required continuation forms (all target forbidden 'poc') ──"
assert_block "C1: git \\<LF> push origin (forbidden via origin)"      "git \\${LF}push origin HEAD:main"
assert_block "C2: git \\<CRLF> push"                                  "git \\${CR}${LF}push poc HEAD:main"
assert_block "C3: git -c key=value \\<LF> push"                       "git -c http.sslVerify=false \\${LF}push poc HEAD:main"
assert_block "C4: command git \\<LF> push"                            "command git \\${LF}push poc HEAD:main"
assert_block "C5: VAR=value git \\<LF> push"                          "GIT_TRACE=0 git \\${LF}push poc HEAD:main"
assert_block "C6: multiple continuations (git \\<LF> -c k=v \\<LF> push)" "git \\${LF}-c http.sslVerify=false \\${LF}push poc HEAD:main"
assert_block "C7: continuation inside a compound (cd ... && git \\<LF> push)" "cd \"$REPO\" && git \\${LF}push poc HEAD:main"

echo "── no-false-positive: continuations must NOT over-block benign commands ──"
# ordinary multiline NON-push command remains allowed (exit 0)
run_hook_json "echo building \\${LF}  && echo done"
[ "$RC" -eq 0 ] && ok "NFP1: ordinary multiline non-push (echo \\<LF> && echo) -> ALLOW (exit 0)" \
                || bad "NFP1: benign multiline command should ALLOW, got RC=$RC :: $(printf '%s' "$OUT" | head -1)"
# a build with a continuation that merely mentions 'push' in a string does not become a push/hard-block
run_hook_json "npm run build \\${LF}  --message \"do not push to prod\""
[ "$RC" -eq 0 ] && ok "NFP2: continuation w/ 'push' only inside a string arg -> ALLOW (exit 0)" \
                || bad "NFP2: 'push' in a string should not hard-block, got RC=$RC :: $(printf '%s' "$OUT" | head -1)"
# a SAFE push across a continuation still resolves (not over-blocked to FORBIDDEN; AUTO/CONFIRM/evidence path)
run_hook_json "git \\${LF}push safe HEAD:topic-work"
if printf '%s' "$OUT" | grep -qi 'FORBIDDEN'; then
  bad "NFP3: safe-remote push across a continuation wrongly hit FORBIDDEN :: $(printf '%s' "$OUT" | head -1)"
else
  ok "NFP3: safe-remote push across a continuation is NOT mis-flagged FORBIDDEN (resolves to evidence/tier path)"
fi

echo ""
echo "pre-push-continuation-failopen tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

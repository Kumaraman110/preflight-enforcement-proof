#!/usr/bin/env bash
# Behavioral test: ROUTER STRUCTURAL CANDIDATE CLASSIFICATION (BLOCKER 3).
#
# THE DEFECT: the old router matched raw substrings (*push* / *gh*pr*create* / *.preflight/gate/*) on the
# JSON blob, so PLAIN DATA containing those bytes — `echo "push"`, `grep push file`, `ls docs/push-notes`,
# `printf '.preflight/gate/'`, a commit message with the word push, a filename with "push" — was routed
# into the ~13s heavy engine. That is friction on ordinary work.
#
# THE FIX: a builtins-only STRUCTURAL recognizer that routes the actual governed SHAPES (git push, gh pr
# create/merge, script wrappers, source/dot, eval/xargs indirection, sentinel writes) and keeps benign
# literal-text cases on the ZERO-SPAWN fast path. This test proves BOTH directions:
#   • BENIGN literal cases → router exits 0 (allow), engine NEVER invoked, ZERO external spawns.
#   • GOVERNED shapes → router routes to the engine (engine witness fires).
# Detection of real governed ops must NOT be weakened — every spelling the engine parses is still routed.
#
# Exit 0 = all pass.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROUTER="$ROOT/hooks/pre-bash-risk-router"
ENGINE="$ROOT/hooks/pre-push-gate-engine"
[ -f "$ROUTER" ] || { echo "FAIL: router not found" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
nlines() { awk 'NF{c++} END{print c+0}' "$1" 2>/dev/null || echo 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T" 2>/dev/null || true' EXIT
WITNESS="$T/spawned.log"; : > "$WITNESS"
ENGINE_WITNESS="$T/engine-invoked.log"; : > "$ENGINE_WITNESS"
# spawn-witness shim dir (do NOT shim bash/sh/timeout/env — the harness's own machinery).
SHIM="$T/shim"; mkdir -p "$SHIM"
for bin in git jq grep sed awk cat mktemp date tr cut sort head tail dirname basename rm cp mv tee touch find xargs python python3 node perl; do
  real="$(command -v "$bin" 2>/dev/null || true)"
  { echo '#!/bin/sh'; printf 'printf "%%s\\n" "%s" >> "%s"\n' "$bin" "$WITNESS"
    [ -n "$real" ] && printf 'exec "%s" "$@"\n' "$real" || echo 'exit 0'; } > "$SHIM/$bin"
  chmod +x "$SHIM/$bin"
done
# workspace mirroring an install; engine wrapped with an invocation witness.
WS="$T/ws"; mkdir -p "$WS/hooks" "$WS/lib" "$WS/.preflight/gate"
cp "$ROUTER" "$WS/hooks/pre-bash-risk-router"
cp "$ROOT/hooks/pre-push-gate" "$WS/hooks/" 2>/dev/null || true
cp "$ROOT/lib/config-overlay.sh" "$ROOT/lib/heartbeat.sh" "$WS/lib/" 2>/dev/null || true
{ echo '#!/usr/bin/env bash'; printf 'printf "engine\\n" >> "%s"\n' "$ENGINE_WITNESS"; printf 'exec bash "%s" "$@"\n' "$ENGINE"; } > "$WS/hooks/pre-push-gate-engine"
chmod +x "$WS/hooks/pre-push-gate-engine"
WROUTER="$WS/hooks/pre-bash-risk-router"
( cd "$WS" && git init -q && git commit -q --allow-empty -m init && git checkout -q -b feature/topic ) >/dev/null 2>&1
HEAD="$(cd "$WS" && git rev-parse HEAD)"
for ev in tests-pass stage1-clean; do printf 'HEAD=%s\nts=now\n' "$HEAD" > "$WS/.preflight/gate/$ev"; done
printf '{"branch":{"base":"main","remote":"origin","forbiddenRemotes":["origin"],"forbiddenRepos":[]}}' > "$WS/.preflight/config.json"

mkjson() {  # build tool JSON with jq so embedded quotes/spaces are faithfully escaped (the real wire shape).
  if command -v jq >/dev/null 2>&1; then jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'
  else printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; fi
}
# Run the router; sets RC, SPAWNS, ENG.
run() {  # $1 = command string
  : > "$WITNESS"; : > "$ENGINE_WITNESS"
  local j; j="$(mkjson "$1")"
  ( cd "$WS" && printf '%s' "$j" | PATH="$SHIM:$PATH" PREFLIGHT_ENGINE_DEADLINE=10 timeout 60 bash "$WROUTER" "$j" >/dev/null 2>&1 ); RC=$?
  SPAWNS="$(nlines "$WITNESS")"; ENG="$(nlines "$ENGINE_WITNESS")"
}
# BENIGN: must stay on the fast path — exit 0, engine NOT invoked, ZERO external spawns.
benign() {  # $1 label ; $2 command
  run "$2"
  if [ "$RC" -eq 0 ] && [ "$ENG" -eq 0 ] && [ "$SPAWNS" -eq 0 ]; then
    ok "BENIGN $1 → fast path (exit 0, engine untouched, 0 spawns)"
  else
    bad "BENIGN $1 → expected fast path; got rc=$RC engine=$ENG spawns=$SPAWNS :: $2"
  fi
}
# GOVERNED: must route to the engine (engine witness fires at least once).
governed() {  # $1 label ; $2 command
  run "$2"
  [ "$ENG" -ge 1 ] && ok "GOVERNED $1 → routed to engine (engine_invocations=$ENG)" \
                   || bad "GOVERNED $1 → engine NOT invoked (rc=$RC engine=$ENG) :: $2"
}
# GOVERNED via RAW wire JSON (bypasses Git-Bash/MSYS arg path-conversion, which rewrites a leading-slash
# absolute path like /opt/tools/git → C:\Program Files\Git\opt\tools\git BEFORE it reaches the wire — a
# test-harness artifact, not router behavior). $2 = the EXACT command-value bytes to embed verbatim.
governed_raw() {  # $1 label ; $2 command value (embedded literally into the JSON, no escaping)
  : > "$WITNESS"; : > "$ENGINE_WITNESS"
  local blob="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$2\"}}"
  ( cd "$WS" && printf '%s' "$blob" | PATH="$SHIM:$PATH" PREFLIGHT_ENGINE_DEADLINE=10 timeout 60 bash "$WROUTER" "$blob" >/dev/null 2>&1 )
  local eng; eng="$(nlines "$ENGINE_WITNESS")"
  [ "$eng" -ge 1 ] && ok "GOVERNED $1 → routed to engine (raw wire; engine_invocations=$eng)" \
                   || bad "GOVERNED $1 → engine NOT invoked (raw wire; engine=$eng) :: $2"
}

echo "════ BENIGN literal-text cases must STAY on the zero-spawn fast path (BLOCKER 3) ════"
benign "echo push"                  'echo "push"'
benign "echo word push in sentence" 'echo "remember to push later"'
benign "grep push file"             'grep push notes.txt'
benign "ls docs/push-notes"         'ls docs/push-notes'
benign "printf gate path literal"   "printf '.preflight/gate/'"
benign "commit msg contains push"   'git commit -m "feat: add push-notification handler"'
benign "filename contains push"     'cat src/pushService.ts'
benign "git status"                 'git status --porcelain'
benign "git log grep push"          'git log --grep=push --oneline'
benign "bash --version"             'bash --version'
benign "bash -x flagonly no script" 'bash -x'
benign "echo gh pr create words"    'echo "open a gh pr create docs page"'
benign "cd into push dir"           'cd src/push && ls'
benign "rm a push-named file"       'rm -f build/push.log'
benign "gh pr view (read-only)"     'gh pr view 12'
benign "gh pr list (read-only)"     'gh pr list'

echo "════ GOVERNED shapes must STILL route to the engine (detection not weakened) ════"
governed "plain git push"           'git push origin HEAD:topic'
governed "git -C dir push"          'git -C /repo push origin main'
governed "git -c k=v push"          'git -c http.x=y push origin main'
governed "command git push"         'command git push origin main'
governed "backslash git push"       '\git push origin main'
governed "env-prefixed git push"    'GIT_TRACE=1 git push origin main'
# Path-qualified git: an absolute-path git program. Sent via RAW wire bytes because Git-Bash/MSYS rewrites
# a leading-slash path in a jq ARG (→ C:\Program Files\Git\...) before it reaches the wire — a harness
# artifact. On the real Claude Code wire the JSON command arrives verbatim; '*/git' matches /opt/tools/git.
governed_raw "path-qualified git push" '/opt/tools/git push origin main'
governed "git push in 2nd segment"  'cd /repo && git push origin main'
governed "git push unknown-gopt"    'git --future-flag push origin main'
governed "bare git push"            'git push'
governed "gh pr create"             'gh pr create --fill'
governed "gh pr merge"              'gh pr merge 12 --squash'
governed "bash script wrapper"      'bash deploy.sh'
governed "sh script wrapper"        'sh ./run.sh'
governed "bash -c inline"           'bash -c "git push origin main"'
governed "source inclusion"         'source ./env.sh'
governed "dot inclusion"            '. ./env.sh'
governed "eval indirection"         'eval "$CMD"'
governed "xargs indirection"        'echo x | xargs git push'
governed "write-gate parity-clean"  'write-gate-evidence parity-clean'
governed "redirect into sentinel"   'echo x > .preflight/gate/parity-clean'
governed "tee into sentinel"        'echo x | tee .preflight/gate/bootstrap-write-approved'

echo "════ LF / CRLF continuation across the git…push boundary still routes ════"
# Raw wire: a shell '\'+LF continuation. On the wire the backslash is JSON-escaped to '\\' and the LF to
# '\n', so the embedded command-value bytes are exactly:  git SP \ \ \ n push …  . The router unescapes
# (\\→\, \n→LF) then joins the '\'+LF continuation, recovering `git push`. Sent raw to avoid the jq round-
# trip ambiguity around backslash+newline.
governed_raw "LF-continuation push" 'git \\\npush origin HEAD:topic'

echo ""
echo "router-structural-classify: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

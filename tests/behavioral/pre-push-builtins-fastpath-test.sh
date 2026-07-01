#!/usr/bin/env bash
# Behavioral test: BUILTINS-ONLY explicit-remote FORBIDDEN fast path + builtins-only engine heartbeat
# (live Gate-4 23s-timeout latency remediation, Part 2 of the incident series).
#
# THE PROBLEM (after the earlier B-EARLY fast block): on this slow-spawn Windows/Git-Bash host the forbidden
# 'origin' decision still landed at ~13-15s of engine-internal time, because it ran AFTER the engine's
# entry heartbeat (which spawned `date` + `git rev-parse HEAD` ~1.45s), the sentinel-tripwire greps, the
# `_pfg_target_cwd` grep, the awk continuation-join, the structural parser's greps/seds, and a jq
# forbiddenRemotes read. Stacked per-spawn tax (~1-1.5s each, jittery) pushed wall-time p95/max to ~25.5s,
# above the router's 23s candidate deadline — another live timeout remained plausible.
#
# THE FIX (this test proves it):
#   1. A BUILTINS-ONLY engine heartbeat (_pfg_heartbeat_builtin) replaces the git/date-spawning lib call on
#      the candidate path: timestamp via `printf '%(%s)T'`/EPOCHSECONDS, HEAD field = literal "candidate".
#   2. A BUILTINS-ONLY explicit-remote fast parser (_pfg_fast_parse_remote) + early forbidden decision runs
#      IMMEDIATELY after command extraction — before the tripwire greps, target-cwd grep, continuation-join,
#      structural parser, and jq read. A confident explicit forbidden remote → exit 2 with NO git/date/awk/
#      sed/grep/evidence-gate/remote-URL spawn.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENGINE="$ROOT/hooks/pre-push-gate-engine"
ROUTER="$ROOT/hooks/pre-bash-risk-router"
[ -f "$ENGINE" ] || { echo "FAIL: engine not found at $ENGINE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required."; echo ""; echo "pre-push-builtins-fastpath tests: 0 passed, 0 failed (skipped)"; exit 0; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# ── Consumer-topology repo: forbidden 'origin'+'poc', intended 'safe', protected base, fresh evidence ──
# Collect all temp roots for cleanup on exit (each mktemp -d below is appended).
_CLEAN=()
trap 'for d in "${_CLEAN[@]}"; do rm -rf "$d" 2>/dev/null || true; done' EXIT
REPO="$(mktemp -d)/repo"; mkdir -p "$REPO"; _CLEAN+=("$(dirname "$REPO")")
( cd "$REPO"
  git init -q; git config user.email t@t; git config user.name t
  git remote add origin https://github.com/forbidden-org/legacy-prod.git
  git remote add poc    https://github.com/forbidden-org/prod-repo.git
  git remote add safe   https://github.com/safe-org/app.git
  mkdir -p .preflight .preflight/gate
  cat > .preflight/config.json <<JSON
{ "branch": { "base": "main", "remote": "poc",
              "forbiddenRemotes": ["origin","poc"], "forbiddenRepos": ["forbidden-org/legacy-prod","forbidden-org/prod-repo"] } }
JSON
  echo x > f; git add -A; git commit -qm init
  git checkout -q -b topic-work
  h="$(git rev-parse HEAD)"
  printf 'HEAD=%s\n' "$h" > .preflight/gate/stage1-clean
  printf 'HEAD=%s\n' "$h" > .preflight/gate/tests-pass
) >/dev/null 2>&1

LF=$'\n'; CR=$'\r'

# A SPACELESS absolute path to a git program, for the "path-qualified git" case. NOTE: a literal
# `/usr/bin/git` cannot be used here — MSYS/Git-Bash path-mangling rewrites it to
# `C:/Program Files/Git/usr/bin/git`, whose embedded SPACE makes it genuinely ambiguous to ANY
# word-splitter (it is no longer a single program token), so the fast parser correctly bails on it.
# A spaceless symlink/copy exercises the path-qualified recognition without that artifact.
GITBIN_DIR="$(mktemp -d)/gb"; mkdir -p "$GITBIN_DIR"; _CLEAN+=("$(dirname "$GITBIN_DIR")")
ln -sf "$(command -v git)" "$GITBIN_DIR/git" 2>/dev/null || cp "$(command -v git)" "$GITBIN_DIR/git"
GITBIN="$GITBIN_DIR/git"

# ── TRIPWIRE PATH: shims that RECORD if invoked, for the binaries the EARLY path must NOT spawn ──────────
# We witness git / date / awk / sed / grep (the prohibited externals on the early forbidden path). We do NOT
# shim jq (the command-extraction spawn is pre-existing and allowed) / cat / mktemp / bash / sh / timeout /
# env (harness machinery). A 'pre-push-gate' tripwire (evidence gate) + a 'git remote get-url' logger prove
# the early decision precedes the evidence gate and any remote-URL resolution.
TRIP="$(mktemp -d)/trip"; mkdir -p "$TRIP"; _CLEAN+=("$(dirname "$TRIP")")
WIT="$TRIP/.witness"; : > "$WIT"
_real_git="$(command -v git)"
# git shim: record EVERY git invocation; specifically tag 'rev-parse' and 'remote get-url'; forward to real git.
cat > "$TRIP/git" <<EOF
#!/bin/sh
printf 'git %s\n' "\$*" >> "$WIT"
exec "$_real_git" "\$@"
EOF
chmod +x "$TRIP/git"
# date / awk / sed / grep tripwires: record (one line per invocation) then forward to the real tool (so any
# FALLBACK path still works). Records just the bin name — presence/count is what the assertions need.
for b in date awk sed grep; do
  _r="$(command -v "$b" 2>/dev/null || true)"
  {
    echo '#!/bin/sh'
    printf 'printf "%%s\\n" "%s" >> "%s"\n' "$b" "$WIT"
    if [ -n "$_r" ]; then printf 'exec "%s" "$@"\n' "$_r"; else echo 'exit 0'; fi
  } > "$TRIP/$b"
  chmod +x "$TRIP/$b"
done

# Robust counter: grep -c prints "N" (and exits 1 on no-match, 2 on missing file). Sanitize to a single int
# so `[ "$n" -eq 0 ]` can never choke on an empty string or a doubled "0\n0".
cnt() {  # $1 = pattern, $2 = file
  local n; n="$(grep -c -- "$1" "$2" 2>/dev/null)"; n="${n%%$'\n'*}"; n="${n//[!0-9]/}"; printf '%s' "${n:-0}"
}

# Wrapper hooks dir so the engine's sibling `pre-push-gate` (evidence gate) is a tripwire, and lib/ resolves.
HK="$(mktemp -d)/hooks"; mkdir -p "$HK" "$(dirname "$HK")/lib"; _CLEAN+=("$(dirname "$HK")")
cp "$ENGINE" "$HK/pre-push-gate-engine"
cp "$ROOT/lib/config-overlay.sh" "$ROOT/lib/heartbeat.sh" "$(dirname "$HK")/lib/" 2>/dev/null || true
# Stage-2B: the engine's authoritative IR parser needs its lib beside it (sibling ../lib) — copy it too,
# else the deterministic-BLOCK gate fires "IR library not found" for every candidate.
cp "$ROOT/lib/shell-structure.sh" "$ROOT/lib/shell-structure-lexer.awk" "$(dirname "$HK")/lib/" 2>/dev/null || true
EVIDENCE_MARKER="$TRIP/.evidence_called"
cat > "$HK/pre-push-gate" <<EOF
#!/usr/bin/env bash
echo evidence >> "$EVIDENCE_MARKER"
exit 0
EOF
chmod +x "$HK/pre-push-gate"
WENGINE="$HK/pre-push-gate-engine"

# run the engine body directly on a command with REAL newlines; capture RC, OUT, witness, markers.
run() {  # $1 = command string (may contain real newlines)
  : > "$WIT"; : > "$EVIDENCE_MARKER"
  local json
  json="$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}')"
  OUT="$(cd "$REPO" && printf '%s' "$json" | PATH="$TRIP:$PATH" _PFG_WATCHDOG_CHILD=1 CLAUDE_PROJECT_DIR="$REPO" timeout 90 bash "$WENGINE" 2>&1)"; RC=$?
}
# run the engine on RAW json (for the malformed-JSON case where we must NOT pre-extract via jq -n)
run_raw() {  # $1 = raw stdin bytes
  : > "$WIT"; : > "$EVIDENCE_MARKER"
  OUT="$(cd "$REPO" && printf '%s' "$1" | PATH="$TRIP:$PATH" _PFG_WATCHDOG_CHILD=1 CLAUDE_PROJECT_DIR="$REPO" timeout 90 bash "$WENGINE" 2>&1)"; RC=$?
}
is_block() { [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'FORBIDDEN'; }
# Fail-CLOSED = NOT a silent allow. Either a hard block (exit 2), OR a CONFIRM (exit 0 + permissionDecision
# "ask" — the human-confirmation tier the engine uses for unresolved/indirection pushes). A silent allow is
# exit 0 with NO permissionDecision JSON (or an explicit "allow") — that is the ONLY failing direction here.
is_failclosed() {
  [ "$RC" -eq 2 ] && return 0
  if [ "$RC" -eq 0 ]; then printf '%s' "$OUT" | grep -q '"permissionDecision":"ask"' && return 0; fi
  return 1
}

echo "════ GROUP 1 — the explicit forbidden-remote forms all BLOCK (is_push=1, explicit_remote=origin) ════"

# 1. exact live LF continuation command (with PATH-shim env prefix + literal $PATH) blocks 'origin'
run "PATH=\"/c/Users/v173617/preflight-gate4-shim:\$PATH\" git \\${LF}push origin HEAD:refs/heads/preflight-live-probe"
is_block && ok "1. exact live LF-continuation candidate → explicit FORBIDDEN 'origin' BLOCK (exit 2)" \
         || bad "1. exact live LF candidate: expected exit2+FORBIDDEN, got RC=$RC :: $(printf '%s' "$OUT" | head -1)"

# 2. CRLF equivalent
run "git \\${CR}${LF}push origin HEAD:main"
is_block && ok "2. CRLF continuation → FORBIDDEN 'origin' BLOCK" || bad "2. CRLF: RC=$RC :: $(printf '%s' "$OUT" | head -1)"

# 3. git -c key=value continuation form
run "git -c http.sslVerify=false \\${LF}push origin HEAD:main"
is_block && ok "3. 'git -c k=v' continuation → FORBIDDEN BLOCK" || bad "3. -c form: RC=$RC :: $(printf '%s' "$OUT" | head -1)"

# 4. command git continuation form
run "command git \\${LF}push origin HEAD:main"
is_block && ok "4. 'command git' continuation → FORBIDDEN BLOCK" || bad "4. command form: RC=$RC :: $(printf '%s' "$OUT" | head -1)"

# 5. environment-prefixed git form
run "GIT_SSH=x FOO=bar git push origin main"
is_block && ok "5. env-prefixed 'VAR=val git push origin' → FORBIDDEN BLOCK" || bad "5. env-prefix: RC=$RC :: $(printf '%s' "$OUT" | head -1)"

# 6. path-qualified git form (spaceless absolute path — see GITBIN note above)
run "$GITBIN push origin main"
is_block && ok "6. path-qualified '<abs>/git push origin' → FORBIDDEN BLOCK" || bad "6. path-qualified: RC=$RC :: $(printf '%s' "$OUT" | head -1)"

# 7. multiple continuations
run "git \\${LF}-c http.sslVerify=false \\${LF}push origin HEAD:main"
is_block && ok "7. multiple continuations → FORBIDDEN BLOCK" || bad "7. multi-continuation: RC=$RC :: $(printf '%s' "$OUT" | head -1)"

echo "════ GROUP 2 — the early FORBIDDEN path spawns NONE of git/date/awk/sed/grep, no evidence gate, no remote-url ════"
# Re-run the exact live candidate and inspect the witness + markers. The early decision must precede ALL of:
#   git (rev-parse / remote get-url / any), date, awk, sed, grep, the evidence gate.
run "PATH=\"/c/Users/v173617/preflight-gate4-shim:\$PATH\" git \\${LF}push origin HEAD:refs/heads/preflight-live-probe"
# git tripwire records 'git <args>'; date/awk/sed/grep record just the bin name (one line per invocation).
_w_git="$(cnt '^git ' "$WIT")"
_w_date="$(cnt '^date$' "$WIT")"
_w_awk="$(cnt '^awk$' "$WIT")"
_w_sed="$(cnt '^sed$' "$WIT")"
_w_grep="$(cnt '^grep$' "$WIT")"
_w_geturl="$(cnt 'remote get-url' "$WIT")"
_w_revparse="$(cnt 'rev-parse' "$WIT")"
is_block || bad "G2 precondition: exact candidate did not BLOCK (RC=$RC) — witness assertions below are moot"
[ "$_w_git" -eq 0 ]    && ok "15a. early forbidden path invoked git ZERO times (no rev-parse, no remote get-url, no git at all)" \
                       || bad "15a. early path invoked git ${_w_git}x: $(grep '^git ' "$WIT" | head -3 | tr '\n' '|')"
[ "$_w_revparse" -eq 0 ] && ok "15b. early forbidden path performed NO 'git rev-parse' (cwd via builtin \$PWD, not git)" \
                       || bad "15b. early path ran 'git rev-parse' ${_w_revparse}x"
[ "$_w_geturl" -eq 0 ] && ok "15c. early forbidden path performed NO 'git remote get-url' (no remote-URL resolution)" \
                       || bad "15c. early path ran 'git remote get-url' ${_w_geturl}x"
[ "$_w_date" -eq 0 ]   && ok "15d. early forbidden path spawned 'date' ZERO times (heartbeat is builtins-only)" \
                       || bad "15d. early path spawned date ${_w_date}x"
# STAGE 2B: the authoritative IR-identify runs ONCE per candidate, BEFORE fast0 (the ordering that closes
# the multi-push fail-open). That ONE step spawns awk exactly TWICE — `awk --version` (impl banner) + the
# `awk -f lexer` scan (both inside lib/shell-structure.sh's single pfg_ss_parse). So the early forbidden
# path spawns awk <=2 (the IR only) — and NOT the heavy-path continuation-join / structural awk. More than
# 2 would mean the heavy pipeline's awk also ran, i.e. fast0 failed to short-circuit.
[ "$_w_awk" -le 2 ]    && ok "15e. early forbidden path spawned 'awk' ${_w_awk}x (<=2: the Stage-2B IR-identify only — awk --version + lexer; fast0 short-circuits before the heavy continuation-join/structural awk)" \
                       || bad "15e. early path spawned awk ${_w_awk}x (>2 → heavy-path awk also ran; fast0 not short-circuiting)"
[ "$_w_sed" -eq 0 ]    && ok "15f. early forbidden path spawned 'sed' ZERO times (no structural-parser sed)" \
                       || bad "15f. early path spawned sed ${_w_sed}x"
[ "$_w_grep" -eq 0 ]   && ok "15g. early forbidden path spawned 'grep' ZERO times (no tripwire/structural grep)" \
                       || bad "15g. early path spawned grep ${_w_grep}x"
[ ! -s "$EVIDENCE_MARKER" ] && ok "15h. early forbidden decision occurred BEFORE the evidence gate (not invoked)" \
                       || bad "15h. evidence gate WAS invoked before the forbidden decision"
printf '%s' "$OUT" | grep -qi 'did not reach a decision\|deadline\|timed out' \
  && bad "15i. diagnostic mentions a TIMEOUT — early decision did not fire" \
  || ok "15i. diagnostic identifies the forbidden remote, not a router timeout"

echo "════ GROUP 3 — no-false-shortcut: safe / implicit / URL / unknown-opt fall through (never wrongly blocked) ════"

# 8. explicit SAFE remote must NOT early-block; falls through to the normal policy path
run "git push safe HEAD:topic-work"
printf '%s' "$OUT" | grep -qi 'FORBIDDEN' && bad "8. safe-remote push wrongly FORBIDDEN-blocked (RC=$RC)" \
  || ok "8. explicit SAFE remote does NOT early-block (falls to normal policy/evidence path)"

# 9. implicit push must NOT use the explicit-name shortcut (no positional remote → no FAST_REMOTE)
run "git push"
printf '%s' "$OUT" | grep -qiE "FORBIDDEN destination 'origin'|FORBIDDEN destination 'poc'" \
  && bad "9. implicit 'git push' wrongly used the forbidden-NAME shortcut" \
  || ok "9. implicit 'git push' (no named remote) does NOT use the name shortcut"

# 10. URL push must NOT be matched by the name shortcut (URL → bail; later forbiddenRepos handles by slug)
#     Use a SAFE URL so a block here would prove the NAME shortcut wrongly fired (not forbiddenRepos).
run "git push https://github.com/safe-org/app.git HEAD:main"
printf '%s' "$OUT" | grep -qiE "config.branch.forbiddenRemotes" \
  && bad "10. URL push wrongly matched the forbidden-NAME shortcut" \
  || ok "10. URL push does NOT use the name shortcut (falls to slug/URL resolution path)"

# 11. unknown git global option → fast parser must bail → full parser/policy decides. The structural parser
#     classes an unknown global option as PRESENT-but-UNRESOLVED → CONFIRM (permissionDecision:ask), which is
#     fail-CLOSED (human confirmation), never a silent allow. Assert fail-closed (block OR ask), proving the
#     fall-through is SAFE even when the builtins shortcut declines.
run "git --unknown-global-opt push origin main"
is_failclosed && ok "11. unknown git global option → fast parser bails, full path fails CLOSED (block or CONFIRM:ask), never silent-allow" \
              || bad "11. unknown-opt fall-through was a SILENT ALLOW (RC=$RC, no ask) — fail-OPEN :: $(printf '%s' "$OUT" | head -2 | tr '\n' ' ')"

echo "════ GROUP 4 — malformed JSON fail-closed + forbiddenRepos intact (existing paths unchanged) ════"

# 12. malformed JSON carrying a continuation forbidden push must remain fail-closed (NOT silent-allow).
#     jq extraction yields empty so the raw blob becomes COMMAND; the fast parser bails on the noisy blob,
#     and the downstream continuation backstop classifies it PRESENT-but-UNRESOLVED → CONFIRM (ask). That is
#     fail-CLOSED (a human confirmation), never a silent allow. Assert fail-closed via is_failclosed.
run_raw "{ \"tool_name\":\"Bash\", \"tool_input\": { \"command\": \"git \\${LF}push origin HEAD:main\" }, BROKEN"
is_failclosed && ok "12. malformed JSON w/ continuation forbidden push stays fail-CLOSED (RC=$RC, block or CONFIRM:ask — not a silent allow)" \
              || bad "12. malformed JSON forbidden push FELL OPEN (RC=$RC, no ask) :: $(printf '%s' "$OUT" | head -1)"

# 13. forbiddenRepos still blocks by RESOLVED slug for a direct forbidden URL (no name on the denylist match)
run "git push https://github.com/forbidden-org/legacy-prod.git HEAD:main"
is_block && ok "13. forbiddenRepos: direct forbidden URL still BLOCKS by resolved slug (later path intact)" \
         || bad "13. forbiddenRepos slug block regressed: RC=$RC :: $(printf '%s' "$OUT" | head -1)"

echo "════ GROUP 5 — builtins-only heartbeat (no external command) ════"

# 14. The engine heartbeat is written WITHOUT spawning date/git. Drive a forbidden candidate (so the engine
#     runs its entry heartbeat then early-exits) and assert: a heartbeat file was appended AND its record is
#     the 3-field builtins form `<digits> candidate pre-push-gate-check`, and NO date/git spawned (G2 covers
#     the spawn witness; here we assert the FORMAT + presence).
HBREPO="$(mktemp -d)/hbrepo"; mkdir -p "$HBREPO/.preflight/gate"; _CLEAN+=("$(dirname "$HBREPO")")
( cd "$HBREPO"; git init -q; git config user.email t@t; git config user.name t
  git remote add origin https://github.com/forbidden-org/legacy-prod.git
  printf '{"branch":{"base":"main","remote":"poc","forbiddenRemotes":["origin"],"forbiddenRepos":[]}}' > .preflight/config.json
  echo x>f; git add -A; git commit -qm i; git checkout -q -b topic
  h="$(git rev-parse HEAD)"; printf 'HEAD=%s\n' "$h" > .preflight/gate/stage1-clean; printf 'HEAD=%s\n' "$h" > .preflight/gate/tests-pass
) >/dev/null 2>&1
: > "$WIT"
HBJSON="$(jq -n --arg c "git push origin HEAD:topic" '{tool_name:"Bash",tool_input:{command:$c}}')"
( cd "$HBREPO" && printf '%s' "$HBJSON" | PATH="$TRIP:$PATH" _PFG_WATCHDOG_CHILD=1 CLAUDE_PROJECT_DIR="$HBREPO" timeout 90 bash "$WENGINE" >/dev/null 2>&1 )
HBFILE="$HBREPO/.preflight/gate/heartbeat-pre-push-gate-check"
if [ -f "$HBFILE" ]; then
  _hb_last="$(tail -1 "$HBFILE")"
  # 3 fields: <digits> candidate pre-push-gate-check
  if printf '%s' "$_hb_last" | grep -qE '^[0-9]+ candidate pre-push-gate-check$'; then
    ok "14a. engine heartbeat appended in the builtins 3-field form ('<ts> candidate pre-push-gate-check'): $_hb_last"
  else
    bad "14a. heartbeat record not in expected builtins 3-field form: '$_hb_last'"
  fi
  # heartbeat write itself spawned no date/git (G2 already covers the early path; this isolates the heartbeat).
  # NOTE: the date tripwire records just the bin name '^date$' (not '^date '); use the sanitizing cnt helper.
  _hb_date="$(cnt '^date$' "$WIT")"; _hb_git="$(cnt 'rev-parse' "$WIT")"
  [ "$_hb_date" -eq 0 ] && [ "$_hb_git" -eq 0 ] \
    && ok "14b. heartbeat written with NO 'date' and NO 'git rev-parse' spawn (builtins-only timestamp + placeholder HEAD)" \
    || bad "14b. heartbeat spawned date=${_hb_date} rev-parse=${_hb_git} (should be builtins-only)"
  # freshness reader compatibility: field 1 is a parseable timestamp the lib's _check_heartbeat_fresh reads
  _hb_ts="$(tail -1 "$HBFILE" | awk '{print $1}')"
  printf '%s' "$_hb_ts" | grep -qE '^[0-9]+$' && [ "$_hb_ts" != "0" ] \
    && ok "14c. heartbeat field 1 is a non-zero integer timestamp (freshness checker stays functional): $_hb_ts" \
    || bad "14c. heartbeat field 1 not a usable timestamp: '$_hb_ts'"
else
  bad "14a. no heartbeat file written at $HBFILE"
fi

echo "════ GROUP 6 — ordinary command stays on the router ZERO-SPAWN fast path (engine never invoked) ════"
# 16. Drive an ORDINARY command through the REAL router with spawn-witness shims + an engine-invocation
#     witness; assert zero spawns and the engine is NOT invoked. (Mirrors router-fastpath-latency-test's
#     mechanism; included here so this suite self-contains the 'ordinary stays fast' guarantee.)
RT="$(mktemp -d)"; SHIM="$RT/shim"; mkdir -p "$SHIM"; _CLEAN+=("$RT")
RWIT="$RT/spawned.log"; : > "$RWIT"; EWIT="$RT/engine-invoked.log"; : > "$EWIT"
for bin in git jq grep sed awk cat mktemp date tr cut sort head tail dirname basename rm cp mv tee touch find xargs python python3 node perl; do
  real="$(command -v "$bin" 2>/dev/null || true)"
  { echo '#!/bin/sh'; printf 'printf "%%s\\n" "%s" >> "%s"\n' "$bin" "$RWIT"
    if [ -n "$real" ]; then printf 'exec "%s" "$@"\n' "$real"; else echo 'exit 0'; fi
  } > "$SHIM/$bin"; chmod +x "$SHIM/$bin"
done
RWS="$RT/ws"; mkdir -p "$RWS/hooks" "$RWS/lib" "$RWS/.preflight/gate"
cp "$ROUTER" "$RWS/hooks/pre-bash-risk-router"
cp "$ROOT/lib/config-overlay.sh" "$ROOT/lib/heartbeat.sh" "$RWS/lib/" 2>/dev/null || true
{ echo '#!/usr/bin/env bash'; printf 'printf "engine\\n" >> "%s"\n' "$EWIT"; printf 'exec bash "%s" "$@"\n' "$ENGINE"; } > "$RWS/hooks/pre-push-gate-engine"
chmod +x "$RWS/hooks/pre-push-gate-engine"
( cd "$RWS" && git init -q && git commit -q --allow-empty -m init ) >/dev/null 2>&1
printf '{"branch":{"base":"main","remote":"origin","forbiddenRemotes":[],"forbiddenRepos":[]}}' > "$RWS/.preflight/config.json"
ORD='{"tool_name":"Bash","tool_input":{"command":"echo hello world"}}'
( cd "$RWS" && printf '%s' "$ORD" | PATH="$SHIM:$PATH" bash "$RWS/hooks/pre-bash-risk-router" "$ORD" >/dev/null 2>&1 )
_ord_spawns="$(wc -l < "$RWIT" | tr -d ' ')"; _ord_eng="$(wc -l < "$EWIT" | tr -d ' ')"
{ [ "$_ord_spawns" -eq 0 ] && [ "$_ord_eng" -eq 0 ]; } \
  && ok "16. ordinary 'echo' command → router ZERO external spawns, engine NOT invoked (fast path intact)" \
  || bad "16. ordinary command spawned=${_ord_spawns} engine_invoked=${_ord_eng} (fast path regressed)"

echo ""
echo "pre-push-builtins-fastpath tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

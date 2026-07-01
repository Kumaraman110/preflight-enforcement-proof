#!/usr/bin/env bash
# Behavioral test: the push-safety control plane FAILS CLOSED when it wedges/stalls — AND a wedge can
# never disable ordinary Bash (the P0 router/engine split).
#
# ARCHITECTURE (post-P0 split):
#   pre-bash-risk-router  — owns the CANDIDATE deadline (PREFLIGHT_ENGINE_DEADLINE, default 30s). A
#       candidate (push/PR/sentinel) whose engine doesn't decide in time -> the router BLOCKs that
#       candidate (exit 2). An ORDINARY command never invokes the engine, so a wedged engine cannot block it.
#   pre-push-gate-engine  — retains Layer-2 per-subprocess wedge-bounding (a single stalled git/jq fails
#       closed fast, without waiting for the router's outer deadline).
#
# THE HOLE THIS GUARDS (RED, pre-split): the monolith ran the heavy body + its self-watchdog for EVERY
# Bash call; on a slow-spawn host the watchdog fired on ORDINARY commands too -> exit 2 for everything ->
# autonomy denied. GREEN: the router's fast path allows ordinary commands with zero engine involvement;
# the deadline is scoped to candidates only.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROUTER="$ROOT/hooks/pre-bash-risk-router"
ENGINE="$ROOT/hooks/pre-push-gate-engine"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

for f in "$ROUTER" "$ENGINE"; do
  [ -f "$f" ] || { bad "missing $f"; echo ""; echo "pre-push-wedge-failclosed tests: ${PASS} passed, ${FAIL} failed"; exit 1; }
done
command -v timeout >/dev/null 2>&1 || { echo "SKIP: 'timeout' unavailable — deadline degrades to inline (documented)."; echo ""; echo "pre-push-wedge-failclosed tests: 0 passed, 0 failed (skipped)"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

mk_ws() {
  local ws="$T/$1"; mkdir -p "$ws/.preflight/gate"
  ( cd "$ws" && git init -q && git commit -q --allow-empty -m init && git checkout -q -b feature/topic-x ) >/dev/null 2>&1
  local head; head="$(cd "$ws" && git rev-parse HEAD)"
  for ev in tests-pass stage1-clean; do printf 'HEAD=%s\nts=now\n' "$head" > "$ws/.preflight/gate/$ev"; done
  printf '{"branch":{"base":"main","remote":"origin","forbiddenRemotes":[],"forbiddenRepos":[]}}' > "$ws/.preflight/config.json"
  # ship the router + engine + libs next to the workspace so the router resolves its sibling engine
  mkdir -p "$ws/hooks" "$ws/lib"
  cp "$ROUTER" "$ENGINE" "$ROOT/hooks/pre-push-gate" "$ws/hooks/" 2>/dev/null
  cp "$ROOT/lib/config-overlay.sh" "$ROOT/lib/heartbeat.sh" "$ws/lib/" 2>/dev/null
  # Stage-2B: the authoritative IR parser lib must sit beside the copied engine (sibling ../lib).
  cp "$ROOT/lib/shell-structure.sh" "$ROOT/lib/shell-structure-lexer.awk" "$ws/lib/" 2>/dev/null
  echo "$ws"
}
WS="$(mk_ws optedin)"
WROUTER="$WS/hooks/pre-bash-risk-router"
WENGINE="$WS/hooks/pre-push-gate-engine"

# git stub that HANGS on every call (worst-case fully-wedged engine).
STUB_ALL="$T/stub_all"; mkdir -p "$STUB_ALL"
printf '#!/bin/sh\nsleep 999\n' > "$STUB_ALL/git"; chmod +x "$STUB_ALL/git"
# git stub that is fast EXCEPT `remote get-url`, which hangs (realistic network/credential wedge).
STUB_REMOTE="$T/stub_remote"; mkdir -p "$STUB_REMOTE"
cat > "$STUB_REMOTE/git" <<EOF
#!/bin/sh
case "\$*" in
  *"remote get-url"*) sleep 999 ;;
  *) exec $(command -v git) "\$@" ;;
esac
EOF
chmod +x "$STUB_REMOTE/git"

PUSH='{"tool_name":"Bash","tool_input":{"command":"git push origin HEAD:feature/x"}}'
ORD='{"tool_name":"Bash","tool_input":{"command":"echo hello"}}'

# ── W1: a CANDIDATE push with a fully-wedged engine -> router BLOCKs (exit 2), fail-CLOSED. ──
# Engine deadline 12s — chosen ABOVE the router's 10s floor and BELOW its derived ceiling (platform-35 −
# grace-2 − overhead-10 = 23s) so the value passes through UN-clamped and the message names exactly "12s".
# (An earlier version set 3s and grepped '3s', but the router floors the deadline to a 10s minimum, so the
# message correctly read "10s" — that was a STALE TEST STRING, not a code bug. We pick a value inside the
# [floor,ceiling] band so the assertion is exact.) The router's deadline (not the test's platform `timeout`)
# renders the BLOCK: the block lands at ~12s, well under the 60s platform ceiling here.
errf="$(mktemp)"; _w1s="$EPOCHREALTIME"
( cd "$WS" && printf '%s' "$PUSH" | PATH="$STUB_ALL:$PATH" PREFLIGHT_ENGINE_DEADLINE=12 \
    timeout 60 bash "$WROUTER" "$PUSH" >/dev/null 2>"$errf" ); _rc=$?
_w1e="$EPOCHREALTIME"; _w1el="$(awk -v s="$_w1s" -v e="$_w1e" 'BEGIN{printf "%.0f", e-s}')"
# The engine-failure diagnostic names the 12s candidate deadline and states ENGINE FAILURE (not a policy
# approval). The message wraps across lines, so match the whole file (-z) tolerant of the wrap, and ALSO
# require it does NOT recommend a human-shell bypass (principle 6) and DOES state it is not an approval.
# Flatten newlines so the wrapped message ("…its 12s\n  candidate deadline…") is matchable on one line;
# -a treats input as text (the stderr may carry odd bytes on a wedged run).
_w1msg="$(tr '\n' ' ' < "$errf" 2>/dev/null)"
if [ "$_rc" -eq 2 ] \
   && printf '%s' "$_w1msg" | grep -aqiE 'FAILED to reach a policy decision within its 12s' \
   && printf '%s' "$_w1msg" | grep -aqiE 'ENGINE FAILURE|not a[[:space:]]+policy approval|NOT a substitute for a policy decision' \
   && ! printf '%s' "$_w1msg" | grep -aqiE 'from a human shell|push from a human' \
   && [ "$_w1el" -lt 40 ]; then
  ok "W1: candidate push + fully-wedged engine -> router BLOCK (exit 2) in ~${_w1el}s, names the 12s candidate deadline AND states engine-failure-not-approval, with NO human-shell-bypass steering (fail-closed)"
else
  bad "W1: expected exit 2 + engine-failure '12s' deadline message (no human-shell steering) in <40s, got RC=$_rc elapsed=${_w1el}s msg='$(head -1 "$errf")'"
fi
rm -f "$errf"

# ── W2 (THE AUTONOMY FIX): an ORDINARY command with the engine fully wedged -> ALLOW (exit 0), FAST. ──
# This is the exact incident: pre-split, a wedged engine blocked every Bash command. Post-split, the
# router's fast path never invokes the engine for an ordinary command, so it allows instantly. We even
# leave the wedging stub on PATH and a tiny engine deadline to prove the engine is simply never consulted.
errf="$(mktemp)"; start="$(date +%s)"
( cd "$WS" && printf '%s' "$ORD" | PATH="$STUB_ALL:$PATH" PREFLIGHT_ENGINE_DEADLINE=3 \
    timeout 30 bash "$WROUTER" "$ORD" >/dev/null 2>"$errf" ); _rc=$?
end="$(date +%s)"; _el=$((end - start))
if [ "$_rc" -eq 0 ] && [ "$_el" -lt 10 ]; then
  ok "W2: ordinary 'echo' with a fully-wedged engine -> ALLOW (exit 0) in ${_el}s (engine never invoked; autonomy preserved)"
else
  bad "W2: ordinary command must ALLOW fast even with a wedged engine, got RC=$_rc elapsed=${_el}s"
fi
rm -f "$errf"

# ── W3: after a candidate times out, the NEXT ordinary command still succeeds immediately. ──
( cd "$WS" && printf '%s' "$PUSH" | PATH="$STUB_ALL:$PATH" PREFLIGHT_ENGINE_DEADLINE=3 timeout 30 bash "$WROUTER" "$PUSH" >/dev/null 2>&1 )
( cd "$WS" && printf '%s' "$ORD" | PATH="$STUB_ALL:$PATH" PREFLIGHT_ENGINE_DEADLINE=3 timeout 30 bash "$WROUTER" "$ORD" >/dev/null 2>&1 ); _rc=$?
[ "$_rc" -eq 0 ] && ok "W3: ordinary command immediately after a candidate timeout -> ALLOW (exit 0); no lingering denial" \
                 || bad "W3: post-timeout ordinary command should allow, got RC=$_rc"

# ── W4: REALISTIC wedge (only `git remote get-url` hangs) -> the ENGINE's Layer-2 subprocess bounding
#       fails closed on its own. Drive the engine body directly; assert exit 2 with the L2/wedge message. ──
errf="$(mktemp)"; start="$(date +%s)"
( cd "$WS" && printf '%s' "$PUSH" | PATH="$STUB_REMOTE:$PATH" \
    timeout 120 bash "$WENGINE" "$PUSH" >/dev/null 2>"$errf" ); _rc=$?
end="$(date +%s)"; _el=$((end - start))
if [ "$_rc" -eq 2 ] && grep -qiE 'timed out|wedge|did not reach' "$errf"; then
  ok "W4: realistic remote-wedge -> engine Layer-2 per-subprocess bounding fail-CLOSED (exit 2) in ${_el}s"
else
  bad "W4: engine Layer-2 should fail-closed (exit 2) on a wedged 'git remote get-url', got RC=$_rc msg='$(head -1 "$errf")'"
fi
rm -f "$errf"

# ── W5: engine MISSING -> router BLOCKs a candidate (scoped) but ALLOWs ordinary. ──
mv "$WENGINE" "$WENGINE.away"
( cd "$WS" && printf '%s' "$PUSH" | bash "$WROUTER" "$PUSH" >/dev/null 2>/tmp/.w5p ); _rcp=$?
( cd "$WS" && printf '%s' "$ORD"  | bash "$WROUTER" "$ORD"  >/dev/null 2>/dev/null ); _rco=$?
mv "$WENGINE.away" "$WENGINE"
{ [ "$_rcp" -eq 2 ] && [ "$_rco" -eq 0 ]; } \
  && ok "W5: engine MISSING -> candidate BLOCKED (exit 2), ordinary ALLOWED (exit 0) — scoped containment" \
  || bad "W5: expected candidate=2 ordinary=0, got push=$_rcp ordinary=$_rco"

# ── D-series: ENGINE decision logic intact on a NORMAL (unwedged) run, body-direct. ──
# IMPORTANT — the probe timeout here is the TEST's own ceiling on the engine BODY (run directly, NOT via the
# router), so it has NO bearing on the production timeout-budget invariant (that lives in the router; see
# tests/behavioral/router-timeout-budget-test.sh). On this Windows/Git-Bash scan-on-exec host the engine body
# takes 117–166s to adjudicate a single push (every git rev-parse/diff pays the spawn tax); on a normal host
# it is seconds. An earlier 90s ceiling was TOO TIGHT for this host and killed the probe at rc=124 even though
# the engine reaches the CORRECT verdict given time — so we use a generous 300s ceiling. This only bounds the
# direct-body probe; it is NOT a product SLO.
_D_PROBE_TIMEOUT="${PREFLIGHT_D_PROBE_TIMEOUT:-300}"
probe_engine() {  # $1 = push cmd ; sets RC, DEC (real git, watchdog-free engine body)
  local cmd="$1" json outf; json="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd")"
  outf="$(mktemp)"
  ( cd "$WS" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$WS" timeout "$_D_PROBE_TIMEOUT" bash "$WENGINE" "$json" >"$outf" 2>/dev/null ); RC=$?
  DEC="$(jq -r '.hookSpecificOutput.permissionDecision // ""' "$outf" 2>/dev/null || echo "")"
  rm -f "$outf"
}
probe_engine 'git push origin HEAD:feature/x'
{ [ "$RC" -eq 0 ] && [ "$DEC" = "allow" ]; } \
  && ok "D1: engine AUTO decision intact (exit 0 + allow) on a clean run" \
  || bad "D1: AUTO push should be 0/allow, got RC=$RC DEC=$DEC"
probe_engine 'git push origin HEAD:main'
{ [ "$RC" -eq 0 ] && [ "$DEC" = "ask" ]; } \
  && ok "D2: engine CONFIRM decision intact (exit 0 + ask) on a clean run" \
  || bad "D2: CONFIRM push should be 0/ask, got RC=$RC DEC=$DEC"

echo ""
echo "pre-push-wedge-failclosed tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Behavioral PERFORMANCE test: Stage-2B authoritative git-push path must retain SAFE MARGIN under the
# router's candidate deadline. The IR parser may no longer skip, so this measures the COMPLETE candidate
# processing (awk spawn + scan + protocol validation + IR construction + operation extraction + push policy
# + diagnostics) per case and asserts the Phase-7 disposition:
#   • a supported AUTO/CONFIRM case must complete with MEANINGFUL MARGIN below the deadline (PASS);
#     timing out / engine-failure / racing immediately below it → FAIL (AUTHORITATIVE PERFORMANCE INSUFFICIENT);
#   • a forbidden case blocking early → PASS (provided no represented push executes);
#   • parser/AWK failure → deterministic BLOCK (a timeout that merely fails-closed is NOT an acceptable PASS).
#
# "Safe margin" gate: MARGIN_MS below the deadline. The deadline is DERIVED from the router's OWN constants
# (SINGLE SOURCE — no hardcoded copy to drift): ceiling = _RTR_PLATFORM_TIMEOUT_S - kill_grace - overhead.
# A supported AUTO/CONFIRM case must finish under PFG_PERF_SAFE_MS (default = deadline - 5000, i.e. >=5s
# margin). Tunable via env for a fast CI host. Records per case: total wall ms, parser (IR) ms, decision,
# and margin. Emits a machine-readable EVIDENCE block so CI logs carry the numbers explicitly.
#
# NOTE (heavy scan-on-exec hosts): the wall time is dominated by per-spawn endpoint-security scanning, not
# the engine's algorithm. The deadline widening (35s->60s platform, 48s ceiling) exists precisely so a
# CORRECT verdict on such a host is not killed mid-decision; this test's margin gate rides the derived value.
#
# Exit 0 = all pass. Isolated mktemp repos, string-only remotes, no network, no consumer.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$ROOT/hooks/pre-push-gate-engine"
ROUTER="$ROOT/hooks/pre-bash-risk-router"
[ -f "$HOOK" ] || { echo "FAIL: engine not found ($HOOK)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; echo "ir-push-perf tests: 0 passed, 0 failed"; exit 0; }

# ── Derive the router candidate deadline from the router's OWN constants (single source of truth). This
# tracks the timeout-budget automatically: if the platform timeout / ceiling changes, this test follows
# without a manual edit (no dual-source drift the way a hardcoded 23000 would). Fallback keeps the test
# runnable if the constants can't be read. ──
_rtr_const(){ grep -E "^$1=" "$ROUTER" 2>/dev/null | head -1 | sed -E "s/^$1=([0-9]+).*/\1/"; }
_PLAT_S="$(_rtr_const _RTR_PLATFORM_TIMEOUT_S)"; _KG_S="$(_rtr_const _RTR_KILL_GRACE_S)"; _OV_S="$(_rtr_const _RTR_OVERHEAD_MARGIN_S)"
if [ -n "$_PLAT_S" ] && [ -n "$_KG_S" ] && [ -n "$_OV_S" ]; then
  _CEIL_S=$(( _PLAT_S - _KG_S - _OV_S )); [ "$_CEIL_S" -lt 10 ] && _CEIL_S=10
else
  _CEIL_S=48   # fallback matching the shipped 60s-platform derivation
fi
DEADLINE_MS="${PFG_PERF_DEADLINE_MS:-$(( _CEIL_S * 1000 ))}"   # the router candidate deadline (derived)
SAFE_MS="${PFG_PERF_SAFE_MS:-$(( DEADLINE_MS - 5000 ))}"       # supported AUTO/CONFIRM must finish >=5s under it
PROBE_TO="${PFG_PERF_PROBE_TO:-$(( _CEIL_S + 17 ))}"           # hard probe cap (s); a run reaching this is a timeout

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
REALGIT="$(command -v git)"
SHIMDIR="$T/shim"; mkdir -p "$SHIMDIR"; MARKER="$T/pushed.marker"
cat > "$SHIMDIR/git" <<EOF
#!/bin/sh
for a in "\$@"; do [ "\$a" = push ] && { echo pushed >> "$MARKER"; exit 0; }; done
exec "$REALGIT" "\$@"
EOF
chmod +x "$SHIMDIR/git"

mk_ws() {
  local ws="$T/$1"; mkdir -p "$ws/.preflight/gate"
  ( cd "$ws" && "$REALGIT" init -q && "$REALGIT" commit -q --allow-empty -m init && "$REALGIT" checkout -q -b "$2" 2>/dev/null || (cd "$ws" && "$REALGIT" branch -m "$2") )
  local h; h="$(cd "$ws" && "$REALGIT" rev-parse HEAD)"
  for ev in tests-pass stage1-clean; do printf 'HEAD=%s\nts=now\n' "$h" > "$ws/.preflight/gate/$ev"; done
  printf '{"branch":{"base":"main","remote":"origin","forbiddenRemotes":["evil"],"forbiddenRepos":["Org/PROD"]}}' > "$ws/.preflight/config.json"
  echo "$ws"
}
WS="$(mk_ws optedin feature/x)"

# run one case → sets RC, DEC, WALL_MS, PARSER_MS (from PFG_SS_SCANNER_DURATION_MS via the engine timing), EXECD.
# We capture the engine's own IR stage delta from PREFLIGHT_ENGINE_TIMING for the parser component.
measure() {  # $1 cmd
  local cmd="$1" js tf; tf="$T/timing.$$"; : > "$MARKER"
  js="$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)")"
  local t0 t1; t0=$EPOCHREALTIME
  local o; o="$(cd "$WS" && printf '%s' "$js" | PATH="$SHIMDIR:$PATH" CLAUDE_PROJECT_DIR="$WS" PREFLIGHT_ENGINE_TIMING=1 PREFLIGHT_ENGINE_TIMING_FILE="$tf" timeout "$PROBE_TO" bash "$HOOK" "$js" 2>/dev/null)"; RC=$?
  t1=$EPOCHREALTIME
  local u0="${t0/./}" u1="${t1/./}"; WALL_MS=$(( (u1-u0)/1000 ))
  DEC="$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision//""' 2>/dev/null || echo "")"
  EXECD=0; [ -s "$MARKER" ] && EXECD=1
  # parser component: delta between command-extracted and ir-identify stages, if timing present.
  PARSER_MS="?"
  if [ -f "$tf" ]; then
    local ce ii
    ce="$(awk '/command-extracted/{print $2}' "$tf" 2>/dev/null | tr -d 'ms' | head -1)"
    ii="$(awk '/ir-identify/{print $2}' "$tf" 2>/dev/null | tr -d 'ms' | head -1)"
    if [ -n "$ce" ] && [ -n "$ii" ]; then PARSER_MS="$(awk -v a="$ce" -v b="$ii" 'BEGIN{printf "%d", b-a}')"; fi
    rm -f "$tf"
  fi
}

# ── supported AUTO/CONFIRM: must finish under SAFE_MS (meaningful margin), never timeout ──
perf_supported() {  # $1 label  $2 cmd  $3 expect-dec(allow|ask)
  measure "$2"
  local margin=$(( DEADLINE_MS - WALL_MS ))
  echo "  EVIDENCE case='$1' wall_ms=$WALL_MS parser_ms=$PARSER_MS rc=$RC dec=$DEC margin_ms=$margin deadline_ms=$DEADLINE_MS"
  if [ "$RC" = 124 ] || [ "$RC" = 137 ]; then bad "$1: TIMEOUT (rc=$RC) — AUTHORITATIVE PERFORMANCE INSUFFICIENT"; return; fi
  if [ "$DEC" != "$3" ]; then bad "$1: expected dec=$3 got dec=$DEC rc=$RC (verdict wrong, not a perf pass)"; return; fi
  if [ "$WALL_MS" -le "$SAFE_MS" ]; then ok "$1: $3 in ${WALL_MS}ms (margin $(( DEADLINE_MS - WALL_MS ))ms >= $(( DEADLINE_MS - SAFE_MS ))ms)"
  else bad "$1: $3 in ${WALL_MS}ms — NO SAFE MARGIN (>${SAFE_MS}ms, racing the ${DEADLINE_MS}ms deadline) — AUTHORITATIVE PERFORMANCE INSUFFICIENT"; fi
}
# ── ALLOWED (rc 0), margin — used where the safe verdict legitimately proceeds WITHOUT an explicit
# permissionDecision JSON (e.g. a safe push inside a subshell, handled by the grouping-recursion path which
# relays an inner allow as a bare exit 0). This is a LATENCY case; the security outcome is "allowed" (rc 0),
# which for a SAFE target is correct. A forbidden subshell push is covered by the BLOCK cases elsewhere.
perf_allowed() {  # $1 label  $2 cmd
  measure "$2"
  local margin=$(( DEADLINE_MS - WALL_MS ))
  echo "  EVIDENCE case='$1' wall_ms=$WALL_MS parser_ms=$PARSER_MS rc=$RC dec=$DEC margin_ms=$margin deadline_ms=$DEADLINE_MS"
  if [ "$RC" = 124 ] || [ "$RC" = 137 ]; then bad "$1: TIMEOUT (rc=$RC) — AUTHORITATIVE PERFORMANCE INSUFFICIENT"; return; fi
  if [ "$RC" != 0 ]; then bad "$1: expected ALLOWED (rc 0) got rc=$RC dec=$DEC"; return; fi
  if [ "$WALL_MS" -le "$SAFE_MS" ]; then ok "$1: allowed (rc0) in ${WALL_MS}ms (margin $(( DEADLINE_MS - WALL_MS ))ms)"
  else bad "$1: allowed in ${WALL_MS}ms — NO SAFE MARGIN (>${SAFE_MS}ms) — AUTHORITATIVE PERFORMANCE INSUFFICIENT"; fi
}
# ── forbidden: blocks early (fast), no shim exec. PASS if RC=2, no exec, and well under deadline. ──
perf_forbidden() {  # $1 label  $2 cmd
  measure "$2"
  local margin=$(( DEADLINE_MS - WALL_MS ))
  echo "  EVIDENCE case='$1' wall_ms=$WALL_MS parser_ms=$PARSER_MS rc=$RC dec=$DEC margin_ms=$margin deadline_ms=$DEADLINE_MS"
  if [ "$RC" = 2 ] && [ "$EXECD" = 0 ] && [ "$WALL_MS" -lt "$DEADLINE_MS" ]; then ok "$1: early BLOCK in ${WALL_MS}ms, shim not run"
  else bad "$1: expected early BLOCK (rc=2,no-exec,<deadline), got rc=$RC exec=$EXECD wall=${WALL_MS}ms"; fi
}
# ── parser/AWK failure: must deterministically BLOCK; a timeout is NOT an acceptable pass. ──
perf_awkfail() {  # $1 label  $2 cmd
  local fa="$T/fakeawk"; mkdir -p "$fa"; printf '#!/bin/sh\nexit 3\n' > "$fa/awk"; chmod +x "$fa/awk"
  local js; js="$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$2" | jq -Rs .)")"
  local t0 t1; t0=$EPOCHREALTIME
  ( cd "$WS" && printf '%s' "$js" | PATH="$fa:$SHIMDIR:$PATH" CLAUDE_PROJECT_DIR="$WS" timeout "$PROBE_TO" bash "$HOOK" "$js" >/dev/null 2>&1 ); RC=$?
  t1=$EPOCHREALTIME; local u0="${t0/./}" u1="${t1/./}"; WALL_MS=$(( (u1-u0)/1000 ))
  echo "  EVIDENCE case='$1' wall_ms=$WALL_MS rc=$RC (awk-abnormal)"
  if [ "$RC" = 2 ] && [ "$WALL_MS" -lt "$DEADLINE_MS" ]; then ok "$1: deterministic BLOCK in ${WALL_MS}ms (dependency failure fails closed cleanly)"
  else bad "$1: awk-failure must BLOCK cleanly under deadline, got rc=$RC wall=${WALL_MS}ms"; fi
}

# a deep valid command (nested subshells around a safe push) + a parser-limit command.
_deep() { local d="$1" o="" c="" i; for ((i=0;i<d;i++)); do o+="( "; c=" )$c"; done; printf '%sgit push origin HEAD:feature/x%s' "$o" "$c"; }
_big()  { local k="$1" s="git push origin HEAD:feature/x # "; while [ "${#s}" -lt "$k" ]; do s+="padpadpadpadpadp "; done; printf '%s' "${s:0:$k}"; }

echo "════ Phase-7 authoritative performance matrix (deadline=${DEADLINE_MS}ms safe<=${SAFE_MS}ms) ════"
perf_supported "1 direct safe push"    "git push origin HEAD:feature/x"        allow
perf_forbidden "2 forbidden push"      "git push evil HEAD:feature/x"
perf_supported "3 canonical protected" "git push origin HEAD:main"             ask
perf_supported "4 multiple pushes"     "git push origin HEAD:feature/x; git push origin HEAD:feature/y" allow
perf_supported "5 1KiB command"        "$(_big 1024)"                          allow
perf_supported "6 4KiB command"        "$(_big 4096)"                          allow
perf_supported "7 16KiB command"       "$(_big 16384)"                         allow
perf_allowed   "8 within-depth valid"  "$(_deep 3)"
perf_awkfail   "9 awk-failure BLOCK"   "git push origin HEAD:feature/x"

echo ""
echo "ir-push-perf tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

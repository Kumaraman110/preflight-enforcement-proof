#!/usr/bin/env bash
# Behavioral test: ROUTER FAST-PATH LATENCY BUDGETS (preflight P0 Part C — measurable product SLOs).
#
# THE SLOs (product targets):
#   Ordinary Bash fast path:  Linux/macOS  p95 < 50ms   · Windows/Git-Bash p95 < 250ms · ZERO external spawns
#   Candidate path:           separately budgeted; the router's candidate DEADLINE must exceed observed
#                             normal p99 with a CLEAR margin AND fail-closed before the platform kill. That
#                             invariant is proven in tests/behavioral/router-timeout-budget-test.sh (this
#                             test does not re-run the multi-minute real engine body — it would only re-prove
#                             the spawn tax).
#
# HARD (deterministic, host-INDEPENDENT) vs REPORTED (measured, host-SENSITIVE):
#   • HARD: the ordinary fast path spawns ZERO external processes (proven with a PATH of spawn-witness shims).
#     This is the real guarantee — it makes fast-path latency equal to exactly ONE hook-process startup on
#     every host, and structurally prevents the every-Bash-denial incident.
#   • HARD: the ordinary fast path never invokes the engine.
#   • HARD: a candidate push DOES invoke the engine (selectivity, not inertness).
#   • REPORTED: fast-path wall-clock p50/p95 vs the product SLO. We assert only a generous REGRESSION ceiling
#     (not the absolute 50/250ms SLO) because wall-clock is dominated by the platform's bash-process startup,
#     which on a scan-on-exec host ("G17") is ~1–1.5s for a SINGLE spawn — pinning pass/fail to 250ms there
#     would make the test flaky, not the framework wrong. The zero-spawn proof is the host-independent SLO.
#
# Exit 0 = all HARD assertions passed; exit 1 = at least one failed. Timing is diagnostic output only.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROUTER="$ROOT/hooks/pre-bash-risk-router"
ENGINE="$ROOT/hooks/pre-push-gate-engine"

PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
info() { echo "  · $1"; }
# count non-empty lines in a file WITHOUT grep -c's "prints 0 AND exits 1" double-output footgun.
nlines() { awk 'NF{c++} END{print c+0}' "$1" 2>/dev/null || echo 0; }

[ -f "$ROUTER" ] || { bad "missing router $ROUTER"; echo ""; echo "router-fastpath-latency: ${PASS} passed, ${FAIL} failed"; exit 1; }
[ -f "$ENGINE" ] || { bad "missing engine $ENGINE"; echo ""; echo "router-fastpath-latency: ${PASS} passed, ${FAIL} failed"; exit 1; }

case "$(uname -s 2>/dev/null || echo unknown)" in
  Linux|Darwin) PLATFORM="unix";    SLO_MS=50 ;;
  *)            PLATFORM="windows"; SLO_MS=250 ;;
esac
echo "platform=${PLATFORM}  fast-path SLO target = p95 < ${SLO_MS}ms (with ZERO external spawns)"
echo ""

T="$(mktemp -d)"; trap 'rm -rf "$T" 2>/dev/null || true' EXIT
WITNESS="$T/spawned.log"; : > "$WITNESS"
ENGINE_WITNESS="$T/engine-invoked.log"; : > "$ENGINE_WITNESS"
SHIM="$T/shim"; mkdir -p "$SHIM"
# Spawn-witness shims for binaries the GATE could call. CRITICAL: do NOT shim bash/sh/timeout/env — those
# are the HARNESS's own machinery (we invoke the router via `bash`), and witnessing them would record the
# harness's own startup, not the router's work. We witness exactly what the router's BODY might spawn.
for bin in git jq grep sed awk cat mktemp date tr cut sort head tail dirname basename rm cp mv tee touch find xargs python python3 node perl; do
  real="$(command -v "$bin" 2>/dev/null || true)"
  {
    echo '#!/bin/sh'
    printf 'printf "%%s\\n" "%s" >> "%s"\n' "$bin" "$WITNESS"
    if [ -n "$real" ]; then printf 'exec "%s" "$@"\n' "$real"; else echo 'exit 0'; fi
  } > "$SHIM/$bin"
  chmod +x "$SHIM/$bin"
done

WS="$T/ws"; mkdir -p "$WS/hooks" "$WS/lib" "$WS/.preflight/gate"
cp "$ROUTER" "$WS/hooks/pre-bash-risk-router"
cp "$ROOT/hooks/pre-push-gate" "$WS/hooks/" 2>/dev/null || true
cp "$ROOT/lib/config-overlay.sh" "$ROOT/lib/heartbeat.sh" "$WS/lib/" 2>/dev/null || true
{
  echo '#!/usr/bin/env bash'
  printf 'printf "engine\\n" >> "%s"\n' "$ENGINE_WITNESS"
  printf 'exec bash "%s" "$@"\n' "$ENGINE"
} > "$WS/hooks/pre-push-gate-engine"
chmod +x "$WS/hooks/pre-push-gate-engine"
WROUTER="$WS/hooks/pre-bash-risk-router"
( cd "$WS" && git init -q && git commit -q --allow-empty -m init ) >/dev/null 2>&1
head="$(cd "$WS" && git rev-parse HEAD 2>/dev/null || echo none)"
for ev in tests-pass stage1-clean; do printf 'HEAD=%s\nts=now\n' "$head" > "$WS/.preflight/gate/$ev"; done
printf '{"branch":{"base":"main","remote":"origin","forbiddenRemotes":[],"forbiddenRepos":[]}}' > "$WS/.preflight/config.json"

ORD='{"tool_name":"Bash","tool_input":{"command":"echo hello world"}}'
ORD_GITSTATUS='{"tool_name":"Bash","tool_input":{"command":"git status --porcelain"}}'
PUSH='{"tool_name":"Bash","tool_input":{"command":"git push origin HEAD:feature/x"}}'

# percentile over whitespace-separated ms values (PURE AWK — python3 is unavailable in some run contexts).
# function defined at top level (awk forbids functions inside END); nearest-rank percentile.
pct() { awk '
  function q(p,   i){ i=int((p/100.0)*n+0.9999)-1; if(i<0)i=0; if(i>=n)i=n-1; return v[i] }
  { for(i=1;i<=NF;i++) v[n++]=$i+0 }
  END{ if(n==0){print "0 0 0"; exit}
       for(i=0;i<n;i++) for(j=i+1;j<n;j++) if(v[j]<v[i]){t=v[i];v[i]=v[j];v[j]=t}
       printf "%.2f %.2f %.2f", q(50), q(95), q(99) }'; }

time_router_ms() {  # $1 = json ; echoes ms (harness clock; includes the bash startup the SLO budgets)
  local json="$1" s e
  s="$EPOCHREALTIME"
  ( cd "$WS" && printf '%s' "$json" | bash "$WROUTER" "$json" >/dev/null 2>&1 )
  e="$EPOCHREALTIME"
  awk -v s="$s" -v e="$e" 'BEGIN{printf "%.3f", (e-s)*1000}'
}

# ── HARD 1: ZERO external spawns on the ordinary fast path ────────────────────────────────────────────────
: > "$WITNESS"
( cd "$WS" && printf '%s' "$ORD" | PATH="$SHIM:$PATH" bash "$WROUTER" "$ORD" >/dev/null 2>&1 )
sc="$(nlines "$WITNESS")"
[ "$sc" -eq 0 ] && ok "fast path 'echo' spawned ZERO external processes (builtins-only; latency = one hook startup, host-independent)" \
                || bad "fast path spawned ${sc} external process(es) — SLO 'zero external spawns' VIOLATED: $(sort -u "$WITNESS" | tr '\n' ' ')"

# ── HARD 2: 'git status' (contains 'git', NOT 'push') is ordinary → zero spawns, engine untouched ────────
: > "$WITNESS"; : > "$ENGINE_WITNESS"
( cd "$WS" && printf '%s' "$ORD_GITSTATUS" | PATH="$SHIM:$PATH" bash "$WROUTER" "$ORD_GITSTATUS" >/dev/null 2>&1 )
gs="$(nlines "$WITNESS")"; ge="$(nlines "$ENGINE_WITNESS")"
{ [ "$gs" -eq 0 ] && [ "$ge" -eq 0 ]; } \
  && ok "'git status' classified ORDINARY → zero spawns, engine NOT invoked (only push/gh-pr-create/sentinel route to the engine)" \
  || bad "'git status' should be ordinary, got spawns=${gs} engine_invocations=${ge}"

# ── HARD 3: the ordinary fast path NEVER invokes the engine across a batch ───────────────────────────────
: > "$ENGINE_WITNESS"
for i in 1 2 3 4 5; do ( cd "$WS" && printf '%s' "$ORD" | bash "$WROUTER" "$ORD" >/dev/null 2>&1 ); done
ei="$(nlines "$ENGINE_WITNESS")"
[ "$ei" -eq 0 ] && ok "engine invoked 0 times across 5 ordinary commands (heavy enforcement is off the fast path)" \
               || bad "engine was invoked ${ei} times on ordinary commands — fast path is NOT engine-free"

# ── HARD 4: a candidate push DOES invoke the engine (selectivity, not inertness) ─────────────────────────
: > "$ENGINE_WITNESS"
( cd "$WS" && printf '%s' "$PUSH" | PREFLIGHT_ENGINE_DEADLINE=10 timeout 20 bash "$WROUTER" "$PUSH" >/dev/null 2>&1 )
ep="$(nlines "$ENGINE_WITNESS")"
[ "$ep" -ge 1 ] && ok "candidate 'git push' DID invoke the engine (router routes risk, allows the rest)" \
               || bad "candidate push did NOT reach the engine (engine_invocations=${ep})"

# ── REPORTED: fast-path wall-clock p50/p95 over N runs (diagnostic; printed vs the product SLO) ───────────
N=40; samples=""
for i in $(seq 1 "$N"); do samples="$samples $(time_router_ms "$ORD")"; done
read -r FP50 FP95 FP99 <<<"$(printf '%s' "$samples" | pct)"
echo ""
echo "── FAST-PATH wall-clock (N=${N}, ordinary 'echo') ──"
info "p50=${FP50}ms  p95=${FP95}ms  p99=${FP99}ms   | product SLO: p95 < ${SLO_MS}ms"
REGRESSION_CEIL_MS=6000
fp95_int="${FP95%.*}"
if [ "${fp95_int:-0}" -lt "$REGRESSION_CEIL_MS" ]; then
  ok "fast-path p95 (${FP95}ms) is under the ${REGRESSION_CEIL_MS}ms regression ceiling (no return to multi-spawn pile-up)"
else
  bad "fast-path p95 (${FP95}ms) exceeded the ${REGRESSION_CEIL_MS}ms regression ceiling — the fast path is doing heavy work again"
fi
if awk -v v="$FP95" -v s="$SLO_MS" 'BEGIN{exit !(v < s)}'; then
  info "✓ meets the product SLO (p95 ${FP95}ms < ${SLO_MS}ms) on THIS host"
else
  info "⚠ p95 ${FP95}ms exceeds the ${SLO_MS}ms product SLO on THIS host — expected on a scan-on-exec (G17) box where a SINGLE bash startup dominates; the HARD guarantee (zero external spawns) holds, so latency is bounded by exactly one hook startup. Report the host, do not relax the zero-spawn rule."
fi

echo ""
info "candidate-path budget (deadline margin + fail-closed-before-platform-kill) is proven in tests/behavioral/router-timeout-budget-test.sh"
echo ""
echo "router-fastpath-latency: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

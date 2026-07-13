#!/usr/bin/env bash
# Behavioral test: ROUTER TIMEOUT-BUDGET INVARIANT (preflight P0 — closes the lost-invariant fail-OPEN RED).
#
# THE INVARIANT (load-bearing): the PreToolUse protocol blocks ONLY on exit 2. The platform's own SIGKILL
# when a hook overruns its registered `timeout` yields rc=137, which is NON-blocking → the tool proceeds
# UNGATED. So the router's clean fail-closed `exit 2` MUST always fire BEFORE the platform can SIGKILL the
# router. The split first shipped a deadline FLOOR but NO ceiling, so at the old 30s default a slow-spawn
# host's router wall (~37s) overran the 35s platform timeout → rc=137 → fail-OPEN on a protected-branch push.
#
# This test guards TWO things, both of which a future edit could silently break:
#   (1) SINGLE SOURCE OF TRUTH (CLAUDE.md rule 5): the router's `_RTR_PLATFORM_TIMEOUT_S` constant MUST equal
#       the hooks.json PreToolUse Bash-hook `timeout` (÷1000). If someone bumps the hooks.json timeout but
#       not the router constant (or vice-versa), the derived ceiling is computed against the WRONG platform
#       kill and the fail-OPEN can silently return — this is exactly the dual-source dead-gate bug class.
#   (2) THE RACE (behavioral): with a SIGTERM-IGNORING slow engine and the SHIPPED DEFAULT deadline, the
#       router emits a clean `exit 2` with a clear margin UNDER a simulated platform SIGKILL — never rc=137.
#       Plus: a huge/garbage `PREFLIGHT_ENGINE_DEADLINE` override is clamped (can only make it STRICTER), and
#       a normal candidate with a healthy fast engine is NOT spuriously blocked.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROUTER="$ROOT/hooks/pre-bash-risk-router"
HOOKS_JSON="$ROOT/hooks/hooks.json"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

[ -f "$ROUTER" ]     || { bad "missing router $ROUTER"; echo ""; echo "router-timeout-budget: ${PASS} passed, ${FAIL} failed"; exit 1; }
[ -f "$HOOKS_JSON" ] || { bad "missing hooks.json $HOOKS_JSON"; echo ""; echo "router-timeout-budget: ${PASS} passed, ${FAIL} failed"; exit 1; }

# ── (1) SINGLE-SOURCE COUPLING: router constant == hooks.json Bash-hook timeout (÷1000) ───────────────────
# Pull the platform timeout the router believes it has.
RTR_PLATFORM_S="$(grep -E '^_RTR_PLATFORM_TIMEOUT_S=' "$ROUTER" | head -1 | sed -E 's/^_RTR_PLATFORM_TIMEOUT_S=([0-9]+).*/\1/')"
# Pull the ACTUAL registered timeout (ms) for the Bash PreToolUse hook from hooks.json.
if command -v jq >/dev/null 2>&1; then
  HJ_TIMEOUT_MS="$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[0].timeout' "$HOOKS_JSON" 2>/dev/null | head -1)"
else
  # jq absent (a documented env caveat) — fall back to a tolerant grep of the Bash block's timeout.
  HJ_TIMEOUT_MS="$(grep -A6 '"matcher": "Bash"' "$HOOKS_JSON" | grep -E '"timeout"' | head -1 | sed -E 's/[^0-9]//g')"
fi
if [ -z "$RTR_PLATFORM_S" ] || [ -z "$HJ_TIMEOUT_MS" ]; then
  bad "could not extract both constants (router=_RTR_PLATFORM_TIMEOUT_S='$RTR_PLATFORM_S', hooks.json Bash timeout='$HJ_TIMEOUT_MS')"
else
  HJ_TIMEOUT_S=$(( HJ_TIMEOUT_MS / 1000 ))
  if [ "$RTR_PLATFORM_S" -eq "$HJ_TIMEOUT_S" ]; then
    ok "single-source: router _RTR_PLATFORM_TIMEOUT_S (${RTR_PLATFORM_S}s) == hooks.json Bash-hook timeout (${HJ_TIMEOUT_MS}ms = ${HJ_TIMEOUT_S}s)"
  else
    bad "DUAL-SOURCE DRIFT: router believes the platform timeout is ${RTR_PLATFORM_S}s but hooks.json registers ${HJ_TIMEOUT_MS}ms (${HJ_TIMEOUT_S}s). The derived deadline ceiling is computed against the WRONG kill → the fail-OPEN RED can silently return. Re-sync _RTR_PLATFORM_TIMEOUT_S with the hooks.json Bash timeout."
  fi
fi

# ── (1b) REGISTRATION SOURCES agree with hooks.json (the INSTALLERS write the live timeout) ───────────────
# hooks.json is the reference, but two installers ALSO emit a PreToolUse Bash `timeout` into a consumer's
# settings: tools/preflight-user.sh (user-level) and tools/preflight-runtime-install.sh (project branch-stable).
# If either drifts from hooks.json, an INSTALLED consumer runs with a platform timeout that no longer matches
# the router's derived ceiling → the fail-OPEN race can silently return on that install. Assert both equal the
# hooks.json Bash timeout (ms). (Same dual-source dead-gate class CLAUDE.md rule 5 names.)
if [ -n "${HJ_TIMEOUT_MS:-}" ]; then
  for pair in "user-installer:$ROOT/tools/preflight-user.sh" "runtime-installer:$ROOT/tools/preflight-runtime-install.sh"; do
    lbl="${pair%%:*}"; f="${pair#*:}"
    [ -f "$f" ] || { bad "missing $lbl ($f)"; continue; }
    # the registration line builds a jq object with `timeout:<ms>` for the Bash PreToolUse hook
    got="$(grep -oE 'timeout:[0-9]+' "$f" | head -1 | sed -E 's/timeout://')"
    if [ -z "$got" ]; then bad "$lbl: could not find a 'timeout:<ms>' registration literal in $f"
    elif [ "$got" -eq "$HJ_TIMEOUT_MS" ]; then ok "$lbl registers timeout:${got} == hooks.json (${HJ_TIMEOUT_MS}ms)"
    else bad "DUAL-SOURCE DRIFT: $lbl registers timeout:${got}ms but hooks.json is ${HJ_TIMEOUT_MS}ms — an install from this source would run the WRONG platform timeout. Re-sync it with hooks.json."
    fi
  done
fi

# Derive the ceiling the way the router does and assert it clears the platform kill with margin.
KILL_GRACE="$(grep -E '^_RTR_KILL_GRACE_S=' "$ROUTER" | head -1 | sed -E 's/^_RTR_KILL_GRACE_S=([0-9]+).*/\1/')"
OVERHEAD="$(grep -E '^_RTR_OVERHEAD_MARGIN_S=' "$ROUTER" | head -1 | sed -E 's/^_RTR_OVERHEAD_MARGIN_S=([0-9]+).*/\1/')"
if [ -n "${RTR_PLATFORM_S:-}" ] && [ -n "${KILL_GRACE:-}" ] && [ -n "${OVERHEAD:-}" ]; then
  CEIL=$(( RTR_PLATFORM_S - KILL_GRACE - OVERHEAD ))
  # The budget is APPORTIONED: deadline(=CEIL) + kill_grace + overhead_margin = platform, by construction.
  # The engine+kill phase finishes by CEIL+KILL_GRACE; the OVERHEAD margin is the headroom RESERVED for the
  # router's OWN startup + post-engine teardown so its exit 2 still lands before the platform kill. The static
  # invariant is therefore: the apportionment does not OVERSUBSCRIBE the platform budget; there IS a real
  # reserved margin (>=5s) for router work; and the deadline clears the floor. The actual race (does exit 2
  # beat the SIGKILL on a real slow run?) is proven behaviorally below — that is the load-bearing half.
  APPORTION=$(( CEIL + KILL_GRACE + OVERHEAD ))
  ENGINE_KILL_PHASE=$(( CEIL + KILL_GRACE ))   # when the engine+grace is guaranteed done; router still has OVERHEAD left
  if [ "$CEIL" -ge 10 ] && [ "$OVERHEAD" -ge 5 ] && [ "$APPORTION" -le "$RTR_PLATFORM_S" ] && [ "$ENGINE_KILL_PHASE" -lt "$RTR_PLATFORM_S" ]; then
    ok "budget apportioned: ceiling=${CEIL}s + grace=${KILL_GRACE}s + reserved-overhead=${OVERHEAD}s = ${APPORTION}s <= platform ${RTR_PLATFORM_S}s; engine+grace done by ${ENGINE_KILL_PHASE}s leaving ${OVERHEAD}s for the router's own exit-2 work"
  else
    bad "budget invariant broken: ceiling=${CEIL}s, reserved-overhead=${OVERHEAD}s, apportion=${APPORTION}s, engine+grace=${ENGINE_KILL_PHASE}s vs platform ${RTR_PLATFORM_S}s (need ceiling>=10, overhead>=5, apportion<=platform, engine+grace<platform)"
  fi
fi

# ── (2) BEHAVIORAL RACE: default deadline + SIGTERM-ignoring engine, under a simulated platform SIGKILL ───
command -v timeout >/dev/null 2>&1 || {
  echo "SKIP (behavioral half): 'timeout' unavailable — the deadline degrades to inline (documented)."
  echo ""; echo "router-timeout-budget: ${PASS} passed, ${FAIL} failed"; [ "$FAIL" -eq 0 ]; exit $?
}
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/hooks"
cp "$ROUTER" "$T/hooks/"
PUSH='{"tool_name":"Bash","tool_input":{"command":"git push origin HEAD:main"}}'

# SIGTERM-ignoring slow engine — the worst case (consumes the full deadline + kill-grace before SIGKILL).
cat > "$T/hooks/pre-push-gate-engine" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
sleep 999
EOF
chmod +x "$T/hooks/pre-push-gate-engine"

PLAT="${RTR_PLATFORM_S:-35}"
s="$EPOCHREALTIME"
printf '%s' "$PUSH" | timeout -s KILL "$PLAT" bash "$T/hooks/pre-bash-risk-router" "$PUSH" >/dev/null 2>"$T/err"; rc=$?
e="$EPOCHREALTIME"
wall="$(awk -v s="$s" -v e="$e" 'BEGIN{printf "%.1f", e-s}')"
if [ "$rc" -eq 2 ] && awk -v w="$wall" -v p="$PLAT" 'BEGIN{exit !(w < p)}'; then
  ok "DEFAULT deadline + SIGTERM-ignoring engine → router clean exit 2 in ${wall}s, UNDER the ${PLAT}s platform SIGKILL (no rc=137 fail-OPEN)"
elif [ "$rc" -eq 137 ]; then
  bad "FAIL-OPEN: the platform SIGKILLed the router (rc=137) at the ${PLAT}s timeout before its exit 2 — the protected-branch push would proceed UNGATED. Lower the default deadline / raise the overhead margin."
else
  bad "expected clean exit 2 under the platform kill, got rc=$rc wall=${wall}s msg='$(head -1 "$T/err")'"
fi

# Healthy fast engine (allow) must NOT be spuriously blocked, even with a huge override (clamped).
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$T/hooks/pre-push-gate-engine"; chmod +x "$T/hooks/pre-push-gate-engine"
printf '%s' "$PUSH" | PREFLIGHT_ENGINE_DEADLINE=9999999999999999999999 bash "$T/hooks/pre-bash-risk-router" "$PUSH" >/dev/null 2>"$T/e2"; rcH=$?
[ "$rcH" -eq 0 ] && ok "huge PREFLIGHT_ENGINE_DEADLINE override is clamped (not a timeout-overflow 124): healthy fast engine still ALLOWS (exit 0)" \
                 || bad "huge override should clamp and allow a healthy engine, got rc=$rcH (a 124 here = the GNU-timeout overflow footgun re-opened)"

echo ""
echo "router-timeout-budget: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

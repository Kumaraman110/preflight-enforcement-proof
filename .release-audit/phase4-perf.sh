#!/usr/bin/env bash
# phase4-perf.sh — measure installed-runtime latency for the three paths (>=20 runs each), report p50/p90/max.
# Drives the REAL installed dispatcher exactly as Claude Code does: stdin = tool JSON, cwd = the repo.
set -uo pipefail
N="${PF_PERF_N:-20}"
DISP="$PREFLIGHT_USER_HOME/dispatcher.cmd"
[ -f "$DISP" ] || { echo "no dispatcher at $DISP"; exit 1; }

# args: <label> <repo-cwd> <command>
measure() {
  local label="$1" cwd="$2" cmd="$3" i t0 t1 ms rc; local -a arr=()
  local json; json="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$cmd" "$cwd")"
  local rcs=""
  for i in $(seq 1 "$N"); do
    t0=$(date +%s%N)
    ( cd "$cwd" && printf '%s' "$json" | bash "$DISP" user-preflight-router >/dev/null 2>&1 ); rc=$?
    t1=$(date +%s%N); ms=$(( (t1-t0)/1000000 )); arr+=("$ms"); rcs="$rcs $rc"
  done
  # sort + percentiles
  local sorted; sorted="$(printf '%s\n' "${arr[@]}" | sort -n)"
  local count; count=$(printf '%s\n' "$sorted" | wc -l | tr -d ' ')
  local p50i p90i; p50i=$(( (count*50+99)/100 )); p90i=$(( (count*90+99)/100 ))
  [ "$p50i" -lt 1 ] && p50i=1; [ "$p90i" -lt 1 ] && p90i=1
  local p50 p90 max; p50=$(printf '%s\n' "$sorted" | sed -n "${p50i}p"); p90=$(printf '%s\n' "$sorted" | sed -n "${p90i}p"); max=$(printf '%s\n' "$sorted" | tail -1)
  printf '%-24s n=%-3s p50=%6sms  p90=%6sms  max=%6sms   rc={%s }\n' "$label" "$count" "$p50" "$p90" "$max" "$(echo "$rcs" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ *$//')"
}

echo "=== Phase 4 performance (installed dispatcher, $N runs/path) — host: Windows/Git-Bash + scan-on-exec EDR ==="
echo ""
echo "-- baseline: bare bash startup (the unavoidable per-Bash-call scan tax, paid regardless of Preflight) --"
{ b=(); for i in $(seq 1 "$N"); do t0=$(date +%s%N); bash -c 'exit 0'; t1=$(date +%s%N); b+=("$(( (t1-t0)/1000000 ))"); done
  s="$(printf '%s\n' "${b[@]}" | sort -n)"; c=$(printf '%s\n' "$s"|wc -l|tr -d ' ')
  printf '%-24s n=%-3s p50=%6sms  p90=%6sms  max=%6sms\n' "bare-bash-startup" "$c" \
    "$(printf '%s\n' "$s"|sed -n "$(((c*50+99)/100))p")" "$(printf '%s\n' "$s"|sed -n "$(((c*90+99)/100))p")" "$(printf '%s\n' "$s"|tail -1)"; }
echo ""
echo "-- (1) INACTIVE path: ordinary command in a non-opted-in repo (router fast-exit) --"
measure "inactive/ordinary" "$INACT" "ls -la"
echo ""
echo "-- (2) ACTIVE-SAFE path: ordinary command in an opted-in repo (router delegates, fast-allow) --"
measure "active/ordinary" "$NLX" "git status"
echo ""
echo "-- (3) CONSEQUENTIAL path: a governed push (full engine decision) --"
measure "consequential/CONFIRM" "$NLX" "git push poc"

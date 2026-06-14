#!/usr/bin/env bash
# heartbeat.sh — passive liveness self-evidencing for shipping gates.
# Source this in any gate; call _write_heartbeat <gate_name> once per invocation.
#
# Every time a gate fires, it appends a timestamp + HEAD to
# .preflight/gate/heartbeat-<gate_name>. This is a cheap append (~1 ms) that
# runs as a side-effect of the gate doing its normal job — ZERO user action.
#
# At session-start, the heartbeat freshness check reads these files and flags
# any gate that SHOULD have fired but hasn't (dead-but-registered detection).
#
# HONESTY LABEL: MECHANICAL (fsync'd append on every invocation). The file
# on disk IS the evidence the hook fired. Residual: truly proving first-ever
# invocation on a cold run before any hook has fired still needs a live host;
# the heartbeat shrinks this to a corner case — named, not hidden.

# ─── Heartbeat write ─────────────────────────────────────────
# $1 = gate name (e.g., "coupled-edit-gate")
_write_heartbeat() {
  local gate_name="${1:-unknown}"
  local hb_dir=".preflight/gate"
  # Only write if the gate directory exists (the framework is initialized)
  [ -d "$hb_dir" ] || return 0
  local ts now head
  now=$(date -u +%s 2>/dev/null || echo "0")
  head=$(git rev-parse HEAD 2>/dev/null || echo "no-git")
  printf '%s %s %s\n' "$now" "$head" "$gate_name" >> "$hb_dir/heartbeat-${gate_name}" 2>/dev/null || true
}

# ─── Heartbeat freshness check ───────────────────────────────
# $1 = gate name, $2 = max age in seconds (default 86400 = 24h)
# Returns 0 if heartbeat is fresh, 1 if stale or missing.
_check_heartbeat_fresh() {
  local gate_name="${1:-unknown}"
  local max_age="${2:-86400}"
  local hb_file=".preflight/gate/heartbeat-${gate_name}"
  [ -f "$hb_file" ] || return 1
  local last_ts
  last_ts=$(tail -1 "$hb_file" 2>/dev/null | awk '{print $1}' || echo "0")
  [ -n "$last_ts" ] && [ "$last_ts" != "0" ] || return 1
  local now
  now=$(date -u +%s 2>/dev/null || echo "0")
  local age=$(( now - last_ts ))
  [ "$age" -lt "$max_age" ]
}

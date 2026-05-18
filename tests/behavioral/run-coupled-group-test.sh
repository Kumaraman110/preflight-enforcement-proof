#!/usr/bin/env bash
# Behavioral test: validates that the coupled-edit-gate mechanically blocks
# edits to files in unacknowledged coupling groups.
#
# This tests the GATE, not the LLM. The gate is deterministic bash — it either
# blocks or doesn't. If the gate works, then even if the LLM tries to fix
# coupled findings independently, the Edit will be blocked.
#
# Test scenarios:
#   1. Edit to a file in an unacknowledged group → BLOCKED
#   2. Edit to a file NOT in any group → ALLOWED
#   3. Edit to a file in an acknowledged group → ALLOWED
#   4. Edit when no groups file exists → ALLOWED
#   5. Edit after groups cleared (empty array) → ALLOWED

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE_SCRIPT="$PLUGIN_ROOT/hooks/coupled-edit-gate"
ACK_SCRIPT="$PLUGIN_ROOT/hooks/write-group-ack"
WRITE_GROUPS="$PLUGIN_ROOT/hooks/write-active-groups"

FAILURES=0
PASSES=0
TEMP_DIR=""

red() { printf "\033[31m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }

setup() {
  TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"
  git init -q
  touch dummy && git add dummy && git commit -qm "init"
  mkdir -p .preflight/gate
}

teardown() {
  cd /
  rm -rf "$TEMP_DIR"
}

# ─── Test 1: Unacknowledged group → BLOCKED ───

test_unacked_blocked() {
  setup

  # Create active groups with TokenProvider.cs and AccountClient.cs coupled
  bash "$WRITE_GROUPS" '[{"files":["Services/TokenProvider.cs","Clients/AccountClient.cs"],"findings":["§4.2 on TokenProvider:18","§4.3 on AccountClient:25"],"acknowledged":false}]'

  # Try to edit TokenProvider.cs — should be BLOCKED
  if bash "$GATE_SCRIPT" "Services/TokenProvider.cs" 2>/dev/null; then
    red "FAIL: Test 1 — edit to unacknowledged group file should be BLOCKED but was ALLOWED"
    FAILURES=$((FAILURES + 1))
  else
    green "PASS: Test 1 — unacknowledged group file correctly BLOCKED"
    PASSES=$((PASSES + 1))
  fi

  teardown
}

# ─── Test 2: File not in any group → ALLOWED ───

test_untracked_allowed() {
  setup

  bash "$WRITE_GROUPS" '[{"files":["Services/TokenProvider.cs","Clients/AccountClient.cs"],"findings":["§4.2"],"acknowledged":false}]'

  # Edit Dockerfile — not in any group
  if bash "$GATE_SCRIPT" "Dockerfile" 2>/dev/null; then
    green "PASS: Test 2 — file not in any group correctly ALLOWED"
    PASSES=$((PASSES + 1))
  else
    red "FAIL: Test 2 — file not in any group should be ALLOWED but was BLOCKED"
    FAILURES=$((FAILURES + 1))
  fi

  teardown
}

# ─── Test 3: Acknowledged group → ALLOWED ───

test_acked_allowed() {
  setup

  bash "$WRITE_GROUPS" '[{"files":["Services/TokenProvider.cs","Clients/AccountClient.cs"],"findings":["§4.2","§4.3"],"acknowledged":false}]'

  # Acknowledge the group
  bash "$ACK_SCRIPT" "0"

  # Now edit should be allowed
  if bash "$GATE_SCRIPT" "Services/TokenProvider.cs" 2>/dev/null; then
    green "PASS: Test 3 — acknowledged group file correctly ALLOWED"
    PASSES=$((PASSES + 1))
  else
    red "FAIL: Test 3 — acknowledged group file should be ALLOWED but was BLOCKED"
    FAILURES=$((FAILURES + 1))
  fi

  teardown
}

# ─── Test 4: No groups file → ALLOWED ───

test_no_groups_file() {
  setup

  # Don't create any groups file
  if bash "$GATE_SCRIPT" "Services/TokenProvider.cs" 2>/dev/null; then
    green "PASS: Test 4 — no groups file, correctly ALLOWED"
    PASSES=$((PASSES + 1))
  else
    red "FAIL: Test 4 — no groups file should mean ALLOWED"
    FAILURES=$((FAILURES + 1))
  fi

  teardown
}

# ─── Test 5: Empty groups array → ALLOWED ───

test_empty_groups() {
  setup

  bash "$WRITE_GROUPS" '[]'

  if bash "$GATE_SCRIPT" "Services/TokenProvider.cs" 2>/dev/null; then
    green "PASS: Test 5 — empty groups array, correctly ALLOWED"
    PASSES=$((PASSES + 1))
  else
    red "FAIL: Test 5 — empty groups should mean ALLOWED"
    FAILURES=$((FAILURES + 1))
  fi

  teardown
}

# ─── Test 6: Multiple groups, only one unacked ───

test_multi_group_partial_ack() {
  setup

  bash "$WRITE_GROUPS" '[{"files":["Services/TokenProvider.cs"],"findings":["§4.2"],"acknowledged":true},{"files":["Clients/AccountClient.cs"],"findings":["§4.3"],"acknowledged":false}]'

  # TokenProvider is in group 0 (acknowledged) — should be allowed
  if bash "$GATE_SCRIPT" "Services/TokenProvider.cs" 2>/dev/null; then
    green "PASS: Test 6a — file in acknowledged group ALLOWED"
    PASSES=$((PASSES + 1))
  else
    red "FAIL: Test 6a — file in acknowledged group should be ALLOWED"
    FAILURES=$((FAILURES + 1))
  fi

  # AccountClient is in group 1 (unacknowledged) — should be blocked
  if bash "$GATE_SCRIPT" "Clients/AccountClient.cs" 2>/dev/null; then
    red "FAIL: Test 6b — file in unacknowledged group should be BLOCKED"
    FAILURES=$((FAILURES + 1))
  else
    green "PASS: Test 6b — file in unacknowledged group correctly BLOCKED"
    PASSES=$((PASSES + 1))
  fi

  teardown
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════

echo "╔══════════════════════════════════════════╗"
echo "║  Behavioral: Coupled-Edit Gate Tests     ║"
echo "╚══════════════════════════════════════════╝"
echo ""

test_unacked_blocked
test_untracked_allowed
test_acked_allowed
test_no_groups_file
test_empty_groups
test_multi_group_partial_ack

echo ""
echo "══════════════════════════════════════════"
echo " Results: $PASSES passed, $FAILURES failed"
echo "══════════════════════════════════════════"

if [ "$FAILURES" -gt 0 ]; then
  red "FAILED: $FAILURES test(s) failed"
  exit 1
else
  green "ALL BEHAVIORAL TESTS PASSED ($PASSES assertions)"
  exit 0
fi

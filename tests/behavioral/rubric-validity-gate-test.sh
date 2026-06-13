#!/usr/bin/env bash
# Tests for the rubric-validity-gate hook.
# Validates: Stage 1 (code-reviewer) is blocked when rubric is invalid/missing.
#
# INTERFACE: the hook reads a JSON object from STDIN (the real Claude Code
# PreToolUse interface): {"tool_name":"Task","tool_input":{"subagent_type":
# "code-reviewer","prompt":"..."}}. Block = exit 2 (stderr carries the reason).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/rubric-validity-gate"
FAILURES=0
PASSES=0

red() { printf "\033[31m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }

# run_task_hook <subagent_type> → sets RC and OUT (stdout+stderr merged).
# Feeds Task tool JSON on stdin — the hook's real input contract.
# Pass "" to omit the subagent_type field entirely.
run_task_hook() {
  local st="$1" json
  if [ -n "$st" ]; then
    json="{\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"$st\",\"prompt\":\"review the diff\"}}"
  else
    json='{"tool_name":"Task","tool_input":{"prompt":"do something","description":"general task"}}'
  fi
  RC=0
  OUT="$(printf '%s' "$json" | bash "$HOOK" 2>&1)" || RC=$?
}

# ─── Setup temp workspace ─────────────────────────────────────

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

setup_workspace() {
  rm -rf "$TMPDIR"/* "$TMPDIR"/.* 2>/dev/null || true
  cd "$TMPDIR"
}

# ─── Test 1: Non-code-reviewer Agent call → ALLOW ────────────

echo "Test 1: Agent call with subagent_type != code-reviewer"
setup_workspace

run_task_hook "Explore"

if [ "$RC" -eq 0 ]; then
  green "PASS: non-code-reviewer agent call allowed"
  PASSES=$((PASSES + 1))
else
  red "FAIL: non-code-reviewer should pass through (exit $RC)"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 2: Code-reviewer, no config file → BLOCK ───────────

echo "Test 2: code-reviewer spawn, no config file"
setup_workspace

run_task_hook "code-reviewer"

if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q "BLOCKED"; then
  green "PASS: no config file blocks code-reviewer"
  PASSES=$((PASSES + 1))
else
  red "FAIL: expected block (exit 2), got exit $RC"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 3: Code-reviewer, config exists, no rubric key → BLOCK ─

echo "Test 3: code-reviewer spawn, config exists but no rubric key"
setup_workspace
mkdir -p .preflight
echo '{"mode":"generic"}' > .preflight/config.json

run_task_hook "code-reviewer"

if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q "no.*rubric"; then
  green "PASS: config without rubric key blocks"
  PASSES=$((PASSES + 1))
else
  red "FAIL: expected block for missing rubric key (exit $RC, output: $OUT)"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 4: Code-reviewer, rubric path resolves → ALLOW ─────

echo "Test 4: code-reviewer spawn, rubric path resolves"
setup_workspace
mkdir -p .preflight
echo "# My rubric" > rubric.md
echo '{"rubric":"rubric.md"}' > .preflight/config.json

run_task_hook "code-reviewer"

if [ "$RC" -eq 0 ]; then
  green "PASS: valid rubric path allows code-reviewer"
  PASSES=$((PASSES + 1))
else
  red "FAIL: valid rubric should allow (exit $RC, output: $OUT)"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 5: Unreachable rubric path (generalized) → BLOCK ──────
# This covers ALL unreachable-path causes: missing file, broken symlink,
# permission-denied, unmounted volume. The OS's [ -f ] check rejects them
# all identically. No platform-specific test needed.

echo "Test 5: code-reviewer spawn, unreachable rubric path (generalized)"
setup_workspace
mkdir -p .preflight
echo '{"rubric":"nonexistent/rubric.md"}' > .preflight/config.json

run_task_hook "code-reviewer"

if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q "not found"; then
  green "PASS: invalid rubric path blocks"
  PASSES=$((PASSES + 1))
else
  red "FAIL: expected block for bad rubric path (exit $RC, output: $OUT)"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 6: Code-reviewer, rubric resolves via PLUGIN_ROOT → ALLOW ─

echo "Test 6: code-reviewer spawn, rubric resolves via plugin-relative path"
setup_workspace
mkdir -p .preflight

# Use a path that exists under PLUGIN_ROOT (the plugin's own examples)
EXAMPLE_RUBRIC="examples/rubrics/rubric-generic-dotnet.md"
if [ -f "$PLUGIN_ROOT/$EXAMPLE_RUBRIC" ]; then
  echo "{\"rubric\":\"$EXAMPLE_RUBRIC\"}" > .preflight/config.json

  run_task_hook "code-reviewer"

  if [ "$RC" -eq 0 ]; then
    green "PASS: plugin-relative rubric path allows"
    PASSES=$((PASSES + 1))
  else
    red "FAIL: plugin-relative rubric should allow (exit $RC)"
    FAILURES=$((FAILURES + 1))
  fi
else
  green "PASS: (skip — example rubric not present, cannot test plugin-relative)"
  PASSES=$((PASSES + 1))
fi

# ─── Test 7: Code-reviewer, array rubric, all resolve → ALLOW ─

echo "Test 7: code-reviewer spawn, array rubric with all paths valid"
setup_workspace
mkdir -p .preflight
echo "# Migration rubric" > migration-rubric.md
echo "# Generic rubric" > generic-rubric.md

# Write array-style config (jq prints arrays as newline-separated via read_rubric_field)
cat > .preflight/config.json <<'CONF'
{"rubric":["migration-rubric.md","generic-rubric.md"]}
CONF

run_task_hook "code-reviewer"

if [ "$RC" -eq 0 ]; then
  green "PASS: array rubric (all valid) allows"
  PASSES=$((PASSES + 1))
else
  red "FAIL: array rubric (all valid) should allow (exit $RC, output: $OUT)"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 8: Code-reviewer, array rubric, one invalid → BLOCK ─

echo "Test 8: code-reviewer spawn, array rubric with one invalid path"
setup_workspace
mkdir -p .preflight
echo "# Good rubric" > good-rubric.md

cat > .preflight/config.json <<'CONF'
{"rubric":["good-rubric.md","missing-rubric.md"]}
CONF

run_task_hook "code-reviewer"

if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q "missing-rubric.md"; then
  green "PASS: array rubric (one invalid) blocks"
  PASSES=$((PASSES + 1))
else
  red "FAIL: expected block for partial-invalid array (exit $RC, output: $OUT)"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 9: No subagent_type field at all → ALLOW ───────────

echo "Test 9: Agent call with no subagent_type field"
setup_workspace

run_task_hook ""

if [ "$RC" -eq 0 ]; then
  green "PASS: no subagent_type passes through"
  PASSES=$((PASSES + 1))
else
  red "FAIL: missing subagent_type should pass (exit $RC)"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 10: .cpsl/config.json fallback location → works ────

echo "Test 10: config at .cpsl/config.json (fallback location)"
setup_workspace
mkdir -p .cpsl
echo "# rubric" > my-rubric.md
echo '{"rubric":"my-rubric.md"}' > .cpsl/config.json

run_task_hook "code-reviewer"

if [ "$RC" -eq 0 ]; then
  green "PASS: .cpsl/config.json fallback works"
  PASSES=$((PASSES + 1))
else
  red "FAIL: .cpsl/config.json should be found (exit $RC, output: $OUT)"
  FAILURES=$((FAILURES + 1))
fi

# ─── Results ──────────────────────────────────────────────────

echo ""
echo "Rubric-validity-gate tests: $PASSES passed, $FAILURES failed"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
else
  exit 0
fi

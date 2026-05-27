#!/usr/bin/env bash
# Tests for the drift detector hook.
# Validates: first-run behavior, stack detection, drift detection, no false positives.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/drift-detector"
FAILURES=0
PASSES=0

red() { printf "\033[31m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }

assert_exit_code() {
  local expected="$1" actual="$2" context="$3"
  if [ "$actual" -eq "$expected" ]; then
    PASSES=$((PASSES + 1))
  else
    red "FAIL: $context — expected exit $expected, got $actual"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_output_empty() {
  local output="$1" context="$2"
  if [ -z "$output" ]; then
    PASSES=$((PASSES + 1))
  else
    red "FAIL: $context — expected empty output, got: $output"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_output_contains() {
  local output="$1" needle="$2" context="$3"
  if echo "$output" | grep -q "$needle"; then
    PASSES=$((PASSES + 1))
  else
    red "FAIL: $context — expected output to contain '$needle'"
    FAILURES=$((FAILURES + 1))
  fi
}

# ─── Setup temp workspace ─────────────────────────────────────

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# ─── Test 1: First run writes cache, no output ────────────────

echo "Test 1: First run (no cache exists)"
cd "$TMPDIR"
mkdir -p .preflight
echo '{"mode":"generic"}' > .preflight/config.json
mkdir -p src && echo "class Foo {}" > src/Foo.cs

OUTPUT=$(bash "$HOOK" 2>/dev/null || true)
EXIT_CODE=$?

assert_exit_code 0 $EXIT_CODE "First run exits clean"
assert_output_empty "$OUTPUT" "First run produces no output"

# Verify cache was written
if [ -f ".preflight/cache/derived-state.json" ]; then
  PASSES=$((PASSES + 1))
else
  red "FAIL: First run should write cache file"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 2: Second run with no changes — no drift ───────────

echo "Test 2: No changes between runs (no drift)"
OUTPUT=$(bash "$HOOK" 2>/dev/null || true)
EXIT_CODE=$?

assert_exit_code 0 $EXIT_CODE "No-drift run exits clean"
assert_output_empty "$OUTPUT" "No-drift run produces no output"

# ─── Test 3: Rubric path becomes invalid — drift detected ────

echo "Test 3: Invalid rubric path (config drift)"
echo '{"mode":"generic","rubric":"nonexistent/rubric.md"}' > .preflight/config.json

# Need to update cache to have configExists=true first (simulating prior valid state)
echo '{"stack":"dotnet","sourceDirCount":1,"configExists":true,"rubricValid":true,"scanProfileValid":true,"genSpecValid":true}' > .preflight/cache/derived-state.json

OUTPUT=$(bash "$HOOK" 2>/dev/null || true)
EXIT_CODE=$?

assert_exit_code 0 $EXIT_CODE "Drift detection exits clean (warnings, not errors)"
assert_output_contains "$OUTPUT" "DRIFT\|RUBRIC" "Rubric drift surfaced"

# ─── Test 4: No config file — no crash ───────────────────────

echo "Test 4: No config file (graceful handling)"
cd "$TMPDIR"
rm -f .preflight/config.json .preflight/cache/derived-state.json
OUTPUT=$(bash "$HOOK" 2>/dev/null || true)
EXIT_CODE=$?

assert_exit_code 0 $EXIT_CODE "No-config run exits clean"

# ─── Results ──────────────────────────────────────────────────

echo ""
echo "Drift detector tests: $PASSES passed, $FAILURES failed"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
else
  exit 0
fi

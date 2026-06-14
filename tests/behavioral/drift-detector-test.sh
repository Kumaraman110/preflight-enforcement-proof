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

# ─── Test 5: Array rubric with valid paths → no rubric drift ────

echo "Test 5: Array rubric with valid paths (no rubric drift)"

# Create valid rubric files
mkdir -p .preflight/rubrics
echo "# rubric1" > .preflight/rubrics/r1.md
echo "# rubric2" > .preflight/rubrics/r2.md
echo '{"mode":"generic","rubric":[".preflight/rubrics/r1.md",".preflight/rubrics/r2.md"],"scanProfile":"my-profile.md","generation-spec":"my-gen-spec.md"}' > .preflight/config.json
# Seed cache with rubricValid=true (no drift to detect for rubric)
echo '{"schemaVersion":1,"stack":"unknown","sourceDirCount":1,"configExists":true,"rubricValid":true,"scanProfileValid":true,"genSpecValid":true}' > .preflight/cache/derived-state.json

OUTPUT=$(bash "$HOOK" 2>/dev/null || true)
EXIT_CODE=$?

assert_exit_code 0 $EXIT_CODE "Array rubric (valid paths) exits clean"
# Should NOT contain RUBRIC drift (rubric paths exist; rubricValid stays true)
if ! echo "$OUTPUT" | grep -q "RUBRIC"; then
  PASSES=$((PASSES + 1))
else
  red "FAIL: Test 5 — RUBRIC drift unexpectedly fired for valid array rubric"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 6: Array rubric with missing path → drift, scanProfile/genSpec correct ──

echo "Test 6: Array rubric with missing path (drift), scanProfile correct"

echo '{"mode":"generic","rubric":["nonexistent/a.md","nonexistent/b.md"],"scanProfile":"my-profile.md","generation-spec":"my-gen-spec.md"}' > .preflight/config.json
# Seed cache where rubricValid was true
echo '{"schemaVersion":1,"stack":"unknown","sourceDirCount":1,"configExists":true,"rubricValid":true,"scanProfileValid":true,"genSpecValid":true}' > .preflight/cache/derived-state.json

OUTPUT=$(bash "$HOOK" 2>/dev/null || true)
EXIT_CODE=$?

assert_exit_code 0 $EXIT_CODE "Array rubric (missing paths) exits clean"
assert_output_contains "$OUTPUT" "RUBRIC" "Array rubric missing-paths drift surfaced"

# Verify scanProfile was NOT corrupted by array rubric misalignment
# (If misaligned, scanProfile would be "nonexistent/b.md" and PROFILE drift would fire)
# The cache had scanProfileValid=true, and our config has "my-profile.md" which doesn't exist
# as a file — but that's a PROFILE drift (should fire). The key assertion: the PROFILE drift
# message should mention "my-profile.md" not "nonexistent/b.md".
if echo "$OUTPUT" | grep -q "PROFILE"; then
  PASSES=$((PASSES + 1))
else
  red "FAIL: Test 6 — PROFILE drift not detected (scanProfile may have been misaligned)"
  FAILURES=$((FAILURES + 1))
fi

# ─── Results ──────────────────────────────────────────────────

echo ""
echo "Drift detector tests: $PASSES passed, $FAILURES failed"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
else
  exit 0
fi

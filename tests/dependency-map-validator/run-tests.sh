#!/usr/bin/env bash
# Dependency-map-validator hook tests.
# Validates: hybrid HEAD-stamp validation logic for map freshness.
#
# Each test creates a temporary git repo, sets up a sidecar, and runs
# the validator to check exit codes and behavior.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATOR="$PLUGIN_ROOT/hooks/dependency-map-validator"
FAILURES=0
PASSES=0

red() { printf "\033[31m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }

setup_temp_repo() {
  TEST_TMPDIR=$(mktemp -d)
  cd "$TEST_TMPDIR"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  git config core.autocrlf false
  mkdir -p .preflight/gate
}

cleanup() {
  cd "$SCRIPT_DIR"
  rm -rf "$TEST_TMPDIR" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────
# Test 1: Fresh sidecar (HEAD matches validAtHEAD) → exit 0
# ──────────────────────────────────────────────────────────────
echo "Test 1: Fresh sidecar (HEAD matches)"
setup_temp_repo

echo "initial" > file.txt
git add file.txt && git commit -q -m "init"
HEAD_SHA=$(git rev-parse HEAD)

cat > .preflight/gate/dependency-map-validated <<ENDJSON
{
  "validAtHEAD": "$HEAD_SHA",
  "mapPath": "dependency-map.json",
  "mapFiles": ["file.txt"],
  "generatedAt": "2026-05-27T10:00:00+00:00",
  "generatedBy": "discovery-analyst"
}
ENDJSON

OUTPUT=$(bash "$VALIDATOR" ".preflight/gate/dependency-map-validated" 2>&1) || true
EXIT_CODE=${PIPESTATUS[0]:-$?}

if [ "$EXIT_CODE" -eq 0 ] && echo "$OUTPUT" | grep -q "FRESH"; then
  green "PASS: fresh sidecar returns exit 0"
  PASSES=$((PASSES + 1))
else
  red "FAIL: fresh sidecar returned exit $EXIT_CODE: $OUTPUT"
  FAILURES=$((FAILURES + 1))
fi

cleanup

# ──────────────────────────────────────────────────────────────
# Test 2: HEAD moved, no map-file overlap → exit 0 (re-stamps)
# ──────────────────────────────────────────────────────────────
echo "Test 2: HEAD moved, no map-file overlap (re-stamps)"
setup_temp_repo

echo "initial" > file.txt
echo "map" > tracked.cs
git add file.txt tracked.cs && git commit -q -m "init"
OLD_HEAD=$(git rev-parse HEAD)

cat > .preflight/gate/dependency-map-validated <<ENDJSON
{
  "validAtHEAD": "$OLD_HEAD",
  "mapPath": "dependency-map.json",
  "mapFiles": ["tracked.cs"],
  "generatedAt": "2026-05-27T10:00:00+00:00",
  "generatedBy": "discovery-analyst"
}
ENDJSON

# Make a new commit that does NOT touch tracked.cs
echo "other change" > unrelated.txt
git add unrelated.txt && git commit -q -m "unrelated change"

OUTPUT=$(bash "$VALIDATOR" ".preflight/gate/dependency-map-validated" 2>&1) || true
EXIT_CODE=${PIPESTATUS[0]:-$?}

if [ "$EXIT_CODE" -eq 0 ] && echo "$OUTPUT" | grep -q "re-stamped"; then
  green "PASS: HEAD moved, no overlap — re-stamped, exit 0"
  PASSES=$((PASSES + 1))
else
  red "FAIL: HEAD moved, no overlap returned exit $EXIT_CODE: $OUTPUT"
  FAILURES=$((FAILURES + 1))
fi

cleanup

# ──────────────────────────────────────────────────────────────
# Test 3: HEAD moved, map-file overlap → exit 1
# ──────────────────────────────────────────────────────────────
echo "Test 3: HEAD moved, map-file overlap (stale)"
setup_temp_repo

echo "initial" > service.cs
git add service.cs && git commit -q -m "init"
OLD_HEAD=$(git rev-parse HEAD)

cat > .preflight/gate/dependency-map-validated <<ENDJSON
{
  "validAtHEAD": "$OLD_HEAD",
  "mapPath": "dependency-map.json",
  "mapFiles": ["service.cs"],
  "generatedAt": "2026-05-27T10:00:00+00:00",
  "generatedBy": "discovery-analyst"
}
ENDJSON

# Make a commit that DOES touch a map file
echo "modified" > service.cs
git add service.cs && git commit -q -m "modify tracked file"

OUTPUT=$(bash "$VALIDATOR" ".preflight/gate/dependency-map-validated" 2>&1) || true
EXIT_CODE=${PIPESTATUS[0]:-$?}

if echo "$OUTPUT" | grep -q "STALE"; then
  green "PASS: HEAD moved with map-file overlap — stale, exit 1"
  PASSES=$((PASSES + 1))
else
  red "FAIL: overlap detection returned exit $EXIT_CODE: $OUTPUT"
  FAILURES=$((FAILURES + 1))
fi

cleanup

# ──────────────────────────────────────────────────────────────
# Test 4: Sidecar missing → exit 1
# ──────────────────────────────────────────────────────────────
echo "Test 4: Sidecar missing (graceful handling)"
setup_temp_repo

echo "content" > file.txt
git add file.txt && git commit -q -m "init"

OUTPUT=$(bash "$VALIDATOR" ".preflight/gate/dependency-map-validated" 2>&1) || true
EXIT_CODE=${PIPESTATUS[0]:-$?}

if echo "$OUTPUT" | grep -q "not found"; then
  green "PASS: missing sidecar returns exit 1"
  PASSES=$((PASSES + 1))
else
  red "FAIL: missing sidecar returned exit $EXIT_CODE: $OUTPUT"
  FAILURES=$((FAILURES + 1))
fi

cleanup

# ──────────────────────────────────────────────────────────────
# Test 5: Git diff fails (invalid SHA in sidecar) → exit 1
# ──────────────────────────────────────────────────────────────
echo "Test 5: Invalid SHA in sidecar (git diff fails)"
setup_temp_repo

echo "content" > file.txt
git add file.txt && git commit -q -m "init"

cat > .preflight/gate/dependency-map-validated <<ENDJSON
{
  "validAtHEAD": "0000000000000000000000000000000000000000",
  "mapPath": "dependency-map.json",
  "mapFiles": ["file.txt"],
  "generatedAt": "2026-05-27T10:00:00+00:00",
  "generatedBy": "discovery-analyst"
}
ENDJSON

OUTPUT=$(bash "$VALIDATOR" ".preflight/gate/dependency-map-validated" 2>&1) || true
EXIT_CODE=${PIPESTATUS[0]:-$?}

if echo "$OUTPUT" | grep -q "STALE"; then
  green "PASS: invalid SHA in sidecar triggers stale, exit 1"
  PASSES=$((PASSES + 1))
else
  red "FAIL: invalid SHA returned exit $EXIT_CODE: $OUTPUT"
  FAILURES=$((FAILURES + 1))
fi

cleanup

# ──────────────────────────────────────────────────────────────
# Results
# ──────────────────────────────────────────────────────────────

echo ""
echo "Dependency-map-validator tests: $PASSES passed, $FAILURES failed"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0

#!/usr/bin/env bash
# Tests for the bootstrap-write-gate hook.
# Validates: clobber protection for CLAUDE.md and .preflight/config.json.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/bootstrap-write-gate"
FAILURES=0
PASSES=0

red() { printf "\033[31m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }

# ─── Setup temp workspace ─────────────────────────────────────

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

setup_git_repo() {
  cd "$TMPDIR"
  rm -rf ./* ./.* 2>/dev/null || true
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  echo "init" > init.txt
  git add init.txt && git commit -q -m "init"
}

# ─── Test 1: New CLAUDE.md (doesn't exist) → ALLOW ───────────

echo "Test 1: Write to NEW CLAUDE.md (no existing file)"
setup_git_repo

# CLAUDE.md does NOT exist; tool input targets it
INPUT='{"file_path":"'"$TMPDIR/CLAUDE.md"'","content":"# New"}'
EXIT_CODE=0
bash "$HOOK" "$INPUT" 2>/dev/null || EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 0 ]; then
  green "PASS: new file creation allowed"
  PASSES=$((PASSES + 1))
else
  red "FAIL: new file creation blocked (exit $EXIT_CODE)"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 2: Existing CLAUDE.md, NO sentinel → BLOCK ─────────

echo "Test 2: Write to EXISTING CLAUDE.md, no sentinel"
setup_git_repo
echo "# Existing" > CLAUDE.md

INPUT='{"file_path":"'"$TMPDIR/CLAUDE.md"'","content":"# Overwrite"}'
EXIT_CODE=0
OUTPUT=$(bash "$HOOK" "$INPUT" 2>&1) || EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 1 ] && echo "$OUTPUT" | grep -q "BLOCKED"; then
  green "PASS: existing file without sentinel blocked"
  PASSES=$((PASSES + 1))
else
  red "FAIL: expected block (exit 1), got exit $EXIT_CODE"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 3: Existing CLAUDE.md, fresh sentinel → ALLOW ──────

echo "Test 3: Write to EXISTING CLAUDE.md, fresh sentinel"
setup_git_repo
echo "# Existing" > CLAUDE.md
git add CLAUDE.md && git commit -q -m "add claude"
HEAD=$(git rev-parse HEAD)

mkdir -p .preflight/gate
cat > .preflight/gate/bootstrap-write-approved <<SENTINEL
{"approvedAtHEAD":"$HEAD","approvedFiles":["CLAUDE.md",".preflight/config.json"],"approvedAt":"2026-05-28T10:00:00Z"}
SENTINEL

INPUT='{"file_path":"'"$TMPDIR/CLAUDE.md"'","content":"# Updated"}'
EXIT_CODE=0
bash "$HOOK" "$INPUT" 2>/dev/null || EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 0 ]; then
  green "PASS: existing file with fresh sentinel allowed"
  PASSES=$((PASSES + 1))
else
  red "FAIL: fresh sentinel should allow (exit $EXIT_CODE)"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 4: Existing CLAUDE.md, STALE sentinel → BLOCK ──────

echo "Test 4: Write to EXISTING CLAUDE.md, stale sentinel (HEAD moved)"
setup_git_repo
echo "# Existing" > CLAUDE.md
git add CLAUDE.md && git commit -q -m "add claude"
OLD_HEAD=$(git rev-parse HEAD)

mkdir -p .preflight/gate
cat > .preflight/gate/bootstrap-write-approved <<SENTINEL
{"approvedAtHEAD":"$OLD_HEAD","approvedFiles":["CLAUDE.md"],"approvedAt":"2026-05-28T10:00:00Z"}
SENTINEL

# Move HEAD forward
echo "more" > extra.txt && git add extra.txt && git commit -q -m "move head"

INPUT='{"file_path":"'"$TMPDIR/CLAUDE.md"'","content":"# Clobber"}'
EXIT_CODE=0
OUTPUT=$(bash "$HOOK" "$INPUT" 2>&1) || EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 1 ] && echo "$OUTPUT" | grep -q "stale"; then
  green "PASS: stale sentinel blocks"
  PASSES=$((PASSES + 1))
else
  red "FAIL: stale sentinel should block (exit $EXIT_CODE)"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 5: Existing config.json, sentinel covers only CLAUDE.md → BLOCK ─

echo "Test 5: Write to config.json, sentinel doesn't cover it"
setup_git_repo
mkdir -p .preflight
echo '{"mode":"generic"}' > .preflight/config.json
git add .preflight/config.json && git commit -q -m "add config"
HEAD=$(git rev-parse HEAD)

mkdir -p .preflight/gate
cat > .preflight/gate/bootstrap-write-approved <<SENTINEL
{"approvedAtHEAD":"$HEAD","approvedFiles":["CLAUDE.md"],"approvedAt":"2026-05-28T10:00:00Z"}
SENTINEL

INPUT='{"file_path":"'"$TMPDIR/.preflight/config.json"'","content":"{}"}'
EXIT_CODE=0
OUTPUT=$(bash "$HOOK" "$INPUT" 2>&1) || EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 1 ] && echo "$OUTPUT" | grep -q "does not cover"; then
  green "PASS: sentinel not covering target blocks"
  PASSES=$((PASSES + 1))
else
  red "FAIL: uncovered file should block (exit $EXIT_CODE, output: $OUTPUT)"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 6: Unrelated file, existing, no sentinel → ALLOW ───

echo "Test 6: Write to unrelated file (not protected)"
setup_git_repo
echo "class Foo {}" > src.cs

INPUT='{"file_path":"'"$TMPDIR/src.cs"'","content":"class Bar {}"}'
EXIT_CODE=0
bash "$HOOK" "$INPUT" 2>/dev/null || EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 0 ]; then
  green "PASS: unrelated file allowed"
  PASSES=$((PASSES + 1))
else
  red "FAIL: unrelated file should pass (exit $EXIT_CODE)"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 7: Malformed sentinel → BLOCK (fail-closed) ────────

echo "Test 7: Existing CLAUDE.md, malformed sentinel (fail-closed)"
setup_git_repo
echo "# Existing" > CLAUDE.md
git add CLAUDE.md && git commit -q -m "add claude"

mkdir -p .preflight/gate
echo "NOT VALID JSON" > .preflight/gate/bootstrap-write-approved

INPUT='{"file_path":"'"$TMPDIR/CLAUDE.md"'","content":"# Clobber"}'
EXIT_CODE=0
OUTPUT=$(bash "$HOOK" "$INPUT" 2>&1) || EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 1 ]; then
  green "PASS: malformed sentinel fails closed (blocks)"
  PASSES=$((PASSES + 1))
else
  red "FAIL: malformed sentinel should fail closed (exit $EXIT_CODE)"
  FAILURES=$((FAILURES + 1))
fi

# ─── Results ──────────────────────────────────────────────────

echo ""
echo "Bootstrap-write-gate tests: $PASSES passed, $FAILURES failed"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
else
  exit 0
fi

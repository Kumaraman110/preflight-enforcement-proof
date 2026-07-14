#!/usr/bin/env bash
# Tests for the bootstrap-write-gate hook.
# Validates: clobber protection for CLAUDE.md and .preflight/config.json.
#
# INTERFACE: the hook reads a JSON object from STDIN (the real Claude Code
# PreToolUse interface): {"tool_name":"Write","tool_input":{"file_path":"...",
# "content":"..."}}. Block = exit 2 (stderr carries the reason).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/bootstrap-write-gate"
FAILURES=0
PASSES=0

red() { printf "\033[31m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }

# run_write_hook <file_path> → sets RC and OUT (stdout+stderr merged).
# Feeds Write tool JSON on stdin — the hook's real input contract.
run_write_hook() {
  local fp="$1"
  RC=0
  # Build the Write JSON with jq so a backslash Windows path ($fp = D:\a\_temp\... from cygwin mktemp on the
  # runner) is escaped to VALID JSON. Raw interpolation made it invalid → the hook's `jq -r .tool_input.file_path`
  # returned empty → not-protected → exit 0 (spurious "expected block got exit 0"). Product hook is correct.
  local json; json="$(jq -n --arg fp "$fp" '{tool_name:"Write",tool_input:{file_path:$fp,content:"x"}}')"
  OUT="$(printf '%s' "$json" | bash "$HOOK" 2>&1)" || RC=$?
}

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
run_write_hook "$TMPDIR/CLAUDE.md"

if [ "$RC" -eq 0 ]; then
  green "PASS: new file creation allowed"
  PASSES=$((PASSES + 1))
else
  red "FAIL: new file creation blocked (exit $RC)"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 2: Existing CLAUDE.md, NO sentinel → BLOCK ─────────

echo "Test 2: Write to EXISTING CLAUDE.md, no sentinel"
setup_git_repo
echo "# Existing" > CLAUDE.md

run_write_hook "$TMPDIR/CLAUDE.md"

if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q "BLOCKED"; then
  green "PASS: existing file without sentinel blocked"
  PASSES=$((PASSES + 1))
else
  red "FAIL: expected block (exit 2), got exit $RC"
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

run_write_hook "$TMPDIR/CLAUDE.md"

if [ "$RC" -eq 0 ]; then
  green "PASS: existing file with fresh sentinel allowed"
  PASSES=$((PASSES + 1))
else
  red "FAIL: fresh sentinel should allow (exit $RC, output: $OUT)"
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

run_write_hook "$TMPDIR/CLAUDE.md"

if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q "stale"; then
  green "PASS: stale sentinel blocks"
  PASSES=$((PASSES + 1))
else
  red "FAIL: stale sentinel should block (exit $RC)"
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

run_write_hook "$TMPDIR/.preflight/config.json"

if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q "does not cover"; then
  green "PASS: sentinel not covering target blocks"
  PASSES=$((PASSES + 1))
else
  red "FAIL: uncovered file should block (exit $RC, output: $OUT)"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 6: Unrelated file, existing, no sentinel → ALLOW ───

echo "Test 6: Write to unrelated file (not protected)"
setup_git_repo
echo "class Foo {}" > src.cs

run_write_hook "$TMPDIR/src.cs"

if [ "$RC" -eq 0 ]; then
  green "PASS: unrelated file allowed"
  PASSES=$((PASSES + 1))
else
  red "FAIL: unrelated file should pass (exit $RC)"
  FAILURES=$((FAILURES + 1))
fi

# ─── Test 7: Malformed sentinel → BLOCK (fail-closed) ────────

echo "Test 7: Existing CLAUDE.md, malformed sentinel (fail-closed)"
setup_git_repo
echo "# Existing" > CLAUDE.md
git add CLAUDE.md && git commit -q -m "add claude"

mkdir -p .preflight/gate
echo "NOT VALID JSON" > .preflight/gate/bootstrap-write-approved

run_write_hook "$TMPDIR/CLAUDE.md"

if [ "$RC" -eq 2 ]; then
  green "PASS: malformed sentinel fails closed (blocks)"
  PASSES=$((PASSES + 1))
else
  red "FAIL: malformed sentinel should fail closed (exit $RC)"
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

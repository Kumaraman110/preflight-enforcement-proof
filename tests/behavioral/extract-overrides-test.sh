#!/usr/bin/env bash
# Tests for lib/extract-overrides.sh — CLAUDE.md override extraction.
# Validates: section parsing, field validation, freshness checks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PLUGIN_ROOT/lib/extract-overrides.sh"
FAILURES=0
PASSES=0

red() { printf "\033[31m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }

assert_eq() {
  local actual="$1" expected="$2" context="$3"
  if [ "$actual" = "$expected" ]; then
    green "PASS: $context"
    PASSES=$((PASSES + 1))
  else
    red "FAIL: $context — expected '$expected', got '$actual'"
    FAILURES=$((FAILURES + 1))
  fi
}

# ─── Setup ────────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

source "$LIB"

setup_workspace() {
  rm -rf "$TMPDIR"/* "$TMPDIR"/.* 2>/dev/null || true
  cd "$TMPDIR"
  git init -q 2>/dev/null
  git config user.email "test@test.com" 2>/dev/null
  git config user.name "Test" 2>/dev/null
  echo "init" > init.txt
  git add init.txt && git commit -q -m "init" 2>/dev/null
}

# ════════════════════════════════════════════════════════════════
# EXTRACTION TESTS (1-6)
# ════════════════════════════════════════════════════════════════

# Test 1: Complete overrides section → all fields extracted
echo "Test 1: Complete overrides section extracts all fields"
setup_workspace
cat > CLAUDE.md <<'EOF'
# My Project

## Tool Overrides
testCommand: mvn verify
buildCommand: mvn package -DskipTests
packageManager: maven

## Other Section
EOF
git add CLAUDE.md && git commit -q -m "add claude"

extract_overrides_from_claude_md "./CLAUDE.md" "$TMPDIR/out.json" 2>/dev/null
tc=$(python -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['overrides'].get('testCommand',''))" "$TMPDIR/out.json" 2>/dev/null)
bc=$(python -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['overrides'].get('buildCommand',''))" "$TMPDIR/out.json" 2>/dev/null)
pm=$(python -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['overrides'].get('packageManager',''))" "$TMPDIR/out.json" 2>/dev/null)

if [ "$tc" = "mvn verify" ] && [ "$bc" = "mvn package -DskipTests" ] && [ "$pm" = "maven" ]; then
  green "PASS: All three fields extracted correctly"
  PASSES=$((PASSES + 1))
else
  red "FAIL: Extraction wrong (tc='$tc', bc='$bc', pm='$pm')"
  FAILURES=$((FAILURES + 1))
fi

# Test 2: No overrides section → empty overrides, exit 0
echo "Test 2: No overrides section is normal (exit 0)"
setup_workspace
cat > CLAUDE.md <<'EOF'
# My Project

## Commands
Just some regular text.
EOF
git add CLAUDE.md && git commit -q -m "add claude"

EXIT_CODE=0
extract_overrides_from_claude_md "./CLAUDE.md" "$TMPDIR/out2.json" 2>/dev/null || EXIT_CODE=$?
count=$(python -c "import json,sys; d=json.load(open(sys.argv[1])); print(len(d['overrides']))" "$TMPDIR/out2.json" 2>/dev/null)

if [ "$EXIT_CODE" -eq 0 ] && [ "$count" = "0" ]; then
  green "PASS: No section → empty overrides, exit 0"
  PASSES=$((PASSES + 1))
else
  red "FAIL: Expected exit 0 + 0 overrides (exit=$EXIT_CODE, count=$count)"
  FAILURES=$((FAILURES + 1))
fi

# Test 3: Malformed lines → warnings, valid lines still extracted
echo "Test 3: Malformed lines warn but don't break extraction"
setup_workspace
cat > CLAUDE.md <<'EOF'
# Project

## Tool Overrides
testCommand: dotnet test
this line has no colon
buildCommand: dotnet build
<!-- this is a comment -->
# this is also a comment

stack: node
EOF
git add CLAUDE.md && git commit -q -m "add claude"

STDERR_OUT=""
extract_overrides_from_claude_md "./CLAUDE.md" "$TMPDIR/out3.json" 2> "$TMPDIR/stderr3.txt" || true
STDERR_OUT=$(cat "$TMPDIR/stderr3.txt")
tc=$(python -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['overrides'].get('testCommand',''))" "$TMPDIR/out3.json" 2>/dev/null)
bc=$(python -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['overrides'].get('buildCommand',''))" "$TMPDIR/out3.json" 2>/dev/null)
st=$(python -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['overrides'].get('stack',''))" "$TMPDIR/out3.json" 2>/dev/null)

if [ "$tc" = "dotnet test" ] && [ "$bc" = "dotnet build" ] && [ "$st" = "node" ] && echo "$STDERR_OUT" | grep -q "Malformed"; then
  green "PASS: Valid lines extracted, malformed warned"
  PASSES=$((PASSES + 1))
else
  red "FAIL: Extraction wrong or no warning (tc='$tc', bc='$bc', st='$st', stderr='$STDERR_OUT')"
  FAILURES=$((FAILURES + 1))
fi

# Test 4: Unregistered field → warning, skipped, others extracted
echo "Test 4: Unregistered field warned and skipped"
setup_workspace
cat > CLAUDE.md <<'EOF'
# Project

## Tool Overrides
testCommand: pytest
unknownField: some value
stack: python
EOF
git add CLAUDE.md && git commit -q -m "add claude"

extract_overrides_from_claude_md "./CLAUDE.md" "$TMPDIR/out4.json" 2> "$TMPDIR/stderr4.txt" || true
STDERR_OUT=$(cat "$TMPDIR/stderr4.txt")
tc=$(python -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['overrides'].get('testCommand',''))" "$TMPDIR/out4.json" 2>/dev/null)
has_unknown=$(python -c "import json,sys; d=json.load(open(sys.argv[1])); print('unknownField' in d['overrides'])" "$TMPDIR/out4.json" 2>/dev/null)

if [ "$tc" = "pytest" ] && [ "$has_unknown" = "False" ] && echo "$STDERR_OUT" | grep -q "Unregistered.*unknownField"; then
  green "PASS: Unregistered field skipped with warning"
  PASSES=$((PASSES + 1))
else
  red "FAIL: Expected skip + warning (tc='$tc', has_unknown='$has_unknown', stderr='$STDERR_OUT')"
  FAILURES=$((FAILURES + 1))
fi

# Test 5: CLAUDE.md missing → exit 1
echo "Test 5: Missing CLAUDE.md → exit 1"
setup_workspace

EXIT_CODE=0
extract_overrides_from_claude_md "./nonexistent.md" "$TMPDIR/out5.json" 2>/dev/null || EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 1 ]; then
  green "PASS: Missing CLAUDE.md returns exit 1"
  PASSES=$((PASSES + 1))
else
  red "FAIL: Expected exit 1 for missing file (got $EXIT_CODE)"
  FAILURES=$((FAILURES + 1))
fi

# Test 6: Whitespace handling (leading/trailing on field and value)
echo "Test 6: Whitespace is trimmed from field names and values"
setup_workspace
cat > CLAUDE.md <<'EOF'
# Project

## Tool Overrides
  testCommand  :  go test ./...
  stack:rust
EOF
git add CLAUDE.md && git commit -q -m "add claude"

extract_overrides_from_claude_md "./CLAUDE.md" "$TMPDIR/out6.json" 2>/dev/null
tc=$(python -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['overrides'].get('testCommand',''))" "$TMPDIR/out6.json" 2>/dev/null)
st=$(python -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['overrides'].get('stack',''))" "$TMPDIR/out6.json" 2>/dev/null)

if [ "$tc" = "go test ./..." ] && [ "$st" = "rust" ]; then
  green "PASS: Whitespace trimmed correctly"
  PASSES=$((PASSES + 1))
else
  red "FAIL: Whitespace not trimmed (tc='$tc', st='$st')"
  FAILURES=$((FAILURES + 1))
fi

# ════════════════════════════════════════════════════════════════
# FRESHNESS TESTS (7-9)
# ════════════════════════════════════════════════════════════════

# Test 7: overrides_are_fresh returns 0 when hash + HEAD match
echo "Test 7: Fresh overrides return 0"
setup_workspace
cat > CLAUDE.md <<'EOF'
## Tool Overrides
testCommand: npm test
EOF
git add CLAUDE.md && git commit -q -m "add claude"

extract_overrides_from_claude_md "./CLAUDE.md" "$TMPDIR/fresh.json" 2>/dev/null

if overrides_are_fresh "$TMPDIR/fresh.json" "./CLAUDE.md"; then
  green "PASS: Fresh overrides detected"
  PASSES=$((PASSES + 1))
else
  red "FAIL: overrides_are_fresh should return 0"
  FAILURES=$((FAILURES + 1))
fi

# Test 8: overrides_are_fresh returns 1 when CLAUDE.md edited
echo "Test 8: Stale after CLAUDE.md edit"
setup_workspace
cat > CLAUDE.md <<'EOF'
## Tool Overrides
testCommand: npm test
EOF
git add CLAUDE.md && git commit -q -m "add claude"

extract_overrides_from_claude_md "./CLAUDE.md" "$TMPDIR/stale.json" 2>/dev/null

# Edit CLAUDE.md
echo "stack: node" >> CLAUDE.md

if ! overrides_are_fresh "$TMPDIR/stale.json" "./CLAUDE.md"; then
  green "PASS: Stale after CLAUDE.md edit"
  PASSES=$((PASSES + 1))
else
  red "FAIL: Should be stale after edit"
  FAILURES=$((FAILURES + 1))
fi

# Test 9: overrides_are_fresh returns 1 when HEAD moves
echo "Test 9: Stale after HEAD moves"
setup_workspace
cat > CLAUDE.md <<'EOF'
## Tool Overrides
testCommand: cargo test
EOF
git add CLAUDE.md && git commit -q -m "add claude"

extract_overrides_from_claude_md "./CLAUDE.md" "$TMPDIR/head.json" 2>/dev/null

# Move HEAD
echo "extra" > extra.txt && git add extra.txt && git commit -q -m "move head"

if ! overrides_are_fresh "$TMPDIR/head.json" "./CLAUDE.md"; then
  green "PASS: Stale after HEAD moves"
  PASSES=$((PASSES + 1))
else
  red "FAIL: Should be stale after HEAD move"
  FAILURES=$((FAILURES + 1))
fi

# ════════════════════════════════════════════════════════════════
# SECTION HEADING TOLERANCE (10)
# ════════════════════════════════════════════════════════════════

# Test 10: Trailing whitespace in heading still matches
echo "Test 10: Section heading with trailing whitespace"
setup_workspace
printf "## Tool Overrides   \ntestCommand: make test\n" > CLAUDE.md
git add CLAUDE.md && git commit -q -m "add claude"

extract_overrides_from_claude_md "./CLAUDE.md" "$TMPDIR/out10.json" 2>/dev/null
tc=$(python -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['overrides'].get('testCommand',''))" "$TMPDIR/out10.json" 2>/dev/null)

assert_eq "$tc" "make test" "Trailing whitespace in heading works"

# ─── Results ──────────────────────────────────────────────────

echo ""
echo "Extract-overrides tests: $PASSES passed, $FAILURES failed"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
else
  exit 0
fi

#!/usr/bin/env bash
# Tests for TDD-skill testCommand resolution through lib/resolve-config.sh.
# Validates: three-layer precedence from the TDD-skill consumer's perspective.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PLUGIN_ROOT/lib/resolve-config.sh"
FAILURES=0
PASSES=0

red() { printf "\033[31m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

cd "$TMPDIR"
git init -q 2>/dev/null
git config user.email "test@test.com" 2>/dev/null
git config user.name "Test" 2>/dev/null
echo "init" > init.txt
git add init.txt && git commit -q -m "init" 2>/dev/null

# Helper: simulate TDD-skill Step 0 resolution
tdd_resolve() {
  local cfg="${1:-}" derived="${2:-}" overrides="${3:-}"
  local result
  result=$(resolve_field_with_source "testCommand" "$cfg" "$derived" "$overrides" 2>/dev/null)
  echo "$result"
}

tdd_resolve_stderr() {
  local cfg="${1:-}" derived="${2:-}" overrides="${3:-}"
  resolve_field_with_source "testCommand" "$cfg" "$derived" "$overrides" 2>&1 >/dev/null
}

# ════════════════════════════════════════════════════════════════
# Test 1: Config has testCommand → TDD uses config value
# ════════════════════════════════════════════════════════════════
echo "Test 1: Config testCommand wins"
echo '{"test":{"command":"dotnet test --no-build"}}' > "$TMPDIR/config.json"
echo '{"testCommand":{"value":"fallback"}}' > "$TMPDIR/derived.json"

result=$(tdd_resolve "$TMPDIR/config.json" "$TMPDIR/derived.json" "/nonexistent")
if [ "$result" = "dotnet test --no-build|explicit" ]; then
  green "PASS: Config testCommand wins (source=explicit)"
  PASSES=$((PASSES + 1))
else
  red "FAIL: Expected 'dotnet test --no-build|explicit', got '$result'"
  FAILURES=$((FAILURES + 1))
fi

# ════════════════════════════════════════════════════════════════
# Test 2: Config silent, override has testCommand → override wins
# ════════════════════════════════════════════════════════════════
echo "Test 2: Override testCommand fills gap"
echo '{}' > "$TMPDIR/config2.json"

cat > CLAUDE.md <<'EOF'
## Tool Overrides
testCommand: mvn verify -Pintegration
EOF
git add CLAUDE.md && git commit -q -m "claude" 2>/dev/null

source "$PLUGIN_ROOT/lib/extract-overrides.sh"
extract_overrides_from_claude_md "./CLAUDE.md" "$TMPDIR/overrides.json" 2>/dev/null

result=$(tdd_resolve "$TMPDIR/config2.json" "$TMPDIR/derived.json" "$TMPDIR/overrides.json")
if [ "$result" = "mvn verify -Pintegration|override" ]; then
  green "PASS: Override testCommand fills gap (source=override)"
  PASSES=$((PASSES + 1))
else
  red "FAIL: Expected 'mvn verify -Pintegration|override', got '$result'"
  FAILURES=$((FAILURES + 1))
fi

# ════════════════════════════════════════════════════════════════
# Test 3: Config and override silent, derived has testCommand
# ════════════════════════════════════════════════════════════════
echo "Test 3: Derived testCommand fills gap"
echo '{}' > "$TMPDIR/config3.json"
echo '{"testCommand":{"value":"pytest -xvs"}}' > "$TMPDIR/derived3.json"

# Override file with empty overrides (simulating no testCommand in CLAUDE.md)
echo '{"extractedAtHEAD":"x","claudeMdHash":"y","extractedAt":"z","overrides":{}}' > "$TMPDIR/override-empty.json"

result=$(tdd_resolve "$TMPDIR/config3.json" "$TMPDIR/derived3.json" "$TMPDIR/override-empty.json")
if [ "$result" = "pytest -xvs|derived" ]; then
  green "PASS: Derived testCommand fills gap (source=derived)"
  PASSES=$((PASSES + 1))
else
  red "FAIL: Expected 'pytest -xvs|derived', got '$result'"
  FAILURES=$((FAILURES + 1))
fi

# ════════════════════════════════════════════════════════════════
# Test 4: All three silent → unresolved (TDD would halt)
# ════════════════════════════════════════════════════════════════
echo "Test 4: All silent → unresolved (halt path)"
echo '{}' > "$TMPDIR/config4.json"
echo '{}' > "$TMPDIR/derived4.json"

result=$(tdd_resolve "$TMPDIR/config4.json" "$TMPDIR/derived4.json" "/nonexistent")
if [ "$result" = "|unresolved" ]; then
  green "PASS: All silent → unresolved"
  PASSES=$((PASSES + 1))
else
  red "FAIL: Expected '|unresolved', got '$result'"
  FAILURES=$((FAILURES + 1))
fi

# ════════════════════════════════════════════════════════════════
# Test 5: Override stale → skipped with warning, falls to derived
# ════════════════════════════════════════════════════════════════
echo "Test 5: Stale override skipped, falls through to derived"
echo '{}' > "$TMPDIR/config5.json"
echo '{"testCommand":{"value":"go test ./..."}}' > "$TMPDIR/derived5.json"

# Create stale override (hash mismatch — CLAUDE.md has been edited since extraction)
echo "extra line" >> CLAUDE.md

stderr_out=$(tdd_resolve_stderr "$TMPDIR/config5.json" "$TMPDIR/derived5.json" "$TMPDIR/overrides.json")
result=$(tdd_resolve "$TMPDIR/config5.json" "$TMPDIR/derived5.json" "$TMPDIR/overrides.json")

if [ "$result" = "go test ./...|derived" ] && echo "$stderr_out" | grep -q "stale"; then
  green "PASS: Stale override skipped with warning, derived wins"
  PASSES=$((PASSES + 1))
else
  red "FAIL: Expected 'go test ./...|derived' + stale warning (result='$result', stderr='$stderr_out')"
  FAILURES=$((FAILURES + 1))
fi

# ════════════════════════════════════════════════════════════════
# Test 6: Config has malformed JSON → treats as silent, falls through
# ════════════════════════════════════════════════════════════════
echo "Test 6: Malformed config JSON falls through"
echo 'NOT VALID JSON {{{{' > "$TMPDIR/config6.json"
echo '{"testCommand":{"value":"cargo test"}}' > "$TMPDIR/derived6.json"

result=$(tdd_resolve "$TMPDIR/config6.json" "$TMPDIR/derived6.json" "/nonexistent")
if [ "$result" = "cargo test|derived" ]; then
  green "PASS: Malformed config falls through to derived"
  PASSES=$((PASSES + 1))
else
  red "FAIL: Expected 'cargo test|derived', got '$result'"
  FAILURES=$((FAILURES + 1))
fi

# ════════════════════════════════════════════════════════════════
# Test 7: Source tag correctness for each layer
# ════════════════════════════════════════════════════════════════
echo "Test 7: Source tags are correct identifiers"
# Already tested individually above, verify the source values are in expected set
ALL_SOURCES_VALID=true

echo '{"testCommand":"from-cfg"}' > "$TMPDIR/cfg7.json"
r=$(tdd_resolve "$TMPDIR/cfg7.json" "/nonexistent" "/nonexistent")
src="${r##*|}"
[ "$src" = "explicit" ] || { ALL_SOURCES_VALID=false; red "  config source should be 'explicit', got '$src'"; }

# Reset CLAUDE.md for fresh override
cat > CLAUDE.md <<'EOF'
## Tool Overrides
testCommand: from-override
EOF
git add CLAUDE.md && git commit -q -m "reset" 2>/dev/null
extract_overrides_from_claude_md "./CLAUDE.md" "$TMPDIR/ov7.json" 2>/dev/null

r=$(tdd_resolve "$TMPDIR/config3.json" "/nonexistent" "$TMPDIR/ov7.json")
src="${r##*|}"
[ "$src" = "override" ] || { ALL_SOURCES_VALID=false; red "  override source should be 'override', got '$src'"; }

echo '{"testCommand":{"value":"from-derived"}}' > "$TMPDIR/d7.json"
r=$(tdd_resolve "$TMPDIR/config3.json" "$TMPDIR/d7.json" "/nonexistent")
src="${r##*|}"
[ "$src" = "derived" ] || { ALL_SOURCES_VALID=false; red "  derived source should be 'derived', got '$src'"; }

r=$(tdd_resolve "$TMPDIR/config3.json" "/nonexistent" "/nonexistent")
src="${r##*|}"
[ "$src" = "unresolved" ] || { ALL_SOURCES_VALID=false; red "  unresolved source should be 'unresolved', got '$src'"; }

if [ "$ALL_SOURCES_VALID" = true ]; then
  green "PASS: All source tags correct (explicit, override, derived, unresolved)"
  PASSES=$((PASSES + 1))
else
  red "FAIL: Some source tags incorrect"
  FAILURES=$((FAILURES + 1))
fi

# ─── Results ──────────────────────────────────────────────────
echo ""
echo "TDD-skill resolution tests: $PASSES passed, $FAILURES failed"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
else
  exit 0
fi

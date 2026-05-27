#!/usr/bin/env bash
# Scan profile and minimal-scan pattern tests.
# Validates: (1) profile parsing for well-formed and malformed inputs,
# (2) minimal scan pattern matching against known-bad fixtures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures"
FAILURES=0
PASSES=0

red() { printf "\033[31m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }

# Test 1: dotnet-framework profile has well-formed frontmatter
PROFILE="$PLUGIN_ROOT/examples/scan-profiles/dotnet-framework.md"
if grep -q "^name: dotnet-framework" "$PROFILE" && \
   grep -q "^stack: dotnet" "$PROFILE" && \
   grep -q "^version: 1" "$PROFILE"; then
  green "PASS: dotnet-framework profile has required frontmatter fields"
  PASSES=$((PASSES + 1))
else
  red "FAIL: dotnet-framework profile missing required frontmatter"
  FAILURES=$((FAILURES + 1))
fi

# Test 2: dotnet-framework profile has 7 categories
CATEGORY_COUNT=$(grep -c "^## §D" "$PROFILE" || echo 0)
if [ "$CATEGORY_COUNT" -eq 7 ]; then
  green "PASS: dotnet-framework profile has 7 §D categories"
  PASSES=$((PASSES + 1))
else
  red "FAIL: expected 7 §D categories, found $CATEGORY_COUNT"
  FAILURES=$((FAILURES + 1))
fi

# Test 3: Every category in dotnet-framework has all 6 required fields
for FIELD in "What:" "Why:" "Severity:" "Glob:" "Signal:" "Replacement:"; do
  FIELD_COUNT=$(grep -c "^\*\*${FIELD}\*\*" "$PROFILE" || echo 0)
  if [ "$FIELD_COUNT" -eq 7 ]; then
    green "PASS: all 7 categories have ${FIELD} field"
    PASSES=$((PASSES + 1))
  else
    red "FAIL: ${FIELD} field count is $FIELD_COUNT (expected 7)"
    FAILURES=$((FAILURES + 1))
  fi
done

# Test 4: §M5 (AWS keys) matches known AWS key fixture
if grep -E "(AKIA|ASIA|A3T[A-Z0-9])[0-9A-Z]{16}" "$FIXTURES/known-aws-key.txt" >/dev/null; then
  green "PASS: §M5 AWS key pattern matches known-aws-key fixture"
  PASSES=$((PASSES + 1))
else
  red "FAIL: §M5 AWS key pattern failed to match known-aws-key fixture"
  FAILURES=$((FAILURES + 1))
fi

# Test 5: §M6 (GitHub tokens) matches known GitHub token fixture
if grep -E "gh[pousr]_[A-Za-z0-9]{36}" "$FIXTURES/known-github-token.txt" >/dev/null; then
  green "PASS: §M6 GitHub token pattern matches known-github-token fixture"
  PASSES=$((PASSES + 1))
else
  red "FAIL: §M6 GitHub token pattern failed to match known-github-token fixture"
  FAILURES=$((FAILURES + 1))
fi

# Test 6: §M2 (passwords) matches known password fixture
if grep -iE "(password|passwd|pwd|passphrase|secret)\s*[=:]\s*[\"'][^\"']{8,}[\"']" "$FIXTURES/known-password.txt" >/dev/null; then
  green "PASS: §M2 password pattern matches known-password fixture"
  PASSES=$((PASSES + 1))
else
  red "FAIL: §M2 password pattern failed to match known-password fixture"
  FAILURES=$((FAILURES + 1))
fi

# Test 7: Malformed profile (no frontmatter) is detectable as malformed
if ! grep -q "^---$" "$FIXTURES/malformed-no-frontmatter.md"; then
  green "PASS: malformed-no-frontmatter fixture correctly lacks frontmatter (detectable)"
  PASSES=$((PASSES + 1))
else
  red "FAIL: malformed-no-frontmatter fixture has frontmatter (test invalid)"
  FAILURES=$((FAILURES + 1))
fi

# Test 8: Empty profile fixture is empty
if [ ! -s "$FIXTURES/malformed-empty.md" ]; then
  green "PASS: malformed-empty fixture is zero bytes (detectable as malformed)"
  PASSES=$((PASSES + 1))
else
  red "FAIL: malformed-empty fixture is not empty"
  FAILURES=$((FAILURES + 1))
fi

# Test 9: Well-formed minimal profile parses correctly
WELLFORMED="$FIXTURES/wellformed-minimal.md"
if grep -q "^name: test-minimal" "$WELLFORMED" && \
   grep -q "^version: 1" "$WELLFORMED" && \
   grep -q "^## §T1" "$WELLFORMED"; then
  green "PASS: wellformed-minimal fixture has correct structure"
  PASSES=$((PASSES + 1))
else
  red "FAIL: wellformed-minimal fixture structure incorrect"
  FAILURES=$((FAILURES + 1))
fi

# Test 10: 4-step loading cascade is documented in analyst
ANALYST="$PLUGIN_ROOT/agents/discovery-analyst.md"
if grep -q "Check project config" "$ANALYST" && \
   grep -q ".preflight/scan-profiles/" "$ANALYST" && \
   grep -q "CLAUDE_PLUGIN_ROOT" "$ANALYST" && \
   grep -q "built-in minimal scan" "$ANALYST"; then
  green "PASS: 4-step loading cascade documented in analyst"
  PASSES=$((PASSES + 1))
else
  red "FAIL: 4-step loading cascade missing or incomplete in analyst"
  FAILURES=$((FAILURES + 1))
fi

# Test 11: 12 minimal scan patterns documented (§M1-§M12)
M_PATTERN_COUNT=$(grep -c "Pattern §M[0-9]" "$ANALYST" || echo 0)
if [ "$M_PATTERN_COUNT" -eq 12 ]; then
  green "PASS: all 12 §M minimal scan patterns documented"
  PASSES=$((PASSES + 1))
else
  red "FAIL: expected 12 §M patterns, found $M_PATTERN_COUNT"
  FAILURES=$((FAILURES + 1))
fi

# Test 12: README.md format spec exists and has key sections
README="$PLUGIN_ROOT/examples/scan-profiles/README.md"
if [ -f "$README" ] && \
   grep -q "Frontmatter" "$README" && \
   grep -q "Category Sections" "$README" && \
   grep -q "Signal Field: Dual-Mode Detection" "$README" && \
   grep -q "Versioning Contract" "$README"; then
  green "PASS: scan profile format specification README exists with required sections"
  PASSES=$((PASSES + 1))
else
  red "FAIL: scan profile README missing or incomplete"
  FAILURES=$((FAILURES + 1))
fi

# Test 13: Path exclusions documented in discovery-analyst
if grep -q "Path Exclusions" "$ANALYST" && \
   grep -q "\*\*/test\*/" "$ANALYST" && \
   grep -q "\*\*/fixture\*/" "$ANALYST" && \
   grep -q "node_modules" "$ANALYST"; then
  green "PASS: path exclusions documented for Tier 1 false-positive mitigation"
  PASSES=$((PASSES + 1))
else
  red "FAIL: path exclusions missing or incomplete in analyst"
  FAILURES=$((FAILURES + 1))
fi

# Test 14: Stop-words documented in discovery-analyst
if grep -q "Stop-Words" "$ANALYST" && \
   grep -q "placeholder" "$ANALYST" && \
   grep -q "changeme" "$ANALYST" && \
   grep -q "fake" "$ANALYST"; then
  green "PASS: stop-words documented for Tier 1 false-positive suppression"
  PASSES=$((PASSES + 1))
else
  red "FAIL: stop-words missing or incomplete in analyst"
  FAILURES=$((FAILURES + 1))
fi

# Test 15: False-positive fixture contains stop-words that would suppress Tier 1 matches
FP_FIXTURE="$FIXTURES/test-data/password-in-test.txt"
if grep -qiE "(password|secret|api_key)\s*=" "$FP_FIXTURE" && \
   grep -qiE "(placeholder|changeme|fake)" "$FP_FIXTURE"; then
  green "PASS: false-positive fixture has both credential patterns and stop-words"
  PASSES=$((PASSES + 1))
else
  red "FAIL: false-positive fixture incorrect"
  FAILURES=$((FAILURES + 1))
fi

echo ""
echo "Scan profile tests: $PASSES passed, $FAILURES failed"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0

#!/usr/bin/env bash
# Behavioral test for lib/null-boundary-lint.sh
#
# Proves the lint flags the three known defect shapes from SessionToken run:
#   1. ChannelCacheService.IsValidChannel - empty guard without null check + fail-open
#   2. ProfileCacheService.IsValidProfile - same shape
#   3. RequestValidation.Validate - W0008 guard (TokenStatus == "") misses null
#
# And does NOT flag the correctly-guarded counter-example.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="${SCRIPT_DIR}/../../lib/null-boundary-lint.sh"
FIXTURE_DIR="${SCRIPT_DIR}/../fixtures/null-lint"

PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$LINT" ]; then
  bad "lint script not found at $LINT"
  echo ""; echo "null-boundary-lint: ${PASS} passed, ${FAIL} failed"; exit 1
fi

# Run lint on fixture directory
OUT=$(bash "$LINT" "$FIXTURE_DIR" 2>&1)
RC=$?

# Should exit 1 (findings present)
if [ "$RC" -eq 1 ]; then
  ok "lint exits 1 when findings present"
else
  bad "lint exited $RC (expected 1), output: $OUT"
fi

# Check each expected finding is present
if echo "$OUT" | grep -q "ChannelCacheService.cs.*EMPTY_GUARD_WITHOUT_NULL_CHECK"; then
  ok "flags ChannelCacheService empty guard without null check"
else
  bad "missing ChannelCacheService empty guard finding. Output: $OUT"
fi

if echo "$OUT" | grep -q "ChannelCacheService.cs.*PERMISSIVE_DEFAULT_UNCONFIGURED"; then
  ok "flags ChannelCacheService permissive default when unconfigured"
else
  bad "missing ChannelCacheService permissive default finding. Output: $OUT"
fi

if echo "$OUT" | grep -q "ProfileCacheService.cs.*EMPTY_GUARD_WITHOUT_NULL_CHECK"; then
  ok "flags ProfileCacheService empty guard without null check"
else
  bad "missing ProfileCacheService empty guard finding. Output: $OUT"
fi

if echo "$OUT" | grep -q "ProfileCacheService.cs.*PERMISSIVE_DEFAULT_UNCONFIGURED"; then
  ok "flags ProfileCacheService permissive default when unconfigured"
else
  bad "missing ProfileCacheService permissive default finding. Output: $OUT"
fi

if echo "$OUT" | grep -q "RequestValidation.cs.*W0008_STYLE_GUARD"; then
  ok "flags RequestValidation W0008-style guard"
else
  bad "missing RequestValidation W0008 finding. Output: $OUT"
fi

# The LIVE PR #95 shape: `(!IsNullOrEmpty(request.SessionToken)) && TokenStatus == ""`.
# A null check of a DIFFERENT variable on the same line must NOT suppress the
# TokenStatus W0008 finding (this is the exact line the run's round 8 caught).
W8_COUNT=$(echo "$OUT" | grep -c "RequestValidation.cs.*W0008_STYLE_GUARD" || true)
if [ "$W8_COUNT" -ge 2 ]; then
  ok "flags the live two-clause W0008 shape (other-variable null check does not suppress)"
else
  bad "live two-clause W0008 shape not flagged (got $W8_COUNT W0008 finding(s)). Output: $OUT"
fi

# Check correctly-guarded file does NOT produce findings
# Run lint on just the well-guarded file
OUT_GOOD=$(bash "$LINT" "$FIXTURE_DIR/WellGuardedService.cs" 2>&1)
RC_GOOD=$?
if [ "$RC_GOOD" -eq 0 ]; then
  ok "does NOT flag WellGuardedService (correctly guarded)"
else
  bad "incorrectly flags WellGuardedService (false positive). Output: $OUT_GOOD"
fi

# JSON output test
OUT_JSON=$(bash "$LINT" "$FIXTURE_DIR" --json 2>&1)
if echo "$OUT_JSON" | grep -q '"type": "EMPTY_GUARD_WITHOUT_NULL_CHECK"'; then
  ok "JSON output includes EMPTY_GUARD_WITHOUT_NULL_CHECK type"
else
  bad "JSON output missing EMPTY_GUARD_WITHOUT_NULL_CHECK. Output: $OUT_JSON"
fi

if echo "$OUT_JSON" | grep -q '"type": "PERMISSIVE_DEFAULT_UNCONFIGURED"'; then
  ok "JSON output includes PERMISSIVE_DEFAULT_UNCONFIGURED type"
else
  bad "JSON output missing PERMISSIVE_DEFAULT_UNCONFIGURED. Output: $OUT_JSON"
fi

if echo "$OUT_JSON" | grep -q '"type": "W0008_STYLE_GUARD"'; then
  ok "JSON output includes W0008_STYLE_GUARD type"
else
  bad "JSON output missing W0008_STYLE_GUARD. Output: $OUT_JSON"
fi

echo ""
echo "null-boundary-lint tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
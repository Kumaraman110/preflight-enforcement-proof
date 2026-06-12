#!/usr/bin/env bash
# Behavioral test for lib/anti-tautology-lint.sh (issue #7).
#
# The live exhibit (PR #95): a generated ResultMessagesTests asserted the buggy
# message map against the map's OWN values — passing while wrong. The lint
# flags the SYMBOL-REFERENCE subset of that class: an assertion line where the
# same class-like identifier appears on both the expected and actual sides.
#
# Asserts:
#   T1. lint exits 1 on the fixture dir (findings present)
#   T2. TautologicalResultMessagesTests.cs: classic Assert.Equal same-class shape flagged
#   T3. TautologicalResultMessagesTests.cs: fluent .Should().Be(same-class) shape flagged
#   T4. exactly 2 findings in the tautological fixture — the var-indirection and
#       cross-line cases are DOCUMENTED MISSES and must NOT be flagged (pins the
#       lint's stated false-negative bounds so a "smarter" rewrite that starts
#       flagging them must update the docs too)
#   T5. GoldenResultMessagesTests.cs (independent literals) NOT flagged — exit 0
#   T6. non-test files are not scanned (a tautology in a non-test .cs is ignored)
#   T7. --json output carries the type and parses under jq
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="${SCRIPT_DIR}/../../lib/anti-tautology-lint.sh"
FIXTURE_DIR="${SCRIPT_DIR}/../fixtures/tautology"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$LINT" ]; then
  bad "lint script not found at $LINT"
  echo ""; echo "anti-tautology-lint tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi

OUT=$(bash "$LINT" "$FIXTURE_DIR" 2>&1); RC=$?

# T1
if [ "$RC" -eq 1 ]; then
  ok "T1: lint exits 1 when findings present"
else
  bad "T1: lint exited $RC (expected 1). Output: $OUT"
fi

# T2: classic Assert.Equal(ResultMessages.X, ResultMessages.Y) — fixture line 17
if echo "$OUT" | grep -q "TautologicalResultMessagesTests.cs:17:TAUTOLOGICAL_ASSERTION"; then
  ok "T2: classic same-class Assert.Equal flagged (line 17)"
else
  bad "T2: missing classic-shape finding at :17. Output: $OUT"
fi

# T3: fluent X.GetMessage().Should().Be(X.E1001) — fixture line 25
if echo "$OUT" | grep -q "TautologicalResultMessagesTests.cs:25:TAUTOLOGICAL_ASSERTION"; then
  ok "T3: fluent same-class .Should().Be() flagged (line 25)"
else
  bad "T3: missing fluent-shape finding at :25. Output: $OUT"
fi

# T4: exactly 2 findings in the tautological file (documented misses stay missed)
TCOUNT=$(echo "$OUT" | grep -c "TautologicalResultMessagesTests.cs.*TAUTOLOGICAL_ASSERTION" || true)
if [ "$TCOUNT" -eq 2 ]; then
  ok "T4: exactly 2 findings — var-indirection and cross-line stay documented misses"
else
  bad "T4: expected exactly 2 findings in tautological fixture, got $TCOUNT. If the lint got smarter, update its documented bounds AND this pin. Output: $OUT"
fi

# T5: golden file clean
OUT_GOOD=$(bash "$LINT" "$FIXTURE_DIR/GoldenResultMessagesTests.cs" 2>&1); RC_GOOD=$?
if [ "$RC_GOOD" -eq 0 ]; then
  ok "T5: golden-literal tests NOT flagged (exit 0)"
else
  bad "T5: golden tests wrongly flagged. Output: $OUT_GOOD"
fi

# T6: non-test filename ignored even with a tautological line in it
TMPD=$(mktemp -d)
printf '%s\n' 'public class Helper {' '  void f() { Assert.Equal(ResultMessages.W0001, ResultMessages.GetMessage("W0001")); }' '}' > "$TMPD/Helper.cs"
OUT_NT=$(bash "$LINT" "$TMPD" 2>&1); RC_NT=$?
rm -rf "$TMPD"
if [ "$RC_NT" -eq 0 ]; then
  ok "T6: non-test file (Helper.cs) not scanned"
else
  bad "T6: non-test file was scanned/flagged. Output: $OUT_NT"
fi

# T7: JSON mode
OUT_JSON=$(bash "$LINT" "$FIXTURE_DIR" --json 2>&1)
if echo "$OUT_JSON" | jq -e '.findings_count >= 2' >/dev/null 2>&1 \
   && echo "$OUT_JSON" | grep -q '"type": "TAUTOLOGICAL_ASSERTION"'; then
  ok "T7: --json parses and carries TAUTOLOGICAL_ASSERTION"
else
  bad "T7: JSON output invalid. Output: $OUT_JSON"
fi

echo ""
echo "anti-tautology-lint tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

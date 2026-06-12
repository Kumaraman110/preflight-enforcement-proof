#!/usr/bin/env bash
# Behavioral test for issue #5 WIRE-A: wire_format parity detection.
#
# Proves the parity engine detects runtime-serialization divergence that is
# invisible to wire_contract alone (both specs are extracted from their own
# source, so each side's DECLARED names look "correct"):
#   W1. serialized-name divergence (legacy camelCase resolver emits resultCode,
#       migrated PropertyNamingPolicy=null emits ResultCode) -> CHANGED
#   W2. that CHANGED is BLOCKING at confidence:high (the RED->GREEN pivot:
#       before WIRE-A, wire_format was not in BLOCKING_CATEGORIES and the
#       divergence surfaced only as advisory)
#   W3. paraphrased result message (message_text observable on result_code)
#       -> CHANGED result_code, blocking (no engine change needed; pins it)
#   W4. identical pair (wire_format:response.SessionToken) -> NO diff entry
#   W5. structural: spec-analyst.md carries the wire_format extraction rules
#       (prompt-level surface — labeled as such; this test pins the prose
#       exists, it cannot prove an LLM follows it)
#   W6. regression: BLOCKING_CATEGORIES still contains the original four and
#       error_path stays advisory (set not clobbered)
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="${SCRIPT_DIR}/../../lib/parity-check.sh"
ANALYST="${SCRIPT_DIR}/../../agents/spec-analyst.md"
FIXTURE_DIR="${SCRIPT_DIR}/../fixtures/wire-format"
LEGACY="${FIXTURE_DIR}/legacy-spec.json"
MIGRATED="${FIXTURE_DIR}/migrated-spec.json"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

for f in "$ENGINE" "$ANALYST" "$LEGACY" "$MIGRATED"; do
  if [ ! -f "$f" ]; then
    bad "required file not found: $f"
    echo ""; echo "wire-format-parity tests: ${PASS} passed, ${FAIL} failed"; exit 1
  fi
done

OUT=$(bash "$ENGINE" "$LEGACY" "$MIGRATED" 2>&1)
RC=$?

# Engine reports blocking violations -> exit 2
if [ "$RC" -eq 2 ]; then
  ok "engine exits 2 (blocking violations present)"
else
  bad "engine exited $RC (expected 2). Output: $OUT"
fi

# --- W1: serialized-name divergence detected as CHANGED ---
W1=$(echo "$OUT" | python -c "
import json,sys
r=json.load(sys.stdin)
e=[c for c in r['changed'] if c['id']=='wire_format:response.ResultCode']
if len(e)!=1: print('ABSENT'); sys.exit()
c=e[0]
b,m=c['baseline_observable'],c['current_observable']
if b.get('serialized_name')=='resultCode' and m.get('serialized_name')=='ResultCode' and c['reason']=='observable_differs':
    print('OK:'+c['severity'])
else:
    print('WRONG:'+json.dumps(c))
")
case "$W1" in
  OK:*) ok "W1: wire_format serialized-name divergence (resultCode vs ResultCode) detected as CHANGED" ;;
  *)    bad "W1: wire_format CHANGED entry wrong/absent: $W1" ;;
esac

# --- W2: that CHANGED is BLOCKING at confidence high (RED->GREEN pivot) ---
if [ "$W1" = "OK:blocking" ]; then
  ok "W2: wire_format CHANGED severity is BLOCKING at confidence:high"
else
  bad "W2: wire_format CHANGED severity is not blocking (got: $W1) — wire_format missing from BLOCKING_CATEGORIES?"
fi

# --- W3: paraphrased result message -> CHANGED result_code, blocking ---
W3=$(echo "$OUT" | python -c "
import json,sys
r=json.load(sys.stdin)
e=[c for c in r['changed'] if c['id']=='result_code:E0001']
if len(e)!=1: print('ABSENT'); sys.exit()
c=e[0]
b,m=c['baseline_observable'],c['current_observable']
if b.get('message_text')!=m.get('message_text') and b.get('result_code')==m.get('result_code'):
    print('OK:'+c['severity'])
else:
    print('WRONG:'+json.dumps(c))
")
if [ "$W3" = "OK:blocking" ]; then
  ok "W3: paraphrased message_text surfaces as CHANGED result_code, blocking"
else
  bad "W3: message_text paraphrase not detected as blocking CHANGED (got: $W3)"
fi

# --- W4: identical pair produces no diff entry ---
W4=$(echo "$OUT" | python -c "
import json,sys
r=json.load(sys.stdin)
hits=[e for k in ('missing','changed','added') for e in r[k] if e['id']=='wire_format:response.SessionToken']
print('CLEAN' if not hits else 'DIRTY:'+json.dumps(hits))
")
if [ "$W4" = "CLEAN" ]; then
  ok "W4: identical wire_format pair (SessionToken) produces no diff entry"
else
  bad "W4: false diff on identical pair: $W4"
fi

# Sanity: exactly the two expected CHANGED entries, nothing phantom
COUNTS=$(echo "$OUT" | python -c "
import json,sys
r=json.load(sys.stdin); s=r['summary']
print(f\"{s['missing']}/{s['changed']}/{s['added']}\")
")
if [ "$COUNTS" = "0/2/0" ]; then
  ok "summary is exactly 0 missing / 2 changed / 0 added (no phantom diffs)"
else
  bad "unexpected diff counts (missing/changed/added): $COUNTS"
fi

# --- W5: structural — spec-analyst.md carries the wire_format extraction rules.
# PROMPT-LEVEL surface: these greps pin that the instructions exist; they cannot
# prove an LLM follows them (honest mechanism label).
if grep -q '`wire_format` | `serialized_name`, `null_emitted`, `context_id`' "$ANALYST"; then
  ok "W5a: observable table has wire_format row (serialized_name, null_emitted, context_id)"
else
  bad "W5a: wire_format observable table row missing in spec-analyst.md"
fi

if grep -q 'wire_format Observable — Computed Serialization Rules' "$ANALYST"; then
  ok "W5b: computed-serialization rules subsection present"
else
  bad "W5b: computed-serialization rules subsection missing in spec-analyst.md"
fi

if grep -q 'PropertyNamingPolicy' "$ANALYST" && grep -q 'ContractResolver' "$ANALYST" \
   && grep -q 'DefaultIgnoreCondition' "$ANALYST" && grep -q 'NullValueHandling' "$ANALYST"; then
  ok "W5c: serializer-config capture covers both stacks (ContractResolver/NullValueHandling + PropertyNamingPolicy/DefaultIgnoreCondition)"
else
  bad "W5c: serializer-config capture guidance incomplete in spec-analyst.md"
fi

if grep -q 'This computation is INFERRED (prompt-level)' "$ANALYST"; then
  ok "W5d: honesty label present (computation is INFERRED/prompt-level)"
else
  bad "W5d: honesty label missing in spec-analyst.md"
fi

if grep -q 'message_text' "$ANALYST" && grep -q 'never paraphrase' "$ANALYST"; then
  ok "W5e: result_code message_text verbatim guidance present"
else
  bad "W5e: message_text guidance missing in spec-analyst.md"
fi

if grep -q '"category_vocabulary": \["result_code", "wire_contract", "wire_format"' "$ANALYST"; then
  ok "W5f: category_vocabulary example includes wire_format"
else
  bad "W5f: category_vocabulary example missing wire_format"
fi

# --- W6: regression — blocking set not clobbered; error_path stays advisory ---
BLOCK_LINE=$(grep 'BLOCKING_CATEGORIES = ' "$ENGINE")
W6_OK=1
for cat in result_code wire_contract side_effect state_transition wire_format; do
  if ! echo "$BLOCK_LINE" | grep -q "\"$cat\""; then
    bad "W6: BLOCKING_CATEGORIES missing \"$cat\" — line: $BLOCK_LINE"
    W6_OK=0
  fi
done
if echo "$BLOCK_LINE" | grep -q '"error_path"'; then
  bad "W6: error_path wrongly promoted into BLOCKING_CATEGORIES"
  W6_OK=0
fi
if ! grep 'ADVISORY_CATEGORIES = ' "$ENGINE" | grep -q '"error_path"'; then
  bad "W6: error_path no longer in ADVISORY_CATEGORIES"
  W6_OK=0
fi
if [ "$W6_OK" -eq 1 ]; then
  ok "W6: BLOCKING_CATEGORIES intact (original four + wire_format), error_path stays advisory"
fi

echo ""
echo "wire-format-parity tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

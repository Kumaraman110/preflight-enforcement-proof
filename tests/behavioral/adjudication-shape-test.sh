#!/usr/bin/env bash
# Behavioral test: adjudication-output-gate fails CLOSED on unexpected top-level shape (L2).
#
# The loophole: a record written as {"verdicts":[...]} (any top-level key other than
# "adjudications") gave the schema walk zero entries — forbidden keys and evidence-less
# DEFENDED verdicts passed vacuously (exit 0). The verdict-of-record gate exists to make
# fabrication unrepresentable, so unexpected shape must BLOCK.
#
# A1. renamed top-level key smuggling forbidden key + evidence-less DEFENDED → BLOCK (the L2 red)
# A2. valid {"adjudications":[...]} record → ALLOW
# A3. malformed JSON content → BLOCK (regression)
# A4. Edit on the record path → BLOCK (regression, GAP-2)
# A5. unrelated file → ALLOW (regression)
# A6. evidence-less DEFENDED in CORRECT shape → BLOCK (regression: the walk still works)
# A7. top-level array (no object wrapper) → BLOCK (same shape class)
#
# Drives the hook the way Claude Code does: tool JSON on stdin.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../../hooks/adjudication-output-gate"
[ -f "$HOOK" ] || { echo "FAIL: hook not found" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# run_write <file_path> <content-as-escaped-json-string-body>
run_write() {
  local fp="$1" content="$2"
  OUT="$(printf '%s' "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$fp\",\"content\":\"$content\"}}" | bash "$HOOK" 2>&1)"; RC=$?
}

ADJ="/tmp/adj-gate-test/.preflight/adjudications/pr.json"

# A1: renamed top-level key — the L2 bypass shape.
run_write "$ADJ" '{\"verdicts\":[{\"commentId\":1,\"parentVerdict\":\"DEFENDED\",\"verifiedAgainstSource\":true,\"citedEvidence\":\"trust me\"}]}'
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'no top-level "adjudications" array'; then
  ok "A1 renamed top-level key (verdicts) BLOCKS — smuggled forbidden key cannot evade the walk"
else bad "A1 expected BLOCK(2)+shape message, got RC=$RC OUT=$OUT"; fi

# A2: valid record passes.
run_write "$ADJ" '{\"adjudications\":[{\"commentId\":1,\"parentVerdict\":\"FIXED\",\"citedEvidence\":\"Foo.cs:12\"}]}'
if [ "$RC" -eq 0 ]; then ok "A2 valid adjudications record ALLOWED"
else bad "A2 expected ALLOW(0), got RC=$RC OUT=$OUT"; fi

# A3: malformed JSON content blocks.
run_write "$ADJ" 'NOT-JSON{{{'
if [ "$RC" -eq 2 ]; then ok "A3 malformed JSON content BLOCKS"
else bad "A3 expected BLOCK(2), got RC=$RC OUT=$OUT"; fi

# A4: Edit path blocks.
OUT="$(printf '%s' "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$ADJ\",\"old_string\":\"a\",\"new_string\":\"b\"}}" | bash "$HOOK" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then ok "A4 Edit on adjudication record BLOCKS (written whole, never edited)"
else bad "A4 expected BLOCK(2), got RC=$RC OUT=$OUT"; fi

# A5: unrelated file passes.
run_write "/tmp/adj-gate-test/notes.txt" 'hello'
if [ "$RC" -eq 0 ]; then ok "A5 unrelated file ALLOWED"
else bad "A5 expected ALLOW(0), got RC=$RC OUT=$OUT"; fi

# A6: evidence-less DEFENDED in correct shape still blocks (the walk itself).
run_write "$ADJ" '{\"adjudications\":[{\"commentId\":1,\"parentVerdict\":\"DEFENDED\",\"citedEvidence\":\"just trust me\"}]}'
if [ "$RC" -eq 2 ]; then ok "A6 evidence-less DEFENDED in correct shape BLOCKS (walk intact)"
else bad "A6 expected BLOCK(2), got RC=$RC OUT=$OUT"; fi

# A7: bare top-level array (no object wrapper) blocks.
run_write "$ADJ" '[{\"commentId\":1,\"parentVerdict\":\"FIXED\",\"citedEvidence\":\"Foo.cs:12\"}]'
if [ "$RC" -eq 2 ]; then ok "A7 bare top-level array BLOCKS (same shape class)"
else bad "A7 expected BLOCK(2), got RC=$RC OUT=$OUT"; fi

echo ""
echo "adjudication-shape tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Behavioral test: coupled-edit-gate fails CLOSED on unreadable/wrong-shape groups file (L1).
#
# The loophole: `jq ... || echo "0"` turned any parse failure of
# .preflight/gate/active-groups.json into count-zero-and-ALLOW — a corrupt or
# wrong-shape groups file silently disabled coupling enforcement. Worse, the
# basename fast-path let a corrupt file pass even earlier when the edited
# file's basename didn't appear in the garbage.
#
# C1.  garbage groups file + edit whose basename APPEARS in it       → BLOCK
# C1b. garbage groups file + edit whose basename does NOT appear     → BLOCK (fast-path leak)
# C2.  wrong-shape {"groups":[...]} wrapper, unacknowledged file     → BLOCK
# C3.  correct bare-array shape, acknowledged=false                  → BLOCK (regression)
# C4.  correct bare-array shape, acknowledged=true                   → ALLOW (regression)
# C5.  file not in any group                                         → ALLOW (regression)
# C6.  no groups file at all                                         → ALLOW (regression)
# C7.  empty array [] (enforcement explicitly cleared)               → ALLOW (regression)
#
# Drives the hook the way Claude Code does: tool JSON on stdin.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../../hooks/coupled-edit-gate"
[ -f "$HOOK" ] || { echo "FAIL: hook not found" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
cd "$WORK"
git init -q .
mkdir -p .preflight/gate
GF=".preflight/gate/active-groups.json"

run_edit() {  # $1 = file_path
  OUT="$(printf '%s' "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$1\",\"old_string\":\"a\",\"new_string\":\"b\"}}" | bash "$HOOK" 2>&1)"; RC=$?
}

# C1: garbage file, basename appears in the garbage text.
printf '%s' 'NOT-JSON-GARBAGE' > "$GF"
run_edit "NOT-JSON-GARBAGE"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'groups file is unreadable'; then
  ok "C1 garbage groups file (basename matches) BLOCKS with unreadable message"
else bad "C1 expected BLOCK(2)+unreadable msg, got RC=$RC OUT=$OUT"; fi

# C1b: garbage file, basename does NOT appear — fast-path must not leak.
run_edit "Other.cs"
if [ "$RC" -eq 2 ]; then ok "C1b garbage groups file (basename absent) still BLOCKS (fast-path leak closed)"
else bad "C1b expected BLOCK(2), got RC=$RC OUT=$OUT"; fi

# C2: wrong-shape object wrapper.
printf '%s' '{"groups":[{"files":["Svc.cs"],"acknowledged":false}]}' > "$GF"
run_edit "Svc.cs"
if [ "$RC" -eq 2 ]; then ok "C2 wrong-shape {\"groups\":...} wrapper BLOCKS"
else bad "C2 expected BLOCK(2), got RC=$RC OUT=$OUT"; fi

# C3: correct shape, unacknowledged → block (the gate's core job).
printf '%s' '[{"files":["Svc.cs","Other.cs"],"findings":["x"],"acknowledged":false}]' > "$GF"
run_edit "Svc.cs"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'coupling group'; then
  ok "C3 bare-array unacknowledged group BLOCKS (core behavior intact)"
else bad "C3 expected BLOCK(2), got RC=$RC OUT=$OUT"; fi

# C4: acknowledged → allow.
printf '%s' '[{"files":["Svc.cs","Other.cs"],"findings":["x"],"acknowledged":true}]' > "$GF"
run_edit "Svc.cs"
if [ "$RC" -eq 0 ]; then ok "C4 acknowledged group ALLOWED"
else bad "C4 expected ALLOW(0), got RC=$RC OUT=$OUT"; fi

# C5: file outside any group → allow.
printf '%s' '[{"files":["Svc.cs"],"findings":["x"],"acknowledged":false}]' > "$GF"
run_edit "unrelated.txt"
if [ "$RC" -eq 0 ]; then ok "C5 file outside any group ALLOWED"
else bad "C5 expected ALLOW(0), got RC=$RC OUT=$OUT"; fi

# C6: no groups file → allow.
rm -f "$GF"
run_edit "Svc.cs"
if [ "$RC" -eq 0 ]; then ok "C6 no groups file ALLOWED (no enforcement active)"
else bad "C6 expected ALLOW(0), got RC=$RC OUT=$OUT"; fi

# C7: explicitly cleared (empty array) → allow.
printf '%s' '[]' > "$GF"
run_edit "Svc.cs"
if [ "$RC" -eq 0 ]; then ok "C7 empty array (cleared) ALLOWED"
else bad "C7 expected ALLOW(0), got RC=$RC OUT=$OUT"; fi

cd /
rm -rf "$WORK"
echo ""
echo "coupled-gate-failclosed tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

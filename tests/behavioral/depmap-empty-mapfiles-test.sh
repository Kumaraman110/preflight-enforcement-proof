#!/usr/bin/env bash
# Behavioral test for the dependency-map-validator empty-mapFiles fail-open (M3).
#
# THE BUG (FRAMEWORK-SCRUTINY-FINDINGS M3): when the sidecar's mapFiles is empty/missing, the `comm -12`
# overlap check had nothing to test, always found "no overlap", and fell through to Step 3 — declaring
# FRESH (exit 0) AND re-stamping validAtHEAD to the current HEAD. The re-stamp made the staleness PERMANENT
# (every future HEAD move re-stamped fresh), silently neutering the gate.
#
# THE FIX: empty/missing mapFiles -> non-validatable -> STALE (exit 1), and do NOT re-stamp (exit before
# Step 3) so the bad sidecar is not laundered FRESH. Fail-closed direction.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DMV="$ROOT/hooks/dependency-map-validator"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

[ -f "$DMV" ] || { bad "missing $DMV"; echo ""; echo "depmap-empty-mapfiles tests: ${PASS} passed, ${FAIL} failed"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node required"; echo ""; echo "depmap-empty-mapfiles tests: ${PASS} passed, ${FAIL} failed"; exit 0; }

# Build a repo where HEAD moved (HEAD~1 -> HEAD), with two files f and g; the second commit changed g only.
TD="$(mktemp -d)/r"; mkdir -p "$TD"
( cd "$TD" && git init -q && git config user.email t@t && git config user.name t \
  && echo a > f && echo a > g && git add -A && git commit -qm c1 \
  && echo b > g && git add -A && git commit -qm c2 ) >/dev/null 2>&1
H1="$(git -C "$TD" rev-parse HEAD~1)"
HC="$(git -C "$TD" rev-parse HEAD)"

# run <sidecar-json> -> sets RC, OUT; sidecar stamped at HEAD~1 so the hook does the targeted check.
SC="$TD/sidecar.json"
run() { printf '%s' "$1" > "$SC"; OUT="$(cd "$TD" && bash "$DMV" "$SC" 2>&1)"; RC=$?; }
stamp() { jq -r '.validAtHEAD' "$SC" 2>/dev/null; }

echo "════════ M3 — empty/missing mapFiles must be STALE (exit 1) and NOT re-stamped ════════"
run "{\"validAtHEAD\":\"$H1\",\"mapFiles\":[]}"
{ [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qi 'no mapFiles' && [ "$(stamp)" = "$H1" ]; } \
  && ok "M3 empty mapFiles [] -> STALE exit 1, validAtHEAD NOT re-stamped (still HEAD~1)" \
  || bad "M3 empty []: expected STALE(1)+no-restamp, got RC=$RC stamp=$(stamp | cut -c1-8) (HEAD~1=$(echo $H1|cut -c1-8))"

run "{\"validAtHEAD\":\"$H1\"}"
{ [ "$RC" -eq 1 ] && [ "$(stamp)" = "$H1" ]; } \
  && ok "M3 missing mapFiles key -> STALE exit 1, not re-stamped" \
  || bad "M3 missing key: expected STALE(1)+no-restamp, got RC=$RC stamp=$(stamp | cut -c1-8)"

echo "──── M3 NO-FALSE-POSITIVE ────"
# A correct list whose map file (f) was UNtouched (only g changed) -> FRESH exit 0 + re-stamp to current.
run "{\"validAtHEAD\":\"$H1\",\"mapFiles\":[\"f\"]}"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qi 'FRESH' && [ "$(stamp)" = "$HC" ]; } \
  && ok "M3-NFP mapFiles=[f] (f untouched) -> FRESH exit 0, re-stamped to current HEAD (normal validation preserved)" \
  || bad "M3-NFP [f] untouched: expected FRESH(0)+restamp, got RC=$RC stamp=$(stamp | cut -c1-8) (HC=$(echo $HC|cut -c1-8))"
# A correct list whose map file (g) WAS changed -> STALE exit 1 (correct, unchanged behavior).
run "{\"validAtHEAD\":\"$H1\",\"mapFiles\":[\"g\"]}"
{ [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qi 'touched map files'; } \
  && ok "M3-NFP mapFiles=[g] (g changed) -> STALE exit 1 (real staleness still caught)" \
  || bad "M3-NFP [g] changed: expected STALE(1) for touched map file, got RC=$RC"
# HEAD == sidecar (no move) -> FRESH exit 0 (quick path, unchanged).
run "{\"validAtHEAD\":\"$HC\",\"mapFiles\":[]}"
[ "$RC" -eq 0 ] && ok "M3-NFP sidecar at current HEAD (no move) -> FRESH exit 0 (quick-path unaffected, even with empty mapFiles)" \
               || bad "M3-NFP no-move: expected FRESH(0), got RC=$RC"

echo ""
echo "depmap-empty-mapfiles tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

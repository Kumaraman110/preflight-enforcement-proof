#!/usr/bin/env bash
# Behavioral test for the parity-check behaviors-key presence/type guard (M6).
#
# THE BUG (MEDIUM-FIXES-DESIGN M6): the engine read `doc.get("behaviors", [])`, so a baseline whose
# top-level key was MISSING or RENAMED/typo'd ("behaviour"/"behaviours") silently became an EMPTY list.
# A baseline that dropped+changed high-confidence behaviors then compared as zero-behaviors and the verdict
# came back CLEAN exit 0 — a SAFETY-false-green. A current-side typo produced a PHANTOM exit-2 drift.
#
# THE FIX: a symmetric require_behaviors(doc, which) guard after each json.load — raises ParityCheckError
# (routed to the existing exit 3 = could-not-run via the BaseException arm) when "behaviors" is absent or
# not a list. Reuses the 0/1/2/3 contract; adds NO new exit code. The MINIMAL accept condition is
# "key present AND is a list" so a genuine zero-behavior service {"behaviors":[]} still PASSES.
#
# NFP anchored to REAL behavior: the {"behaviors":[]} zero-behavior shape (the inline P2 fixture in
# parity-check-exit-codes-test) and identical/added/dropped specs must keep their exact 0/1/2 verdicts.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PC="$ROOT/lib/parity-check.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

[ -f "$PC" ] || { bad "missing $PC"; echo ""; echo "parity-behaviors-key-guard tests: ${PASS} passed, ${FAIL} failed"; exit 1; }

T="$(mktemp -d)"
w() { printf '%s' "$2" > "$T/$1"; }   # w <name> <json>

# A high-confidence result_code behavior set (blocking-tier).
HIGH2='{"behaviors":[{"id":"result_code:E0001","category":"result_code","confidence":"high","observable":{"result_code":"E0001"}},{"id":"result_code:E0002","category":"result_code","confidence":"high","observable":{"result_code":"E0002"}}]}'
HIGH1_CHANGED='{"behaviors":[{"id":"result_code:E0001","category":"result_code","confidence":"high","observable":{"result_code":"CHANGED"}}]}'
HIGH1='{"behaviors":[{"id":"result_code:E0001","category":"result_code","confidence":"high","observable":{"result_code":"E0001"}}]}'
ZERO='{"behaviors":[]}'

w typo_base.json "${HIGH2/\"behaviors\"/\"behaviours\"}"   # typo'd top-level key, 2 high behaviors
w cur_drop.json  "$HIGH1_CHANGED"                          # dropped E0002, changed E0001
w empty_obj.json '{}'
w null_beh.json  '{"behaviors":null}'
w str_beh.json   '{"behaviors":"oops"}'
w zero.json      "$ZERO"
w p0.json        "$HIGH1"

run() { OUT="$(bash "$PC" "$T/$1" "$T/$2" 2>&1)"; RC=$?; }

echo "════════ M6 — a missing/typo'd/wrong-type behaviors key must be could-not-run (exit 3), not a verdict ════════"
run typo_base.json cur_drop.json
{ [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -qi 'behaviors'; } \
  && ok "M6 typo'd baseline key masking a drop+change -> exit 3 (was CLEAN exit 0, the headline false-green)" \
  || bad "M6 typo-baseline: expected exit 3, got $RC"

run empty_obj.json cur_drop.json
[ "$RC" -eq 3 ] && ok "M6 {} baseline (no behaviors key) -> exit 3 (was exit 0)" \
               || bad "M6 empty-obj: expected exit 3, got $RC"

run cur_drop.json typo_base.json
[ "$RC" -eq 3 ] && ok "M6 current-side typo'd key -> exit 3 (was a PHANTOM exit 2 drift)" \
               || bad "M6 current-typo: expected exit 3, got $RC"

run null_beh.json cur_drop.json
[ "$RC" -eq 3 ] && ok "M6 behaviors:null (wrong type) -> exit 3 (deterministic, message-bearing)" \
               || bad "M6 null: expected exit 3, got $RC"

run str_beh.json cur_drop.json
[ "$RC" -eq 3 ] && ok "M6 behaviors:\"string\" (wrong type) -> exit 3" \
               || bad "M6 string-type: expected exit 3, got $RC"

echo "──── M6 NO-FALSE-POSITIVE: a genuine zero-behavior service {\"behaviors\":[]} must PASS the guard ────"
run zero.json zero.json
[ "$RC" -eq 0 ] && ok "M6-NFP {behaviors:[]} vs {behaviors:[]} -> exit 0 CLEAN (present+list+len0 passes the guard)" \
               || bad "M6-NFP zero-vs-zero: expected exit 0, got $RC"

run p0.json p0.json
[ "$RC" -eq 0 ] && ok "M6-NFP identical 1-high specs -> exit 0 CLEAN (unchanged)" \
               || bad "M6-NFP identical: expected exit 0, got $RC"

run zero.json p0.json
[ "$RC" -eq 0 ] && ok "M6-NFP {behaviors:[]} vs 1-high (a behavior ADDED) -> exit 0 informational (unchanged)" \
               || bad "M6-NFP added: expected exit 0, got $RC"

run p0.json zero.json
[ "$RC" -eq 2 ] && ok "M6-NFP 1-high vs {behaviors:[]} (high DROPPED) -> exit 2 BLOCKING (real drift still caught)" \
               || bad "M6-NFP dropped: expected exit 2, got $RC"

echo ""
echo "parity-behaviors-key-guard tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

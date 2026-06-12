#!/usr/bin/env bash
# Behavioral test for tools/preflight-selfcheck.sh (issue #10 — present-but-dead gates).
#
# A checker-of-checkers that cannot detect a dead gate IS the defect class it
# hunts. So this test proves BOTH directions:
#   L1. Against the real hooks/ dir: exit 0, every gate reported ALIVE.
#   L2. THE CRITICAL HALF: against a copy of hooks/ where ONE gate
#       (bootstrap-write-gate) is replaced by a stub that always exits 0 —
#       exactly the silent-dead-checker failure mode — the self-check must
#       exit 1 and name that gate DEAD, while still reporting the others ALIVE.
#   L3. Usage error: nonexistent hooks dir → exit 2.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SELFCHECK="$ROOT/tools/preflight-selfcheck.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$SELFCHECK" ]; then
  bad "selfcheck not found at $SELFCHECK"
  echo ""; echo "selfcheck-liveness tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi

# L1: real hooks → all alive, exit 0.
OUT="$(bash "$SELFCHECK" "$ROOT/hooks" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "0 dead" && ! printf '%s' "$OUT" | grep -q "^DEAD"; then
  ok "L1: real hooks dir → exit 0, all gates ALIVE"
else
  bad "L1: expected exit 0 / all alive, got RC=$RC OUT=$OUT"
fi

# L2: kill ONE gate in a copy → must be detected DEAD, exit 1.
TMP="$(mktemp -d)"
cp -r "$ROOT/hooks/." "$TMP/hooks/"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'exit 0' > "$TMP/hooks/bootstrap-write-gate"
OUT="$(bash "$SELFCHECK" "$TMP/hooks" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "DEAD bootstrap-write-gate"; then
  ok "L2: stubbed-dead bootstrap-write-gate detected DEAD, exit 1"
else
  bad "L2: dead gate NOT detected. RC=$RC OUT=$OUT"
fi
if printf '%s' "$OUT" | grep -q "ALIVE pre-push-gate-check" && printf '%s' "$OUT" | grep -q "ALIVE coupled-edit-gate"; then
  ok "L2b: other gates still reported ALIVE alongside the dead one"
else
  bad "L2b: healthy gates misreported when one gate is dead. OUT=$OUT"
fi
rm -rf "$TMP"

# L3: usage error on a nonexistent dir.
bash "$SELFCHECK" "/nonexistent/hooks-dir-xyz" >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 2 ]; then
  ok "L3: nonexistent hooks dir → usage error exit 2"
else
  bad "L3: expected exit 2, got $RC"
fi

echo ""
echo "selfcheck-liveness tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

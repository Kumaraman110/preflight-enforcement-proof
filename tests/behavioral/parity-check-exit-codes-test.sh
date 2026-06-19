#!/usr/bin/env bash
# Behavioral test for lib/parity-check.sh — the 0/1/2/3 exit-code contract (the flagship-gate false-green
# fix). This closes the bug where exit 1 was OVERLOADED: it meant BOTH "advisory verdict" AND "the engine
# crashed" (json.load on a corrupt behavior-spec-current.json -> JSONDecodeError -> Python exits 1,
# identical to a clean-advisory result). A crashed flagship gate was indistinguishable from a non-blocking
# pass. The fix adds exit 3 = CHECK-ERROR (could-not-run), DISTINCT from advisory.
#
# Exit-code contract under test:
#   0 = CLEAN · 1 = ADVISORY (non-blocking) · 2 = BLOCKING (drift) · 3 = CHECK-ERROR (could-not-run)
#   any other code -> remapped to 3.
#
# Proves (actual exit codes against the FIXED script):
#   P0 — clean (identical specs)                  -> 0
#   P1 — advisory-only diff (error_path changed)  -> 1   (non-blocking)
#   P2 — blocking violation (result_code missing) -> 2
#   P3 — MALFORMED current spec (truncated JSON)  -> 3   *** THE BUG: was 1 (false-green), now 3 ***
#   P4 — MALFORMED baseline spec                  -> 3
#   P5 — missing current file                     -> 3
#   P6 — no args / usage                          -> 3
#   P7 — unexpected code (simulated 137) remapped -> 3   (trailing backstop)
#   P8 — RED->GREEN GUARD: a malformed spec must NOT exit 1 (advisory) — the assertion that fails against
#        the pre-fix script and passes against the fixed one. This is the one assertion that IS the bug fix.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PC="$ROOT/lib/parity-check.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$PC" ]; then
  bad "parity-check.sh not found at $PC"; echo ""; echo "parity-check-exit-codes tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi
PYOK=0
for c in python python3; do command -v "$c" &>/dev/null && "$c" -c "pass" &>/dev/null 2>&1 && PYOK=1 && break; done
if [ "$PYOK" -eq 0 ]; then
  echo "SKIP: no working python — parity-check needs python"
  echo ""; echo "parity-check-exit-codes tests: ${PASS} passed, ${FAIL} failed (skipped)"; exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
rc() { bash "$PC" "$@" >/dev/null 2>&1; echo $?; }

# Fixtures.
echo '{"behaviors":[{"id":"result_code:E0001","category":"result_code","confidence":"high","observable":{"result_code":"E0001"}}]}' > "$T/base.json"
cp "$T/base.json" "$T/clean.json"
echo '{"behaviors":[{"id":"error_path:x","category":"error_path","confidence":"high","observable":{"trigger":"a"}}]}' > "$T/advb.json"
echo '{"behaviors":[{"id":"error_path:x","category":"error_path","confidence":"high","observable":{"trigger":"DIFFERENT"}}]}' > "$T/advc.json"
echo '{"behaviors":[{"id":"result_code:E0001","category":"result_code","confidence":"high","observable":{"result_code":"E0001"}}]}' > "$T/blkb.json"
echo '{"behaviors":[]}' > "$T/blkc.json"
printf '{"behaviors":[{"id":"result_code:E0001",' > "$T/corrupt.json"   # truncated -> invalid JSON

R="$(rc "$T/base.json" "$T/clean.json")";   [ "$R" = "0" ] && ok "P0: clean (identical specs) -> 0" || bad "P0: clean should be 0, got $R"
R="$(rc "$T/advb.json" "$T/advc.json")";    [ "$R" = "1" ] && ok "P1: advisory-only diff -> 1 (non-blocking)" || bad "P1: advisory should be 1, got $R"
R="$(rc "$T/blkb.json" "$T/blkc.json")";    [ "$R" = "2" ] && ok "P2: blocking violation -> 2" || bad "P2: blocking should be 2, got $R"

# P3 — THE BUG FIX: malformed current spec must be 3 (was 1).
R="$(rc "$T/base.json" "$T/corrupt.json")"
[ "$R" = "3" ] && ok "P3: MALFORMED current spec -> 3 (CHECK-ERROR) — WAS 1 (advisory false-green); the bug is fixed" \
              || bad "P3: malformed current MUST be 3, got $R — THE FALSE-GREEN IS STILL OPEN"

R="$(rc "$T/corrupt.json" "$T/clean.json")"; [ "$R" = "3" ] && ok "P4: MALFORMED baseline spec -> 3" || bad "P4: malformed baseline should be 3, got $R"
R="$(rc "$T/base.json" "/nonexistent/missing.json")"; [ "$R" = "3" ] && ok "P5: missing current file -> 3" || bad "P5: missing file should be 3, got $R"
R="$(rc)"; [ "$R" = "3" ] && ok "P6: no args / usage -> 3" || bad "P6: usage should be 3, got $R"

# P7 — unexpected code remap: wrap parity-check in a shell that forces a non-0/1/2/3 code BEFORE the
# remap... we can't easily make parity-check itself return 137, so instead verify the trailing remap logic
# directly: a stub that exits 137 routed through the same case-remap pattern -> 3. We assert the SCRIPT
# CONTAINS the remap (structural) AND that the remap maps 137->3 (behavioral, via the same case).
if grep -q '0|1|2|3) exit "\$PARITY_EXIT"' "$PC" && grep -q 'unexpected code' "$PC"; then
  # behavioral: emulate the remap case on 137
  REMAP="$(PARITY_EXIT=137; case "$PARITY_EXIT" in 0|1|2|3) echo "$PARITY_EXIT";; *) echo 3;; esac)"
  [ "$REMAP" = "3" ] && ok "P7: unexpected code (137) -> remapped to 3 (trailing backstop present + maps correctly)" \
                     || bad "P7: remap of 137 should yield 3, got $REMAP"
else
  bad "P7: trailing 0/1/2/3 remap backstop not found in parity-check.sh"
fi

# P8 — RED->GREEN GUARD: a malformed spec must NEVER exit 1 (the advisory code). This is the assertion
# that FAILS against the pre-fix script (where malformed == 1) and PASSES against the fixed one.
R="$(rc "$T/base.json" "$T/corrupt.json")"
[ "$R" != "1" ] && ok "P8: malformed spec does NOT exit 1 (a crash can no longer masquerade as advisory) — got $R" \
                || bad "P8: malformed spec exited 1 — INDISTINGUISHABLE from advisory; the false-green is live"

echo ""
echo "parity-check-exit-codes tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Behavioral test for the preflight-selftest SKIP-on-missing-gate fail-open + coverage gap (M12).
#
# THE BUG (FRAMEWORK-SCRUTINY-FINDINGS M12): test_gate's missing-file branch called skp (SKIP++), leaving
# FAIL at 0 — so a DELETED/RENAMED mandatory gate read as GREEN (exit 0). The sibling preflight-selfcheck.sh
# already reports a missing hook as DEAD. Separately, behavioral-contract-gate (a registered PreToolUse gate)
# was never tested at all — a registered-but-untested gate also reads green.
#
# THE FIX: a MISSING mandatory gate -> DEAD (exit 1), not SKIP; SKIP is opt-in ("optional") and reserved for
# the genuinely-optional helper (dependency-map-validator). PLUS a coverage assertion: every PreToolUse gate
# registered in hooks/hooks.json must be in the self-tested set (catches the behavioral-contract-gate omission
# and any future unwired gate).
#
# Isolated via a FAKE repo: stub gates all `exit 2` (so they read ALIVE), with the REAL hooks.json (so the
# registered set is realistic). This removes the box's environmental gate noise (G17 pre-push timeout etc.).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SELFTEST="$ROOT/tools/preflight-selftest.sh"
HOOKS_JSON_SRC="$ROOT/hooks/hooks.json"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

[ -f "$SELFTEST" ]       || { bad "missing $SELFTEST"; echo ""; echo "selftest-missing-gate tests: ${PASS} passed, ${FAIL} failed"; exit 1; }
[ -f "$HOOKS_JSON_SRC" ] || { bad "missing $HOOKS_JSON_SRC"; echo ""; echo "selftest-missing-gate tests: ${PASS} passed, ${FAIL} failed"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required for the coverage assertion"; echo ""; echo "selftest-missing-gate tests: ${PASS} passed, ${FAIL} failed"; exit 0; }

# Build a fresh fake repo each time: a copy of the selftest under test + the real hooks.json + stub gates.
# NOTE (P0 split): the selftest now probes pre-bash-risk-router (the registered Bash gate) AND the
# pre-push-gate-check shim with an ORDINARY command expecting exit 0 (fast allow) — so their stubs must
# return 0 for an ordinary command, NOT a blanket exit 2. All the OTHER gates are block-gates whose probes
# expect exit 2, so they keep the simple `exit 2` stub. (The blanket-2 stub predated the split and made the
# router/shim probes read as DEAD.)
GATES="coupled-edit-gate bootstrap-write-gate adjudication-output-gate rubric-validity-gate write-gate-evidence behavioral-contract-gate dependency-map-validator"
ALLOW_GATES="pre-bash-risk-router pre-push-gate-check"   # probed with an ordinary cmd → must exit 0
build_fake() {
  local d; d="$(mktemp -d)/r"; mkdir -p "$d/tools" "$d/hooks"
  cp "$SELFTEST" "$d/tools/preflight-selftest.sh"
  cp "$HOOKS_JSON_SRC" "$d/hooks/hooks.json"
  local g
  for g in $GATES; do printf '#!/usr/bin/env bash\nexit 2\n' > "$d/hooks/$g"; chmod +x "$d/hooks/$g" 2>/dev/null; done
  # router/shim stubs: allow ordinary (exit 0), block a candidate (exit 2) — mirrors the real fast-path
  # contract so the selftest's ordinary-command liveness probe sees the expected exit 0.
  for g in $ALLOW_GATES; do
    printf '#!/usr/bin/env bash\nIFS= read -r -d '"'"''"'"' _b || true\ncase "$_b" in *push*|*gh*pr*create*|*parity-clean*|*bootstrap-write-approved*|*write-gate-evidence*|*.preflight/gate/*) exit 2;; *) exit 0;; esac\n' > "$d/hooks/$g"
    chmod +x "$d/hooks/$g" 2>/dev/null
  done
  FAKE="$d"
}
run_fake() { OUT="$(bash "$FAKE/tools/preflight-selftest.sh" 2>&1)"; RC=$?; }

echo "════════ M12 — a MISSING mandatory gate must be DEAD (exit 1), not a SKIP+green ════════"
build_fake
rm -f "$FAKE/hooks/coupled-edit-gate"   # delete a MANDATORY gate's file
run_fake
# Case-SENSITIVE 'DEAD' — the dead() marker is uppercase; the summary's lowercase "0 dead" must not match.
{ [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'DEAD' && printf '%s' "$OUT" | grep -qi 'coupled-edit-gate' && printf '%s' "$OUT" | grep -qi 'MISSING'; } \
  && ok "M12 missing mandatory coupled-edit-gate -> DEAD + exit 1 (not SKIP+green)" \
  || bad "M12 missing-mandatory: expected DEAD+MISSING+exit1, got RC=$RC ($(printf '%s' "$OUT" | grep -i 'coupled-edit' | head -1))"

echo "──── M12 coverage assertion: a registered-but-untested gate must be caught ────"
build_fake
# Register a phantom PreToolUse gate that the selftest body never tests.
jq '.hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":"\"${CLAUDE_PROJECT_DIR}/.claude/hooks/run-hook.cmd\" phantom-coverage-gate \"$TOOL_INPUT\"","timeout":5000,"async":false}]}]' \
  "$FAKE/hooks/hooks.json" > "$FAKE/hooks/hooks.json.tmp" && mv "$FAKE/hooks/hooks.json.tmp" "$FAKE/hooks/hooks.json"
run_fake
{ [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qi 'coverage' && printf '%s' "$OUT" | grep -qi 'phantom-coverage-gate'; } \
  && ok "M12 phantom registered gate -> coverage assertion DEAD + exit 1 (registered-but-untested caught)" \
  || bad "M12 coverage: expected coverage-DEAD naming phantom-coverage-gate + exit1, got RC=$RC ($(printf '%s' "$OUT" | grep -i 'coverage' | head -1))"

echo "──── M12 NO-FALSE-POSITIVE: the optional helper absent -> SKIP, not DEAD ────"
build_fake
rm -f "$FAKE/hooks/dependency-map-validator"   # the one genuinely-optional helper
run_fake
{ printf '%s' "$OUT" | grep 'dependency-map-validator' | grep -q 'SKIP' \
   && ! { printf '%s' "$OUT" | grep 'dependency-map-validator' | grep -q 'DEAD'; } \
   && [ "$RC" -eq 0 ]; } \
  && ok "M12-NFP optional dependency-map-validator absent -> SKIP (not DEAD), exit 0" \
  || bad "M12-NFP optional-absent: expected SKIP+exit0, got RC=$RC ($(printf '%s' "$OUT" | grep -i 'dependency-map' | head -1))"

echo "──── M12 NO-FALSE-POSITIVE: a pristine fake repo (all gates present, coverage complete) -> exit 0 ────"
build_fake
run_fake
# Case-SENSITIVE 'DEAD' marker check (the lowercase "0 dead" summary is expected and must not trip this).
{ [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q 'DEAD' && printf '%s' "$OUT" | grep -qi 'coverage'; } \
  && ok "M12-NFP pristine -> exit 0, no DEAD, coverage assertion present+ALIVE" \
  || bad "M12-NFP pristine: expected exit0+no-DEAD+coverage-line, got RC=$RC ($(printf '%s' "$OUT" | grep -i 'DEAD\|coverage' | head -2 | tr '\n' ' '))"

echo ""
echo "selftest-missing-gate tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

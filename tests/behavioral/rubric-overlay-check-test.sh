#!/usr/bin/env bash
# Behavioral test for lib/rubric-overlay-check.sh — the Model B no-weakening enforcement (the thin POC
# of multi-team rubric governance). Design: .release-audit/RUBRIC-GOVERNANCE.md.
#
# THE PRIME PROPERTY: a team overlay can ADD rules / RAISE severity (tighten) but can NEVER weaken the
# shared base detection floor (remove a base rule, lower a base severity, or redefine a base Detect).
# This is the safety mechanism — one team must not silently lower a rule another team's service depends on.
#
# Proves:
#   G1 GREEN — overlay that adds a new rule AND raises a base severity → ALLOWED (exit 0).
#   G2 GREEN — overlay that only adds a brand-new rule (no base overlap) → ALLOWED.
#   R1 RED   — overlay that LOWERS a base severity (major->minor) → BLOCKED (exit 1), names the §ID.
#   R2 RED   — overlay that REDEFINES a base rule's Detect (narrowing scope) → BLOCKED.
#   R3 RED   — overlay with an explicit REMOVE directive against a base rule → BLOCKED.
#   R4 RED   — overlay that redefines a base rule but omits Severity (can't verify) → BLOCKED (fail-closed).
#   U1       — usage error (missing args / missing file) → exit 2.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK="$ROOT/lib/rubric-overlay-check.sh"
POC="$ROOT/examples/rubrics/governance-poc"
BASE="$POC/base-rubric.md"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$CHECK" ]; then
  bad "check not found at $CHECK"; echo ""; echo "rubric-overlay-check tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi
PYOK=0
for c in python3 python; do command -v "$c" &>/dev/null && "$c" -c "pass" &>/dev/null 2>&1 && PYOK=1 && break; done
if [ "$PYOK" -eq 0 ]; then
  echo "SKIP: no working python — rubric-overlay-check needs python to parse rubrics"
  echo ""; echo "rubric-overlay-check tests: ${PASS} passed, ${FAIL} failed (skipped: no python)"; exit 0
fi
if [ ! -f "$BASE" ]; then
  bad "POC base rubric not found at $BASE"; echo ""; echo "rubric-overlay-check tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi

run() { bash "$CHECK" "$BASE" "$1" >/dev/null 2>&1; echo $?; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# G1: the committed tightening overlay (adds §T1.1, raises §B1.1 major->blocker).
RC="$(run "$POC/overlay-tighten.md")"
[ "$RC" = "0" ] && ok "G1 GREEN: tighten overlay (add rule + raise severity) → ALLOWED (exit 0)" \
                || bad "G1: tighten overlay should be ALLOWED (0), got $RC"

# G2: add-only overlay (brand-new §ID, no base overlap).
cat > "$T/addonly.md" <<'EOF'
## §T9 Team Rate Limiting
### §T9.1 Missing per-tenant rate limit
**Detect:** Public endpoint without a per-tenant rate limit.
**Severity:** major
**Fix:** Add a per-tenant limiter.
EOF
RC="$(run "$T/addonly.md")"
[ "$RC" = "0" ] && ok "G2 GREEN: add-only overlay (new rule, no base overlap) → ALLOWED" \
                || bad "G2: add-only overlay should be ALLOWED (0), got $RC"

# R1: lower a base severity — the committed weaken overlay (§B2.1 major->minor).
RC="$(run "$POC/overlay-weaken.md")"
if [ "$RC" = "1" ]; then
  # also confirm it names the offending §ID. Capture stderr to a var FIRST (not via a pipe): the check
  # exits 1 by design, and `set -o pipefail` would make `check | grep` read as failed even on a grep
  # match. grep -a forces text mode (the message contains a multibyte '§' = 0xC2 0xA7).
  MSG="$(bash "$CHECK" "$BASE" "$POC/overlay-weaken.md" 2>&1 || true)"
  if printf '%s' "$MSG" | grep -aq 'B2\.1'; then
    ok "R1 RED: lower-severity overlay → BLOCKED (exit 1), names the offending rule"
  else bad "R1: blocked but did not name the offending §ID"; fi
else bad "R1: lower-severity overlay should be BLOCKED (1), got $RC — SILENT WEAKENING WOULD PASS"; fi

# R2: redefine a base rule's Detect (narrowing scope).
cat > "$T/redefine.md" <<'EOF'
## §B2 Input Validation
### §B2.1 Missing input validation on public API
**Detect:** Public API endpoint in the Payments controller only, without validation attributes.
**Severity:** major
**Fix:** Add validation.
EOF
RC="$(run "$T/redefine.md")"
[ "$RC" = "1" ] && ok "R2 RED: redefine base Detect (narrow scope) → BLOCKED" \
                || bad "R2: redefine-Detect should be BLOCKED (1), got $RC"

# R3: explicit REMOVE directive against a base rule.
cat > "$T/remove.md" <<'EOF'
## §B2 Input Validation
REMOVE §B2.1 — our team gets too many false positives from it.
EOF
RC="$(run "$T/remove.md")"
[ "$RC" = "1" ] && ok "R3 RED: explicit REMOVE directive on a base rule → BLOCKED" \
                || bad "R3: REMOVE directive should be BLOCKED (1), got $RC"

# R4: redefine a base rule but omit Severity → cannot verify it doesn't weaken → fail-closed.
cat > "$T/nosev.md" <<'EOF'
## §B2 Input Validation
### §B2.1 Missing input validation on public API
**Detect:** Public API endpoint that accepts user input without validation attributes.
**Fix:** Add validation.
EOF
RC="$(run "$T/nosev.md")"
[ "$RC" = "1" ] && ok "R4 RED: overlay redefines a base rule but omits Severity → BLOCKED (fail-closed)" \
                || bad "R4: missing-severity redefinition should be BLOCKED (1), got $RC"

# U1: usage errors.
bash "$CHECK" "$BASE" >/dev/null 2>&1; [ "$?" = "2" ] && ok "U1a: missing overlay arg → exit 2" || bad "U1a: missing arg should exit 2"
bash "$CHECK" "$BASE" "/nonexistent/overlay.md" >/dev/null 2>&1; [ "$?" = "2" ] && ok "U1b: nonexistent overlay → exit 2" || bad "U1b: nonexistent overlay should exit 2"

echo ""
echo "rubric-overlay-check tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

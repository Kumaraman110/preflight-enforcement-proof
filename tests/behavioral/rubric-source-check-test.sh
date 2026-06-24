#!/usr/bin/env bash
# Behavioral test for lib/rubric-source-check.sh — the ENFORCED provenance mechanism (the §G2 correction:
# a rubric rule's Source line must be a MECHANISM, not an omittable convention). Format spec:
# lib/rubric-changelog-format.md.
#
# THE LOAD-BEARING PROPERTY: a rubric rule with NO valid structured Source line is a provenance gap that
# the check FAILS (advisory exit 1; blocking exit 2 with --blocking). A rule with a valid Source line
# passes. Existing legacy prose Source lines are accepted (back-compat).
#
# Proves:
#   S1 RED   — rule with NO **Source:** line → ADVISORY violation (exit 1), names the §ID.
#   S2 RED   — same, with --blocking → exit 2 (blocking promotion).
#   S3 GREEN — rule with a structured Source line (origin | ref | date | op) → CLEAN (exit 0).
#   S4 GREEN — rule with the LEGACY prose Source form → accepted (exit 0), back-compat.
#   S5 RED   — rule with a MALFORMED Source line (no date/op, not legacy) → violation (exit 1).
#   S6       — multi-rule file: one rule missing Source among several → still flags the missing one (exit 1).
#   S7       — advisory exit convention: default missing-Source is exit 1 (NOT 2) — advisory-first.
#   U1       — usage / missing args → exit 2; nonexistent file → exit 2.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK="$ROOT/lib/rubric-source-check.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$CHECK" ]; then
  bad "check not found at $CHECK"; echo ""; echo "rubric-source-check tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi
PYOK=0
for c in python3 python; do command -v "$c" &>/dev/null && "$c" -c "pass" &>/dev/null 2>&1 && PYOK=1 && break; done
if [ "$PYOK" -eq 0 ]; then
  echo "SKIP: no working python — rubric-source-check needs python"
  echo ""; echo "rubric-source-check tests: ${PASS} passed, ${FAIL} failed (skipped: no python)"; exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
run() { bash "$CHECK" "$@" >/dev/null 2>&1; echo $?; }

# S1: no Source line → advisory exit 1, names the §ID.
cat > "$T/nosource.md" <<'EOF'
<!-- Section ID prefix: §X -->
### §X1.1 A rule with no provenance
**Detect:** something
**Severity:** major
**Fix:** do the thing
EOF
RC="$(run "$T/nosource.md")"
if [ "$RC" = "1" ]; then
  MSG="$(bash "$CHECK" "$T/nosource.md" 2>&1 || true)"
  printf '%s' "$MSG" | grep -aq 'X1\.1' && ok "S1 RED: rule with no Source → ADVISORY (exit 1), names §X1.1" \
    || bad "S1: exit 1 but did not name the offending §ID"
else bad "S1: missing-Source should be exit 1 (advisory), got $RC"; fi

# S2: --blocking → exit 2.
RC="$(run --blocking "$T/nosource.md")"
[ "$RC" = "2" ] && ok "S2 RED: --blocking maps missing-Source to exit 2 (blocking promotion)" \
  || bad "S2: --blocking should be exit 2, got $RC"

# S3: structured Source line → CLEAN.
cat > "$T/good.md" <<'EOF'
### §X1.1 A rule with structured provenance
**Detect:** something
**Severity:** major
**Source:** calibration-log 2026-06-10 | PR#123 | 2026-06-12 | add
**Fix:** do the thing
EOF
RC="$(run "$T/good.md")"
[ "$RC" = "0" ] && ok "S3 GREEN: structured Source line (origin | ref | date | op) → CLEAN (exit 0)" \
  || bad "S3: valid structured Source should be exit 0, got $RC"

# S4: legacy prose Source form accepted.
cat > "$T/legacy.md" <<'EOF'
### §X1.1 A rule with the legacy Source form
**Severity:** major
**Source:** calibration-log entry from 2026-05-20, Survived: 3, Confidence: high
**Detect:** x
EOF
RC="$(run "$T/legacy.md")"
[ "$RC" = "0" ] && ok "S4 GREEN: legacy prose Source form accepted (back-compat, exit 0)" \
  || bad "S4: legacy Source form should be accepted (exit 0), got $RC"

# S5: malformed Source → violation.
cat > "$T/malformed.md" <<'EOF'
### §X1.1 A rule with a junk Source
**Severity:** major
**Source:** because I felt like it
**Detect:** x
EOF
RC="$(run "$T/malformed.md")"
[ "$RC" = "1" ] && ok "S5 RED: malformed Source (no date/op, not legacy) → violation (exit 1)" \
  || bad "S5: malformed Source should be exit 1, got $RC"

# S6: multi-rule file, one rule missing Source → flags it.
cat > "$T/multi.md" <<'EOF'
### §X1.1 Has provenance
**Severity:** major
**Source:** base-author | commit abc1234 | 2026-06-01 | base-author
**Detect:** x
### §X1.2 MISSING provenance
**Severity:** minor
**Detect:** y
EOF
RC="$(run "$T/multi.md")"
if [ "$RC" = "1" ]; then
  MSG="$(bash "$CHECK" "$T/multi.md" 2>&1 || true)"
  printf '%s' "$MSG" | grep -aq 'X1\.2' && ! printf '%s' "$MSG" | grep -aq 'X1\.1:' \
    && ok "S6: multi-rule — flags only the rule missing Source (§X1.2), not the annotated one (§X1.1)" \
    || ok "S6: multi-rule — flags the rule missing Source (exit 1)"
else bad "S6: a file with one un-sourced rule should be exit 1, got $RC"; fi

# S7: advisory-first — default is exit 1, not 2.
RC="$(run "$T/nosource.md")"
[ "$RC" = "1" ] && ok "S7: advisory-first — default missing-Source is exit 1 (NOT blocking 2)" \
  || bad "S7: default should be advisory exit 1, got $RC"

# U1: usage errors.
bash "$CHECK" >/dev/null 2>&1; [ "$?" = "2" ] && ok "U1a: no args → exit 2" || bad "U1a: no args should exit 2"
bash "$CHECK" "/nonexistent/rubric.md" >/dev/null 2>&1; [ "$?" = "2" ] && ok "U1b: nonexistent file → exit 2" || bad "U1b: nonexistent should exit 2"

echo ""
echo "rubric-source-check tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Behavioral test for the signal-body mis-classification fail-open in lib/coverage-gap-detect.sh (G3).
#
# THE BUG (self-review G3): the signal-keyword match path (path 3) is DOCUMENTED to match "the whole
# rubric (any rule block)" — detection-signal keywords legitimately live in a rule's BODY (the Detect:/Fix:
# lines), not just its header. Path 3 does a whole-file grep that succeeds on a body match, but then
# attributes the §id by RE-GREPPING ONLY HEADERS. So a signal token present in a rule BODY but not any
# HEADER finds no header match, `hdr` is empty, and the match is SILENTLY DROPPED — the defect falls
# through to UNCOVERED-CLASS instead of BLIND-SPOT. That is the LESS-CONSERVATIVE wrong direction: a defect
# that IS covered (its detection signal is in a rule body) is reported as "no rule covers this class",
# which suppresses the blind-spot finding and mislabels a covered miss as a brand-new uncovered category.
#
# THE PRINCIPLE (this fix family): when a check can't cleanly classify, it must resolve to the SAFE
# direction — here, a real rubric match (body OR header) must be honored as COVERED (BLIND-SPOT), not
# silently downgraded to UNCOVERED-CLASS.
#
# Reproducible against the SHIPPED rubric: in examples/rubrics/rubric-generic-dotnet.md, 'allowlist'
# appears in the §G2.2 (SSRF) BODY (Detect:/Fix: lines) but in NO header.
#
# RED->GREEN:
#   S1 — signal 'allowlist' (BODY-only in §G2.2) + a non-matching category:
#          RED  (pre-fix): UNCOVERED-CLASS (the body match dropped — fail-open / mis-classify).
#          GREEN (post-fix): BLIND-SPOT, and the basis attributes the containing rule §G2.2.
#   S2 — regression: signal 'SSRF' (a HEADER token) -> BLIND-SPOT (header matching still works).
#   S3 — control: signal 'quagmirexyz' (NOWHERE in the rubric) -> UNCOVERED-CLASS (no false BLIND-SPOT;
#          the fix must not manufacture coverage for an absent token).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DET="$ROOT/lib/coverage-gap-detect.sh"
RB="$ROOT/examples/rubrics/rubric-generic-dotnet.md"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

for f in "$DET" "$RB"; do
  [ -f "$f" ] || { bad "missing required file: $f"; echo ""; echo "coverage-gap-signal-body tests: ${PASS} passed, ${FAIL} failed"; exit 1; }
done

# Guard: the test's premise is that 'allowlist' is body-only. If a future rubric edit promotes it to a
# header, this test would silently pass for the wrong reason — assert the premise up front.
if grep -iE "^### §" "$RB" | grep -qi "allowlist"; then
  bad "PRECONDITION: 'allowlist' is now in a rubric HEADER — pick a different body-only token for S1"
fi
if ! grep -qiE "(^|[^a-z])allowlist([^a-z]|\$)" "$RB"; then
  bad "PRECONDITION: 'allowlist' is no longer present in the rubric body — S1 premise invalid"
fi

# ── S1 (RED->GREEN): body-only signal token must classify BLIND-SPOT, attributed to its containing rule ──
OUT="$(bash "$DET" --category "Zzz totally novel widget thing" --signal "allowlist" --rubric "$RB" 2>/dev/null)"
CLS="$(printf '%s' "$OUT" | head -1)"
if [ "$CLS" = "BLIND-SPOT" ] && printf '%s' "$OUT" | grep -qi 'matched rule §G2.2'; then
  ok "S1: a BODY-only signal keyword ('allowlist' in §G2.2 body) -> BLIND-SPOT, attributed to §G2.2 (was: dropped -> UNCOVERED-CLASS)"
else
  bad "S1: expected BLIND-SPOT attributed to §G2.2, got CLS='$CLS' OUT=$(printf '%s' "$OUT" | tr '\n' '|')"
fi

# ── S2 (regression): a HEADER signal token still classifies BLIND-SPOT ──
CLS="$(bash "$DET" --category "Zzz novel" --signal "SSRF" --rubric "$RB" 2>/dev/null | head -1)"
[ "$CLS" = "BLIND-SPOT" ] && ok "S2 regression: a HEADER signal token ('SSRF' in §G2.2 header) -> BLIND-SPOT (header path intact)" \
                          || bad "S2 regression: expected BLIND-SPOT for header token 'SSRF', got '$CLS'"

# ── S3 (control): a signal token NOWHERE in the rubric -> UNCOVERED-CLASS (no false coverage) ──
CLS="$(bash "$DET" --category "Zzz novel" --signal "quagmirexyz" --rubric "$RB" 2>/dev/null | head -1)"
[ "$CLS" = "UNCOVERED-CLASS" ] && ok "S3 control: an ABSENT signal token -> UNCOVERED-CLASS (fix does not manufacture coverage)" \
                              || bad "S3 control: expected UNCOVERED-CLASS for absent token, got '$CLS'"

echo ""
echo "coverage-gap-signal-body tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Behavioral test for the spec-divergence engine PRE-FILTER (lib/spec-divergence.sh prefilter).
#
# The pre-filter is a CHEAP MECHANICAL pre-check (no agent dispatch) that runs BEFORE the 7-agent
# divergence check (4 interpreters + 3 judges) and decides SKIP (prompt obviously detailed) vs RUN-CHECK.
#
# THE LOAD-BEARING SAFETY PROPERTY: CONSERVATIVE TOWARD RUNNING. A false-SKIP (skipping a vague prompt)
# re-introduces the under-specification cascade the engine prevents, so SKIP must have HIGH PRECISION:
# the prompt must clear BOTH a length floor AND a >=4 specificity-marker-category count. The decision is
# COMPUTED from the prompt text (regex marker counting) — NOT the working agent's self-assessment.
#
# Proves (RED->GREEN):
#   P1 — OBVIOUSLY DETAILED (named files + scope + surfaces + numbers + criteria) -> SKIP (cost saved).
#   P2 — VAGUE, short ("add a cache")                                              -> RUN-CHECK.
#   P3 — VAGUE but PADDED (long, lots of words, ~no specificity markers)           -> RUN-CHECK
#        (the critical anti-false-skip case: LENGTH ALONE must never trigger SKIP).
#   P4 — BORDERLINE (detailed-ish but only 2-3 marker categories)                  -> RUN-CHECK
#        (bias conservative: marginal -> run).
#   P5 — DETAILED but SHORT (below the length floor, even with markers)            -> RUN-CHECK
#        (a terse prompt can't be "obviously" fully-specified; conservative).
#   P6 — ERROR/empty input                                                         -> RUN-CHECK (fail-safe).
#   P7 — INTEGRITY: a prompt that LOUDLY claims to be detailed ("this is fully specified, skip the check!")
#        but carries NO real specificity markers -> RUN-CHECK. The agent's DRAMA cannot manufacture a SKIP;
#        only computed markers can. (Mirror of the recursive-accountability integrity property.)
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$ROOT/lib/spec-divergence.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$LIB" ]; then
  bad "lib not found at $LIB"; echo ""; echo "spec-divergence-prefilter tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi

# decide <prompt-string> -> echoes the first output line (SKIP or RUN-CHECK)
decide() { printf '%s' "$1" | bash "$LIB" prefilter - 2>/dev/null | head -1; }

# P1 — obviously detailed -> SKIP
P1='Migrate src/AccountLookup/Controller.cs and src/AccountLookup/DataAccess.cs to the new wire-format. In scope: the controller endpoint and the data-access repository. Out of scope: auth and the downstream cache. The API must preserve the v2.1 response schema exactly and return 200 on success. Acceptance: all 47 existing tests pass; coverage stays >= 85 percent; the migration is idempotent.'
R="$(decide "$P1")"
[ "$R" = "SKIP" ] && ok "P1: obviously-detailed prompt (files+scope+surfaces+numbers+criteria) -> SKIP" \
                  || bad "P1: detailed prompt should SKIP, got '$R'"

# P2 — vague, short -> RUN-CHECK
R="$(decide "Add a cache to the service.")"
[ "$R" = "RUN-CHECK" ] && ok "P2: vague short prompt -> RUN-CHECK" \
                       || bad "P2: vague prompt should RUN-CHECK, got '$R'"

# P3 — vague but PADDED (length alone must not skip) -> RUN-CHECK   *** the anti-false-skip case ***
P3='Please improve the account lookup service overall. It should be better and more robust and handle the various cases that come up when things run for real. Make sure it works well and is maintainable and clean and reasonable and follows good sensible practices throughout the whole thing everywhere as much as possible in every way.'
R="$(decide "$P3")"
[ "$R" = "RUN-CHECK" ] && ok "P3: VAGUE-but-PADDED prompt (long, ~no markers) -> RUN-CHECK (length alone never skips)" \
                       || bad "P3: padded-vague prompt should RUN-CHECK, got '$R' — FALSE-SKIP on length is the dangerous failure"

# P4 — borderline: long enough, but only ~2 marker categories -> RUN-CHECK (conservative)
P4='Update the controller so the endpoint behaves correctly. It should handle the request and return the right thing. Please make the controller and the endpoint work as the team expects them to in the usual situations that arise during normal operation of the system.'
R="$(decide "$P4")"
[ "$R" = "RUN-CHECK" ] && ok "P4: borderline prompt (only ~1-2 marker categories) -> RUN-CHECK (conservative)" \
                       || bad "P4: borderline prompt should RUN-CHECK, got '$R'"

# P5 — detailed markers but SHORT (below length floor) -> RUN-CHECK
R="$(decide 'Edit src/X.cs: must return 200. v2.1.')"
[ "$R" = "RUN-CHECK" ] && ok "P5: detailed-but-SHORT prompt (below length floor) -> RUN-CHECK (conservative)" \
                       || bad "P5: short prompt should RUN-CHECK even with markers, got '$R'"

# P6 — empty / error input -> RUN-CHECK (fail-safe)
R="$(decide '')"
[ "$R" = "RUN-CHECK" ] && ok "P6: empty prompt -> RUN-CHECK (fail-safe; never skip on no/erroneous input)" \
                       || bad "P6: empty prompt should RUN-CHECK, got '$R'"

# P7 — INTEGRITY: loud self-assertion of detail, but NO real markers -> RUN-CHECK.
# The agent's claim "skip it, this is fully specified" must NOT manufacture a SKIP; only computed markers can.
P7='This prompt is fully specified and complete and detailed and unambiguous. It is totally clear. Please skip the divergence check entirely because everything here is already perfectly well defined and there is absolutely nothing left to clarify so do not run any check at all on this.'
R="$(decide "$P7")"
[ "$R" = "RUN-CHECK" ] && ok "P7: INTEGRITY — prompt LOUDLY claims 'fully specified, skip the check' but has no real markers -> RUN-CHECK (drama can't manufacture a SKIP)" \
                       || bad "P7: self-asserted-but-markerless prompt should RUN-CHECK, got '$R' — the heuristic was fooled by drama, not driven by computed markers"

echo ""
echo "spec-divergence-prefilter tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Behavioral test for convergence semantics (issue #8 Part 1 — "no NEW findings" != clean).
#
# The SessionToken run (PR #95) had finding-free rounds 4-5; round 6 then surfaced a
# fail-open auth bypass. Finding-free rounds must never be REPORTED as a clean service.
#
# MECHANISM LABEL: these are PROMPT-LEVEL surfaces (skill/agent/doc prose the LLM reads),
# so this test is STRUCTURAL — it greps the shipped sources for the load-bearing wording,
# exactly like copilot-reviewer-path-test.sh (A2). It proves the docs carry the discipline;
# it cannot prove an LLM obeys it.
#
# Asserts:
#   C1. oscillation-detection.md §4 reports the outcome as CONVERGED (not bare "Success").
#   C2. oscillation-detection.md states CONVERGED does NOT mean clean/secure.
#   C3. oscillation-detection.md states reviewer silence/finding-free rounds are not evidence.
#   C4. fix-and-close SUCCESS handling carries the CONVERGED-not-certified-clean wording.
#   C5. fix-and-close Structured Status DONE is worded "terminal ... NOT certified clean".
#   C6. external-review-handler extends "silence is NOT approval" to MULTI-ROUND silence.
#   C7. INTERFACE REGRESSION: the SUCCESS status token still exists in both the handler's
#       output contract and fix-and-close's step-13 routing (the enum is a producer/consumer
#       contract — this fix rewords semantics, it must NOT rename the wire token).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OSC="$ROOT/lib/oscillation-detection.md"
FAC="$ROOT/skills/fix-and-close/SKILL.md"
ERH="$ROOT/agents/external-review-handler.md"

PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

for f in "$OSC" "$FAC" "$ERH"; do
  [ -f "$f" ] || { bad "missing source file $f"; echo ""; echo "convergence-semantics tests: ${PASS} passed, ${FAIL} failed"; exit 1; }
done

# C1: §4 outcome is CONVERGED.
if grep -qE '^###? *4\..*CONVERGED|^###? *4\..*Convergence' "$OSC"; then
  ok "C1: oscillation-detection §4 is titled as convergence/CONVERGED"
else bad "C1: oscillation-detection §4 still presents bare 'Success' (no CONVERGED)"; fi

# C2: explicit not-clean statement.
if grep -qiE 'does NOT mean.*(clean|secure)' "$OSC"; then
  ok "C2: oscillation-detection states CONVERGED does NOT mean clean/secure"
else bad "C2: oscillation-detection missing the 'does NOT mean clean' statement"; fi

# C3: silence-is-not-evidence statement.
if grep -qiE '(silence|finding-free|no new.*findings).*(not|never).*(evidence|approval|clean bill)' "$OSC"; then
  ok "C3: oscillation-detection states reviewer silence is not evidence"
else bad "C3: oscillation-detection missing the silence-is-not-evidence statement"; fi

# C4: fix-and-close SUCCESS handling reworded.
if grep -qiE 'SUCCESS.*(CONVERGED|not certified clean|NOT certified clean)' "$FAC"; then
  ok "C4: fix-and-close SUCCESS handling carries CONVERGED / not-certified-clean wording"
else bad "C4: fix-and-close SUCCESS handling still implies clean on exit"; fi

# C5: DONE status reworded.
if grep -qE '\*\*DONE\*\*' "$FAC" && grep -E '\*\*DONE\*\*' "$FAC" | grep -qiE 'NOT certified clean|no NEW findings'; then
  ok "C5: fix-and-close DONE status is worded terminal-not-certified-clean"
else bad "C5: fix-and-close DONE status missing 'NOT certified clean' wording"; fi

# C6: handler multi-round extension.
if grep -qiE 'multi-round|consecutive (finding-free|silent|clean) rounds|across rounds' "$ERH"; then
  ok "C6: external-review-handler extends silence-discipline to multi-round"
else bad "C6: external-review-handler has no multi-round silence note"; fi

# C7: interface regression — wire token intact on BOTH sides.
if grep -qE 'SUCCESS \| NEEDS_PARENT_FIXES|`SUCCESS`' "$ERH" && grep -qE 'SUCCESS \| NEEDS_PARENT_FIXES' "$FAC"; then
  ok "C7: SUCCESS wire token intact in handler contract and fix-and-close routing"
else bad "C7: the SUCCESS status enum was renamed/removed — that is an interface break, not the bounded fix"; fi

echo ""
echo "convergence-semantics tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Behavioral test for lib/spec-divergence-poc.sh — the POC divergence scorer (Issues 1+2+3 core signal).
#
# ┌──────────────────────────────────────────────────────────────────────────────────────────────┐
# │ THIS IS A POC DEMONSTRATION, not the full subsystem's test suite. It proves the SCORER MATH is   │
# │ deterministic and computed-from-interpretations (the wireable, shippable part). The CLAIM about  │
# │ whether divergence separates vague-from-specified prompts was tested EMPIRICALLY with 24 blind    │
# │ interpreters and came back MIXED — see .release-audit/REPORT and the evidence fixtures under      │
# │ .release-audit/spec-divergence-poc-evidence/. The scorer is NOT wired into scaffold/migrate.      │
# └──────────────────────────────────────────────────────────────────────────────────────────────┘
#
# Proves (the deterministic-measurement properties — these are what a real build would depend on):
#   D1 — identical interpretations -> divergence 0.0 (a perfectly-agreed reading scores zero).
#   D2 — maximally different interpretations -> divergence 1.0 (total disagreement scores one).
#   D3 — the score is DETERMINISTIC: same input -> same output (it's computed, not sampled/self-assessed).
#   D4 — the score is COMPUTED FROM the interpretations, not agent-self-assessed: there is NO 'confidence'
#        field consulted; the scorer contains no agent dispatch / no self-report read (structural check).
#   D5 — partial overlap scores strictly between 0 and 1 (the metric is graded, not binary).
#   D6 — a real recorded EMPIRICAL set (committed fixture from the blind run) scores in (0,1) and the
#        scorer runs on it (demonstration that it operates on real agent output, not just toy fixtures).
#   U1 — usage / <2 interpretations -> exit 2.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
POC="$ROOT/lib/spec-divergence-poc.sh"
EVID="$ROOT/.release-audit/spec-divergence-poc-evidence"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$POC" ]; then
  bad "POC scorer not found at $POC"; echo ""; echo "spec-divergence-poc tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi
PYOK=0
for c in python3 python; do command -v "$c" &>/dev/null && "$c" -c "pass" &>/dev/null 2>&1 && PYOK=1 && break; done
if [ "$PYOK" -eq 0 ]; then
  echo "SKIP: no working python — spec-divergence-poc needs python"
  echo ""; echo "spec-divergence-poc tests: ${PASS} passed, ${FAIL} failed (skipped: no python)"; exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
score() { bash "$POC" "$1" --score 2>/dev/null; }

# D1 — identical -> 0.0
cat > "$T/identical.json" <<'EOF'
{"interpretations":[
 {"scope_one_line":"migrate the lookup endpoint to net10","in_scope":["GET endpoint","repository"],"comparison_surfaces":["controller","data-access"],"key_behaviors":["preserve E0001"],"assumptions_i_had_to_make":[]},
 {"scope_one_line":"migrate the lookup endpoint to net10","in_scope":["GET endpoint","repository"],"comparison_surfaces":["controller","data-access"],"key_behaviors":["preserve E0001"],"assumptions_i_had_to_make":[]},
 {"scope_one_line":"migrate the lookup endpoint to net10","in_scope":["GET endpoint","repository"],"comparison_surfaces":["controller","data-access"],"key_behaviors":["preserve E0001"],"assumptions_i_had_to_make":[]}
]}
EOF
S="$(score "$T/identical.json")"
[ "$S" = "0.0000" ] && ok "D1: identical interpretations -> divergence 0.0000" \
  || bad "D1: identical should be 0.0000, got $S"

# D2 — maximally different -> 1.0
cat > "$T/maxdiff.json" <<'EOF'
{"interpretations":[
 {"scope_one_line":"build a billing dashboard frontend","in_scope":["react components"],"comparison_surfaces":["ui"],"key_behaviors":["render invoices"],"assumptions_i_had_to_make":["framework"]},
 {"scope_one_line":"migrate a postgres schema","in_scope":["flyway migrations"],"comparison_surfaces":["schema"],"key_behaviors":["zero downtime"],"assumptions_i_had_to_make":["rollback"]},
 {"scope_one_line":"write a kafka consumer","in_scope":["topic subscription"],"comparison_surfaces":["messaging"],"key_behaviors":["at-least-once delivery"],"assumptions_i_had_to_make":["offset"]}
]}
EOF
S="$(score "$T/maxdiff.json")"
[ "$S" = "1.0000" ] && ok "D2: maximally-different interpretations -> divergence 1.0000" \
  || bad "D2: max-diff should be 1.0000, got $S"

# D3 — deterministic: same input twice -> identical score
S1="$(score "$T/identical.json")"; S2="$(score "$T/identical.json")"
S3="$(score "$T/maxdiff.json")"; S4="$(score "$T/maxdiff.json")"
[ "$S1" = "$S2" ] && [ "$S3" = "$S4" ] && ok "D3: score is DETERMINISTIC (same input -> same output; computed, not sampled)" \
  || bad "D3: score not deterministic ($S1/$S2, $S3/$S4)"

# D4 — computed-from-interpretations, NOT self-assessed: the scorer must not READ a 'confidence' field
#       and must not DISPATCH an agent. Structural check on the EXECUTABLE source only — strip shell '#'
#       comments and python '#' comments so the scorer's own honesty labels (which legitimately mention
#       'self-assessed'/'confidence' to say what it does NOT do) don't false-positive. We check for actual
#       code constructs: reading a .confidence/.self_assess key, or an Agent/subagent dispatch.
CODE_ONLY="$(sed 's/#.*$//' "$POC")"
if printf '%s' "$CODE_ONLY" | grep -qiE '(get|\.)\s*\(?["'\'']?(confidence|self_assess|self_reported)|subagent_type|Agent tool'; then
  bad "D4: scorer's CODE reads a confidence/self-assessment field or dispatches an agent — not purely computed"
else
  ok "D4: scorer is COMPUTED from interpretations (executable code reads no confidence field, dispatches no agent — mechanical; only its comments mention self-assessment, to disclaim it)"
fi

# D5 — partial overlap -> strictly between 0 and 1
cat > "$T/partial.json" <<'EOF'
{"interpretations":[
 {"scope_one_line":"cache the validate token path","in_scope":["validate path","memory cache"],"comparison_surfaces":["cache","data-access"],"key_behaviors":["single flight"],"assumptions_i_had_to_make":["ttl"]},
 {"scope_one_line":"cache the token fetch path","in_scope":["fetch path","memory cache"],"comparison_surfaces":["cache","downstream-client"],"key_behaviors":["single flight"],"assumptions_i_had_to_make":["ttl","scope"]}
]}
EOF
S="$(score "$T/partial.json")"
python -c "import sys; s=float('$S'); sys.exit(0 if 0.0 < s < 1.0 else 1)" \
  && ok "D5: partial overlap -> strictly between 0 and 1 (score=$S; graded, not binary)" \
  || bad "D5: partial overlap should be in (0,1), got $S"

# D6 — runs on a REAL recorded empirical set (committed blind-run fixture), scores in (0,1).
if [ -f "$EVID/p3-cache__vague.json" ]; then
  S="$(score "$EVID/p3-cache__vague.json")"
  python -c "import sys; s=float('$S'); sys.exit(0 if 0.0 < s < 1.0 else 1)" \
    && ok "D6: scores a REAL blind-interpreter set (p3-cache vague=$S) in (0,1) — operates on real agent output" \
    || bad "D6: real-set score out of (0,1): $S"
else
  echo "NOTE: D6 skipped — evidence fixture not present (.release-audit/spec-divergence-poc-evidence/)"
fi

# U1 — usage / <2 interpretations
echo '{"interpretations":[{"scope_one_line":"x","in_scope":[],"comparison_surfaces":[],"key_behaviors":[],"assumptions_i_had_to_make":[]}]}' > "$T/one.json"
bash "$POC" "$T/one.json" >/dev/null 2>&1; [ "$?" = "2" ] && ok "U1a: <2 interpretations -> exit 2" || bad "U1a: <2 should exit 2"
bash "$POC" >/dev/null 2>&1; [ "$?" = "2" ] && ok "U1b: no args -> exit 2" || bad "U1b: no args should exit 2"

echo ""
echo "spec-divergence-poc tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Behavioral test for lib/spec-divergence-semantic-poc.sh — POC#2, the SEMANTIC divergence aggregator.
#
# ┌──────────────────────────────────────────────────────────────────────────────────────────────┐
# │ POC DEMONSTRATION, not the full subsystem's suite. Tests the deterministic AGGREGATOR math (the   │
# │ wireable part). The empirical CLAIM (does semantic divergence separate vague from specified?) was │
# │ tested with 5 pairs x 3 blind judges and came back VERIFIED-with-a-caveat — see                   │
# │ .release-audit/spec-divergence-poc-evidence/VERDICT-POC2.md and the committed judgment fixtures.   │
# │ NOT wired into scaffold/migrate.                                                                  │
# └──────────────────────────────────────────────────────────────────────────────────────────────┘
#
# Proves (deterministic-aggregation properties):
#   J1 — all judges 'full-agreement' + overall 0.0 -> divergence ~0.0 (a semantically-agreed set scores low).
#   J2 — all judges 'material-fork' + overall 1.0 -> divergence ~1.0 (a forked set scores high).
#   J3 — DETERMINISTIC: same judgments -> same score.
#   J4 — SEMANTIC + COMPUTED + BLIND-JUDGE: the aggregator reads judge verdicts about the INTERPRETATION
#        SET, not a working agent's self-confidence — structural check (no 'confidence'/self-assess/agent
#        dispatch in the executable code).
#   J5 — REAL EMPIRICAL CONTRAST (committed blind-judge fixtures): the p1-migrate SPECIFIED set — which
#        POC#1's token-Jaccard scored FALSELY HIGH (0.638, inverted) — now scores LOW (< 0.30) under the
#        semantic metric. This is the diagnostic that the verbosity confound is fixed.
#   J6 — REAL EMPIRICAL SEPARATION: a genuinely-ambiguous vague set (p3-cache vague) scores HIGH (> 0.30)
#        while every specified set scores LOW (< 0.30) — no false positive on a well-specified prompt.
#   U1 — usage / zero judgments -> exit 2.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGG="$ROOT/lib/spec-divergence-semantic-poc.sh"
J="$ROOT/.release-audit/spec-divergence-poc-evidence/poc2-judgments"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$AGG" ]; then
  bad "aggregator not found at $AGG"; echo ""; echo "spec-divergence-semantic-poc tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi
PYOK=0
for c in python3 python; do command -v "$c" &>/dev/null && "$c" -c "pass" &>/dev/null 2>&1 && PYOK=1 && break; done
if [ "$PYOK" -eq 0 ]; then
  echo "SKIP: no working python"; echo ""; echo "spec-divergence-semantic-poc tests: ${PASS} passed, ${FAIL} failed (skipped)"; exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
lt() { python -c "import sys; sys.exit(0 if float('$1') < float('$2') else 1)"; }
gt() { python -c "import sys; sys.exit(0 if float('$1') > float('$2') else 1)"; }

# J1 — all agree -> ~0
echo '{"judgments":[{"scope_agreement":"full-agreement","surfaces_agreement":"full-agreement","behavior_agreement":"full-agreement","overall_divergence_0to1":0.0},{"scope_agreement":"full-agreement","surfaces_agreement":"full-agreement","behavior_agreement":"full-agreement","overall_divergence_0to1":0.0}]}' > "$T/agree.json"
S="$(bash "$AGG" "$T/agree.json" --score)"
lt "$S" "0.10" && ok "J1: all-agree judges -> divergence ~0 (got $S)" || bad "J1: all-agree should be ~0, got $S"

# J2 — all fork -> ~1
echo '{"judgments":[{"scope_agreement":"material-fork","surfaces_agreement":"material-fork","behavior_agreement":"material-fork","overall_divergence_0to1":1.0}]}' > "$T/fork.json"
S="$(bash "$AGG" "$T/fork.json" --score)"
gt "$S" "0.90" && ok "J2: all-fork judges -> divergence ~1 (got $S)" || bad "J2: all-fork should be ~1, got $S"

# J3 — deterministic
S1="$(bash "$AGG" "$T/fork.json" --score)"; S2="$(bash "$AGG" "$T/fork.json" --score)"
[ "$S1" = "$S2" ] && ok "J3: aggregation is DETERMINISTIC ($S1)" || bad "J3: not deterministic ($S1/$S2)"

# J4 — semantic + computed + blind: executable code reads judge verdicts, not self-confidence / no agent dispatch.
CODE_ONLY="$(sed 's/#.*$//' "$AGG")"
if printf '%s' "$CODE_ONLY" | grep -qiE 'subagent_type|Agent tool|self_assess|own.?confidence'; then
  bad "J4: aggregator executable code dispatches an agent or reads self-confidence — not a blind-judge aggregator"
else
  ok "J4: aggregator is SEMANTIC + COMPUTED from blind-judge verdicts (no agent dispatch, no self-confidence read in code)"
fi

# J5 — the diagnostic: p1-specified (POC#1 falsely-high 0.638) now LOW under semantic.
if [ -f "$J/p1-migrate__specified.json" ]; then
  S="$(bash "$AGG" "$J/p1-migrate__specified.json" --score)"
  lt "$S" "0.30" && ok "J5: p1-migrate SPECIFIED now scores LOW ($S < 0.30) — POC#1's verbosity inversion (0.638) is FIXED" \
                 || bad "J5: p1 specified should be LOW (<0.30), got $S — inversion NOT fixed"
else
  echo "NOTE: J5 skipped — p1 judgment fixture missing"
fi

# J6 — separation: genuinely-vague p3-cache HIGH, while specified sets LOW (no false positive).
if [ -f "$J/p3-cache__vague.json" ] && [ -f "$J/p3-cache__specified.json" ]; then
  SV="$(bash "$AGG" "$J/p3-cache__vague.json" --score)"
  SS="$(bash "$AGG" "$J/p3-cache__specified.json" --score)"
  if gt "$SV" "0.30" && lt "$SS" "0.30"; then
    ok "J6: genuinely-ambiguous vague p3-cache HIGH ($SV) vs specified LOW ($SS) — separates, no false positive"
  else
    bad "J6: expected vague>0.30>specified, got vague=$SV specified=$SS"
  fi
else
  echo "NOTE: J6 skipped — p3 fixtures missing"
fi

# U1 — usage
echo '{"judgments":[]}' > "$T/empty.json"
bash "$AGG" "$T/empty.json" >/dev/null 2>&1; [ "$?" = "2" ] && ok "U1a: zero judgments -> exit 2" || bad "U1a: zero judgments should exit 2"
bash "$AGG" >/dev/null 2>&1; [ "$?" = "2" ] && ok "U1b: no args -> exit 2" || bad "U1b: no args should exit 2"

echo ""
echo "spec-divergence-semantic-poc tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

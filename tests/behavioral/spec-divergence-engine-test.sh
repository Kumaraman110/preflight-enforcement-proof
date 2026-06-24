#!/usr/bin/env bash
# Behavioral test for lib/spec-divergence.sh — the productionized spec-divergence ENGINE CORE (Issues
# 1+2+3 unified). Carries POC#2's integrity properties forward and adds the elicitation + artifact pieces.
#
# ┌──────────────────────────────────────────────────────────────────────────────────────────────┐
# │ Tests the MECHANICAL core (scoring, blind-judge-brief, decision, questions, artifact). The agent  │
# │ DISPATCHES (generating blind interpretations + blind judgments) are PROMPT-LEVEL skill steps — a   │
# │ bash lib can't spawn sub-agents — and are NOT exercised here (see the engine's honesty label and   │
# │ the skill wiring). The engine ELICITS on high divergence; it does NOT hard-block (advisory).        │
# └──────────────────────────────────────────────────────────────────────────────────────────────┘
#
# Proves:
#   E1 — INTEGRITY (blindness, mechanical): build-judge-brief emits ONLY interpretations; the original
#        prompt / any prompt-leaking key is stripped, so a judge CANNOT see the prompt. This is the
#        property that keeps the score an independent anchor (not self-assessment).
#   E2 — SEMANTIC + COMPUTED: agreeing judge verdicts -> low; forking -> high (reuses POC#2 aggregation);
#        no token overlap, no self-confidence read, no agent dispatch in the engine code (structural).
#   E3 — the diagnostic from POC#2: p1-migrate SPECIFIED (token-Jaccard scored 0.638 falsely-high) scores
#        LOW here and DECIDES PROCEED — the verbosity inversion stays fixed in the productionized engine.
#   E4 — SEPARATION: genuinely-ambiguous p3-cache vague scores HIGH and DECIDES ELICIT, while a specified
#        set DECIDES PROCEED — no false-positive ELICIT on a well-specified prompt.
#   E5 — ELICITATION targets the forked axes worst-first: questions on a forked set name the >=0.5 axes;
#        a low-divergence set yields no targeted questions.
#   E6 — ARTIFACT: write-elicited writes a well-formed .preflight/<svc>/spec-elicited.md (header + pinned).
#   E7 — ADVISORY THRESHOLD is configurable: a high enough --threshold flips a forked set's decision to
#        PROCEED (proving it is a parameter, default advisory, NOT a hardcoded hard block).
#   E8 — DETERMINISTIC: same judgments -> same score.
#   U1 — usage / bad input -> exit 2.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENG="$ROOT/lib/spec-divergence.sh"
EV="$ROOT/.release-audit/spec-divergence-poc-evidence"
J="$EV/poc2-judgments"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$ENG" ]; then
  bad "engine not found at $ENG"; echo ""; echo "spec-divergence-engine tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi
PYOK=0
for c in python3 python; do command -v "$c" &>/dev/null && "$c" -c "pass" &>/dev/null 2>&1 && PYOK=1 && break; done
if [ "$PYOK" -eq 0 ]; then
  echo "SKIP: no working python"; echo ""; echo "spec-divergence-engine tests: ${PASS} passed, ${FAIL} failed (skipped)"; exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
lt() { python -c "import sys; sys.exit(0 if float('$1') <  float('$2') else 1)"; }
gt() { python -c "import sys; sys.exit(0 if float('$1') >  float('$2') else 1)"; }
score_of() { bash "$ENG" score "$1" 2>/dev/null | grep -a 'SEMANTIC DIVERGENCE' | grep -oE '[0-9]+\.[0-9]+' | head -1; }

# ── E1 — INTEGRITY: build-judge-brief strips the prompt; a leak key is removed. ──
cat > "$T/interp-with-leak.json" <<'EOF'
{"interpretations":[
 {"scope_boundary":"cache validate path","prompt":"add caching to the token service","core_behavior":"single-flight"},
 {"scope_boundary":"cache fetch path","request":"add caching","core_behavior":"memoize"}
]}
EOF
BRIEF="$(bash "$ENG" build-judge-brief "$T/interp-with-leak.json" 2>/dev/null)"
if printf '%s' "$BRIEF" | grep -qiE '"prompt"|"request"|add caching to the token service'; then
  bad "E1: judge brief LEAKED the prompt — blindness broken (judge could infer vague/specified)"
else
  ok "E1: INTEGRITY — judge brief strips the prompt + leak keys (judges are MECHANICALLY blind to the request)"
fi

# ── E2 — semantic+computed: agree->low, fork->high; no token/self-confidence/agent-dispatch in code. ──
echo '{"judgments":[{"scope_agreement":"full-agreement","surfaces_agreement":"full-agreement","behavior_agreement":"full-agreement","overall_divergence_0to1":0.0}]}' > "$T/agree.json"
echo '{"judgments":[{"scope_agreement":"material-fork","surfaces_agreement":"material-fork","behavior_agreement":"material-fork","overall_divergence_0to1":1.0}]}' > "$T/fork.json"
SA="$(score_of "$T/agree.json")"; SF="$(score_of "$T/fork.json")"
CODE_ONLY="$(sed 's/#.*$//' "$ENG")"
if lt "$SA" "0.10" && gt "$SF" "0.90" && ! printf '%s' "$CODE_ONLY" | grep -qiE 'jaccard|token.set|subagent_type|Agent tool|own.?confidence'; then
  ok "E2: SEMANTIC+COMPUTED — agree=$SA low, fork=$SF high; no token-overlap / self-confidence / agent-dispatch in engine code"
else
  bad "E2: semantic/computed property broken (agree=$SA fork=$SF, or forbidden construct in code)"
fi

# ── E3 — the POC#2 diagnostic survives: p1 specified LOW + PROCEED. ──
if [ -f "$J/p1-migrate__specified.json" ]; then
  S="$(score_of "$J/p1-migrate__specified.json")"; D="$(bash "$ENG" decision "$J/p1-migrate__specified.json" 2>/dev/null)"
  if lt "$S" "0.30" && [ "$D" = "PROCEED" ]; then
    ok "E3: p1-migrate SPECIFIED scores LOW ($S) + PROCEED — POC#1 verbosity inversion (0.638) stays fixed in the engine"
  else bad "E3: p1 specified should be LOW+PROCEED, got $S / $D"; fi
else echo "NOTE: E3 skipped — fixture missing"; fi

# ── E4 — separation + decision: p3 vague HIGH+ELICIT, a specified set PROCEED. ──
if [ -f "$J/p3-cache__vague.json" ] && [ -f "$J/p3-cache__specified.json" ]; then
  SV="$(score_of "$J/p3-cache__vague.json")"; DV="$(bash "$ENG" decision "$J/p3-cache__vague.json" 2>/dev/null)"
  DS="$(bash "$ENG" decision "$J/p3-cache__specified.json" 2>/dev/null)"
  if gt "$SV" "0.30" && [ "$DV" = "ELICIT" ] && [ "$DS" = "PROCEED" ]; then
    ok "E4: SEPARATION — p3 vague HIGH ($SV)+ELICIT vs specified PROCEED (no false-positive elicit)"
  else bad "E4: expected vague HIGH+ELICIT / specified PROCEED, got $SV/$DV and $DS"; fi
else echo "NOTE: E4 skipped — fixtures missing"; fi

# ── E5 — elicitation targets forked axes worst-first; low-divergence -> no questions. ──
if [ -f "$J/p3-cache__vague.json" ]; then
  Q="$(bash "$ENG" questions "$J/p3-cache__vague.json" 2>/dev/null)"
  printf '%s' "$Q" | grep -qiE 'Q1.*(SCOPE|SURFACES|BEHAVIOR)' \
    && ok "E5a: ELICIT targets forked axes (worst-first questions emitted for the vague set)" \
    || bad "E5a: expected targeted questions for the forked vague set"
fi
QL="$(bash "$ENG" questions "$T/agree.json" 2>/dev/null)"
printf '%s' "$QL" | grep -qi 'no.*targeted\|below the elicitation bar' \
  && ok "E5b: a low-divergence (agreeing) set yields NO targeted questions" \
  || bad "E5b: agreeing set should yield no targeted questions"

# ── E6 — artifact writer. ──
printf '## Scope\nPin: migrate X endpoint only\n' > "$T/pinned.md"
bash "$ENG" write-elicited "SvcE6" "$T/pinned.md" "$T" >/dev/null 2>&1
if [ -f "$T/.preflight/SvcE6/spec-elicited.md" ] && grep -q "Pinned Spec" "$T/.preflight/SvcE6/spec-elicited.md" && grep -q "migrate X endpoint" "$T/.preflight/SvcE6/spec-elicited.md"; then
  ok "E6: write-elicited produces a well-formed .preflight/<svc>/spec-elicited.md (header + pinned content)"
else bad "E6: elicited artifact missing or malformed"; fi

# ── E7 — threshold is a configurable advisory parameter (high threshold flips ELICIT->PROCEED). ──
if [ -f "$J/p3-cache__vague.json" ]; then
  DHI="$(bash "$ENG" decision "$J/p3-cache__vague.json" --threshold 0.99 2>/dev/null)"
  [ "$DHI" = "PROCEED" ] && ok "E7: threshold is a configurable ADVISORY parameter (--threshold 0.99 flips the forked set to PROCEED — not a hardcoded hard block)" \
                         || bad "E7: high threshold should flip decision to PROCEED, got $DHI"
fi

# ── E8 — deterministic. ──
S1="$(score_of "$T/fork.json")"; S2="$(score_of "$T/fork.json")"
[ "$S1" = "$S2" ] && ok "E8: DETERMINISTIC (same judgments -> same score)" || bad "E8: not deterministic ($S1/$S2)"

# ── U1 — usage. ──
bash "$ENG" >/dev/null 2>&1; [ "$?" = "2" ] && ok "U1a: no subcommand -> exit 2" || bad "U1a"
bash "$ENG" score "/nonexistent.json" >/dev/null 2>&1; [ "$?" = "2" ] && ok "U1b: missing file -> exit 2" || bad "U1b"

echo ""
echo "spec-divergence-engine tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

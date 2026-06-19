#!/usr/bin/env bash
# Behavioral test for the spec-divergence engine WIRING [Component 3] into scaffold + migrate.
#
# This is a STRUCTURAL wiring test (the agent dispatches it triggers are prompt-level and can't be unit-run
# here). It confirms the engine is wired at the FRESH-AMBIGUITY entry points, references the shared
# procedure + the mechanical lib, is labeled ADVISORY, and is NOT wired onto internal already-pinned
# dispatches.
#
# Proves:
#   W1 — scaffold has a 'Phase 0 — Spec-Divergence Check' wired at its initial-prompt entry point
#        (before Phase 1 Design).
#   W2 — migrate has a 'Phase 0 — Spec-Divergence Check' wired at its $ARGUMENTS-parse entry point
#        (before Setup / Phase 1 Discovery).
#   W3 — both reference the shared procedure (lib/spec-divergence.md) AND the mechanical engine
#        (lib/spec-divergence.sh), not a re-invented inline flow.
#   W4 — both are labeled ADVISORY (ELICIT, not hard-block) — preserves the proven-only-at-n=5 honesty.
#   W5 — both explicitly say NOT to fire on internal dispatches (discovery-analyst/spec-analyst/implementer
#        operate on an already-pinned spec) — the fire-point discipline that bounds cost.
#   W6 — the shared procedure doc exists and documents blind generation, blind judging (judge never sees
#        the prompt), the cost profile, and the advisory->hard-gate promotion path.
#   W7 — the engine + shared doc ship via the installer surfaces (lib/) — they reach a consumer.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCAF="$ROOT/skills/scaffold/SKILL.md"
MIG="$ROOT/skills/migrate/SKILL.md"
DOC="$ROOT/lib/spec-divergence.md"
ENG="$ROOT/lib/spec-divergence.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# W1 — scaffold Phase 0 before Phase 1 Design.
if grep -q 'Phase 0 — Spec-Divergence Check' "$SCAF"; then
  p0=$(grep -n 'Phase 0 — Spec-Divergence Check' "$SCAF" | head -1 | cut -d: -f1)
  p1=$(grep -n 'Phase 1 — Design' "$SCAF" | head -1 | cut -d: -f1)
  if [ -n "$p0" ] && [ -n "$p1" ] && [ "$p0" -lt "$p1" ]; then
    ok "W1: scaffold Phase 0 spec-divergence wired BEFORE Phase 1 Design (lines $p0 < $p1)"
  else bad "W1: scaffold Phase 0 not before Phase 1 (p0=$p0 p1=$p1)"; fi
else bad "W1: scaffold has no Phase 0 — Spec-Divergence Check"; fi

# W2 — migrate Phase 0 before Setup/Phase 1.
if grep -q 'Phase 0 — Spec-Divergence Check' "$MIG"; then
  p0=$(grep -n 'Phase 0 — Spec-Divergence Check' "$MIG" | head -1 | cut -d: -f1)
  p1=$(grep -n 'Phase 1 — Discovery' "$MIG" | head -1 | cut -d: -f1)
  if [ -n "$p0" ] && [ -n "$p1" ] && [ "$p0" -lt "$p1" ]; then
    ok "W2: migrate Phase 0 spec-divergence wired BEFORE Phase 1 Discovery (lines $p0 < $p1)"
  else bad "W2: migrate Phase 0 not before Phase 1 (p0=$p0 p1=$p1)"; fi
else bad "W2: migrate has no Phase 0 — Spec-Divergence Check"; fi

# W3 — both reference the shared doc + the mechanical engine.
for f in "$SCAF" "$MIG"; do
  n=$(basename "$(dirname "$f")")
  if grep -q 'lib/spec-divergence.md' "$f" && grep -q 'spec-divergence.sh' "$f"; then
    ok "W3:$n references the shared procedure (spec-divergence.md) + the mechanical engine (spec-divergence.sh)"
  else bad "W3:$n missing reference to the shared doc or the engine"; fi
done

# W4 — both labeled ADVISORY (not hard-block).
for f in "$SCAF" "$MIG"; do
  n=$(basename "$(dirname "$f")")
  grep -qiE 'ADVISORY|do not hard-block|does NOT hard-block' "$f" \
    && ok "W4:$n labels the spec-divergence check ADVISORY (ELICIT, not hard-block)" \
    || bad "W4:$n does not label it advisory"
done

# W5 — both say NOT to fire on internal dispatches.
for f in "$SCAF" "$MIG"; do
  n=$(basename "$(dirname "$f")")
  grep -qiE 'not.*(re-?run|fire).*(internal|dispatch)|do NOT re-run Phase 0|operate on (the |an )?(now-)?pinned spec' "$f" \
    && ok "W5:$n states Phase 0 fires only at fresh-ambiguity entry points, NOT internal dispatches" \
    || bad "W5:$n does not restrict firing to fresh-ambiguity entry points"
done

# W6 — shared doc documents the integrity + cost + promotion.
if [ -f "$DOC" ]; then
  miss=""
  grep -qiE 'BLIND interpreter|blind interpretations' "$DOC" || miss="$miss blind-gen"
  grep -qiE 'never see the (original )?(prompt|request)|strips the prompt|judges? .* (blind|never)' "$DOC" || miss="$miss judge-blind"
  grep -qiE 'cost profile|N \+ M|7 agent' "$DOC" || miss="$miss cost"
  grep -qiE 'advisory.*(hard gate|blocking)|promotion' "$DOC" || miss="$miss promotion"
  [ -z "$miss" ] && ok "W6: shared doc documents blind-gen, judge-blindness, cost profile, and the advisory->hard-gate promotion path" \
                 || bad "W6: shared doc missing:$miss"
else bad "W6: lib/spec-divergence.md not found"; fi

# W7 — engine + doc are in lib/ (an installed surface -> reaches consumers).
{ [ -f "$ENG" ] && [ -f "$DOC" ]; } && ok "W7: engine + shared doc live under lib/ (installed surface — reach the consumer)" \
                                    || bad "W7: engine or doc not under lib/"

echo ""
echo "spec-divergence-wiring tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

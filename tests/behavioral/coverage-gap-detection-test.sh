#!/usr/bin/env bash
# Behavioral test for self-learning coverage-gap detection (Layer 1 + Layer 2).
# Design: .release-audit/COVERAGE-GAP-DESIGN.md
#
# LAYER 1 (lib/capture-finding.sh) — SOURCE-AGNOSTIC capture. ANY adjudicated defect, regardless of how it
#   was found, flows to ONE capture path via --source. The hole it closes: today only the Copilot handler
#   auto-captures (agents/external-review-handler.md:3; parent forbidden: fix-and-close SKILL:244,:473), so
#   deploy/review/incident findings silently bypass capture.
#
# LAYER 2 (lib/coverage-gap-detect.sh) — MECHANICAL coverage-gap self-detection. Classifies a post-merge
#   defect as BLIND-SPOT (a rubric rule covers it but it got past the gate), UNCOVERED-CLASS (no rule
#   covers it), or NEW-COVERAGE (structurally uncoverable). Computed from (defect-category, rubric-rules,
#   gate-evidence) — NEVER the working agent's self-assessment.
#
# THE INTEGRITY TEST (the most important): the determination is COMPUTED, not self-assessed. A working
#   agent CLAIMING "not my fault" cannot suppress a mechanically-detected gap; an agent CLAIMING "huge
#   gap" cannot manufacture a false blind-spot on a genuinely-novel class. Same defect + opposite claims
#   => same classification (the claim fields are inert by construction).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CAP="$ROOT/lib/capture-finding.sh"
DET="$ROOT/lib/coverage-gap-detect.sh"
RB="$ROOT/examples/rubrics/rubric-generic-dotnet.md"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

for f in "$CAP" "$DET" "$RB"; do
  [ -f "$f" ] || { bad "missing required file: $f"; echo ""; echo "coverage-gap-detection tests: ${PASS} passed, ${FAIL} failed"; exit 1; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
WS="$T/ws"; mkdir -p "$WS/.preflight"
( cd "$WS" && git init -q && git commit -q --allow-empty -m init ) >/dev/null 2>&1
printf '{"capture":{"calibrationLog":"docs/review/calibration-log.md","checklistAdditions":"docs/review/checklist-additions.md","falsePositives":"docs/review/false-positives.md"}}' > "$WS/.preflight/config.json"

# ════════════════════════════ LAYER 1 — source-agnostic capture ════════════════════════════

# L1a — a NON-Copilot source (deploy) flows to capture (RED: was bypassed; only Copilot auto-captured).
PREFLIGHT_CAPTURE_TS=2026-06-20T00:00:00Z bash "$CAP" \
  --source deploy --category "Null deref on empty response" --summary "deploy: NRE on 204" \
  --bucket checklist-additions --repo-root "$WS" >/dev/null 2>&1
if grep -q 'deploy: NRE on 204' "$WS/docs/review/checklist-additions.md" 2>/dev/null \
   && grep -q '\*\*Source:\*\* deploy' "$WS/docs/review/checklist-additions.md" 2>/dev/null; then
  ok "L1a: a NON-Copilot (deploy) finding flows to capture, source-labeled (was: silently bypassed)"
else bad "L1a: deploy finding did not reach capture with a deploy source label"; fi

# L1b — a Copilot source STILL captures (no regression).
PREFLIGHT_CAPTURE_TS=2026-06-20T00:00:00Z bash "$CAP" \
  --source "copilot PR#95" --category "Log injection (CWE-117)" --summary "copilot: unsanitized log" \
  --bucket calibration-log --rule "§G2.1" --repo-root "$WS" >/dev/null 2>&1
if grep -q 'copilot: unsanitized log' "$WS/docs/review/calibration-log.md" 2>/dev/null; then
  ok "L1b: a Copilot finding still captures (no regression to the existing on-ramp)"
else bad "L1b: copilot finding did not capture"; fi

# L1c — fail-safe: no --bucket => routed (checklist-additions, low confidence), NEVER dropped.
PREFLIGHT_CAPTURE_TS=2026-06-20T00:00:00Z bash "$CAP" \
  --source incident --category "Race in cache invalidation" --summary "incident: stale cache" \
  --repo-root "$WS" >/dev/null 2>&1
if grep -q 'incident: stale cache' "$WS/docs/review/checklist-additions.md" 2>/dev/null \
   && grep -A6 'incident: stale cache' "$WS/docs/review/checklist-additions.md" | grep -qi 'Confidence:.*low'; then
  ok "L1c: a finding with no known bucket is still captured (fail-safe: checklist-additions, low confidence — never dropped)"
else bad "L1c: bucket-less finding was dropped or not low-confidence"; fi

# L1d — required fields enforced (a meaningless entry is refused, exit 2).
bash "$CAP" --source deploy --summary "no category" --repo-root "$WS" >/dev/null 2>&1
[ "$?" = "2" ] && ok "L1d: a finding missing --category is refused (exit 2) — no meaningless capture entry" \
               || bad "L1d: missing-category capture should exit 2"

# ════════════════════════════ LAYER 2 — mechanical gap classification ════════════════════════════

cls() { bash "$DET" "$@" --rubric "$RB" 2>/dev/null | head -1; }

# L2a — BLIND-SPOT: a defect whose CWE matches an existing rule (CWE-117 = §G2.1) that got past the gate.
R="$(cls --category "Log injection" --cwe "CWE-117")"
[ "$R" = "BLIND-SPOT" ] && ok "L2a: CWE-117 defect matches existing rule §G2.1 -> BLIND-SPOT (covered kind escaped)" \
                        || bad "L2a: expected BLIND-SPOT, got '$R'"

# L2a2 — BLIND-SPOT via category-token match (no CWE): 'SSRF' matches §G2.2.
R="$(cls --category "SSRF risk in outbound fetch")"
[ "$R" = "BLIND-SPOT" ] && ok "L2a2: 'SSRF' category-token matches a rule -> BLIND-SPOT" \
                        || bad "L2a2: expected BLIND-SPOT for SSRF, got '$R'"

# L2b — UNCOVERED-CLASS: a defect category no rule covers, not flagged uncoverable.
R="$(cls --category "Timezone offset mishandling in date parsing")"
[ "$R" = "UNCOVERED-CLASS" ] && ok "L2b: a defect with NO matching rule -> UNCOVERED-CLASS (a coverage gap to close)" \
                             || bad "L2b: expected UNCOVERED-CLASS, got '$R'"

# L2c — NEW-COVERAGE: no rule matches AND flagged structurally uncoverable => NOT a blind spot.
R="$(cls --category "Intermittent race only under production load" --uncoverable)"
[ "$R" = "NEW-COVERAGE" ] && ok "L2c: novel, structurally-uncoverable defect -> NEW-COVERAGE (not mislabeled a blind spot)" \
                          || bad "L2c: expected NEW-COVERAGE, got '$R'"

# L2d — gate evidence strengthens BLIND-SPOT: with stage1-clean present at HEAD, the matched rule provably
#       did not fire on a passing gate.
GD="$T/gate"; mkdir -p "$GD"; printf 'HEAD=abc\n' > "$GD/stage1-clean"
OUT="$(bash "$DET" --category "Log injection" --cwe "CWE-117" --rubric "$RB" --gate-evidence "$GD" 2>/dev/null)"
if printf '%s' "$OUT" | head -1 | grep -q 'BLIND-SPOT' && printf '%s' "$OUT" | grep -qi 'affirmatively passed'; then
  ok "L2d: with stage1-clean gate evidence at HEAD -> BLIND-SPOT, basis notes the gate affirmatively passed"
else bad "L2d: gate-evidence-strengthened blind-spot not detected: $(printf '%s' "$OUT" | head -1)"; fi

# ════════════════════════════ THE INTEGRITY TEST (most important) ════════════════════════════
# The classification must be COMPUTED, immune to the working agent's claims about its own culpability.

# I1 — agent CLAIMS "not my fault" on a defect that MECHANICALLY matches a rule -> still BLIND-SPOT.
cat > "$T/excuse.json" <<'JSON'
{ "category": "Log injection", "cwe": "CWE-117",
  "claimedNotMyFault": true, "agentExcuse": "unforeseeable, input looked safe, not a coverage gap",
  "shouldHaveCaught": false }
JSON
RE="$(bash "$DET" --json "$T/excuse.json" --rubric "$RB" 2>/dev/null | head -1)"
[ "$RE" = "BLIND-SPOT" ] && ok "I1: agent claiming 'not my fault' CANNOT suppress a mechanically-provable gap -> BLIND-SPOT" \
                         || bad "I1: excuse suppressed the gap (got '$RE') — INTEGRITY VIOLATION"

# I2 — SAME defect, agent CLAIMS "huge gap, my fault" -> still BLIND-SPOT (same verdict).
cat > "$T/drama.json" <<'JSON'
{ "category": "Log injection", "cwe": "CWE-117",
  "claimedHugeGap": true, "agentDrama": "massive coverage failure, I should obviously have caught this!",
  "shouldHaveCaught": true }
JSON
RD="$(bash "$DET" --json "$T/drama.json" --rubric "$RB" 2>/dev/null | head -1)"
[ "$RD" = "BLIND-SPOT" ] && ok "I2: SAME defect + opposite claim ('huge gap') -> SAME BLIND-SPOT verdict (claim is inert)" \
                         || bad "I2: opposite claim changed the verdict (got '$RD') — INTEGRITY VIOLATION"

# I3 — a genuinely-novel class with agent CLAIMING "huge blind spot!" -> NEW-COVERAGE, NOT manufactured.
cat > "$T/manufacture.json" <<'JSON'
{ "category": "Timezone offset mishandling under DST transition", "uncoverable": true,
  "claimedHugeGap": true, "agentDrama": "this is a catastrophic blind spot in my coverage!!" }
JSON
RM="$(bash "$DET" --json "$T/manufacture.json" --rubric "$RB" 2>/dev/null | head -1)"
[ "$RM" = "NEW-COVERAGE" ] && ok "I3: agent claiming 'huge blind spot' on a novel class CANNOT manufacture one -> NEW-COVERAGE" \
                           || bad "I3: drama manufactured a false blind-spot (got '$RM') — INTEGRITY VIOLATION"

# I4 — the binding property, stated directly: same factual defect, claims flipped => identical classification.
[ "$RE" = "$RD" ] && ok "I4: classification is a PURE FUNCTION of the artifacts (excuse-verdict == drama-verdict == $RE) — not self-assessed" \
                  || bad "I4: claim fields altered the verdict ($RE vs $RD) — the determination is NOT purely computed"

echo ""
echo "coverage-gap-detection tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

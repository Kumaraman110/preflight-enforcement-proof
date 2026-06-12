#!/usr/bin/env bash
# Behavioral test for the unconfigured-coverage default (gap #29 + contradiction finding).
#
# skills/migrate/SKILL.md self-contradicted on the fallback floor applied when
# test.coverageBaseline is null: the Test-migration phase step said 80% while the
# Coverage-discipline block and the Check 5 gate execution said 85%. A dual-sourced
# default is the dead-gate/dual-source bug class (CLAUDE.md rule 5). The fix aligns
# every statement to 85%, makes the Coverage-discipline block the canonical statement,
# and makes defaults/config-template.json legible about what null means.
#
# MECHANISM LABEL: these are PROMPT-LEVEL/doc surfaces (skill prose + config template
# comments the LLM reads), so this test is STRUCTURAL — it greps the shipped sources
# for the load-bearing wording, exactly like convergence-semantics-test.sh. It proves
# the docs carry one coherent number; it cannot prove an LLM obeys it.
#
# Asserts:
#   V1. Exactly one distinct default percentage in fallback contexts: 85% present in
#       BOTH known SKILL.md contexts AND in the Check 5 fallback (echo "85.0"), AND
#       '80%' absent from the entire file (pre-fix, 80 appeared only at the
#       contradicting line, so global absence is the correct pin).
#   V2. The two contexts cross-reference each other (single-source discipline: the
#       Coverage-discipline block is canonical; the phase step says it must match).
#   V3. defaults/config-template.json parses (jq -e) AND its test-block comment
#       documents the 85% fallback + the explicit-pin guidance (e.g. 96.0).
#   V4. The template comment states test thresholds are NOT locally overridable via
#       config.local.json (pins the lib/config-overlay.sh allowlist linkage).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MIG="$ROOT/skills/migrate/SKILL.md"
TPL="$ROOT/defaults/config-template.json"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

for f in "$MIG" "$TPL"; do
  [ -f "$f" ] || { bad "missing source file $f"; echo ""; echo "coverage-default-consistency tests: ${PASS} passed, ${FAIL} failed"; exit 1; }
done

# --- V1: one distinct default percentage across all fallback contexts -------------
if grep -q 'default to 85%' "$MIG"; then
  ok "V1a: Test-migration phase step states the 85% fallback"
else bad "V1a: Test-migration phase step does not state 'default to 85%'"; fi

if grep -q 'default 85%' "$MIG"; then
  ok "V1b: Coverage-discipline block states the 85% fallback"
else bad "V1b: Coverage-discipline block does not state 'default 85%'"; fi

if grep -qE 'echo "85\.0"' "$MIG"; then
  ok "V1c: Check 5 gate execution falls back to 85.0"
else bad "V1c: Check 5 COVERAGE_FLOOR fallback is not 85.0"; fi

if ! grep -q '80%' "$MIG"; then
  ok "V1d: '80%' absent from SKILL.md (no competing default survives)"
else bad "V1d: '80%' still present in SKILL.md — the contradiction is back"; fi

# --- V2: the two contexts cross-reference each other -------------------------------
if grep 'default to 85%' "$MIG" | grep -q 'Coverage discipline'; then
  ok "V2a: phase step names the canonical Coverage-discipline statement (must-match)"
else bad "V2a: phase step does not cross-reference the Coverage-discipline section"; fi

if grep 'default 85%' "$MIG" | grep -qi 'canonical'; then
  ok "V2b: Coverage-discipline block is marked the canonical statement of the default"
else bad "V2b: Coverage-discipline block is not marked canonical"; fi

if grep 'default 85%' "$MIG" | grep -q 'Test migration'; then
  ok "V2c: canonical statement names the phase step that must match it"
else bad "V2c: canonical statement does not name the Test-migration phase step"; fi

# --- V3: template parses and documents the null semantics --------------------------
if jq -e . "$TPL" >/dev/null 2>&1; then
  ok "V3a: defaults/config-template.json is valid JSON (jq -e)"
else bad "V3a: defaults/config-template.json fails jq -e"; fi

TCOMMENT="$(jq -r '.test._comment_coverageBaseline // ""' "$TPL" 2>/dev/null)"
if printf '%s' "$TCOMMENT" | grep -q '85%'; then
  ok "V3b: template test comment documents the 85% migrate-skill fallback"
else bad "V3b: template test comment missing the 85% fallback"; fi

if printf '%s' "$TCOMMENT" | grep -qE 'explicit number|96\.0'; then
  ok "V3c: template test comment carries the explicit-pin guidance (e.g. 96.0)"
else bad "V3c: template test comment missing explicit-pin guidance"; fi

# --- V4: not locally overridable (overlay-allowlist linkage) ------------------------
if printf '%s' "$TCOMMENT" | grep -q 'config.local.json' \
   && printf '%s' "$TCOMMENT" | grep -qiE 'NOT overridable|not overridable'; then
  ok "V4: template comment states test.* is NOT overridable via config.local.json"
else bad "V4: template comment missing the not-locally-overridable statement"; fi

echo ""
echo "coverage-default-consistency tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

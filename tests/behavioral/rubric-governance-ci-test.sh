#!/usr/bin/env bash
# Behavioral test for .github/workflows/rubric-governance.yaml — the ADVISORY-FIRST CI step (Model B).
#
# WHAT IT CHECKS: the workflow is valid YAML, wires BOTH governance checks (no-weaken overlay-check +
# provenance source-check), is genuinely ADVISORY (each check step ends `exit 0` so a violation reports
# but does not block), uses the dead-gate-safe exit-capture idiom (set +e around the call — the trap the
# parity CI steps documented), and documents the advisory→blocking promotion path.
#
# Proves:
#   W1 — workflow file exists and is valid YAML.
#   W2 — it triggers on rubric paths (pull_request paths include rubrics/overlay/lib rubric scripts).
#   W3 — it wires the no-weaken overlay-check AND the provenance source-check.
#   W4 — ADVISORY: each check step ends `exit 0` (a violation surfaces, does not block). This is the
#        load-bearing "advisory-first" property.
#   W5 — DEAD-GATE-SAFE: the exit code is captured via `set +e ... rc=$? ... set -e` (not a bare call that
#        errexit would abort before reporting) — the documented parity-CI idiom.
#   W6 — documents the promotion path (advisory→blocking) AND that it must become a required check to
#        actually block (the same ceiling as the parity job).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WF="$ROOT/.github/workflows/rubric-governance.yaml"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$WF" ]; then
  bad "workflow not found at $WF"; echo ""; echo "rubric-governance-ci tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi

# W1 — valid YAML (python yaml if available; else a lightweight structural fallback).
PY=""
for c in python3 python; do command -v "$c" &>/dev/null && "$c" -c "pass" &>/dev/null 2>&1 && PY="$c" && break; done
if [ -n "$PY" ] && "$PY" -c "import yaml" >/dev/null 2>&1; then
  # Open with explicit utf-8: the workflow contains box-drawing/emoji chars in comments, and this
  # Windows python defaults to cp1252 for open() — without encoding='utf-8' the READ fails (a console
  # quirk), NOT a YAML error. We must test the YAML, not the platform's default codec.
  if "$PY" -c "import yaml,sys; yaml.safe_load(open(sys.argv[1], encoding='utf-8'))" "$WF" >/dev/null 2>&1; then
    ok "W1: workflow is valid YAML"
  else
    bad "W1: workflow is NOT valid YAML"
  fi
else
  # Fallback: must have the top-level keys.
  grep -qE '^name:' "$WF" && grep -qE '^on:' "$WF" && grep -qE '^jobs:' "$WF" \
    && ok "W1: workflow has name/on/jobs (yaml lib unavailable — structural check)" \
    || bad "W1: workflow missing top-level name/on/jobs"
fi

# W2 — triggers on rubric paths.
grep -qE 'examples/rubrics|rubrics/\*\*|rubric-overlay-check' "$WF" \
  && ok "W2: triggers on rubric/overlay paths" \
  || bad "W2: no rubric-path trigger"

# W3 — wires both checks.
HAS_OVERLAY="$(grep -c 'rubric-overlay-check.sh' "$WF")"
HAS_SOURCE="$(grep -c 'rubric-source-check.sh' "$WF")"
[ "$HAS_OVERLAY" -ge 1 ] && [ "$HAS_SOURCE" -ge 1 ] \
  && ok "W3: wires both the no-weaken overlay-check and the provenance source-check" \
  || bad "W3: missing a check (overlay-check=$HAS_OVERLAY, source-check=$HAS_SOURCE)"

# W4 — ADVISORY: each check step ends `exit 0`. Expect >= 2 advisory exit-0 lines (one per check step).
ADV="$(grep -cE '^[[:space:]]*exit 0[[:space:]]*$' "$WF")"
[ "$ADV" -ge 2 ] \
  && ok "W4: ADVISORY — $ADV check steps end 'exit 0' (violations report but do not block)" \
  || bad "W4: expected ≥2 'exit 0' advisory step-ends, found $ADV — may not be advisory-first"

# W5 — dead-gate-safe exit capture (set +e around the call).
SETPE="$(grep -c 'set +e' "$WF")"
[ "$SETPE" -ge 2 ] && grep -q 'set -e' "$WF" \
  && ok "W5: DEAD-GATE-SAFE — exit captured via 'set +e ... set -e' around each check call ($SETPE sites)" \
  || bad "W5: missing the set +e/set -e exit-capture idiom (dead-gate trap risk), found $SETPE"

# W6 — promotion path + required-check ceiling documented.
grep -qiE 'PROMOTE|advisory.*blocking|blocking' "$WF" && grep -qiE 'required (status )?check' "$WF" \
  && ok "W6: documents advisory→blocking promotion AND the 'required check' ceiling to actually block" \
  || bad "W6: missing promotion-path / required-check documentation"

echo ""
echo "rubric-governance-ci tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

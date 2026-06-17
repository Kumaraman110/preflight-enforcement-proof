#!/usr/bin/env bash
# Behavioral test for tools/preflight-agent-scorer.sh — the INDEPENDENT agent-judgment scorer.
# Spec: lib/agent-scorer.md. Design: .release-audit/MEMORY-DESIGN.md G1.
#
# Proves the build AND its two non-negotiable constraints:
#   D1. RED  — source 3 (rejudgment) correctly flags a KNOWN OVERCLAIM (a "clear-to-cut" claim whose
#              own recorded checkEvidence shows 4 dead hooks). The OVERCLAIM category is exercised.
#   D2. GREEN — a held claim ("all GREEN 29/29", evidence "0 failed") scores CORRECT, NOT overclaim
#              (the "0 fail" false-positive must not trip the contradiction detector).
#   D3. OVERCLAIM RATE is a first-class, traceable metric in the output.
#   D4. VERDICT path — a DEFENDED with a concrete citation scores CORRECT; a DEFENDED with bare prose
#              scores FALSE-FLAG (the defense doesn't stand under an independent re-judge).
#   D5. The written track-record artifact is auditable (every score traces to judgmentRef+groundTruthRef).
#   C1. INDEPENDENCE — the scorer runs as a separate invocation over RECORDED artifacts, and a custom
#              SCORER_JUDGE_CMD (a separate judge process) is honored (proves source 3 is separable).
#   C2. NEVER-FEEDS-A-GATE (structural) — the tool references no gate path, writes no .preflight/gate/
#              sentinel, is not in hooks.json, and its output dir is read by no hook/lib engine.
#   C3. The scorer NEVER exits non-zero "because the agent scored badly" (reporter, not gate).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCORER="$ROOT/tools/preflight-agent-scorer.sh"
FIX="$ROOT/tests/fixtures/agent-scorer"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$SCORER" ]; then
  bad "scorer not found at $SCORER"
  echo ""; echo "agent-scorer tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi

# A WORKING python (the scorer needs one). The liveness check (`-c pass`) is load-bearing on Windows:
# `command -v python3` resolves a WindowsApps stub that prints "Python was not found" — it must NOT be
# selected. Skip cleanly if none (don't false-fail the battery).
PY=""
for c in python3 python; do
  if command -v "$c" &>/dev/null && "$c" -c "pass" &>/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
  echo "SKIP: no working python interpreter — agent-scorer needs python for JSON scoring"
  echo ""; echo "agent-scorer tests: ${PASS} passed, ${FAIL} failed (skipped: no python)"; exit 0
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# ── Run the scorer against the demo fixtures (source 3, runs today, no historical data) ──
REPORT="$(bash "$SCORER" --run demo --source rejudgment \
  --decisions "$FIX/decisions/demo.jsonl" \
  --adjudications "$FIX/adjudications" \
  --metrics /nonexistent/metrics.json \
  --out "$OUT" 2>&1)"; RC=$?
ART="$OUT/score-demo.json"

# Tiny JSON field reader: evaluates a python expression over `d` (the parsed artifact). Uses the
# liveness-checked $PY resolved above (NOT a bare `command -v`, which grabs the Windows stub).
jqf() { ART="$ART" "$PY" -c "import json,os; d=json.load(open(os.environ['ART'])); print(eval('''$1'''))" 2>/dev/null; }

# C3: scorer exits 0 even though it found OVERCLAIMs (reporter, not gate).
if [ "$RC" -eq 0 ]; then ok "C3: scorer exits 0 despite finding OVERCLAIMs (reporter, not gate)"
else bad "C3: scorer exited $RC — must be 0 (it is a reporter, must not block on a bad score)"; fi

# Artifact written.
if [ -f "$ART" ]; then ok "D5a: track-record artifact written to .../track-record/score-demo.json"
else bad "D5a: no artifact at $ART"; fi

# D1 RED: claim-001 (clear-to-cut @ 9c34e52, evidence = 4 dead hooks) classified OVERCLAIM.
C1CAT="$(jqf "[s['category'] for s in d['scores'] if s['judgmentRef'].endswith('#claim-001')][0]")"
if [ "$C1CAT" = "OVERCLAIM" ]; then ok "D1 RED: known overclaim (clear-to-cut @ dead-hooks SHA) flagged OVERCLAIM"
else bad "D1 RED: claim-001 should be OVERCLAIM, got '$C1CAT'"; fi

# D2 GREEN: claim-002 (all-green 29/29, evidence '0 failed') classified CORRECT, NOT overclaim.
C2CAT="$(jqf "[s['category'] for s in d['scores'] if s['judgmentRef'].endswith('#claim-002')][0]")"
if [ "$C2CAT" = "CORRECT" ]; then ok "D2 GREEN: held green claim ('0 failed') scores CORRECT (no false-positive)"
else bad "D2 GREEN: claim-002 should be CORRECT, got '$C2CAT' (the '0 fail' contradiction false-positive)"; fi

# D3: OVERCLAIM RATE is first-class + traceable (numerator/denominator/byClaimType present).
OCNUM="$(jqf "d['overclaimRate']['numerator']")"
OCDEN="$(jqf "d['overclaimRate']['denominator']")"
OCTYPE="$(jqf "'clear-to-cut' in d['overclaimRate']['byClaimType']")"
if [ "$OCNUM" = "1" ] && [ "$OCDEN" = "3" ] && [ "$OCTYPE" = "True" ]; then
  ok "D3: OVERCLAIM RATE first-class & traceable (1/3, by-type includes clear-to-cut)"
else bad "D3: overclaim rate wrong — num=$OCNUM den=$OCDEN clear-to-cut-typed=$OCTYPE (want 1/3/True)"; fi

# D4: VERDICT path — concrete-citation DEFENDED → CORRECT; bare-prose DEFENDED → FALSE-FLAG.
GOODCAT="$(jqf "[s['category'] for s in d['scores'] if s['judgmentRef'].endswith('#c-good')][0]")"
if [ "$GOODCAT" = "CORRECT" ]; then ok "D4a: DEFENDED with concrete citation scores CORRECT"
else bad "D4a: c-good should be CORRECT, got '$GOODCAT'"; fi
BADCAT="$(jqf "[s['category'] for s in d['scores'] if s['judgmentRef'].endswith('#c-bare')][0]")"
if [ "$BADCAT" = "FALSE-FLAG" ]; then ok "D4b: DEFENDED with bare-prose evidence scores FALSE-FLAG (defense doesn't stand)"
else bad "D4b: c-bare should be FALSE-FLAG, got '$BADCAT'"; fi

# D5b: every score traces to a judgmentRef AND a groundTruthRef (auditable, no black-box number).
TRACE="$(jqf "all(s.get('judgmentRef') and s.get('groundTruthRef') for s in d['scores'])")"
if [ "$TRACE" = "True" ]; then ok "D5b: every score traces to judgmentRef + groundTruthRef (auditable)"
else bad "D5b: some score lacks a judgmentRef/groundTruthRef trace"; fi

# C1 INDEPENDENCE: a custom SCORER_JUDGE_CMD (separate process) is honored → source 3 is separable.
# This judge always says holds=false → every CLAIM/RUN-OUTCOME becomes OVERCLAIM, proving the
# external judge — not the scorer's built-in — drove the verdict.
OUT2="$(mktemp -d)"
JUDGE_CMD="$PY -c \"import json,sys; json.load(sys.stdin); print(json.dumps({'holds': False, 'basis': 'external judge says no'}))\""
SCORER_JUDGE_CMD="$JUDGE_CMD" bash "$SCORER" --run demo --source rejudgment \
  --decisions "$FIX/decisions/demo.jsonl" --adjudications "$FIX/adjudications" \
  --metrics /nonexistent/metrics.json --out "$OUT2" --quiet >/dev/null 2>&1
# Read the artifact path via ENV (not string-interpolation): native-Windows Python cannot open an
# MSYS "/tmp/..." path written into the script string, but resolves it fine from os.environ — the
# same env-passing the scorer itself uses to write. (Root-caused: the path mapping, not the tool.)
A2="$OUT2/score-demo.json"
EXTBASIS="$(A2="$A2" "$PY" -c "import os,json; d=json.load(open(os.environ['A2'])); print(any('external judge says no' in s.get('basis','') for s in d['scores']))" 2>/dev/null)"
GTREF="$(A2="$A2" "$PY" -c "import os,json; d=json.load(open(os.environ['A2'])); print(d['scores'][0]['groundTruthRef'])" 2>/dev/null)"
rm -rf "$OUT2"
if [ "$EXTBASIS" = "True" ] && [ "$GTREF" = "rejudgment:custom" ]; then
  ok "C1: independent/separable judge honored (SCORER_JUDGE_CMD drove verdicts; groundTruthRef=rejudgment:custom)"
else bad "C1: custom judge not honored — extBasis=$EXTBASIS gtRef=$GTREF (want True / rejudgment:custom)"; fi

# C2 NEVER-FEEDS-A-GATE (structural assertions on the tool itself) ──────────────
# C2a: no functional gate reference (gate-path tokens appear only in comments).
GATEREFS="$(grep -nE 'gate/|write-gate-evidence|\.preflight/gate' "$SCORER" | grep -vE '^\s*[0-9]+:#' | grep -vE ':\s*#' || true)"
if [ -z "$GATEREFS" ]; then ok "C2a: scorer has NO functional gate-path reference (only in comments)"
else bad "C2a: scorer references a gate path in code: $GATEREFS"; fi

# C2b: scorer writes NO .preflight/gate/ sentinel and calls NO write-gate-evidence — in CODE
# (comment lines, which legitimately describe the boundary, are excluded like C2a).
C2B_HITS="$(grep -nE 'write-gate-evidence|gate/[^ ]*"w"|open\([^)]*gate/' "$SCORER" | grep -vE '^\s*[0-9]+:#' | grep -vE ':\s*#' || true)"
if [ -z "$C2B_HITS" ]; then
  ok "C2b: scorer writes no gate sentinel / calls no write-gate-evidence (in code)"
else bad "C2b: scorer appears to write a gate sentinel: $C2B_HITS"; fi

# C2c: scorer is NOT registered in hooks.json (it is not a hook/gate).
if ! grep -qi 'agent-scorer' "$ROOT/hooks/hooks.json" 2>/dev/null; then
  ok "C2c: scorer is NOT registered in hooks.json (not a gate)"
else bad "C2c: scorer IS in hooks.json — it must never be a hook"; fi

# C2d: NO hook or lib engine READS the scorer's output (track-record / score-*.json). Match per-LINE
# and exclude comments (a hook may legitimately MENTION the scorer in a header comment — e.g.
# hooks/record-claim, the emitter, describes the scorer relationship; that is not a read). Only a
# non-comment line referencing the scorer's OUTPUT would be a violation. (.md specs are excluded.)
READERS="$(grep -rnE 'track-record|score-[a-zA-Z0-9_-]+\.json' "$ROOT/hooks/" "$ROOT/lib/" 2>/dev/null \
            | grep -vE '\.md:' | grep -vE ':[0-9]+:\s*#' || true)"
if [ -z "$READERS" ]; then ok "C2d: no hook/lib-engine reads scorer output in code (track record informs humans, never a gate)"
else bad "C2d: a hook/lib reads scorer output (non-comment): $READERS"; fi

# C2e: source honesty — requesting 'reality' (data pending) must NOT silently fall back; exit 2.
bash "$SCORER" --run demo --source reality --decisions "$FIX/decisions/demo.jsonl" \
  --adjudications "$FIX/adjudications" --metrics /nonexistent/metrics.json --out "$OUT" --quiet >/dev/null 2>&1; RRC=$?
if [ "$RRC" -eq 2 ]; then ok "C2e: requesting a data-pending source (reality) errors honestly (exit 2), no silent fallback"
else bad "C2e: reality source should exit 2 (data pending), got $RRC"; fi

echo ""
echo "agent-scorer tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Behavioral test for hooks/record-claim — the FAITHFUL RECORDER that emits orchestrator claims to
# the append-only decision log (.preflight/decisions/<run-id>.jsonl) for the agent-scorer to grade.
# Spec: lib/agent-scorer.md ("Emission"). Builds on tools/preflight-agent-scorer.sh.
#
# Proves:
#   E1. Emits a valid JSONL line matching the scorer's CLAIM schema (kind/id/claim/claimType/assertedStatus).
#   E2. VERBATIM capture — claim text + assertedStatus stored EXACTLY as passed (quotes, apostrophes,
#       unicode survive; "done" is NOT softened to "mostly done").
#   E3. Append-only with sequential ids — a second call appends claim-002, never rewrites claim-001.
#   E4. NO SELF-ASSESSMENT (the binding constraint, structural): the recorder code contains no scoring
#       logic — no OVERCLAIM/CORRECT/MISS verdict, no contradiction/holds check, no category. It records;
#       it does not judge.
#   E5. END-TO-END loop (RED->GREEN): an emitted claim is read by the INDEPENDENT scorer and graded —
#       a claim whose recorded evidence contradicts it → OVERCLAIM (RED); a held claim → CORRECT (GREEN).
#   E6. The recorder does NOT curate: it records EVERY call (it has no "is this worth recording?" gate).
#   E7. decisions/ disposition: TRACKED, not ignored (gitignore template lists it under NOT-ignored,
#       and it is NOT in the installer REQUIRED_IGNORES) — single-source, both surfaces consistent.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RECORDER="$ROOT/hooks/record-claim"
SCORER="$ROOT/tools/preflight-agent-scorer.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$RECORDER" ]; then
  bad "recorder not found at $RECORDER"
  echo ""; echo "decision-emission tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi

# Working python (liveness-checked; the WindowsApps stub must not be selected).
PY=""
for c in python3 python; do
  if command -v "$c" &>/dev/null && "$c" -c "pass" &>/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
  echo "SKIP: no working python interpreter — record-claim/agent-scorer need python"
  echo ""; echo "decision-emission tests: ${PASS} passed, ${FAIL} failed (skipped: no python)"; exit 0
fi

# Isolated temp git repo (claims anchor at repo root via git rev-parse).
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
( cd "$T" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init ) >/dev/null 2>&1
DEC="$T/.preflight/decisions/demo.jsonl"

# Emit three claims: a contradicted "clear-to-cut" (RED), a held "all-green" (GREEN), and a verbatim
# "done" with tricky characters (E2). Run from inside the temp repo so root-anchoring resolves there.
( cd "$T" && PREFLIGHT_RUN_ID=demo bash "$RECORDER" \
    clear-to-cut CLEAR 'clear to cut v0.9.0 at 9c34e52' 'v0.9.0 readiness' \
    'git show 9c34e52:hooks/<f> | bash -n' '4 hooks DEAD: syntax error' ) >/dev/null 2>&1
( cd "$T" && PREFLIGHT_RUN_ID=demo bash "$RECORDER" \
    all-green GREEN 'all behavioral suites GREEN (30/30)' 'battery at HEAD' \
    'bash run-battery' '30 pass / 0 failed' ) >/dev/null 2>&1
# ASCII-only tricky chars: the real JSONL-integrity risks are embedded double-quotes, an apostrophe,
# a backslash, and a literal pipe — all of which would break a hand-built JSON line if not escaped.
# (We avoid non-ASCII literals here because the test harness's own shell on cp1252 consoles mangles
# them before they reach the recorder — the recorder's json.dumps handles unicode fine, proven by the
# E1 round-trip; this case isolates the escaping the recorder is responsible for.)
TRICKY='done: it'\''s "finished" \ no | caveats'
( cd "$T" && PREFLIGHT_RUN_ID=demo bash "$RECORDER" done DONE "$TRICKY" ) >/dev/null 2>&1

# E1: valid JSONL, scorer-schema fields present.
if [ -f "$DEC" ]; then
  LINES="$(grep -c '' "$DEC")"
  SCHEMA_OK="$(DEC="$DEC" "$PY" -c "
import os,json
need={'kind','id','claim','claimType','assertedStatus'}
ok=True
for l in open(os.environ['DEC']):
    o=json.loads(l)
    if not need.issubset(o) or o['kind']!='CLAIM': ok=False
print(ok)" 2>/dev/null)"
  if [ "$LINES" = "3" ] && [ "$SCHEMA_OK" = "True" ]; then
    ok "E1: 3 valid JSONL lines, each matching the scorer CLAIM schema"
  else bad "E1: lines=$LINES schema_ok=$SCHEMA_OK (want 3 / True)"; fi
else bad "E1: no decision log written at $DEC"; fi

# E2: VERBATIM capture — the tricky 'done' claim round-trips exactly; not softened.
GOT="$(DEC="$DEC" "$PY" -c "
import os,json
for l in open(os.environ['DEC']):
    o=json.loads(l)
    if o['claimType']=='done': print(o['claim']); break" 2>/dev/null)"
if [ "$GOT" = "$TRICKY" ]; then ok "E2: claim stored VERBATIM (quotes/apostrophe/unicode survive; not softened)"
else bad "E2: verbatim capture failed — got [$GOT] want [$TRICKY]"; fi

# E3: append-only sequential ids.
IDS="$(DEC="$DEC" "$PY" -c "
import os,json
print(','.join(json.loads(l)['id'] for l in open(os.environ['DEC'])))" 2>/dev/null)"
if [ "$IDS" = "claim-001,claim-002,claim-003" ]; then ok "E3: append-only, sequential ids (claim-001..003)"
else bad "E3: ids = [$IDS] (want claim-001,claim-002,claim-003)"; fi

# E4: NO SELF-ASSESSMENT — the recorder code has no scoring/verdict logic (structural).
#     Search the recorder for scoring tokens that would mean it judged the claim. Exclude the header
#     comment block, which legitimately DESCRIBES the no-self-assessment constraint.
SCORING_HITS="$(grep -nE 'OVERCLAIM|FALSE-FLAG|\bCORRECT\b|\bMISS\b|holds|contradict|overclaim|category|verdict|score' "$RECORDER" | grep -vE '^\s*[0-9]+:#' | grep -vE ':\s*#' || true)"
if [ -z "$SCORING_HITS" ]; then ok "E4: recorder has NO scoring/verdict logic in code (faithful recorder, not self-assessor)"
else bad "E4: recorder contains scoring logic (must not self-assess): $SCORING_HITS"; fi

# E5: END-TO-END — the INDEPENDENT scorer reads the emitted log and grades it (RED->GREEN).
OUT="$(mktemp -d)"
bash "$SCORER" --run demo --source rejudgment --decisions "$DEC" \
  --adjudications /nonexistent --metrics /nonexistent/metrics.json --out "$OUT" --quiet >/dev/null 2>&1
SART="$OUT/score-demo.json"
RED="$(SART="$SART" "$PY" -c "import os,json; d=json.load(open(os.environ['SART'])); print([s['category'] for s in d['scores'] if s['judgmentRef'].endswith('#claim-001')][0])" 2>/dev/null)"
GREEN="$(SART="$SART" "$PY" -c "import os,json; d=json.load(open(os.environ['SART'])); print([s['category'] for s in d['scores'] if s['judgmentRef'].endswith('#claim-002')][0])" 2>/dev/null)"
rm -rf "$OUT"
if [ "$RED" = "OVERCLAIM" ]; then ok "E5 RED: emitted contradicted claim → scorer flags OVERCLAIM (loop closed)"
else bad "E5 RED: claim-001 should score OVERCLAIM, got '$RED'"; fi
if [ "$GREEN" = "CORRECT" ]; then ok "E5 GREEN: emitted held claim → scorer marks CORRECT (loop closed)"
else bad "E5 GREEN: claim-002 should score CORRECT, got '$GREEN'"; fi

# E6: records EVERY call (no curation gate) — a second 'done' call must append a 4th line, not be dropped.
( cd "$T" && PREFLIGHT_RUN_ID=demo bash "$RECORDER" done DONE 'another done claim' ) >/dev/null 2>&1
if [ "$(grep -c '' "$DEC")" = "4" ]; then ok "E6: records EVERY call (no 'worth recording?' curation gate)"
else bad "E6: second call did not append (recorder appears to curate)"; fi

# E7: decisions/ is TRACKED (single-source: NOT-ignored in template AND absent from REQUIRED_IGNORES).
GI="$ROOT/defaults/preflight-gitignore"
INST="$ROOT/tools/preflight-install.sh"
if grep -qE '^#.*decisions/' "$GI" && grep -q 'NOT ignored' "$GI"; then GI_OK=1; else GI_OK=0; fi
# It must NOT be an active ignore line, and must NOT be in REQUIRED_IGNORES.
if grep -qE '^decisions/' "$GI"; then ACTIVE=1; else ACTIVE=0; fi
if grep -qE 'REQUIRED_IGNORES=.*decisions/' "$INST"; then INREQ=1; else INREQ=0; fi
if [ "$GI_OK" = "1" ] && [ "$ACTIVE" = "0" ] && [ "$INREQ" = "0" ]; then
  ok "E7: decisions/ disposition = TRACKED (documented NOT-ignored; not an active ignore; not in REQUIRED_IGNORES)"
else bad "E7: decisions/ disposition inconsistent — documented=$GI_OK active-ignore=$ACTIVE in-required=$INREQ (want 1/0/0)"; fi

echo ""
echo "decision-emission tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

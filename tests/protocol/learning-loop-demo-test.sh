#!/usr/bin/env bash
# Behavioral test: the two-service learning-loop demo (stretch goal).
#
# Proves the learning property end to end AND that promotion is gated by a human approval:
#   - ServiceN's drift escapes the initial ruleset;
#   - promotion WITHOUT a valid approval FAILS CLOSED (ruleset unchanged → ServiceN+1 still escapes);
#   - promotion WITH a valid, approver-signed approval succeeds → ServiceN+1 equivalent drift is CAUGHT;
#   - an approval signed with the WRONG (non-approver) key CANNOT promote (no self-promotion).
# Deterministic: injected --now, throwaway approver key, fixed fixtures.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

if ! _probe_python; then
  bad "no working python3/python (fail-closed: NOT green)"; echo ""; echo "learning-loop-demo: ${PASS} passed, ${FAIL} failed"; exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NOW="2026-07-11T09:30:00Z"; EXP="2026-07-11T10:30:00Z"
APPROVER_KEY="$TMP/approver.key"; printf 'security-lead-approver-key\n' > "$APPROVER_KEY"
WRONG_KEY="$TMP/wrong.key"; printf 'engine-cannot-self-promote\n' > "$WRONG_KEY"

# Mint a signed approval for the proposed rule id (the demo binds intentId = rule id,
# commitSha = the fixed demo placeholder).
mint() {  # $1 out  $2 key-file  $3 intentId
  ( cd "$PROTO_ROOT" && "$PF_PY" - "$1" "$2" "$3" "$EXP" <<'PY'
import sys, json
sys.path.insert(0,'verifier')
from pfverify import approval
out,keyf,iid,exp = sys.argv[1:5]
key=open(keyf,'rb').read().strip()
a=approval.build_approval(intent_id=iid, commit_sha="0000000000000000000000000000000000000000",
                          approver_id="security-lead", issued_at="2026-07-11T09:00:00Z", expires_at=exp)
json.dump(approval.sign_approval(a,key), open(out,'w',encoding='utf-8'))
PY
)
}
run_demo() {  # $1 approval-path(or "") $2 key-file(or "") ; echoes json, sets DRC
  local ap=() ; [ -n "$1" ] && ap=(--approval "$1")
  local kf=() ; [ -n "$2" ] && kf=(--approval-key-file "$2")
  DEMO_OUT="$( cd "$PROTO_ROOT" && "$PF_PY" -m verifier.demo.learning_loop "${ap[@]}" "${kf[@]}" --now "$NOW" 2>/dev/null )"
  DRC=$?
}
field() { printf '%s' "$1" | "$PF_PY" -c "import sys,json;print(json.load(sys.stdin).get('$2'))"; }

# ── 1. NO approval → drift escapes, promotion fails closed, ServiceN+1 NOT caught, loop NOT proven ──
run_demo "" ""
ESC="$(field "$DEMO_OUT" serviceN_drift_escaped)"
PROMO="$(field "$DEMO_OUT" promoted)"
CAUGHT="$(field "$DEMO_OUT" serviceN1_equivalent_drift_caught)"
[ "$ESC" = "True" ] && ok "ServiceN drift escapes the initial ruleset" || bad "drift did not escape (got $ESC)"
[ "$PROMO" = "False" ] && ok "promotion WITHOUT approval fails closed (ruleset unchanged)" || bad "promoted without approval! ($PROMO)"
[ "$CAUGHT" = "False" ] && ok "ServiceN+1 drift NOT caught without the promoted rule" || bad "caught without promotion?! ($CAUGHT)"
[ "$DRC" = 1 ] && ok "loop NOT proven without approval (exit 1)" || bad "unexpected demo exit ($DRC)"

# ── 2. WRONG key (engine self-mint) → cannot promote ─────────────────────────────────────────────────
mint "$TMP/appr_wrong.json" "$WRONG_KEY" "INSECURE-DESERIALIZE"
run_demo "$TMP/appr_wrong.json" "$APPROVER_KEY"
[ "$(field "$DEMO_OUT" promoted)" = "False" ] && ok "approval signed with WRONG key cannot promote (no self-promotion)" || bad "wrong-key approval promoted!"

# ── 3. VALID approval → promotion succeeds, ServiceN+1 equivalent drift CAUGHT, loop proven ─────────
mint "$TMP/appr_ok.json" "$APPROVER_KEY" "INSECURE-DESERIALIZE"
run_demo "$TMP/appr_ok.json" "$APPROVER_KEY"
[ "$(field "$DEMO_OUT" promoted)" = "True" ] && ok "valid approval promotes the adjudicated rule" || bad "valid approval did not promote"
[ "$(field "$DEMO_OUT" serviceN1_equivalent_drift_caught)" = "True" ] && ok "ServiceN+1 equivalent drift CAUGHT locally after promotion" || bad "ServiceN+1 drift not caught after promotion"
[ "$(field "$DEMO_OUT" loop_proven)" = "True" ] && ok "learning loop PROVEN (escaped→adjudicated→approved-promotion→caught)" || bad "loop not proven"
[ "$DRC" = 0 ] && ok "demo exit 0 on proven loop" || bad "demo exit not 0 ($DRC)"

# ── 4. WRONG rule id in approval → binding mismatch, no promotion ────────────────────────────────────
mint "$TMP/appr_wid.json" "$APPROVER_KEY" "SOME-OTHER-RULE"
run_demo "$TMP/appr_wid.json" "$APPROVER_KEY"
[ "$(field "$DEMO_OUT" promoted)" = "False" ] && ok "approval for a different rule id cannot promote (binding)" || bad "wrong-rule-id approval promoted!"

# ── 5. DETERMINISM: identical inputs → byte-identical demo output ────────────────────────────────────
run_demo "$TMP/appr_ok.json" "$APPROVER_KEY"; O1="$DEMO_OUT"
run_demo "$TMP/appr_ok.json" "$APPROVER_KEY"; O2="$DEMO_OUT"
[ "$O1" = "$O2" ] && ok "demo deterministic (byte-identical on repeat)" || bad "demo non-deterministic"

echo ""
echo "learning-loop-demo: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

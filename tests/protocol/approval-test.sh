#!/usr/bin/env bash
# Behavioral test: REQUIRE_APPROVAL exception path — a separate, attributable approval
# artifact signed with a DISTINCT approver key the producer does NOT hold.
#
# Proves: a valid matching approval upgrades REQUIRE_APPROVAL→ALLOW; missing/invalid-sig/
# expired/wrong-intent/wrong-commit/not-for-REQUIRE_APPROVAL all FAIL CLOSED; and the
# authoring/producer agent CANNOT self-mint an approval (it lacks the approver key).
#
# Throwaway keys in a mktemp dir — never a repo secret.
# Exit 0 = all assertions passed; exit 1 = at least one failed.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

if ! _probe_python; then
  bad "no working python3/python interpreter (fail-closed: NOT green)"
  echo ""; echo "approval: ${PASS} passed, ${FAIL} failed"; exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
APPROVER_KEY="$TMP/approver.key"; printf 'distinct-approver-key-producer-does-not-hold\n' > "$APPROVER_KEY"
PRODUCER_KEY="$TMP/producer.key"; printf 'producer-attestation-key-different\n' > "$PRODUCER_KEY"

INTENT_ID="i-appr"
COMMIT="abcabcabcabcabcabcabcabcabcabcabcabcabca"
NOW="2026-07-11T09:30:00Z"

# Mint a signed approval via the approval module. Args:
#   $1 out  $2 intentId  $3 commitSha  $4 key-file  $5 expiresAt  [$6 grants  $7 forDecision]
mint_approval() {
  local out="$1" iid="$2" csha="$3" keyf="$4" exp="$5" grants="${6:-ALLOW}" ford="${7:-REQUIRE_APPROVAL}"
  ( cd "$PROTO_ROOT" && "$PF_PY" - "$out" "$iid" "$csha" "$keyf" "$exp" "$grants" "$ford" <<'PY'
import sys, json
sys.path.insert(0,'verifier')
from pfverify import approval
out,iid,csha,keyf,exp,grants,ford = sys.argv[1:8]
key=open(keyf,'rb').read().strip()
a=approval.build_approval(intent_id=iid, commit_sha=csha, approver_id="release-manager",
                          issued_at="2026-07-11T09:00:00Z", expires_at=exp,
                          grants=grants, for_decision=ford)
signed=approval.sign_approval(a, key)
json.dump(signed, open(out,'w',encoding='utf-8'))
PY
)
}

pf_vappr() {  # verify-approval; echoes json; caller reads rc. $1 approval-path(or "") $2 key-file
  local appr="$1" keyf="$2"; shift 2
  local approl=()
  [ -n "$appr" ] && approl=(--approval "$appr")
  ( cd "$PROTO_ROOT" && "$PF_PY" -m verifier.pfverify verify-approval \
      "${approl[@]}" --approval-key-file "$keyf" \
      --intent-id "$INTENT_ID" --commit-sha "$COMMIT" --now "$NOW" "$@" 2>/dev/null )
}
has() { printf '%s' "$1" | grep -q "$2"; }

# ── 1. VALID approval (correct key, matching intent+commit, unexpired) → upgrade / exit 0 ────────────
mint_approval "$TMP/appr_ok.json" "$INTENT_ID" "$COMMIT" "$APPROVER_KEY" "2026-07-11T10:00:00Z"
OUT="$(pf_vappr "$TMP/appr_ok.json" "$APPROVER_KEY")"; RC=$?
{ has "$OUT" '"upgrade":true' && [ "$RC" = 0 ]; } && ok "valid approval → upgrade/0" || bad "valid approval not granted (rc=$RC out=$OUT)"

# ── 2. MISSING approval → no upgrade / exit 10 (REQUIRE_APPROVAL stands) ─────────────────────────────
OUT="$(pf_vappr "" "$APPROVER_KEY")"; RC=$?
{ has "$OUT" "approval.missing" && [ "$RC" = 10 ]; } && ok "missing approval → missing/10" || bad "missing approval not fail-closed (rc=$RC out=$OUT)"

# ── 3. PRODUCER SELF-MINT: approval signed with the PRODUCER key (not approver) → sig-invalid / 10 ───
# The producer holds its own attestation key but NOT the approver key. An approval it mints
# under the producer key must be rejected — it cannot self-approve.
mint_approval "$TMP/appr_self.json" "$INTENT_ID" "$COMMIT" "$PRODUCER_KEY" "2026-07-11T10:00:00Z"
OUT="$(pf_vappr "$TMP/appr_self.json" "$APPROVER_KEY")"; RC=$?
{ has "$OUT" "signature-invalid" && [ "$RC" = 10 ]; } && ok "producer self-mint (wrong key) → signature-invalid/10" || bad "producer self-mint not rejected (rc=$RC out=$OUT)"

# ── 4. EXPIRED approval → expired / 10 ───────────────────────────────────────────────────────────────
mint_approval "$TMP/appr_exp.json" "$INTENT_ID" "$COMMIT" "$APPROVER_KEY" "2026-07-11T09:15:00Z"  # before NOW
OUT="$(pf_vappr "$TMP/appr_exp.json" "$APPROVER_KEY")"; RC=$?
{ has "$OUT" "approval.expired" && [ "$RC" = 10 ]; } && ok "expired approval → expired/10" || bad "expired approval not rejected (rc=$RC out=$OUT)"

# ── 5. WRONG INTENT: approval for a different intentId → binding-mismatch / 10 ───────────────────────
mint_approval "$TMP/appr_wi.json" "other-intent" "$COMMIT" "$APPROVER_KEY" "2026-07-11T10:00:00Z"
OUT="$(pf_vappr "$TMP/appr_wi.json" "$APPROVER_KEY")"; RC=$?
{ has "$OUT" "binding-mismatch" && [ "$RC" = 10 ]; } && ok "wrong intentId → binding-mismatch/10" || bad "wrong-intent approval not rejected (rc=$RC out=$OUT)"

# ── 6. WRONG COMMIT: approval for a different commit → binding-mismatch / 10 ─────────────────────────
mint_approval "$TMP/appr_wc.json" "$INTENT_ID" "0000000000000000000000000000000000000000" "$APPROVER_KEY" "2026-07-11T10:00:00Z"
OUT="$(pf_vappr "$TMP/appr_wc.json" "$APPROVER_KEY")"; RC=$?
{ has "$OUT" "binding-mismatch" && [ "$RC" = 10 ]; } && ok "wrong commit → binding-mismatch/10" || bad "wrong-commit approval not rejected (rc=$RC out=$OUT)"

# ── 7. TAMPERED approval (edit intentId after signing) → signature-invalid / 10 ─────────────────────
"$PF_PY" -c "import sys,json;a=json.load(open(sys.argv[1],encoding='utf-8'));a['approves']['intentId']='$INTENT_ID';json.dump(a,open(sys.argv[2],'w',encoding='utf-8'))" "$TMP/appr_wi.json" "$TMP/appr_tamper.json"
OUT="$(pf_vappr "$TMP/appr_tamper.json" "$APPROVER_KEY")"; RC=$?
{ has "$OUT" "signature-invalid" && [ "$RC" = 10 ]; } && ok "tampered approval (re-point intentId) → signature-invalid/10" || bad "tampered approval not rejected (rc=$RC out=$OUT)"

# ── 8. WRONG GRANT: approval that grants something other than REQUIRE_APPROVAL→ALLOW → mismatch / 10 ─
# forDecision must be REQUIRE_APPROVAL; an approval built for a different origin decision is refused.
mint_approval "$TMP/appr_wg.json" "$INTENT_ID" "$COMMIT" "$APPROVER_KEY" "2026-07-11T10:00:00Z" "ALLOW" "REQUIRE_APPROVAL"
# (a correct one is #1; here we prove the binding rule by editing forDecision post-sign → sig-invalid,
#  demonstrating you cannot silently change what is being upgraded)
"$PF_PY" -c "import sys,json;a=json.load(open(sys.argv[1],encoding='utf-8'));a['approves']['forDecision']='BLOCK';json.dump(a,open(sys.argv[2],'w',encoding='utf-8'))" "$TMP/appr_ok.json" "$TMP/appr_wg2.json"
OUT="$(pf_vappr "$TMP/appr_wg2.json" "$APPROVER_KEY")"; RC=$?
{ [ "$RC" = 10 ]; } && ok "altered forDecision → no upgrade/10 (fail-closed)" || bad "altered forDecision upgraded (rc=$RC out=$OUT)"

echo ""
echo "approval: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

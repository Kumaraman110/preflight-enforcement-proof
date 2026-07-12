#!/usr/bin/env bash
# Phase-4 INTEGRATION FIXTURE: a deterministic, offline GitHub-equivalent that exercises the
# full two-stage remote gate (trusted gate machinery + untrusted subject commit) and proves the
# seven required positive/adversarial cases end to end — with no network, no real GitHub, no
# secrets, and WITHOUT touching the dirty pilot.
#
# It models the hardened workflow precisely:
#   • a TRUSTED package root = this repo's own committed verifier+policy (--pkg-root);
#   • an UNTRUSTED subject = a throwaway git checkout the "PR" produced (--repo-root);
#   • ephemeral throwaway attest + approver keys (never repo secrets);
#   • the gate run via verifier/ci/remote-gate.sh exactly as Stage 2 invokes it.
#
# Cases proven:
#   1. valid evidence passes (ALLOW → exit 0 + signed attestation);
#   2. forged local ALLOW fails (subject HEAD != claimed head → BLOCK);
#   3. wrong commit fails;
#   4. tampered attestation fails (verify-attestation rejects);
#   5. producer self-approval fails (approval signed with non-approver key);
#   6. separate valid approval succeeds (REQUIRE_APPROVAL → approved → exit 0);
#   7. workflow failure cannot be interpreted as approval (BLOCK/REQUIRE_APPROVAL exit != 0;
#      and a fork that TAMPERS the policy in its own tree cannot force ALLOW — trusted pkg-root wins).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

if ! _probe_python; then
  bad "no working python3/python (fail-closed: NOT green)"; echo ""; echo "integration-fixture: ${PASS} passed, ${FAIL} failed"; exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  bad "git unavailable"; echo ""; echo "integration-fixture: ${PASS} passed, ${FAIL} failed"; exit 1
fi

GATE="$PROTO_ROOT/verifier/ci/remote-gate.sh"
POLICY_REL="protocol/policies/push-safety.v1.policy.json"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NOW="2026-07-11T09:05:00Z"; EXP="2026-07-11T10:05:00Z"
SLUG="United-Airlines-Org/preflight"
ATTEST_KEY="$TMP/attest.key"; printf 'ci-attest-key\n' > "$ATTEST_KEY"
APPROVER_KEY="$TMP/approver.key"; printf 'ci-approver-key-distinct\n' > "$APPROVER_KEY"
PRODUCER_KEY="$TMP/producer.key"; printf 'producer-key\n' > "$PRODUCER_KEY"
# BUNDLE key authenticates the producer's evidence (incl. the tier claim). The deployed workflow
# provisions it + passes --require-bundle-attestation; the fixture models that hardened config.
BUNDLE_KEY="$TMP/bundle.key"; printf 'ci-bundle-key\n' > "$BUNDLE_KEY"

# Build a "subject" checkout (what actions/checkout of the PR head yields). $1=tier $2=name → sets SUBJ + SHEAD
build_subject() {
  local tier="$1" name="$2"
  SUBJ="$TMP/subject-$name"; mkdir -p "$SUBJ/artifacts"
  git init -q "$SUBJ"
  ( cd "$SUBJ" && git config user.email t@t && git config user.name T && git config commit.gpgsign false \
      && git remote add origin "https://github.com/$SLUG.git" )
  printf 'all tests passed\n' > "$SUBJ/artifacts/tests.log"
  printf 'tier=%s\n' "$tier"  > "$SUBJ/artifacts/tier.txt"
  ( cd "$SUBJ" && git add -A && git commit -q -m init )
  SHEAD="$( cd "$SUBJ" && git rev-parse HEAD )"
}

# Build the producer's claim (intent+bundle) for a given head+tier, sealed against the subject tree.
# By default the bundle is HMAC-signed with the trusted BUNDLE key (models an authentic producer);
# pass a 5th arg = key file to sign with a DIFFERENT key (a forgery), or "" to leave unsigned.
build_claim() {  # $1 head  $2 tier  $3 subject-dir  $4 outdir  [$5 bundle-key(default $BUNDLE_KEY; ""=unsigned)]
  local head="$1" tier="$2" subj="$3" out="$4"; mkdir -p "$out"
  local bkey; if [ "$#" -ge 5 ]; then bkey="$5"; else bkey="$BUNDLE_KEY"; fi
  cat > "$out/intent.json" <<EOF
{"schemaVersion":"1.0.0","intentId":"i-fix","action":{"type":"git-push","attributes":{"remote":"origin","refspec":"HEAD:main"}},"actor":{"kind":"model","id":"claude"},"subject":{"repo":"github.com/$SLUG","head":"$head","branch":"main"}}
EOF
  cat > "$out/bundle.json" <<EOF
{"schemaVersion":"1.0.0","intentRef":{"intentId":"i-fix","subjectHead":"$head"},"issuer":{"adapter":"preflight-test","version":"0.1.0"},"evidence":[{"type":"tests-pass","producedAt":"2026-07-11T09:00:00Z","boundHead":"$head","artifact":{"path":"artifacts/tests.log","sha256":"0"},"claims":{"passed":true}},{"type":"push-tier","producedAt":"2026-07-11T09:00:05Z","boundHead":"$head","artifact":{"path":"artifacts/tier.txt","sha256":"0"},"claims":{"tier":"$tier"}}],"attestation":{"algo":"sha256","bundleDigest":"0"}}
EOF
  local sealargs=(--bundle "$out/bundle.json" --evidence-root "$subj")
  [ -n "$bkey" ] && sealargs+=(--attestation-key-file "$bkey")
  ( cd "$PROTO_ROOT" && "$PF_PY" verifier/tools/seal_bundle.py "${sealargs[@]}" >/dev/null )
}

# Stage 2 invocation: TRUSTED pkg-root = the real repo; subject = the (untrusted) checkout.
stage2() {  # $1 claim-dir  $2 subject-dir  [extra args] ; sets GRC + ODIR
  ODIR="$TMP/out-$RANDOM$RANDOM"; mkdir -p "$ODIR"
  local approval=(); [ -f "$1/approval.json" ] && approval=(--approval "$1/approval.json")
  bash "$GATE" \
    --pkg-root "$PROTO_ROOT" --repo-root "$2" \
    --intent "$1/intent.json" --bundle "$1/bundle.json" \
    --policy "$POLICY_REL" \
    --now "$NOW" --issued-at "$NOW" --expires-at "$EXP" --expected-repo "$SLUG" \
    --run-id "fix-run" --nonce "fix-nonce" --out-dir "$ODIR" \
    --attest-key-file "$ATTEST_KEY" --approval-key-file "$APPROVER_KEY" \
    --bundle-key-file "$BUNDLE_KEY" \
    --require-attestation --require-bundle-attestation "${approval[@]}" "${@:3}" >/dev/null 2>&1
  GRC=$?
}
mint_approval() {  # $1 out  $2 key  $3 head
  ( cd "$PROTO_ROOT" && "$PF_PY" - "$1" "$2" "$3" "$EXP" <<'PY'
import sys, json
sys.path.insert(0,'verifier')
from pfverify import approval
out,keyf,head,exp = sys.argv[1:5]
key=open(keyf,'rb').read().strip()
a=approval.build_approval(intent_id="i-fix", commit_sha=head, approver_id="release-manager",
                          issued_at="2026-07-11T09:00:00Z", expires_at=exp)
json.dump(approval.sign_approval(a,key), open(out,'w',encoding='utf-8'))
PY
)
}

# ── CASE 1: valid evidence passes ────────────────────────────────────────────────────────────────────
build_subject AUTO valid
build_claim "$SHEAD" AUTO "$SUBJ" "$TMP/claim1"
stage2 "$TMP/claim1" "$SUBJ"
[ "$GRC" = 0 ] && ok "case1 valid evidence → exit 0 (ALLOW)" || bad "case1 valid evidence not ALLOW (rc=$GRC)"
[ -s "$ODIR/attestation.json" ] && ok "case1 signed attestation produced" || bad "case1 no attestation"

# ── CASE 2: forged local ALLOW fails (claim a FAKE head; subject HEAD differs) ───────────────────────
build_claim "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" AUTO "$TMP/fake2" "$TMP/claim2"
# seal against a fake tree so the local producer "believed" ALLOW; verify remotely vs real subject.
mkdir -p "$TMP/fake2/artifacts"; printf 'all tests passed\n' > "$TMP/fake2/artifacts/tests.log"; printf 'tier=AUTO\n' > "$TMP/fake2/artifacts/tier.txt"
build_claim "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" AUTO "$TMP/fake2" "$TMP/claim2"
stage2 "$TMP/claim2" "$SUBJ"
[ "$GRC" != 0 ] && ok "case2 forged local ALLOW → non-zero ($GRC) — cannot pass remotely" || bad "case2 forged ALLOW passed! (rc=$GRC)"

# ── CASE 3: wrong commit fails (claim a real-looking but different 40-hex head) ──────────────────────
build_claim "0000000000000000000000000000000000000000" AUTO "$SUBJ" "$TMP/claim3"
stage2 "$TMP/claim3" "$SUBJ"
[ "$GRC" = 20 ] && ok "case3 wrong commit → BLOCK exit 20" || bad "case3 wrong commit not BLOCK (rc=$GRC)"

# ── CASE 4: tampered attestation fails (produce a valid one, tamper, re-verify) ─────────────────────
build_claim "$SHEAD" AUTO "$SUBJ" "$TMP/claim4"; stage2 "$TMP/claim4" "$SUBJ"
[ -s "$ODIR/attestation.json" ] || bad "case4 setup: no attestation to tamper"
"$PF_PY" -c "import sys,json;a=json.load(open(sys.argv[1],encoding='utf-8'));a['commitSha']='1111111111111111111111111111111111111111';json.dump(a,open(sys.argv[2],'w',encoding='utf-8'))" "$ODIR/attestation.json" "$TMP/att_tampered.json"
OUT="$( cd "$PROTO_ROOT" && "$PF_PY" -m verifier.pfverify verify-attestation --attestation "$TMP/att_tampered.json" --attest-key-file "$ATTEST_KEY" --now "2026-07-11T09:30:00Z" 2>/dev/null )"; VRC=$?
{ printf '%s' "$OUT" | grep -q "forged" && [ "$VRC" = 20 ]; } && ok "case4 tampered attestation → rejected (forged/20)" || bad "case4 tamper not rejected (rc=$VRC out=$OUT)"

# ── CASE 5: producer self-approval fails (approval signed with the PRODUCER key, not approver) ──────
build_subject CONFIRM selfappr
build_claim "$SHEAD" CONFIRM "$SUBJ" "$TMP/claim5"
mint_approval "$TMP/claim5/approval.json" "$PRODUCER_KEY" "$SHEAD"   # WRONG key
stage2 "$TMP/claim5" "$SUBJ"
[ "$GRC" = 10 ] && ok "case5 producer self-approval → still exit 10 (cannot self-approve)" || bad "case5 self-approval passed! (rc=$GRC)"

# ── CASE 6: separate valid approval succeeds (REQUIRE_APPROVAL + approver-signed approval) ──────────
build_claim "$SHEAD" CONFIRM "$SUBJ" "$TMP/claim6"
mint_approval "$TMP/claim6/approval.json" "$APPROVER_KEY" "$SHEAD"   # CORRECT approver key
stage2 "$TMP/claim6" "$SUBJ"
[ "$GRC" = 0 ] && ok "case6 valid separate approval → exit 0" || bad "case6 valid approval did not pass (rc=$GRC)"

# ── CASE 7a: workflow failure cannot be read as approval — BLOCK/REQUIRE_APPROVAL are non-zero ──────
build_subject CONFIRM noappr
build_claim "$SHEAD" CONFIRM "$SUBJ" "$TMP/claim7"
stage2 "$TMP/claim7" "$SUBJ"
[ "$GRC" = 10 ] && ok "case7a REQUIRE_APPROVAL with no approval → exit 10 (non-success, not a pass)" || bad "case7a unexpected (rc=$GRC)"

# ── CASE 7b: FORK ATTACK — subject tree TAMPERS the policy to force ALLOW; trusted pkg-root wins ────
# The untrusted subject checkout contains its OWN protocol/policies/... that maps everything to ALLOW.
# Because Stage 2 runs the verifier + policy from --pkg-root (trusted), the subject's policy is ignored.
build_subject BLOCK forkatk
mkdir -p "$SUBJ/protocol/policies"
cat > "$SUBJ/protocol/policies/push-safety.v1.policy.json" <<'EOF'
{"schemaVersion":"1.0.0","policyId":"push-safety.v1","appliesTo":{"actionType":"git-push"},"requiredEvidence":[],"freshnessWindowSeconds":999999999,"tierDecisionMap":{"AUTO":"ALLOW","CONFIRM":"ALLOW","BLOCK":"ALLOW"},"tierEvidenceType":"push-tier","tierClaimKey":"tier"}
EOF
# Also plant a malicious verifier in the subject to prove it is NOT executed.
mkdir -p "$SUBJ/verifier/pfverify"; printf 'print("ALLOW")\n' > "$SUBJ/verifier/pfverify/__main__.py"
( cd "$SUBJ" && git add -A && git commit -q -m "malicious: force ALLOW" )
SHEAD="$( cd "$SUBJ" && git rev-parse HEAD )"
build_claim "$SHEAD" BLOCK "$SUBJ" "$TMP/claim7b"
# Stage 2 uses --pkg-root = TRUSTED repo (real BLOCK policy), --repo-root = the malicious subject.
stage2 "$TMP/claim7b" "$SUBJ"
[ "$GRC" = 20 ] && ok "case7b FORK policy/verifier tamper → still BLOCK exit 20 (trusted pkg-root wins)" || bad "case7b fork tamper forced non-BLOCK! (rc=$GRC)"

# ── CASE 8: FORK EVIDENCE FORGERY — self-classified tier=AUTO in a bundle NOT signed by the bundle key ─
# Under the hardened deployed config (--require-bundle-attestation + trusted PREFLIGHT_BUNDLE_KEY), a
# fork that writes tier=AUTO into its own evidence and signs the bundle with its OWN (wrong) key is
# rejected: the bundle signature does not verify under the trusted bundle key → BLOCK. This closes the
# evidence-authenticity gap the final adversarial review flagged.
build_subject AUTO forgeevid   # subject genuinely at AUTO tier, but the producer is untrusted
FORK_KEY="$TMP/fork.key"; printf 'fork-controlled-key\n' > "$FORK_KEY"
build_claim "$SHEAD" AUTO "$SUBJ" "$TMP/claim8" "$FORK_KEY"   # signed with the WRONG (fork) bundle key
stage2 "$TMP/claim8" "$SUBJ"
[ "$GRC" = 20 ] && ok "case8 fork-forged evidence (wrong bundle key) → BLOCK exit 20 (evidence authenticity enforced)" || bad "case8 forged evidence not blocked (rc=$GRC)"
# And the honest producer (correct bundle key) still passes:
build_subject AUTO honestprod; build_claim "$SHEAD" AUTO "$SUBJ" "$TMP/claim8b"   # default = correct BUNDLE_KEY
stage2 "$TMP/claim8b" "$SUBJ"
[ "$GRC" = 0 ] && ok "case8b honest producer (correct bundle key) → ALLOW exit 0" || bad "case8b honest producer blocked (rc=$GRC)"

echo ""
echo "integration-fixture: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

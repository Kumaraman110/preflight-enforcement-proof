#!/usr/bin/env bash
# OFFLINE model of the sandbox three-job Stage-2 flow (generator → sealer → judge), with the
# same artifact hand-off the GitHub workflow uses. Proves the full adversarial matrix with NO
# network / NO GitHub / NO real secrets — so the design is validated before any live mutation.
#
# Job roles (least-privilege, disjoint secrets):
#   A generate-evidence.sh  — NO signing secret; INDEPENDENTLY derives tier+tests from subject C
#   B seal-claim.sh         — ONLY bundle key; signs the generator's bundle
#   C remote-gate.sh (judge)— ONLY attest key (+approval key); trusted verifier/policy from base
#
# Exit 0 = all assertions passed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"   # repo root = trusted "default branch" checkout
GATE="$REPO/gate"
GATEENTRY="$REPO/verifier/ci/remote-gate.sh"
POLICY_REL="protocol/policies/push-safety.v1.policy.json"

PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

PF_PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { "$c" -c 'import sys;sys.exit(0 if sys.version_info[0]>=3 else 1)' && PF_PY="$c" && break; }; done
[ -n "$PF_PY" ] || { bad "no python"; echo "offline-flow: $PASS passed, $FAIL failed"; exit 1; }
command -v git >/dev/null 2>&1 || { bad "no git"; echo "offline-flow: $PASS passed, $FAIL failed"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SLUG="owner/preflight-enforcement-proof"
NOW="2026-07-12T09:05:00Z"; EXP="2026-07-12T10:05:00Z"
export PF_PRODUCED_AT="2026-07-12T09:00:00Z"

# Throwaway keys (never real secrets)
BUNDLE_KEY="$TMP/bundle.key"; printf 'test-bundle-key\n' > "$BUNDLE_KEY"
ATTEST_KEY="$TMP/attest.key"; printf 'test-attest-key\n' > "$ATTEST_KEY"
APPROVER_KEY="$TMP/approver.key"; printf 'test-approver-key-distinct\n' > "$APPROVER_KEY"
PRODUCER_KEY="$TMP/producer.key"; printf 'a-producer-key-not-approver\n' > "$PRODUCER_KEY"

# Build a BASE repo (the "default branch" tree) so the subject has a real base to diff against.
BASEREPO="$TMP/base"; mkdir -p "$BASEREPO/app/safe" "$BASEREPO/app/review" "$BASEREPO/app/protected"
git init -q "$BASEREPO"
( cd "$BASEREPO" && git config user.email t@t && git config user.name T && git config commit.gpgsign false \
    && git remote add origin "https://github.com/$SLUG.git" )
printf 'base\n' > "$BASEREPO/app/safe/a.txt"
printf 'base\n' > "$BASEREPO/app/review/r.txt"
printf 'base\n' > "$BASEREPO/app/protected/p.txt"
( cd "$BASEREPO" && git add -A && git commit -q -m base )
BASE_SHA="$( cd "$BASEREPO" && git rev-parse HEAD )"

# make_subject <name> <change-path> <pr-authored-tier-hint> → SUBJ + HEAD  (clones base, adds a change)
make_subject(){
  local name="$1" cpath="$2" hint="$3"
  local S="$TMP/subject-$name"
  git clone -q "$BASEREPO" "$S"
  ( cd "$S" && git config user.email t@t && git config user.name T && git config commit.gpgsign false )
  mkdir -p "$S/$(dirname "$cpath")"; printf 'changed by PR\n' >> "$S/$cpath"
  # The UNTRUSTED PR ships raw evidence hints in-tree (this is "an untrusted PR produces evidence").
  mkdir -p "$S/.gate/artifacts"
  printf 'pr says tests passed\n' > "$S/.gate/artifacts/tests.log"
  printf 'tier=%s\n' "$hint"      > "$S/.gate/artifacts/tier.txt"   # PR-authored HINT (untrusted)
  ( cd "$S" && git add -A && git commit -q -m "$name change" )
  SUBJ="$S"; HEAD="$( cd "$S" && git rev-parse HEAD )"
}

# run_flow <subject> <out> [judge-extra-args...] → sets RC (judge exit) + ODIR
# Models A→B→C with the artifact hand-off (evidence copied out by A, reconstructed by C).
run_flow(){
  local subj="$1" claim="$2"; shift 2; mkdir -p "$claim"
  # JOB A (no secret): generate authoritative evidence + naked bundle.
  bash "$GATE/generate-evidence.sh" "$subj" "$BASE_SHA" "$HEAD" "$SLUG" "$claim" "$REPO" 2>/dev/null || { RC=97; return; }
  # JOB B (bundle key only): sign the generator's bundle.
  ( export PREFLIGHT_BUNDLE_KEY="$(cat "$BUNDLE_KEY")"; bash "$GATE/seal-claim.sh" "$claim/bundle.json" "$REPO" ) 2>/dev/null || { RC=98; return; }
  # JOB C (attest key only): fresh subject checkout (simulate a clean re-fetch), reconstruct the
  # generator's UNTRACKED evidence from the run-scoped artifact, then run the trusted judge.
  local jsub="$TMP/judge-subject-$RANDOM"; git clone -q "$subj" "$jsub" >/dev/null 2>&1
  ( cd "$jsub" && git remote set-url origin "https://github.com/$SLUG.git" && git checkout -q "$HEAD" )
  mkdir -p "$jsub/.gate/evidence"
  cp "$claim/evidence/tests.log" "$jsub/.gate/evidence/tests.log"
  cp "$claim/evidence/tier.txt"  "$jsub/.gate/evidence/tier.txt"
  ODIR="$TMP/out-$RANDOM$RANDOM"; mkdir -p "$ODIR"
  local approval=(); [ -f "$claim/approval.json" ] && approval=(--approval "$claim/approval.json")
  ( export PREFLIGHT_ATTEST_KEY="$(cat "$ATTEST_KEY")"; export PREFLIGHT_BUNDLE_KEY="$(cat "$BUNDLE_KEY")"; export PREFLIGHT_APPROVAL_KEY="$(cat "$APPROVER_KEY")"
    bash "$GATEENTRY" \
      --pkg-root "$REPO" --repo-root "$jsub" \
      --intent "$claim/intent.json" --bundle "$claim/bundle.json" \
      --policy "$POLICY_REL" --now "$NOW" --issued-at "$NOW" --expires-at "$EXP" \
      --expected-repo "$SLUG" --run-id "off-run" --nonce "off-run-1" \
      --out-dir "$ODIR" --require-attestation --require-bundle-attestation "${approval[@]}" "$@" ) >/dev/null 2>&1
  RC=$?
}

mint_approval(){  # $1 out $2 key $3 head
  ( cd "$REPO" && "$PF_PY" - "$1" "$2" "$3" "$EXP" <<'PY'
import sys, json
sys.path.insert(0,'verifier')
from pfverify import approval
out,keyf,head,exp = sys.argv[1:5]
key=open(keyf,'rb').read().strip()
a=approval.build_approval(intent_id="i-sandbox", commit_sha=head, approver_id="release-manager",
                          issued_at="2026-07-12T09:00:00Z", expires_at=exp)
json.dump(approval.sign_approval(a,key), open(out,'w',encoding='utf-8'))
PY
)
}

# ── CASE 1: valid safe change (app/safe) → generator derives AUTO → ALLOW exit 0 + attestation ──
make_subject valid app/safe/a.txt AUTO
run_flow "$SUBJ" "$TMP/c1"
[ "$RC" = 0 ] && ok "case1 safe change → ALLOW exit 0" || bad "case1 not ALLOW (rc=$RC)"
[ -s "$ODIR/attestation.json" ] && ok "case1 signed decision attestation produced" || bad "case1 no attestation"

# ── CASE 2: FORGED EVIDENCE — PR touches app/protected but lies tier=AUTO in its hint ───────────
#    generator derives BLOCK from the changed path (ignores the PR hint) → BLOCK exit 20.
make_subject forge app/protected/p.txt AUTO
run_flow "$SUBJ" "$TMP/c2"
[ "$RC" = 20 ] && ok "case2 forged tier hint (protected change, PR lies AUTO) → BLOCK exit 20" || bad "case2 forged evidence not blocked (rc=$RC)"

# ── CASE 3: FORGED LOCAL ALLOW — claim a fake head that isn't the subject HEAD → identity BLOCK ──
make_subject forgehead app/safe/a.txt AUTO
run_flow "$SUBJ" "$TMP/c3"
# tamper the sealed claim to name a different head, then re-run ONLY the judge against it
"$PF_PY" -c "import json,sys;i=json.load(open(sys.argv[1]));i['subject']['head']='deadbeefdeadbeefdeadbeefdeadbeefdeadbeef';json.dump(i,open(sys.argv[1],'w'))" "$TMP/c3/intent.json"
"$PF_PY" -c "import json,sys;b=json.load(open(sys.argv[1]));b['intentRef']['subjectHead']='deadbeefdeadbeefdeadbeefdeadbeefdeadbeef';json.dump(b,open(sys.argv[1],'w'))" "$TMP/c3/bundle.json"
jsub="$TMP/judge-c3"; git clone -q "$SUBJ" "$jsub" >/dev/null 2>&1
( cd "$jsub" && git remote set-url origin "https://github.com/$SLUG.git" && git checkout -q "$HEAD" )
mkdir -p "$jsub/.gate/evidence"; cp "$TMP/c3/evidence/"* "$jsub/.gate/evidence/"
ODIR3="$TMP/out-c3"; mkdir -p "$ODIR3"
( export PREFLIGHT_ATTEST_KEY="$(cat "$ATTEST_KEY")"; export PREFLIGHT_BUNDLE_KEY="$(cat "$BUNDLE_KEY")"
  bash "$GATEENTRY" --pkg-root "$REPO" --repo-root "$jsub" --intent "$TMP/c3/intent.json" --bundle "$TMP/c3/bundle.json" \
    --policy "$POLICY_REL" --now "$NOW" --issued-at "$NOW" --expires-at "$EXP" --expected-repo "$SLUG" \
    --run-id r --nonce n --out-dir "$ODIR3" --require-attestation --require-bundle-attestation ) >/dev/null 2>&1
RC3=$?
[ "$RC3" = 20 ] && ok "case3 forged head (local ALLOW claim) → identity BLOCK exit 20" || bad "case3 forged head not blocked (rc=$RC3)"

# ── CASE 4: JUDGE REPLACEMENT — subject tree carries a malicious policy+verifier; trusted wins ──
make_subject judgesub app/protected/p.txt AUTO
# plant malicious trusted-looking files in the subject (must be IGNORED: pkg-root is the base)
mkdir -p "$SUBJ/protocol/policies" "$SUBJ/verifier/pfverify"
cat > "$SUBJ/protocol/policies/push-safety.v1.policy.json" <<'EOF'
{"schemaVersion":"1.0.0","policyId":"push-safety.v1","appliesTo":{"actionType":"git-push"},"requiredEvidence":[],"freshnessWindowSeconds":999999999,"tierDecisionMap":{"AUTO":"ALLOW","CONFIRM":"ALLOW","BLOCK":"ALLOW"},"tierEvidenceType":"push-tier","tierClaimKey":"tier"}
EOF
printf 'print("ALLOW")\n' > "$SUBJ/verifier/pfverify/__main__.py"
( cd "$SUBJ" && git add -A && git commit -q -m "malicious policy+verifier" ); HEAD="$( cd "$SUBJ" && git rev-parse HEAD )"
run_flow "$SUBJ" "$TMP/c4"
[ "$RC" = 20 ] && ok "case4 judge-replacement (malicious policy/verifier in subject) → BLOCK exit 20 (trusted pkg-root wins)" || bad "case4 judge replacement forced non-BLOCK (rc=$RC)"

# ── CASE 5: MISSING AUTHORITY — no bundle key at the sealer → fail closed, never ALLOW ──────────
make_subject noauth app/safe/a.txt AUTO
bash "$GATE/generate-evidence.sh" "$SUBJ" "$BASE_SHA" "$HEAD" "$SLUG" "$TMP/c5" "$REPO" 2>/dev/null
( unset PREFLIGHT_BUNDLE_KEY; bash "$GATE/seal-claim.sh" "$TMP/c5/bundle.json" "$REPO" ) >/dev/null 2>&1
SEALRC=$?
[ "$SEALRC" = 30 ] && ok "case5 sealer with no bundle key → fail-closed exit 30 (never ALLOW)" || bad "case5 sealer didn't fail closed (rc=$SEALRC)"

# ── CASE 6: MISSING AUTHORITY at judge — no attest key + --require-attestation → exit 30 ─────────
make_subject noattest app/safe/a.txt AUTO
run_flow "$SUBJ" "$TMP/c6"   # first a normal seal so the bundle is valid
jsub="$TMP/judge-c6"; git clone -q "$SUBJ" "$jsub" >/dev/null 2>&1
( cd "$jsub" && git remote set-url origin "https://github.com/$SLUG.git" && git checkout -q "$HEAD" )
mkdir -p "$jsub/.gate/evidence"; cp "$TMP/c6/evidence/"* "$jsub/.gate/evidence/"
ODIR6="$TMP/out-c6"; mkdir -p "$ODIR6"
( unset PREFLIGHT_ATTEST_KEY; export PREFLIGHT_BUNDLE_KEY="$(cat "$BUNDLE_KEY")"
  bash "$GATEENTRY" --pkg-root "$REPO" --repo-root "$jsub" --intent "$TMP/c6/intent.json" --bundle "$TMP/c6/bundle.json" \
    --policy "$POLICY_REL" --now "$NOW" --issued-at "$NOW" --expires-at "$EXP" --expected-repo "$SLUG" \
    --run-id r --nonce n --out-dir "$ODIR6" --require-attestation --require-bundle-attestation ) >/dev/null 2>&1
RC6=$?
[ "$RC6" = 30 ] && ok "case6 judge with no attest key → fail-closed exit 30" || bad "case6 judge didn't fail closed (rc=$RC6)"

# ── CASE 7: CONFIRM path — app/review change → generator derives CONFIRM → exit 10 (no approval) ─
make_subject review app/review/r.txt AUTO
run_flow "$SUBJ" "$TMP/c7"
[ "$RC" = 10 ] && ok "case7 review change → REQUIRE_APPROVAL exit 10 (no approval)" || bad "case7 not REQUIRE_APPROVAL (rc=$RC)"

# ── CASE 8: CONFIRM + valid distinct approval → exit 0 ; SELF-APPROVAL (producer key) → exit 10 ──
make_subject approve app/review/r.txt AUTO
run_flow_prep(){ bash "$GATE/generate-evidence.sh" "$SUBJ" "$BASE_SHA" "$HEAD" "$SLUG" "$1" "$REPO" 2>/dev/null; ( export PREFLIGHT_BUNDLE_KEY="$(cat "$BUNDLE_KEY")"; bash "$GATE/seal-claim.sh" "$1/bundle.json" "$REPO" ) >/dev/null 2>&1; }
run_flow_prep "$TMP/c8"
mint_approval "$TMP/c8/approval.json" "$APPROVER_KEY" "$HEAD"
run_flow "$SUBJ" "$TMP/c8b" ; # regenerate cleanly with approval present
cp "$TMP/c8/approval.json" "$TMP/c8b/approval.json"
# re-run judge for c8b WITH approval
jsub="$TMP/judge-c8"; git clone -q "$SUBJ" "$jsub" >/dev/null 2>&1
( cd "$jsub" && git remote set-url origin "https://github.com/$SLUG.git" && git checkout -q "$HEAD" )
mkdir -p "$jsub/.gate/evidence"; cp "$TMP/c8b/evidence/"* "$jsub/.gate/evidence/"
ODIR8="$TMP/out-c8"; mkdir -p "$ODIR8"
( export PREFLIGHT_ATTEST_KEY="$(cat "$ATTEST_KEY")"; export PREFLIGHT_BUNDLE_KEY="$(cat "$BUNDLE_KEY")"; export PREFLIGHT_APPROVAL_KEY="$(cat "$APPROVER_KEY")"
  bash "$GATEENTRY" --pkg-root "$REPO" --repo-root "$jsub" --intent "$TMP/c8b/intent.json" --bundle "$TMP/c8b/bundle.json" \
    --policy "$POLICY_REL" --now "$NOW" --issued-at "$NOW" --expires-at "$EXP" --expected-repo "$SLUG" \
    --run-id r --nonce n --out-dir "$ODIR8" --require-attestation --require-bundle-attestation --approval "$TMP/c8b/approval.json" ) >/dev/null 2>&1
RC8=$?
[ "$RC8" = 0 ] && ok "case8 CONFIRM + valid distinct approval → exit 0" || bad "case8 valid approval didn't upgrade (rc=$RC8)"
# self-approval: sign with the producer key (not the approver key) → stays exit 10
mint_approval "$TMP/c8b/self.json" "$PRODUCER_KEY" "$HEAD"
( export PREFLIGHT_ATTEST_KEY="$(cat "$ATTEST_KEY")"; export PREFLIGHT_BUNDLE_KEY="$(cat "$BUNDLE_KEY")"; export PREFLIGHT_APPROVAL_KEY="$(cat "$APPROVER_KEY")"
  bash "$GATEENTRY" --pkg-root "$REPO" --repo-root "$jsub" --intent "$TMP/c8b/intent.json" --bundle "$TMP/c8b/bundle.json" \
    --policy "$POLICY_REL" --now "$NOW" --issued-at "$NOW" --expires-at "$EXP" --expected-repo "$SLUG" \
    --run-id r --nonce n --out-dir "$TMP/out-c8self" --require-attestation --require-bundle-attestation --approval "$TMP/c8b/self.json" ) >/dev/null 2>&1
RC8S=$?
[ "$RC8S" = 10 ] && ok "case8 self-approval (producer key ≠ approver) → still exit 10" || bad "case8 self-approval upgraded! (rc=$RC8S)"

# ── CASE 9: REPLAY — a valid attestation from case1 re-presented for a DIFFERENT commit → rejected ─
make_subject replay app/safe/a.txt AUTO
run_flow "$SUBJ" "$TMP/c9"
[ -s "$ODIR/attestation.json" ] || bad "case9 setup: no attestation"
# take case9's attestation, verify-attestation but EXPECT a different commit → binding-mismatch
OUT="$( cd "$REPO" && "$PF_PY" -m verifier.pfverify verify-attestation --attestation "$ODIR/attestation.json" \
        --attest-key-file "$ATTEST_KEY" --now "2026-07-12T09:30:00Z" \
        --expect-commit-sha "0000000000000000000000000000000000000000" 2>/dev/null )"; VRC=$?
{ [ "$VRC" = 20 ] && printf '%s' "$OUT" | grep -qi "binding\|mismatch\|forged"; } && ok "case9 replay onto different commit → rejected (exit 20)" || bad "case9 replay not rejected (rc=$VRC out=$OUT)"

echo ""
echo "offline-flow: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

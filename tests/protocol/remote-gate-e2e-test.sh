#!/usr/bin/env bash
# Behavioral test: the CI entrypoint verifier/ci/remote-gate.sh end-to-end, OFFLINE.
#
# Drives the full remote gate against a REAL throwaway git checkout with throwaway keys —
# no network, no GitHub. Proves the decision→exit-code contract usable as a required
# status check: ALLOW→0 (+attestation.json), BLOCK→20, REQUIRE_APPROVAL→10 (no approval),
# REQUIRE_APPROVAL + valid approval→0. Also proves the producer cannot self-approve.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

if ! _probe_python; then
  bad "no working python3/python (fail-closed: NOT green)"; echo ""; echo "remote-gate-e2e: ${PASS} passed, ${FAIL} failed"; exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  bad "git unavailable"; echo ""; echo "remote-gate-e2e: ${PASS} passed, ${FAIL} failed"; exit 1
fi

GATE="$PROTO_ROOT/verifier/ci/remote-gate.sh"
[ -f "$GATE" ] || { bad "entrypoint missing: $GATE"; echo ""; echo "remote-gate-e2e: ${PASS} passed, ${FAIL} failed"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NOW="2026-07-11T09:05:00Z"; EXP="2026-07-11T10:05:00Z"
REPO_SLUG="United-Airlines-Org/preflight"
ATTEST_KEY="$TMP/attest.key"; printf 'ci-attest-key\n' > "$ATTEST_KEY"
APPROVER_KEY="$TMP/approver.key"; printf 'ci-approver-key-distinct\n' > "$APPROVER_KEY"
PRODUCER_KEY="$TMP/producer.key"; printf 'producer-key\n' > "$PRODUCER_KEY"

# Real throwaway checkout with committed artifacts + fake origin.
REPO="$TMP/repo"; mkdir -p "$REPO/artifacts"
git init -q "$REPO"
( cd "$REPO" && git config user.email t@t.test && git config user.name T && git config commit.gpgsign false \
    && git remote add origin "https://github.com/$REPO_SLUG.git" )
printf 'all tests passed\n' > "$REPO/artifacts/tests.log"
printf 'tier=%s\n' AUTO      > "$REPO/artifacts/tier.txt"
( cd "$REPO" && git add -A && git commit -q -m init )
HEAD="$( cd "$REPO" && git rev-parse HEAD )"

# Build a sealed intent+bundle for a given tier, bound to the real head+repo.
mk() {  # $1 tier  $2 out-intent  $3 out-bundle
  cat > "$2" <<EOF
{"schemaVersion":"1.0.0","intentId":"i-ci","action":{"type":"git-push","attributes":{"remote":"origin","refspec":"HEAD:main"}},"actor":{"kind":"model","id":"claude"},"subject":{"repo":"github.com/$REPO_SLUG","head":"$HEAD","branch":"main"}}
EOF
  cat > "$3" <<EOF
{"schemaVersion":"1.0.0","intentRef":{"intentId":"i-ci","subjectHead":"$HEAD"},"issuer":{"adapter":"preflight-test","version":"0.1.0"},"evidence":[{"type":"tests-pass","producedAt":"2026-07-11T09:00:00Z","boundHead":"$HEAD","artifact":{"path":"artifacts/tests.log","sha256":"0"},"claims":{"passed":true}},{"type":"push-tier","producedAt":"2026-07-11T09:00:05Z","boundHead":"$HEAD","artifact":{"path":"artifacts/tier.txt","sha256":"0"},"claims":{"tier":"$1"}}],"attestation":{"algo":"sha256","bundleDigest":"0"}}
EOF
  ( cd "$PROTO_ROOT" && "$PF_PY" verifier/tools/seal_bundle.py --bundle "$3" --evidence-root "$REPO" >/dev/null )
}

run_gate() {  # extra args ; sets GRC + OUTDIR
  OUTDIR="$TMP/out-$RANDOM$RANDOM"; mkdir -p "$OUTDIR"
  bash "$GATE" --repo-root "$REPO" --intent "$1" --bundle "$2" \
    --policy "$PROTO_ROOT/protocol/policies/push-safety.v1.policy.json" \
    --now "$NOW" --issued-at "$NOW" --expires-at "$EXP" --expected-repo "$REPO_SLUG" \
    --out-dir "$OUTDIR" "${@:3}" >/dev/null 2>&1
  GRC=$?
}

# ── 1. ALLOW: AUTO tier → exit 0 + attestation.json written + it verifies ────────────────────────────
mk AUTO "$TMP/ai.json" "$TMP/ab.json"
run_gate "$TMP/ai.json" "$TMP/ab.json" --attest-key-file "$ATTEST_KEY"
[ "$GRC" = 0 ] && ok "gate ALLOW → exit 0" || bad "gate ALLOW wrong exit ($GRC)"
[ -s "$OUTDIR/decision.json" ] && ok "gate wrote decision.json" || bad "no decision.json"
[ -s "$OUTDIR/attestation.json" ] && ok "gate wrote attestation.json on ALLOW" || bad "no attestation.json"
# the emitted attestation verifies under the same key, bound to the real head
if [ -s "$OUTDIR/attestation.json" ]; then
  OUT="$(cd "$PROTO_ROOT" && "$PF_PY" -m verifier.pfverify verify-attestation --attestation "$OUTDIR/attestation.json" --attest-key-file "$ATTEST_KEY" --now "2026-07-11T09:30:00Z" --expect-commit-sha "$HEAD" 2>/dev/null)"
  printf '%s' "$OUT" | grep -q '"ok":true' && ok "emitted attestation verifies + binds real commit" || bad "emitted attestation did not verify ($OUT)"
fi

# ── 2. BLOCK: forbidden tier → exit 20 ───────────────────────────────────────────────────────────────
mk BLOCK "$TMP/bi.json" "$TMP/bb.json"
run_gate "$TMP/bi.json" "$TMP/bb.json" --attest-key-file "$ATTEST_KEY"
[ "$GRC" = 20 ] && ok "gate BLOCK → exit 20" || bad "gate BLOCK wrong exit ($GRC)"

# ── 3. REQUIRE_APPROVAL, no approval → exit 10 (blocks the check) ────────────────────────────────────
mk CONFIRM "$TMP/ci.json" "$TMP/cb.json"
run_gate "$TMP/ci.json" "$TMP/cb.json" --attest-key-file "$ATTEST_KEY"
[ "$GRC" = 10 ] && ok "gate REQUIRE_APPROVAL (no approval) → exit 10" || bad "gate REQUIRE_APPROVAL wrong exit ($GRC)"

# ── 4. REQUIRE_APPROVAL + valid approval → exit 0 ────────────────────────────────────────────────────
( cd "$PROTO_ROOT" && "$PF_PY" - "$TMP/approval.json" "$HEAD" "$APPROVER_KEY" "$EXP" <<'PY'
import sys, json
sys.path.insert(0,'verifier')
from pfverify import approval
out,head,keyf,exp = sys.argv[1:5]
key=open(keyf,'rb').read().strip()
a=approval.build_approval(intent_id="i-ci", commit_sha=head, approver_id="release-manager",
                          issued_at="2026-07-11T09:00:00Z", expires_at=exp)
json.dump(approval.sign_approval(a,key), open(out,'w',encoding='utf-8'))
PY
)
run_gate "$TMP/ci.json" "$TMP/cb.json" --attest-key-file "$ATTEST_KEY" --approval "$TMP/approval.json" --approval-key-file "$APPROVER_KEY"
[ "$GRC" = 0 ] && ok "gate REQUIRE_APPROVAL + valid approval → exit 0" || bad "valid approval did not upgrade ($GRC)"

# ── 5. PRODUCER SELF-APPROVE: approval signed with the PRODUCER key → still exit 10 ─────────────────
( cd "$PROTO_ROOT" && "$PF_PY" - "$TMP/self.json" "$HEAD" "$PRODUCER_KEY" "$EXP" <<'PY'
import sys, json
sys.path.insert(0,'verifier')
from pfverify import approval
out,head,keyf,exp = sys.argv[1:5]
key=open(keyf,'rb').read().strip()
a=approval.build_approval(intent_id="i-ci", commit_sha=head, approver_id="the-producer-itself",
                          issued_at="2026-07-11T09:00:00Z", expires_at=exp)
json.dump(approval.sign_approval(a,key), open(out,'w',encoding='utf-8'))
PY
)
run_gate "$TMP/ci.json" "$TMP/cb.json" --attest-key-file "$ATTEST_KEY" --approval "$TMP/self.json" --approval-key-file "$APPROVER_KEY"
[ "$GRC" = 10 ] && ok "producer self-approve (wrong key) → still exit 10 (cannot self-approve)" || bad "producer self-approve upgraded! ($GRC)"

echo ""
echo "remote-gate-e2e: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

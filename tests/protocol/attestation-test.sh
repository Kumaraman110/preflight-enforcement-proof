#!/usr/bin/env bash
# Behavioral test: DECISION ATTESTATION — signed, tamper-evident, replay-resistant.
#
# Proves: a valid attestation verifies; tamper/wrong-key/expiry/replay-across-
# commit-or-action-or-repo all FAIL CLOSED; and signature verification is a separately
# testable function. Determinism: identical inputs produce byte-identical signed bytes.
#
# Uses THROWAWAY HMAC keys in a mktemp dir — never a repo secret.
# Exit 0 = all assertions passed; exit 1 = at least one failed.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

if ! _probe_python; then
  bad "no working python3/python interpreter (fail-closed: NOT green)"
  echo ""; echo "attestation: ${PASS} passed, ${FAIL} failed"; exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
KEY="$TMP/attest.key"; printf 'independent-env-key-not-in-repo\n' > "$KEY"
WRONG="$TMP/wrong.key"; printf 'attacker-key\n' > "$WRONG"

# A minimal intent + bundle (sealed) to derive action/evidence digests from.
mkdir -p "$TMP/artifacts"; printf 'ok\n' > "$TMP/artifacts/a.txt"
cat > "$TMP/i.json" <<EOF
{"schemaVersion":"1.0.0","intentId":"i-att","action":{"type":"git-push","attributes":{"remote":"origin","refspec":"HEAD:main"}},"actor":{"kind":"model","id":"claude"},"subject":{"repo":"github.com/o/r","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","branch":"main"}}
EOF
cat > "$TMP/b.json" <<EOF
{"schemaVersion":"1.0.0","intentRef":{"intentId":"i-att","subjectHead":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"issuer":{"adapter":"preflight-test","version":"0.1.0"},"evidence":[{"type":"push-tier","producedAt":"2026-07-11T09:00:00Z","boundHead":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","artifact":{"path":"artifacts/a.txt","sha256":"0"},"claims":{"tier":"AUTO"}}],"attestation":{"algo":"sha256","bundleDigest":"0"}}
EOF
( cd "$PROTO_ROOT" && "$PF_PY" verifier/tools/seal_bundle.py --bundle "$TMP/b.json" --evidence-root "$TMP" >/dev/null )
cat > "$TMP/decision.json" <<EOF
{"schemaVersion":"1.0.0","decision":"ALLOW","policyId":"push-safety.v1","intentId":"i-att","evaluatedAt":"2026-07-11T09:05:00Z","reasons":[],"violations":[],"checks":[]}
EOF

COMMIT="1234567890abcdef1234567890abcdef12345678"
REPOID="github.com/o/r"

pf_attest() {  # writes signed attestation to $1 ; extra args after
  local out="$1"; shift
  ( cd "$PROTO_ROOT" && "$PF_PY" -m verifier.pfverify attest \
      --intent "$TMP/i.json" --bundle "$TMP/b.json" --decision "$TMP/decision.json" \
      --repo-id "$REPOID" --commit-sha "$COMMIT" --attest-key-file "$KEY" \
      --issued-at "2026-07-11T09:05:00Z" --expires-at "2026-07-11T10:05:00Z" \
      --run-id "run-1" --nonce "nonce-abc" "$@" > "$out" 2>/dev/null )
}
pf_vatt() {  # verify-attestation; echoes json; caller reads rc. args after the attestation path
  local att="$1"; shift
  ( cd "$PROTO_ROOT" && "$PF_PY" -m verifier.pfverify verify-attestation \
      --attestation "$att" --attest-key-file "$KEY" "$@" 2>/dev/null )
}
jget() { "$PF_PY" -c "import sys,json;print(json.load(sys.stdin).get('$1',''))"; }

# NOTE: MSYS translates path ARGV args to native Windows paths for python.exe, but does
# NOT rewrite a path baked into a `-c` code string. So every python one-liner below takes
# its paths via sys.argv, never embedded.

# Derive independent binding facts (what a remote verifier would re-resolve).
ADIG="$(cd "$PROTO_ROOT" && "$PF_PY" -c "import sys,json;sys.path.insert(0,'verifier');from pfverify import attest;print(attest.action_digest(json.load(open(sys.argv[1],encoding='utf-8'))))" "$TMP/i.json")"
EDIG="$(cd "$PROTO_ROOT" && "$PF_PY" -c "import sys,json;sys.path.insert(0,'verifier');from pfverify import attest;print(attest.evidence_digest(json.load(open(sys.argv[1],encoding='utf-8'))))" "$TMP/b.json")"

# ── 1. produce a signed attestation ──────────────────────────────────────────────────────────────────
pf_attest "$TMP/att.json"; RC=$?
if [ "$RC" = 0 ] && [ -s "$TMP/att.json" ]; then ok "attest: produced signed attestation (rc=0)"; else bad "attest: failed to produce (rc=$RC)"; fi
SIGLEN="$("$PF_PY" -c "import sys,json;print(len(json.load(open(sys.argv[1],encoding='utf-8'))['attestation']['signature']))" "$TMP/att.json" 2>/dev/null)"
[ "$SIGLEN" = 64 ] && ok "attestation carries a 64-hex HMAC signature" || bad "signature length wrong: $SIGLEN"

# ── 2. VALID: correct key + not expired + bound to real facts → ok / exit 0 ──────────────────────────
OUT="$(pf_vatt "$TMP/att.json" --now "2026-07-11T09:30:00Z" --expect-repo-id "$REPOID" --expect-commit-sha "$COMMIT" --expect-action-digest "$ADIG" --expect-evidence-digest "$EDIG")"; RC=$?
V="$(printf '%s' "$OUT" | jget ok)"
{ [ "$V" = "True" ] && [ "$RC" = 0 ]; } && ok "verify-attestation valid → ok/0" || bad "valid attestation not accepted (ok=$V rc=$RC out=$OUT)"

# ── 3. WRONG KEY: attacker key → signature-invalid / 20 ──────────────────────────────────────────────
OUT="$(cd "$PROTO_ROOT" && "$PF_PY" -m verifier.pfverify verify-attestation --attestation "$TMP/att.json" --attest-key-file "$WRONG" --now "2026-07-11T09:30:00Z" 2>/dev/null)"; RC=$?
{ printf '%s' "$OUT" | grep -q "signature-invalid" && [ "$RC" = 20 ]; } && ok "wrong key → signature-invalid/20" || bad "wrong key not rejected (rc=$RC out=$OUT)"

# ── 4. TAMPER: edit a signed field without re-signing → forged (+ signature) / 20 ────────────────────
"$PF_PY" -c "import sys,json;a=json.load(open(sys.argv[1],encoding='utf-8'));a['commitSha']='ffffffffffffffffffffffffffffffffffffffff';json.dump(a,open(sys.argv[2],'w',encoding='utf-8'))" "$TMP/att.json" "$TMP/att_tamper.json"
OUT="$(pf_vatt "$TMP/att_tamper.json" --now "2026-07-11T09:30:00Z")"; RC=$?
{ printf '%s' "$OUT" | grep -q "forged" && [ "$RC" = 20 ]; } && ok "tampered attestation → forged/20" || bad "tamper not caught (rc=$RC out=$OUT)"

# ── 5. EXPIRED: now past expiresAt → expired / 20 ────────────────────────────────────────────────────
OUT="$(pf_vatt "$TMP/att.json" --now "2026-07-11T11:00:00Z")"; RC=$?
{ printf '%s' "$OUT" | grep -q "expired" && [ "$RC" = 20 ]; } && ok "expired attestation → expired/20" || bad "expiry not enforced (rc=$RC out=$OUT)"

# ── 6. REPLAY across COMMIT: bind to a different commit → binding-mismatch / 20 ──────────────────────
OUT="$(pf_vatt "$TMP/att.json" --now "2026-07-11T09:30:00Z" --expect-commit-sha "0000000000000000000000000000000000000000")"; RC=$?
{ printf '%s' "$OUT" | grep -q "binding-mismatch" && [ "$RC" = 20 ]; } && ok "replay onto other commit → binding-mismatch/20" || bad "commit replay not caught (rc=$RC out=$OUT)"

# ── 7. REPLAY across ACTION: bind to a different action digest → binding-mismatch / 20 ───────────────
OUT="$(pf_vatt "$TMP/att.json" --now "2026-07-11T09:30:00Z" --expect-action-digest "0000000000000000000000000000000000000000000000000000000000000000")"; RC=$?
{ printf '%s' "$OUT" | grep -q "binding-mismatch" && [ "$RC" = 20 ]; } && ok "replay onto other action → binding-mismatch/20" || bad "action replay not caught (rc=$RC out=$OUT)"

# ── 8. REPLAY across REPO: bind to a different repoId → binding-mismatch / 20 ────────────────────────
OUT="$(pf_vatt "$TMP/att.json" --now "2026-07-11T09:30:00Z" --expect-repo-id "github.com/attacker/evil")"; RC=$?
{ printf '%s' "$OUT" | grep -q "binding-mismatch" && [ "$RC" = 20 ]; } && ok "replay onto other repo → binding-mismatch/20" || bad "repo replay not caught (rc=$RC out=$OUT)"

# ── 9. DETERMINISM: identical inputs → byte-identical signed attestation ─────────────────────────────
pf_attest "$TMP/att_a.json"; pf_attest "$TMP/att_b.json"
if diff -q "$TMP/att_a.json" "$TMP/att_b.json" >/dev/null 2>&1; then ok "attestation deterministic (byte-identical on repeat)"; else bad "attestation non-deterministic"; fi

# ── 10. SEPARATELY-TESTABLE signature function (verify_signature) ────────────────────────────────────
( cd "$PROTO_ROOT" && "$PF_PY" - "$TMP/att.json" "$KEY" "$WRONG" <<'PY'
import sys, json
sys.path.insert(0,'verifier')
from pfverify import attest
att=json.load(open(sys.argv[1],encoding='utf-8'))
key=open(sys.argv[2],'rb').read().strip()
wrong=open(sys.argv[3],'rb').read().strip()
good = attest.verify_signature(att, key)
bad_key = attest.verify_signature(att, wrong)
# tamper a field -> verify_signature must be False (payloadDigest recompute mismatch)
att2=dict(att); att2['nonce']='x'
tampered = attest.verify_signature(att2, key)
sys.exit(0 if (good and not bad_key and not tampered) else 1)
PY
)
[ $? -eq 0 ] && ok "verify_signature() separately testable (good=True, wrong-key=False, tampered=False)" || bad "verify_signature() behaved wrongly"

echo ""
echo "attestation: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

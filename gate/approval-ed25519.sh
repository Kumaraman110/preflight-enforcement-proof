#!/usr/bin/env bash
# Asymmetric (Ed25519) approval — sign + verify. The FALLBACK for approval-authority separation
# when GitHub environment required-reviewers are unavailable on the plan (see docs/SANDBOX.md).
#
# Two modes:
#   sign   <payload.json> <priv.pem> <out-approval.json>
#          Produces {"payload":<canonical payload>,"sig":"<base64 ed25519 sig over the canonical
#          payload bytes>","alg":"ed25519"}. Only the approve workflow (which holds the PRIVATE
#          key as a secret) can do this. The judge does NOT hold the private key.
#   verify <approval.json> <pub.pem> <expected-payload.json>
#          Exit 0 iff (a) the signature verifies under the PUBLIC key AND (b) the embedded payload
#          is byte-identical (canonical) to the independently reconstructed expected payload. Any
#          tamper / wrong key / payload drift → non-zero. The judge holds ONLY the public key, so
#          it can VERIFY but can NEVER MINT an approval — this is the anti-self-approval property.
#
# The payload is scoped (built by build-approval-payload) to repo|pr|commit|actionDigest|
# evidenceDigest|policyVersion|decisionDigest|expiry|nonce|runId, so an approval cannot be replayed
# onto another commit/repo/action/evidence/decision/policy, or reused past expiry.
set -uo pipefail

MODE="${1:?sign|verify}"; shift

canon() {  # canonicalize a JSON file to stable bytes (sorted keys, compact)
  python - "$1" <<'PY'
import sys,json
d=json.load(open(sys.argv[1],encoding='utf-8'))
sys.stdout.write(json.dumps(d,sort_keys=True,separators=(',',':'),ensure_ascii=False))
PY
}

case "$MODE" in
  sign)
    PAYLOAD="${1:?payload}"; PRIV="${2:?priv.pem}"; OUT="${3:?out}"
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    canon "$PAYLOAD" > "$TMP/canon.json"
    openssl pkeyutl -sign -inkey "$PRIV" -rawin -in "$TMP/canon.json" -out "$TMP/sig.bin" 2>/dev/null || { echo "sign failed" >&2; exit 30; }
    SIG_B64="$(base64 -w0 "$TMP/sig.bin")"
    python - "$TMP/canon.json" "$SIG_B64" "$OUT" <<'PY'
import sys,json
canon=open(sys.argv[1],encoding='utf-8').read()
sig=sys.argv[2]; out=sys.argv[3]
json.dump({"payload":json.loads(canon),"sig":sig,"alg":"ed25519"}, open(out,'w',encoding='utf-8'))
PY
    echo "approval signed (ed25519)" >&2
    ;;
  verify)
    APPROVAL="${1:?approval.json}"; PUB="${2:?pub.pem}"; EXPECT="${3:?expected payload}"
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    # 1. extract the embedded payload + signature
    python - "$APPROVAL" "$TMP/payload.json" "$TMP/sig.b64" <<'PY' || { echo "malformed approval" >&2; exit 20; }
import sys,json
a=json.load(open(sys.argv[1],encoding='utf-8'))
assert a.get("alg")=="ed25519", "bad alg"
json.dump(a["payload"], open(sys.argv[2],'w',encoding='utf-8'))
open(sys.argv[3],'w').write(a["sig"])
PY
    # 2. canonicalize the embedded payload + the independently-expected payload; they must match
    canon "$TMP/payload.json" > "$TMP/payload.canon"
    canon "$EXPECT"           > "$TMP/expect.canon"
    if ! cmp -s "$TMP/payload.canon" "$TMP/expect.canon"; then
      echo "approval payload does not match expected scope (replay/binding-mismatch)" >&2; exit 20; fi
    # 3. verify the signature over the canonical payload bytes under the PUBLIC key
    base64 -d "$TMP/sig.b64" > "$TMP/sig.bin" 2>/dev/null || { echo "bad sig encoding" >&2; exit 20; }
    if openssl pkeyutl -verify -pubin -inkey "$PUB" -rawin -in "$TMP/payload.canon" -sigfile "$TMP/sig.bin" >/dev/null 2>&1; then
      echo "approval signature VALID under public key" >&2; exit 0
    fi
    echo "approval signature INVALID under public key" >&2; exit 20
    ;;
  *) echo "usage: approval-ed25519.sh sign|verify ..." >&2; exit 30;;
esac

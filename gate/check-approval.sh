#!/usr/bin/env bash
# JUDGE-side approval check (Ed25519, public key only). Called only when the base decision is
# REQUIRE_APPROVAL. Reconstructs the fully-scoped expected payload INDEPENDENTLY from the trusted
# facts (repo, PR, re-resolved commit, action/evidence digests from the sealed claim, policy
# version, decision digest) and verifies the supplied approval's signature under the PUBLIC key
# and payload-equality. The judge holds NO private key, so it can never mint an approval.
#
# Exit 0 = valid approval (upgrade REQUIRE_APPROVAL→ALLOW); non-zero = no valid approval (stays
# REQUIRE_APPROVAL / BLOCK). Fail-closed.
#
# Usage: check-approval.sh GATE REPO PR SUBJECT_DIR INTENT BUNDLE DECISION_JSON APPROVAL_JSON PUB_PEM POLICY_VERSION
set -uo pipefail
GATE="${1:?}"; REPO="${2:?}"; PR="${3:?}"; SUBJ="${4:?}"; INTENT="${5:?}"; BUNDLE="${6:?}"
DECISION="${7:?}"; APPROVAL="${8:?}"; PUB="${9:?}"; PV="${10:?}"

[ -f "$APPROVAL" ] || { echo "check-approval: no approval present" >&2; exit 10; }
[ -f "$PUB" ]      || { echo "check-approval: no public key committed" >&2; exit 30; }

PF_PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { "$c" -c 'import sys;sys.exit(0 if sys.version_info[0]>=3 else 1)' && PF_PY="$c" && break; }; done
[ -n "$PF_PY" ] || { echo "check-approval: no python" >&2; exit 30; }

# Independently re-resolve the commit from the subject checkout (never trust the approval's claim).
COMMIT="$(git -C "$SUBJ" rev-parse HEAD 2>/dev/null || echo)"
[ -n "$COMMIT" ] || { echo "check-approval: cannot resolve subject HEAD" >&2; exit 30; }

# action + evidence digests from the (trusted) sealed claim, computed by the verifier's own funcs.
AD="$( cd "$GATE" && "$PF_PY" -c "import sys,json;sys.path.insert(0,'verifier');from pfverify import attest;print(attest.action_digest(json.load(open(sys.argv[1],encoding='utf-8'))))" "$INTENT" )"
ED="$( cd "$GATE" && "$PF_PY" -c "import sys,json;sys.path.insert(0,'verifier');from pfverify import attest;print(attest.evidence_digest(json.load(open(sys.argv[1],encoding='utf-8'))))" "$BUNDLE" )"
# decision digest = canonical sha256 of the STABLE decision fields only (decision+policyId+
# violations+reasons), EXCLUDING the volatile evaluatedAt timestamp so the digest is identical
# across re-runs of the same commit (else the approval, bound at approve-time, never matches).
DD="$( cd "$GATE" && "$PF_PY" -c "import sys,json;sys.path.insert(0,'verifier');from pfverify import canonical;d=json.load(open(sys.argv[1],encoding='utf-8'));core={k:d.get(k) for k in ('decision','policyId','violations','reasons')};print(canonical.sha256_hex(canonical.canonical_bytes(core)))" "$DECISION" )"

# Reconstruct the expected payload, taking expiry+nonce FROM the supplied approval (they are not
# secret; the signature still binds them, and expiry is separately enforced below).
EXP="$( "$PF_PY" -c "import sys,json;print(json.load(open(sys.argv[1],encoding='utf-8'))['payload'].get('expiresAt',''))" "$APPROVAL" )"
NONCE="$( "$PF_PY" -c "import sys,json;print(json.load(open(sys.argv[1],encoding='utf-8'))['payload'].get('nonce',''))" "$APPROVAL" )"
[ -n "$EXP" ] && [ -n "$NONCE" ] || { echo "check-approval: approval missing expiry/nonce" >&2; exit 20; }

# Enforce expiry independently (deterministic 'now' from the caller env or wall clock).
NOW="${PF_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
if [ "$NOW" ">" "$EXP" ]; then echo "check-approval: approval expired ($EXP < $NOW)" >&2; exit 20; fi

EXPECT="$(mktemp)"; trap 'rm -f "$EXPECT"' EXIT
bash "$GATE/gate/build-approval-payload.sh" "$REPO" "$PR" "$COMMIT" "$AD" "$ED" "$PV" "$DD" "$EXP" "$NONCE" > "$EXPECT"

# Verify signature (public key) + payload byte-equality to the independently reconstructed scope.
bash "$GATE/gate/approval-ed25519.sh" verify "$APPROVAL" "$PUB" "$EXPECT"
rc=$?
[ "$rc" = 0 ] && echo "check-approval: VALID Ed25519 approval → upgrade to ALLOW" >&2
exit "$rc"

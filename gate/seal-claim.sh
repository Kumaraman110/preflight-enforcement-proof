#!/usr/bin/env bash
# TRUSTED sealer (Stage-2 job B). Holds ONLY PREFLIGHT_BUNDLE_KEY (the tier/evidence authority).
# It HMAC-signs the naked bundle produced by the evidence-generator (job A) over the bundle's
# canonical digest — it does NOT recompute artifact hashes (the generator already did, against the
# subject) and therefore needs NO access to the subject tree: it operates purely on the bundle JSON.
# This is why the sealer can run with the bundle key ONLY and nothing else.
#
# It NEVER signs a PR-authored bundle: job A overwrote the bundle with generator-derived evidence.
#
# Usage: seal-claim.sh <bundle-json> <gate-dir>
#   env: PREFLIGHT_BUNDLE_KEY (required; fail-closed if absent)
set -uo pipefail
BUNDLE="${1:?bundle json}"; GATE="${2:?gate dir}"

if [ -z "${PREFLIGHT_BUNDLE_KEY:-}" ]; then
  echo "seal-claim: PREFLIGHT_BUNDLE_KEY absent — cannot authenticate evidence (fail closed)" >&2
  exit 30
fi
PF_PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { "$c" -c 'import sys;sys.exit(0 if sys.version_info[0]>=3 else 1)' && PF_PY="$c" && break; }; done
[ -n "$PF_PY" ] || { echo "seal-claim: no python" >&2; exit 30; }

KEYFILE="$(mktemp)"; trap 'rm -f "$KEYFILE"' EXIT
printf '%s' "$PREFLIGHT_BUNDLE_KEY" > "$KEYFILE"

# Sign over the EXISTING digest/hashes (no artifact recompute → no subject tree needed).
( cd "$GATE" && "$PF_PY" verifier/tools/seal_bundle.py \
    --bundle "$BUNDLE" --no-recompute-artifacts --attestation-key-file "$KEYFILE" >/dev/null )
echo "seal-claim: bundle signed under PREFLIGHT_BUNDLE_KEY" >&2

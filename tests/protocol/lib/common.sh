#!/usr/bin/env bash
# Shared helpers for the protocol/verifier behavioral tests. Sourced, not executed.
#
# Provides: PASS/FAIL counters, ok()/bad(), a working-python probe (this Windows host
# has a broken `python3` Store stub but a working `python`; CI Linux is the inverse),
# a decision-field extractor, and a fixture builder that mints a positive intent+bundle
# and seals real artifact hashes + bundleDigest. Every test builds its own throwaway
# fixtures under a mktemp dir — nothing touches the repo's real .preflight/ state.

set -uo pipefail

PROTO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"   # repo root
VERIFIER_DIR="$PROTO_ROOT/verifier"
POLICY="$PROTO_ROOT/protocol/policies/push-safety.v1.policy.json"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# Resolve a WORKING python interpreter (try python3, then python). Fail-closed: if
# neither runs, the caller aborts (a verifier that can't run must not report green).
PF_PY=""
_probe_python() {
  local cand
  for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import sys;sys.exit(0 if sys.version_info[0]>=3 else 1)' >/dev/null 2>&1; then
      PF_PY="$cand"; return 0
    fi
  done
  return 1
}

# Run the verifier. Args: <intent> <bundle> <evidence-root> <now> [extra args...]
# Echoes the decision JSON on stdout; the caller reads $? for the exit code.
pf_verify() {
  local intent="$1" bundle="$2" eroot="$3" now="$4"; shift 4
  ( cd "$PROTO_ROOT" && "$PF_PY" -m verifier.pfverify \
      --intent "$intent" --bundle "$bundle" --policy "$POLICY" \
      --evidence-root "$eroot" --now "$now" "$@" 2>/dev/null )
}

# Extract a top-level string field from a decision JSON blob (stdin) with python.
pf_field() {  # $1 = field
  "$PF_PY" -c "import sys,json;
d=json.load(sys.stdin)
v=d.get('$1','')
print(','.join(v) if isinstance(v,list) else v)"
}

# Seal a bundle: recompute artifact hashes + bundleDigest (+ optional hmac signature).
pf_seal() {  # $1=bundle $2=evidence-root [$3=key-file]
  local extra=()
  [ -n "${3:-}" ] && extra=(--attestation-key-file "$3")
  ( cd "$PROTO_ROOT" && "$PF_PY" verifier/tools/seal_bundle.py \
      --bundle "$1" --evidence-root "$2" "${extra[@]}" >/dev/null )
}

# Build a POSITIVE fixture in $1 (a fresh dir). Sets globals FX_INTENT/FX_BUNDLE/FX_ROOT/FX_HEAD.
# Tier defaults to AUTO; override with $2.
pf_build_positive() {
  local dir="$1" tier="${2:-AUTO}"
  FX_ROOT="$dir"; FX_HEAD="abc1234def5678"
  FX_INTENT="$dir/intent.json"; FX_BUNDLE="$dir/bundle.json"
  mkdir -p "$dir/artifacts"
  printf 'all tests passed\n' > "$dir/artifacts/tests.log"
  printf 'tier=%s\n' "$tier" > "$dir/artifacts/tier.txt"
  cat > "$FX_INTENT" <<EOF
{"schemaVersion":"1.0.0","intentId":"i-001","action":{"type":"git-push","attributes":{"remote":"safe","refspec":"HEAD:topic"}},"actor":{"kind":"model","id":"claude-opus-4-8"},"subject":{"repo":"demo","head":"$FX_HEAD","branch":"topic"}}
EOF
  cat > "$FX_BUNDLE" <<EOF
{"schemaVersion":"1.0.0","intentRef":{"intentId":"i-001","subjectHead":"$FX_HEAD"},"issuer":{"adapter":"preflight-test","version":"0.1.0"},"evidence":[{"type":"tests-pass","producedAt":"2026-07-10T09:00:00Z","boundHead":"$FX_HEAD","artifact":{"path":"artifacts/tests.log","sha256":"0"},"claims":{"passed":true}},{"type":"push-tier","producedAt":"2026-07-10T09:00:05Z","boundHead":"$FX_HEAD","artifact":{"path":"artifacts/tier.txt","sha256":"0"},"claims":{"tier":"$tier"}}],"attestation":{"algo":"sha256","bundleDigest":"0"}}
EOF
  pf_seal "$FX_BUNDLE" "$FX_ROOT"
}

# Rewrite one JSON file through a python transform. $1=infile $2=outfile $3=python-body
# The body receives `d` (parsed dict) and must mutate it in place.
pf_mutate() {
  local infile="$1" outfile="$2" body="$3"
  "$PF_PY" - "$infile" "$outfile" <<PY
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
$body
json.dump(d,open(sys.argv[2],"w",encoding="utf-8"))
PY
}

# Assert a decision + exit code from a completed pf_verify call.
# $1=label $2=decision-json $3=captured-rc $4=want-decision $5=want-rc
pf_assert() {
  local label="$1" out="$2" rc="$3" wantdec="$4" wantrc="$5"
  local dec; dec="$(printf '%s' "$out" | pf_field decision)"
  if [ "$dec" = "$wantdec" ] && [ "$rc" = "$wantrc" ]; then
    ok "$label — decision=$dec rc=$rc"
  else
    bad "$label — expected decision=$wantdec rc=$wantrc, got decision=$dec rc=$rc; violations=$(printf '%s' "$out" | pf_field violations)"
  fi
}

# Assert a specific violation code is present.
pf_assert_violation() {  # $1=label $2=json $3=code
  if printf '%s' "$2" | pf_field violations | grep -q "$3"; then
    ok "$1 — violation $3 present"
  else
    bad "$1 — expected violation $3, got: $(printf '%s' "$2" | pf_field violations)"
  fi
}

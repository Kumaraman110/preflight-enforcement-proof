#!/usr/bin/env bash
# Preflight Remote Decision Gate — portable CI entrypoint.
#
# Runs the INDEPENDENT verifier in remote-authoritative mode against a real checkout,
# produces an inspectable decision.json + (on a passing decision) a signed attestation.json,
# and exits with a code suitable for a required status check:
#     0   = ALLOW              (or REQUIRE_APPROVAL upgraded by a valid approval)
#     10  = REQUIRE_APPROVAL   (no valid approval present — blocks the check until approved)
#     20  = BLOCK              (denied or unverifiable)
#     30  = usage / internal   (never a silent pass)
#
# It is fully drivable OFFLINE (a mktemp git checkout + throwaway keys, no network, no
# GitHub) — that is exactly what the e2e test exercises. The signing key comes from
# PREFLIGHT_ATTEST_KEY (env) or --attest-key-file; the approver key from
# PREFLIGHT_APPROVAL_KEY (env) or --approval-key-file. NEVER a repo secret.
#
# This entrypoint does NOT mutate branch protection or any GitHub state; it only decides
# and attests. Configuring it as a required status check is a documented operator step.
set -uo pipefail

REPO_ROOT="" INTENT="" BUNDLE="" POLICY="" NOW="" EXPECTED_REPO=""
OUT_DIR="." APPROVAL="" ATTEST_KEY_FILE="" APPROVAL_KEY_FILE="" BUNDLE_KEY_FILE=""
POLICY_VERSION="1.0.0" RUN_ID="local-run" NONCE="nonce-0"
ISSUED_AT="" EXPIRES_AT="" UNTRACKED="no" PKG_ROOT_OVERRIDE="" REQUIRE_ATTESTATION="0"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT="$2"; shift 2;;
    --intent) INTENT="$2"; shift 2;;
    --bundle) BUNDLE="$2"; shift 2;;
    --policy) POLICY="$2"; shift 2;;
    --now) NOW="$2"; shift 2;;
    --expected-repo) EXPECTED_REPO="$2"; shift 2;;
    --out-dir) OUT_DIR="$2"; shift 2;;
    --approval) APPROVAL="$2"; shift 2;;
    --attest-key-file) ATTEST_KEY_FILE="$2"; shift 2;;
    --approval-key-file) APPROVAL_KEY_FILE="$2"; shift 2;;
    --bundle-key-file) BUNDLE_KEY_FILE="$2"; shift 2;;
    --policy-version) POLICY_VERSION="$2"; shift 2;;
    --run-id) RUN_ID="$2"; shift 2;;
    --nonce) NONCE="$2"; shift 2;;
    --issued-at) ISSUED_AT="$2"; shift 2;;
    --expires-at) EXPIRES_AT="$2"; shift 2;;
    --untracked-files) UNTRACKED="$2"; shift 2;;
    # --pkg-root: the TRUSTED verifier package root (dir containing verifier/ and protocol/).
    # In CI this MUST point at a checkout of a trusted ref, NOT the PR-under-decision tree —
    # otherwise a fork PR could edit the verifier/policy to force ALLOW. If unset, it derives
    # from this script's own location (correct only when the script itself is the trusted copy).
    --pkg-root) PKG_ROOT_OVERRIDE="$2"; shift 2;;
    # --require-attestation: fail CLOSED (exit 30, non-success) if no signing key is available.
    # For a REQUIRED status check the decision must be independently attestable; a fork PR with
    # no secrets therefore cannot produce a passing authoritative result.
    --require-attestation) REQUIRE_ATTESTATION="1"; shift 1;;
    *) echo "remote-gate: unknown arg $1" >&2; exit 30;;
  esac
done

# Resolve a WORKING python (python3 then python) — fail closed if neither runs.
PF_PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys;sys.exit(0 if sys.version_info[0]>=3 else 1)' >/dev/null 2>&1; then PF_PY="$c"; break; fi
done
[ -n "$PF_PY" ] || { echo "remote-gate: no working python3/python" >&2; exit 30; }

# Locate the verifier package root (dir containing verifier/ and protocol/). SECURITY: in CI
# this MUST be a TRUSTED checkout (base ref / this action's own copy), never the PR-under-
# decision tree — else a fork could edit the verifier or policy to force ALLOW. The
# --pkg-root override (from the workflow, pointing at the trusted checkout) takes precedence;
# otherwise it derives from this script's own location (valid only when this script IS the
# trusted copy). This script lives at <pkg-root>/verifier/ci/remote-gate.sh.
if [ -n "$PKG_ROOT_OVERRIDE" ]; then
  PKG_ROOT="$(cd "$PKG_ROOT_OVERRIDE" && pwd)"
else
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PKG_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
fi
# The policy MUST be resolved from the trusted PKG_ROOT unless the caller passed an absolute
# path. A bare/relative --policy is interpreted relative to PKG_ROOT (trusted), NOT the PR cwd.
case "$POLICY" in
  /*|[A-Za-z]:*) : ;;                          # absolute (caller's explicit choice)
  *) POLICY="$PKG_ROOT/$POLICY" ;;             # relative → trusted package root
esac

# Mandatory inputs.
for v in REPO_ROOT INTENT BUNDLE POLICY NOW; do
  eval "val=\$$v"; [ -n "$val" ] || { echo "remote-gate: --${v,,} required" >&2; exit 30; }
done
[ -n "$NOW" ] || { echo "remote-gate: --now required (deterministic)"; exit 30; }
: "${ISSUED_AT:=$NOW}"
: "${EXPIRES_AT:=$NOW}"   # caller should pass a real expiry; default = now (immediately stale) is fail-safe

# The attestation signing key: env takes precedence, else a file. Written to a temp file
# for the python subcommand (never echoed).
KEYFILE=""
if [ -n "${PREFLIGHT_ATTEST_KEY:-}" ]; then
  KEYFILE="$(mktemp)"; printf '%s' "$PREFLIGHT_ATTEST_KEY" > "$KEYFILE"
elif [ -n "$ATTEST_KEY_FILE" ]; then
  KEYFILE="$ATTEST_KEY_FILE"
fi

APPROVER_KEYFILE=""
if [ -n "${PREFLIGHT_APPROVAL_KEY:-}" ]; then
  APPROVER_KEYFILE="$(mktemp)"; printf '%s' "$PREFLIGHT_APPROVAL_KEY" > "$APPROVER_KEYFILE"
elif [ -n "$APPROVAL_KEY_FILE" ]; then
  APPROVER_KEYFILE="$APPROVAL_KEY_FILE"
fi

# OPTIONAL separate bundle-signing key (evidence authenticity). Distinct from the
# attestation-signing key. Only when present does the verifier require an HMAC on the bundle.
BUNDLE_KEYFILE=""
if [ -n "${PREFLIGHT_BUNDLE_KEY:-}" ]; then
  BUNDLE_KEYFILE="$(mktemp)"; printf '%s' "$PREFLIGHT_BUNDLE_KEY" > "$BUNDLE_KEYFILE"
elif [ -n "$BUNDLE_KEY_FILE" ]; then
  BUNDLE_KEYFILE="$BUNDLE_KEY_FILE"
fi

# FAIL-CLOSED on missing signing material when attestation is required. A REQUIRED status
# check must yield an independently-attestable decision; without the key (e.g. a fork PR with
# no access to secrets) we must NOT emit a passing result. Exit 30 = non-success, not ALLOW.
if [ "$REQUIRE_ATTESTATION" = "1" ] && [ -z "$KEYFILE" ]; then
  echo "remote-gate: --require-attestation set but no signing key (PREFLIGHT_ATTEST_KEY / --attest-key-file) available — failing closed" >&2
  mkdir -p "$OUT_DIR"
  printf '{"decision":"BLOCK","reason":"attestation-key-unavailable","attested":false}\n' > "$OUT_DIR/decision.json"
  exit 30
fi

mkdir -p "$OUT_DIR"
DECISION_JSON="$OUT_DIR/decision.json"
ATTEST_JSON="$OUT_DIR/attestation.json"

# ── 1. Independent verification (remote-authoritative). ─────────────────────────────────────────────
# NOTE: the gate's signing key (PREFLIGHT_ATTEST_KEY) signs the DECISION ATTESTATION (the
# gate's OUTPUT), NOT the producer's evidence bundle. Those are distinct purposes. Only
# pass --attestation-key-file (which requires an HMAC signature ON THE BUNDLE) when a
# SEPARATE bundle-signing key is supplied via --bundle-key-file / PREFLIGHT_BUNDLE_KEY.
# The core enforcement (identity re-resolution) does not depend on a bundle signature.
VERIFY_ARGS=(--intent "$INTENT" --bundle "$BUNDLE" --policy "$POLICY"
             --evidence-root "$REPO_ROOT" --now "$NOW"
             --mode remote-authoritative --repo-root "$REPO_ROOT" --untracked-files "$UNTRACKED")
[ -n "$EXPECTED_REPO" ] && VERIFY_ARGS+=(--expected-repo "$EXPECTED_REPO")
[ -n "${BUNDLE_KEYFILE:-}" ] && VERIFY_ARGS+=(--attestation-key-file "$BUNDLE_KEYFILE")

( cd "$PKG_ROOT" && "$PF_PY" -m verifier.pfverify "${VERIFY_ARGS[@]}" ) > "$DECISION_JSON" 2>/dev/null
VRC=$?
DECISION="$("$PF_PY" -c "import sys,json;print(json.load(open(sys.argv[1],encoding='utf-8')).get('decision','BLOCK'))" "$DECISION_JSON" 2>/dev/null || echo BLOCK)"
echo "remote-gate: verifier decision=$DECISION (rc=$VRC)"

emit_attestation() {  # $1 decision-file ; returns nonzero if an attestation was REQUIRED but not written
  if [ -z "$KEYFILE" ]; then
    echo "remote-gate: no attestation key — decision not attested" >&2
    [ "$REQUIRE_ATTESTATION" = "1" ] && return 1 || return 0
  fi
  local commit repoid
  # Re-resolve the authoritative commit + repo for the attestation binding (independent).
  commit="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo)"
  repoid="$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || echo)"
  [ -n "$EXPECTED_REPO" ] && repoid="$EXPECTED_REPO"
  if ( cd "$PKG_ROOT" && "$PF_PY" -m verifier.pfverify attest \
        --intent "$INTENT" --bundle "$BUNDLE" --decision "$1" \
        --repo-id "$repoid" --commit-sha "$commit" --attest-key-file "$KEYFILE" \
        --policy-version "$POLICY_VERSION" --issued-at "$ISSUED_AT" --expires-at "$EXPIRES_AT" \
        --run-id "$RUN_ID" --nonce "$NONCE" ) > "$ATTEST_JSON" 2>/dev/null; then
    echo "remote-gate: wrote $ATTEST_JSON"; return 0
  fi
  echo "remote-gate: attestation step failed" >&2
  [ "$REQUIRE_ATTESTATION" = "1" ] && return 1 || return 0
}

# A passing decision under --require-attestation MUST carry a written attestation, else the
# check fails closed (a pass with no independently-verifiable attestation is not acceptable).
pass_or_failclosed() {  # $1 decision-file
  if emit_attestation "$1"; then exit 0; fi
  echo "remote-gate: passing decision but attestation required and not produced — failing closed" >&2
  exit 30
}

case "$DECISION" in
  ALLOW)
    pass_or_failclosed "$DECISION_JSON";;
  REQUIRE_APPROVAL)
    # A separate, attributable approval (signed with the DISTINCT approver key) can upgrade
    # to a pass. The producer cannot self-approve — it lacks the approver key.
    if [ -n "$APPROVAL" ] && [ -n "$APPROVER_KEYFILE" ]; then
      INTENT_ID_VAL="$("$PF_PY" -c "import sys,json;print(json.load(open(sys.argv[1],encoding='utf-8')).get('intentId','unknown'))" "$DECISION_JSON")"
      COMMIT_VAL="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo)"
      ( cd "$PKG_ROOT" && "$PF_PY" -m verifier.pfverify verify-approval \
          --approval "$APPROVAL" --approval-key-file "$APPROVER_KEYFILE" \
          --intent-id "$INTENT_ID_VAL" --commit-sha "$COMMIT_VAL" --now "$NOW" ) >/dev/null 2>&1
      ARC=$?
      if [ "$ARC" = 0 ]; then
        echo "remote-gate: REQUIRE_APPROVAL upgraded by a valid approval → pass"
        pass_or_failclosed "$DECISION_JSON"
      fi
      echo "remote-gate: approval present but invalid/mismatched → REQUIRE_APPROVAL stands" >&2
    fi
    echo "remote-gate: REQUIRE_APPROVAL — no valid approval; blocking the check" >&2
    exit 10;;
  *)
    echo "remote-gate: BLOCK/unverifiable → non-zero" >&2
    exit 20;;
esac

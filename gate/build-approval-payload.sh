#!/usr/bin/env bash
# Build the CANONICAL, fully-scoped approval payload. Both the approve workflow (to sign) and the
# judge (to reconstruct the expected payload independently) call this with the SAME inputs, so the
# judge never trusts the approval's self-declared scope — it recomputes it and requires byte-equality.
#
# Scope (per directive): the approval is bound to repo | pr | commit | actionDigest | evidenceDigest
# | policyVersion | decisionDigest | expiry | nonce. An approval for one (repo,pr,commit,action,
# evidence,decision,policy) tuple cannot be replayed onto another, and expires.
#
# Usage: build-approval-payload.sh REPO PR COMMIT ACTION_DIGEST EVIDENCE_DIGEST POLICY_VERSION \
#                                  DECISION_DIGEST EXPIRES_AT NONCE  > payload.json
set -euo pipefail
REPO="${1:?}"; PR="${2:?}"; COMMIT="${3:?}"; AD="${4:?}"; ED="${5:?}"; PV="${6:?}"; DD="${7:?}"; EXP="${8:?}"; NONCE="${9:?}"
python - "$REPO" "$PR" "$COMMIT" "$AD" "$ED" "$PV" "$DD" "$EXP" "$NONCE" <<'PY'
import sys,json
repo,pr,commit,ad,ed,pv,dd,exp,nonce = sys.argv[1:10]
payload={
  "schemaVersion":"1.0.0",
  "grants":"ALLOW",
  "forDecision":"REQUIRE_APPROVAL",
  "repo":repo,
  "pr":str(pr),
  "commitSha":commit,
  "actionDigest":ad,
  "evidenceDigest":ed,
  "policyVersion":pv,
  "decisionDigest":dd,
  "expiresAt":exp,
  "nonce":nonce,
}
sys.stdout.write(json.dumps(payload,sort_keys=True,separators=(',',':'),ensure_ascii=False))
PY

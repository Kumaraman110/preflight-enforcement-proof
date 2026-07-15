#!/usr/bin/env bash
# resultcode-parity-loop-test.sh — regression for the v0.11 REAL learning loop.
#
# Protects the survival-thesis artifact: the result-code wire-contract parity rule
# (verifier/rules/resultcode_parity.py, adjudicated from the genuine PR-12 CPSL SessionToken
# finding — invented S0000/W0024, dropped W0011) and the promotion gate (a distinct-approver
# signed approval; the producer cannot self-promote).
#
# Proves, deterministically (stdlib + the shipped pfverify.approval module, no network):
#   1. the rule CATCHES the equivalent drift in the Service N+1 fixture (TokenManager) — introduced
#      + dropped codes vs the legacy contract;
#   2. the rule PASSES the corrected fixture (parity restored);
#   3. promotion is GATED: without an approval -> not promoted; a producer/wrong key -> not promoted;
#      a distinct-approver signed approval -> promoted (no self-promotion).
#
# Exit 0 = all passed. Fully isolated: no repo mutation, no network.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RULES="$ROOT/verifier/rules"
FIX="$RULES/fixtures"
PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
trailer(){ echo ""; echo "resultcode-parity-loop: ${PASS} passed, ${FAIL} failed"; [ "$FAIL" -eq 0 ]; }

PF_PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { "$c" -c 'import sys;sys.exit(0 if sys.version_info[0]>=3 else 1)' >/dev/null 2>&1 && PF_PY="$c" && break; }; done
[ -n "$PF_PY" ] || { bad "no working python3/python (fail-closed)"; trailer; exit $?; }
[ -f "$RULES/resultcode_parity.py" ] || { bad "rule module missing"; trailer; exit $?; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# A path a Windows python.exe can open: on cygwin/msys, python.exe needs a Windows path, not /tmp/...
# (cygpath -w). Off-cygwin (real POSIX python) this is a no-op passthrough. Shell redirections still use
# the msys "$TMP/..." form (the shell opens those); only paths handed INTO python get normalized.
winp(){ if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; else printf '%s' "$1"; fi; }
RULE_JSON="$(winp "$TMP/rule.json")"
FIX_W="$(winp "$FIX")"

# Build the promoted-rule json (legacyContract = the shipped TokenManager legacy contract).
( cd "$RULES" && "$PF_PY" - "$RULE_JSON" <<'PY'
import json, sys
import resultcode_parity as rcp
rule=dict(rcp.RULE_TEMPLATE)
rule["legacyContract"]=[c.strip() for c in open("fixtures/tokenmanager-legacy-codes.txt").read().split()]
json.dump(rule,open(sys.argv[1],"w"))
PY
) || { bad "could not build rule json"; trailer; exit $?; }

# 1. DRIFTED fixture -> rule must FLAG (exit 1) with introduced + dropped violations.
if ( cd "$RULES" && "$PF_PY" resultcode_parity.py "$RULE_JSON" "$FIX_W/tokenmanager-migrated-DRIFTED.cs" > "$TMP/drift.json" 2>/dev/null ); then
  bad "rule PASSED the drifted fixture (should have flagged it)"
else
  if grep -q 'introduced-code' "$TMP/drift.json" && grep -q 'dropped-code' "$TMP/drift.json"; then
    ok "rule CATCHES the Service N+1 equivalent drift (introduced + dropped codes)"
  else
    bad "rule failed but did not report introduced+dropped violations: $(tr -d '\n' < "$TMP/drift.json" | head -c 200)"
  fi
fi

# 2. CORRECTED fixture -> rule must PASS (exit 0, clean).
if ( cd "$RULES" && "$PF_PY" resultcode_parity.py "$RULE_JSON" "$FIX_W/tokenmanager-corrected.cs" > "$TMP/corr.json" 2>/dev/null ); then
  grep -q '"clean": true' "$TMP/corr.json" && ok "rule PASSES the corrected fixture (parity restored)" \
    || bad "corrected fixture: exit 0 but not clean"
else
  bad "rule FLAGGED the corrected fixture (false positive): $(tr -d '\n' < "$TMP/corr.json" | head -c 200)"
fi

# 3. promotion gate (distinct-approver signed approval; producer cannot self-promote).
APPROVER="$TMP/approver.key"; printf 'security-lead-approver-key-v11\n' > "$APPROVER"
WRONG="$TMP/wrong.key"; printf 'producer-cannot-self-promote\n' > "$WRONG"
GATE_OUT="$( cd "$ROOT" && "$PF_PY" - "$(winp "$APPROVER")" "$(winp "$WRONG")" <<'PY'
import sys, json
sys.path.insert(0, "verifier")
from pfverify import approval as ap
from pfverify.engine import _parse_rfc3339
approver = open(sys.argv[1], "rb").read().strip()
wrong = open(sys.argv[2], "rb").read().strip()
now = _parse_rfc3339("2026-07-15T12:00:00Z")
RID = "R-RESULTCODE-PARITY"
signed = ap.sign_approval(ap.build_approval(intent_id=RID, commit_sha="0"*40,
                          approver_id="security-lead", issued_at="2026-07-15T00:00:00Z",
                          expires_at="2099-01-01T00:00:00Z"), approver)
def prom(appr, key):
    ok, _ = ap.verify_approval(appr, key, intent_id=RID, commit_sha="0"*40, now=now)
    return ok
res = {
  "no_approval": prom(None, approver),          # must be False
  "wrong_key":   prom(signed, wrong),           # must be False (no self-promotion)
  "valid":       prom(signed, approver),        # must be True
}
print(json.dumps(res))
PY
)"
NOAP="$(printf '%s' "$GATE_OUT" | "$PF_PY" -c "import sys,json;print(json.load(sys.stdin)['no_approval'])")"
WK="$(printf '%s' "$GATE_OUT" | "$PF_PY" -c "import sys,json;print(json.load(sys.stdin)['wrong_key'])")"
VAL="$(printf '%s' "$GATE_OUT" | "$PF_PY" -c "import sys,json;print(json.load(sys.stdin)['valid'])")"
[ "$NOAP" = "False" ] && ok "promotion WITHOUT approval is refused (fail-closed)" || bad "promotion allowed with no approval ($NOAP)"
[ "$WK" = "False" ]   && ok "promotion with a PRODUCER/wrong key is refused (no self-promotion)" || bad "producer key promoted a rule ($WK)"
[ "$VAL" = "True" ]   && ok "promotion with a DISTINCT-approver signed approval succeeds" || bad "valid approval did not promote ($VAL)"

trailer

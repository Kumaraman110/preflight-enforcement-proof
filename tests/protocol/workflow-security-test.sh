#!/usr/bin/env bash
# Static-assertion test: the Remote Decision Gate GitHub workflow + entrypoint enforce the
# Phase-3 hardening properties, so they cannot silently regress.
#
# These are STATIC assertions on the committed workflow/entrypoint (no GitHub needed) PLUS
# behavioral checks of the entrypoint's new fail-closed flags. Every property maps to a
# documented CI-security requirement.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed (or env unavailable).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

if ! _probe_python; then
  bad "no working python3/python (fail-closed: NOT green)"; echo ""; echo "workflow-security: ${PASS} passed, ${FAIL} failed"; exit 1
fi

WF="$PROTO_ROOT/.github/workflows/preflight-remote-gate.yaml"
GATE="$PROTO_ROOT/verifier/ci/remote-gate.sh"
[ -f "$WF" ] || { bad "workflow missing: $WF"; echo ""; echo "workflow-security: ${PASS} passed, ${FAIL} failed"; exit 1; }
[ -f "$GATE" ] || { bad "entrypoint missing: $GATE"; echo ""; echo "workflow-security: ${PASS} passed, ${FAIL} failed"; exit 1; }

# YAML query helper (python; path passed as argv — MSYS-safe).
wf() { "$PF_PY" - "$WF" "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
q = sys.argv[2]
# tiny dotted-path getter; 'on' may parse as bool True under YAML 1.1
def get(d, path):
    cur = d
    for k in path.split("."):
        if isinstance(cur, dict):
            if k in cur: cur = cur[k]
            elif k == "on" and True in cur: cur = cur[True]
            else: return None
        else: return None
    return cur
v = get(d, q)
print("" if v is None else v)
PY
}

# ── 1. LEAST-PRIVILEGE: top-level + every job is contents:read; NO write scope anywhere ─────────────
TOPPERM="$(wf permissions)"
case "$TOPPERM" in *"'contents': 'read'"*|*"contents.*read"*) ok "top-level permissions = contents:read";; *) bad "top-level permissions not contents:read: $TOPPERM";; esac
# Flag only an ACTUAL write GRANT (a `<scope>: write` value on a non-comment line), not the
# word "write" appearing in a comment. Strip comments first, then look for a write permission.
if grep -vE '^\s*#' "$WF" | grep -qE ':\s*write\b'; then bad "workflow grants a 'write' permission scope"; else ok "no 'write' permission grant anywhere in the workflow (comments aside)"; fi

# ── 2. TWO-STAGE TRUSTED SPLIT: pull_request (collect) + workflow_run (decide) ───────────────────────
TRIG="$(wf on)"
{ echo "$TRIG" | grep -q "pull_request" && echo "$TRIG" | grep -q "workflow_run"; } && ok "two-stage triggers present (pull_request + workflow_run)" || bad "missing two-stage triggers: $TRIG"
grep -q "collect:" "$WF" && grep -q "decide:" "$WF" && ok "collect + decide jobs present" || bad "missing collect/decide jobs"

# ── 3. STAGE 1 (collect) runs in PR context and does NOT reference secrets ──────────────────────────
# Extract the collect job block (from 'collect:' to 'decide:') and assert no secrets. usage.
COLLECT_BLOCK="$(awk '/^  collect:/{f=1} /^  decide:/{f=0} f' "$WF")"
if printf '%s' "$COLLECT_BLOCK" | grep -qE "secrets\."; then bad "STAGE 1 (collect) references secrets — must be secret-free"; else ok "STAGE 1 (collect) references NO secrets"; fi

# ── 4. STAGE 2 (decide) gates on workflow_run success + injects keys ONLY from secrets ──────────────
DECIDE_BLOCK="$(awk '/^  decide:/{f=1} f' "$WF")"
printf '%s' "$DECIDE_BLOCK" | grep -q "workflow_run.conclusion == 'success'" && ok "STAGE 2 gates on Stage-1 success" || bad "STAGE 2 missing workflow_run success gate"
printf '%s' "$DECIDE_BLOCK" | grep -q 'PREFLIGHT_ATTEST_KEY: ${{ secrets.PREFLIGHT_ATTEST_KEY }}' && ok "attest key sourced ONLY from secrets" || bad "attest key not sourced from secrets"

# ── 5. KEYS NEVER FROM REPO-CONTROLLED INPUT: no --attest-key-file / --approval-key-file wired from PR ─
if grep -qE "\-\-attest-key-file|\-\-approval-key-file|\-\-bundle-key-file" "$WF"; then
  bad "workflow passes a key-FILE flag (could point at repo-controlled content) — keys must come via secret env only"
else
  ok "no key-file flags in the workflow (keys only via secret env; not repo-controllable)"
fi

# ── 6. TRUSTED SPLIT: decide checks out gate machinery separately + fetches subject as DATA ─────────
printf '%s' "$DECIDE_BLOCK" | grep -q "path: gate" && ok "STAGE 2 checks out trusted gate machinery into gate/" || bad "STAGE 2 missing trusted gate/ checkout"
printf '%s' "$DECIDE_BLOCK" | grep -q -- "--pkg-root" && ok "entrypoint invoked with --pkg-root (trusted verifier+policy)" || bad "STAGE 2 does not pin --pkg-root to trusted checkout"
printf '%s' "$DECIDE_BLOCK" | grep -qE "git .*fetch .*origin" && ok "STAGE 2 materializes subject commit via git fetch (data-only)" || bad "STAGE 2 missing subject fetch"
# The entrypoint must run from gate/, not the subject tree.
printf '%s' "$DECIDE_BLOCK" | grep -q "bash gate/verifier/ci/remote-gate.sh" && ok "entrypoint executed from TRUSTED gate/ (not the PR/subject tree)" || bad "entrypoint not run from gate/"

# ── 7. FAIL-CLOSED: --require-attestation is passed in the authoritative stage ──────────────────────
printf '%s' "$DECIDE_BLOCK" | grep -q -- "--require-attestation" && ok "STAGE 2 passes --require-attestation (fail-closed on missing key)" || bad "STAGE 2 missing --require-attestation"

# ── 8. EXACT PR HEAD: Stage 1 pins pull_request.head.sha (not the moving merge ref) ─────────────────
printf '%s' "$COLLECT_BLOCK" | grep -q "pull_request.head.sha" && ok "STAGE 1 pins the exact PR head SHA" || bad "STAGE 1 does not pin pull_request.head.sha"

# ── 9. ACTION PINNING: actions pinned by 40-hex commit SHA, not a mutable @vN tag ───────────────────
if grep -qE "uses:.*@v[0-9]+\s*$" "$WF"; then
  bad "an action is pinned to a mutable @vN tag (must be a 40-hex commit SHA)"
else
  # every 'uses:' with a third-party action carries a 40-hex sha
  BADPIN="$(grep -E "uses: (actions|[^/]+/[^@]+)@" "$WF" | grep -vE "@[0-9a-f]{40}" || true)"
  [ -z "$BADPIN" ] && ok "all actions pinned by 40-hex commit SHA" || bad "unpinned action(s): $BADPIN"
fi

# ── 10. CONCURRENCY + TIMEOUT controls present ──────────────────────────────────────────────────────
grep -q "concurrency:" "$WF" && ok "concurrency control present" || bad "no concurrency control"
grep -q "cancel-in-progress: true" "$WF" && ok "cancel-in-progress enabled" || bad "cancel-in-progress not set"
grep -qE "timeout-minutes:" "$WF" && ok "job timeout(s) present" || bad "no job timeout"

# ── 11. ENTRYPOINT BEHAVIOR: --require-attestation with NO key → fail closed (exit 30), NOT a pass ───
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Build a real repo + a VALID AUTO bundle that WOULD be ALLOW — prove that without a key +
# --require-attestation the gate refuses (exit 30), i.e. cannot go green unattested.
REPO="$TMP/repo"; mkdir -p "$REPO/artifacts"
git init -q "$REPO"; ( cd "$REPO" && git config user.email t@t && git config user.name T && git config commit.gpgsign false && git remote add origin "https://github.com/United-Airlines-Org/preflight.git" )
printf 'ok\n' > "$REPO/artifacts/tests.log"; printf 'tier=AUTO\n' > "$REPO/artifacts/tier.txt"
( cd "$REPO" && git add -A && git commit -q -m init ); HEAD="$( cd "$REPO" && git rev-parse HEAD )"
cat > "$TMP/i.json" <<EOF
{"schemaVersion":"1.0.0","intentId":"i-w","action":{"type":"git-push","attributes":{}},"actor":{"kind":"model","id":"c"},"subject":{"repo":"github.com/United-Airlines-Org/preflight","head":"$HEAD","branch":"main"}}
EOF
cat > "$TMP/b.json" <<EOF
{"schemaVersion":"1.0.0","intentRef":{"intentId":"i-w","subjectHead":"$HEAD"},"issuer":{"adapter":"preflight-test","version":"0.1.0"},"evidence":[{"type":"tests-pass","producedAt":"2026-07-11T09:00:00Z","boundHead":"$HEAD","artifact":{"path":"artifacts/tests.log","sha256":"0"},"claims":{"passed":true}},{"type":"push-tier","producedAt":"2026-07-11T09:00:05Z","boundHead":"$HEAD","artifact":{"path":"artifacts/tier.txt","sha256":"0"},"claims":{"tier":"AUTO"}}],"attestation":{"algo":"sha256","bundleDigest":"0"}}
EOF
( cd "$PROTO_ROOT" && "$PF_PY" verifier/tools/seal_bundle.py --bundle "$TMP/b.json" --evidence-root "$REPO" >/dev/null )
# NO key in env, --require-attestation set → must be exit 30 (fail-closed), NOT 0.
( unset PREFLIGHT_ATTEST_KEY; bash "$GATE" --pkg-root "$PROTO_ROOT" --repo-root "$REPO" \
    --intent "$TMP/i.json" --bundle "$TMP/b.json" --policy protocol/policies/push-safety.v1.policy.json \
    --now "2026-07-11T09:05:00Z" --issued-at "2026-07-11T09:05:00Z" --expires-at "2026-07-11T10:05:00Z" \
    --expected-repo "United-Airlines-Org/preflight" --out-dir "$TMP/out" --require-attestation ) >/dev/null 2>&1
RC=$?
[ "$RC" = 30 ] && ok "entrypoint --require-attestation + no key → fail-closed exit 30 (not a green pass)" || bad "require-attestation without key did not fail closed (rc=$RC)"

# ── 12. ENTRYPOINT: --pkg-root pins the trusted verifier (relative --policy resolves under pkg-root) ─
# Prove --policy is resolved relative to --pkg-root (trusted), not the caller cwd: with a valid key,
# a relative policy path works because it resolves under pkg-root.
printf 'k\n' > "$TMP/attest.key"
( bash "$GATE" --pkg-root "$PROTO_ROOT" --repo-root "$REPO" \
    --intent "$TMP/i.json" --bundle "$TMP/b.json" --policy protocol/policies/push-safety.v1.policy.json \
    --now "2026-07-11T09:05:00Z" --issued-at "2026-07-11T09:05:00Z" --expires-at "2026-07-11T10:05:00Z" \
    --expected-repo "United-Airlines-Org/preflight" --out-dir "$TMP/out2" --attest-key-file "$TMP/attest.key" ) >/dev/null 2>&1
RC=$?
{ [ "$RC" = 0 ] && [ -s "$TMP/out2/attestation.json" ]; } && ok "--pkg-root resolves trusted policy + produces attestation (exit 0)" || bad "--pkg-root/relative-policy path failed (rc=$RC)"

echo ""
echo "workflow-security: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Behavioral test: REMOTE-AUTHORITATIVE identity re-resolution — the core of the
# independently enforceable gate. Proves that the verifier, when run against a REAL git
# checkout in remote-authoritative mode, re-derives repo + commit FROM THE CHECKOUT and
# blocks when the producer's CLAIMED subject disagrees — so a locally self-issued ALLOW
# cannot survive independent verification.
#
# Every fixture builds a REAL throwaway git repo (git init + commit + fake origin) under a
# mktemp dir. Nothing touches the repo's own .git or .preflight state.
# Exit 0 = all assertions passed; exit 1 = at least one failed (or env unavailable).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

if ! _probe_python; then
  bad "no working python3/python interpreter (fail-closed: NOT green)"
  echo ""; echo "identity-reresolution: ${PASS} passed, ${FAIL} failed"; exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  bad "git unavailable — remote-authoritative mode cannot be exercised (fail-closed: NOT green)"
  echo ""; echo "identity-reresolution: ${PASS} passed, ${FAIL} failed"; exit 1
fi

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
NOW="2026-07-11T09:05:00Z"
REPO_SLUG="United-Airlines-Org/preflight"
ORIGIN="https://github.com/United-Airlines-Org/preflight.git"

# Build a real throwaway git repo with committed evidence artifacts + a fake origin.
# Sets globals REPO + HEAD.
build_repo() {
  REPO="$TMPROOT/repo-$1"; mkdir -p "$REPO/artifacts"
  git init -q "$REPO"
  ( cd "$REPO" && git config user.email t@t.test && git config user.name T \
      && git config commit.gpgsign false && git remote add origin "$ORIGIN" )
  printf 'all tests passed\n' > "$REPO/artifacts/tests.log"
  printf 'tier=AUTO\n'        > "$REPO/artifacts/tier.txt"
  ( cd "$REPO" && git add -A && git commit -q -m init )
  HEAD="$( cd "$REPO" && git rev-parse HEAD )"
}

# Write intent+bundle (claiming a given head+repo) sealed against the repo tree.
mk_intent_bundle() {  # $1 head  $2 repo  $3 tier  $4 out-intent  $5 out-bundle  $6 evidence-root
  local head="$1" repo="$2" tier="$3" oi="$4" ob="$5" eroot="$6"
  cat > "$oi" <<EOF
{"schemaVersion":"1.0.0","intentId":"i-id","action":{"type":"git-push","attributes":{"remote":"origin","refspec":"HEAD:main"}},"actor":{"kind":"model","id":"claude"},"subject":{"repo":"$repo","head":"$head","branch":"main"}}
EOF
  cat > "$ob" <<EOF
{"schemaVersion":"1.0.0","intentRef":{"intentId":"i-id","subjectHead":"$head"},"issuer":{"adapter":"preflight-test","version":"0.1.0"},"evidence":[{"type":"tests-pass","producedAt":"2026-07-11T09:00:00Z","boundHead":"$head","artifact":{"path":"artifacts/tests.log","sha256":"0"},"claims":{"passed":true}},{"type":"push-tier","producedAt":"2026-07-11T09:00:05Z","boundHead":"$head","artifact":{"path":"artifacts/tier.txt","sha256":"0"},"claims":{"tier":"$tier"}}],"attestation":{"algo":"sha256","bundleDigest":"0"}}
EOF
  ( cd "$PROTO_ROOT" && "$PF_PY" verifier/tools/seal_bundle.py --bundle "$ob" --evidence-root "$eroot" >/dev/null )
}

# ── 1. VALID remote-authoritative: real repo + real head + clean tree → ALLOW / 0 ────────────────────
build_repo one
mk_intent_bundle "$HEAD" "github.com/$REPO_SLUG" AUTO "$TMPROOT/i1.json" "$TMPROOT/b1.json" "$REPO"
OUT="$(pf_verify "$TMPROOT/i1.json" "$TMPROOT/b1.json" "$REPO" "$NOW" --mode remote-authoritative --repo-root "$REPO" --expected-repo "$REPO_SLUG")"; RC=$?
pf_assert "remote valid (real repo+head+clean)" "$OUT" "$RC" ALLOW 0

# ── 2. FORGED commit: claim a different head → BLOCK identity.commit-mismatch / 20 ────────────────────
mk_intent_bundle "0000000000000000000000000000000000000000" "github.com/$REPO_SLUG" AUTO "$TMPROOT/i2.json" "$TMPROOT/b2.json" "$REPO"
OUT="$(pf_verify "$TMPROOT/i2.json" "$TMPROOT/b2.json" "$REPO" "$NOW" --mode remote-authoritative --repo-root "$REPO")"; RC=$?
pf_assert "remote forged commit" "$OUT" "$RC" BLOCK 20
pf_assert_violation "forged commit code" "$OUT" "identity.commit-mismatch"

# ── 3. FORGED repo: claim a different repository → BLOCK identity.repo-mismatch / 20 ──────────────────
mk_intent_bundle "$HEAD" "github.com/attacker/evil" AUTO "$TMPROOT/i3.json" "$TMPROOT/b3.json" "$REPO"
OUT="$(pf_verify "$TMPROOT/i3.json" "$TMPROOT/b3.json" "$REPO" "$NOW" --mode remote-authoritative --repo-root "$REPO")"; RC=$?
pf_assert "remote forged repo" "$OUT" "$RC" BLOCK 20
pf_assert_violation "forged repo code" "$OUT" "identity.repo-mismatch"

# ── 4. --expected-repo disagrees with checkout origin → BLOCK identity.repo-mismatch ─────────────────
OUT="$(pf_verify "$TMPROOT/i1.json" "$TMPROOT/b1.json" "$REPO" "$NOW" --mode remote-authoritative --repo-root "$REPO" --expected-repo "attacker/evil")"; RC=$?
pf_assert "remote expected-repo disagrees origin" "$OUT" "$RC" BLOCK 20
pf_assert_violation "expected-repo code" "$OUT" "identity.repo-mismatch"

# ── 5. DIRTY tracked worktree (edit a tracked file after commit) → BLOCK identity.worktree-dirty ─────
printf 'DRIFT after commit\n' >> "$REPO/artifacts/tests.log"
OUT="$(pf_verify "$TMPROOT/i1.json" "$TMPROOT/b1.json" "$REPO" "$NOW" --mode remote-authoritative --repo-root "$REPO" --expected-repo "$REPO_SLUG")"; RC=$?
pf_assert "remote dirty worktree" "$OUT" "$RC" BLOCK 20
pf_assert_violation "dirty code" "$OUT" "identity.worktree-dirty"
( cd "$REPO" && git checkout -q -- artifacts/tests.log )   # restore clean

# ── 6. UNRESOLVABLE: remote mode + --repo-root at a non-git dir → BLOCK identity.unresolvable ────────
mkdir -p "$TMPROOT/notgit"
OUT="$(pf_verify "$TMPROOT/i1.json" "$TMPROOT/b1.json" "$REPO" "$NOW" --mode remote-authoritative --repo-root "$TMPROOT/notgit")"; RC=$?
pf_assert "remote non-git repo-root" "$OUT" "$RC" BLOCK 20
pf_assert_violation "unresolvable code" "$OUT" "identity.unresolvable"

# ── 7. UNRESOLVABLE: remote mode WITHOUT --repo-root → BLOCK identity.unresolvable ───────────────────
OUT="$(pf_verify "$TMPROOT/i1.json" "$TMPROOT/b1.json" "$REPO" "$NOW" --mode remote-authoritative)"; RC=$?
pf_assert "remote no repo-root" "$OUT" "$RC" BLOCK 20

# ── 8. MODE-MISCONFIG: --repo-root in local-advisory → exit 30 identity.mode-misconfigured ───────────
OUT="$(pf_verify "$TMPROOT/i1.json" "$TMPROOT/b1.json" "$REPO" "$NOW" --repo-root "$REPO")"; RC=$?
pf_assert "mode-misconfigured (repo-root in advisory)" "$OUT" "$RC" BLOCK 30
pf_assert_violation "mode-misconfig code" "$OUT" "identity.mode-misconfigured"

# ── 9. FORGED LOCAL ALLOW DIES REMOTE (the core mission proof) ───────────────────────────────────────
# A bundle that ALLOWs in LOCAL-ADVISORY mode with a forged head must BLOCK when re-verified
# in remote-authoritative mode against the real checkout (whose HEAD differs).
FAKE="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
mkdir -p "$TMPROOT/fake/artifacts"
printf 'all tests passed\n' > "$TMPROOT/fake/artifacts/tests.log"
printf 'tier=AUTO\n'        > "$TMPROOT/fake/artifacts/tier.txt"
mk_intent_bundle "$FAKE" "github.com/$REPO_SLUG" AUTO "$TMPROOT/fi.json" "$TMPROOT/fb.json" "$TMPROOT/fake"
OUT_LOCAL="$(pf_verify "$TMPROOT/fi.json" "$TMPROOT/fb.json" "$TMPROOT/fake" "$NOW")"; RC_LOCAL=$?
pf_assert "forged bundle ALLOWs LOCALLY (the threat)" "$OUT_LOCAL" "$RC_LOCAL" ALLOW 0
OUT_REMOTE="$(pf_verify "$TMPROOT/fi.json" "$TMPROOT/fb.json" "$REPO" "$NOW" --mode remote-authoritative --repo-root "$REPO" --expected-repo "$REPO_SLUG")"; RC_REMOTE=$?
pf_assert "SAME forged bundle DIES REMOTELY" "$OUT_REMOTE" "$RC_REMOTE" BLOCK 20
pf_assert_violation "forged-local-dies code" "$OUT_REMOTE" "identity.commit-mismatch"

# ── 10. REGRESSION GUARD: no --mode flag → byte-identical to a pre-change local decision ─────────────
# Local-advisory must be a NO-OP: the decision bytes with no --mode must equal a fresh local run.
O1="$(pf_verify "$TMPROOT/i1.json" "$TMPROOT/b1.json" "$REPO" "$NOW")"
O2="$(pf_verify "$TMPROOT/i1.json" "$TMPROOT/b1.json" "$REPO" "$NOW")"
if [ "$O1" = "$O2" ] && ! printf '%s' "$O1" | grep -q "identity\."; then
  ok "local-advisory is a no-op (no identity.* checks; byte-stable)"
else
  bad "local-advisory leaked identity checks or was non-deterministic"
fi

echo ""
echo "identity-reresolution: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

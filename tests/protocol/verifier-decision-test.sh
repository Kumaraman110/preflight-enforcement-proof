#!/usr/bin/env bash
# Behavioral test: the server-authoritative evidence verifier (pfverify) MVP.
#
# Proves the deterministic Policy Decision contract across the full matrix the mission
# requires: POSITIVE (ALLOW), REQUIRE_APPROVAL, and the fail-closed negatives —
# malformed, missing, stale, forged (artifact + resealed), contradictory, and
# dependency-failure. The AUTHORITATIVE result is the JSON `decision`; the process
# exit code mirrors it (0/10/20). No input may yield ALLOW without a fully-passed
# verification.
#
# Every fixture is a throwaway mktemp dir — the repo's real .preflight/ is never touched.
# Exit 0 = all assertions passed; exit 1 = at least one failed (or env unavailable).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

if ! _probe_python; then
  bad "no working python3/python interpreter — verifier cannot run (fail-closed: NOT green)"
  echo ""; echo "verifier-decision: ${PASS} passed, ${FAIL} failed"; exit 1
fi

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
NOW="2026-07-10T09:05:00Z"        # 5 min after the fixture evidence → fresh

# ── 1. POSITIVE — valid, fresh, AUTO tier → ALLOW / exit 0 ────────────────────────────────────────────
D="$TMPROOT/pos"; mkdir -p "$D"; pf_build_positive "$D" AUTO
OUT="$(pf_verify "$FX_INTENT" "$FX_BUNDLE" "$FX_ROOT" "$NOW")"; RC=$?
pf_assert "positive/AUTO" "$OUT" "$RC" ALLOW 0

# ── 2. REQUIRE_APPROVAL — valid, fresh, CONFIRM tier → REQUIRE_APPROVAL / exit 10 ─────────────────────
D="$TMPROOT/confirm"; mkdir -p "$D"; pf_build_positive "$D" CONFIRM
OUT="$(pf_verify "$FX_INTENT" "$FX_BUNDLE" "$FX_ROOT" "$NOW")"; RC=$?
pf_assert "confirm/CONFIRM tier" "$OUT" "$RC" REQUIRE_APPROVAL 10

# ── 3. BLOCK tier — verified evidence carries tier=BLOCK → BLOCK / exit 20 ────────────────────────────
D="$TMPROOT/blocktier"; mkdir -p "$D"; pf_build_positive "$D" BLOCK
OUT="$(pf_verify "$FX_INTENT" "$FX_BUNDLE" "$FX_ROOT" "$NOW")"; RC=$?
pf_assert "block-tier" "$OUT" "$RC" BLOCK 20

# ── 4. MALFORMED — bundle is not valid JSON → BLOCK / exit 20 ─────────────────────────────────────────
D="$TMPROOT/malformed"; mkdir -p "$D"; pf_build_positive "$D" AUTO
printf 'not json {{{' > "$D/bad-bundle.json"
OUT="$(pf_verify "$FX_INTENT" "$D/bad-bundle.json" "$FX_ROOT" "$NOW")"; RC=$?
pf_assert "malformed-bundle" "$OUT" "$RC" BLOCK 20

# ── 5. MALFORMED (schema) — required field removed → BLOCK schema.bundle.invalid ──────────────────────
D="$TMPROOT/schema"; mkdir -p "$D"; pf_build_positive "$D" AUTO
pf_mutate "$FX_BUNDLE" "$D/noissuer.json" "d.pop('issuer',None)"
OUT="$(pf_verify "$FX_INTENT" "$D/noissuer.json" "$FX_ROOT" "$NOW")"; RC=$?
pf_assert "schema-missing-required" "$OUT" "$RC" BLOCK 20
pf_assert_violation "schema-missing-required code" "$OUT" "schema.bundle.invalid"

# ── 6. MISSING evidence — drop the required tests-pass item → BLOCK evidence.missing ──────────────────
D="$TMPROOT/missing"; mkdir -p "$D"; pf_build_positive "$D" AUTO
pf_mutate "$FX_BUNDLE" "$D/missing.json" "d['evidence']=[e for e in d['evidence'] if e['type']!='tests-pass']"
pf_seal "$D/missing.json" "$FX_ROOT"    # reseal so digest is valid — isolate the MISSING signal
OUT="$(pf_verify "$FX_INTENT" "$D/missing.json" "$FX_ROOT" "$NOW")"; RC=$?
pf_assert "missing-required-evidence" "$OUT" "$RC" BLOCK 20
pf_assert_violation "missing code" "$OUT" "evidence.missing"

# ── 7. STALE — reference time is 2 days after evidence (> 86400s window) → BLOCK freshness.stale ──────
D="$TMPROOT/stale"; mkdir -p "$D"; pf_build_positive "$D" AUTO
OUT="$(pf_verify "$FX_INTENT" "$FX_BUNDLE" "$FX_ROOT" "2026-07-12T09:05:00Z")"; RC=$?
pf_assert "stale-window" "$OUT" "$RC" BLOCK 20
pf_assert_violation "stale code" "$OUT" "freshness.stale"

# ── 8. STALE (head) — evidence boundHead differs from subject head → BLOCK ────────────────────────────
D="$TMPROOT/headstale"; mkdir -p "$D"; pf_build_positive "$D" AUTO
pf_mutate "$FX_BUNDLE" "$D/hs.json" "
for e in d['evidence']: e['boundHead']='0000000deadbeef'"
pf_seal "$D/hs.json" "$FX_ROOT"
OUT="$(pf_verify "$FX_INTENT" "$D/hs.json" "$FX_ROOT" "$NOW")"; RC=$?
pf_assert "stale-head" "$OUT" "$RC" BLOCK 20

# ── 9. FORGED (artifact) — edit the artifact AFTER sealing → BLOCK hash.mismatch ──────────────────────
D="$TMPROOT/forged"; mkdir -p "$D"; pf_build_positive "$D" AUTO
printf 'TAMPERED after seal\n' > "$FX_ROOT/artifacts/tests.log"
OUT="$(pf_verify "$FX_INTENT" "$FX_BUNDLE" "$FX_ROOT" "$NOW")"; RC=$?
pf_assert "forged-artifact" "$OUT" "$RC" BLOCK 20
pf_assert_violation "forged code" "$OUT" "hash.mismatch"

# ── 10. FORGED (digest) — flip a claim WITHOUT resealing → BLOCK integrity.digest-mismatch ────────────
D="$TMPROOT/digest"; mkdir -p "$D"; pf_build_positive "$D" AUTO
pf_mutate "$FX_BUNDLE" "$D/dig.json" "
for e in d['evidence']:
  if e['type']=='push-tier': e['claims']['tier']='AUTO'
d['evidence'][0]['claims']['passed']=True
d['evidence'][0]['claims']['injected']='surprise'"   # change body, do NOT reseal
OUT="$(pf_verify "$FX_INTENT" "$D/dig.json" "$FX_ROOT" "$NOW")"; RC=$?
pf_assert "forged-digest-no-reseal" "$OUT" "$RC" BLOCK 20
pf_assert_violation "digest code" "$OUT" "integrity.digest-mismatch"

# ── 11. CONTRADICTORY — intentRef head disagrees with intent subject head → BLOCK ─────────────────────
D="$TMPROOT/contra"; mkdir -p "$D"; pf_build_positive "$D" AUTO
pf_mutate "$FX_BUNDLE" "$D/contra.json" "d['intentRef']['subjectHead']='9999999ccccccc'"
pf_seal "$D/contra.json" "$FX_ROOT"
OUT="$(pf_verify "$FX_INTENT" "$D/contra.json" "$FX_ROOT" "$NOW")"; RC=$?
pf_assert "contradiction-intentref" "$OUT" "$RC" BLOCK 20
pf_assert_violation "contradiction code" "$OUT" "contradiction.intentRef"

# ── 12. CONTRADICTORY (internal) — two evidence items disagree on boundHead → BLOCK ───────────────────
D="$TMPROOT/contra2"; mkdir -p "$D"; pf_build_positive "$D" AUTO
pf_mutate "$FX_BUNDLE" "$D/c2.json" "d['evidence'][1]['boundHead']='1111111aaaaaaa'"
pf_seal "$D/c2.json" "$FX_ROOT"
OUT="$(pf_verify "$FX_INTENT" "$D/c2.json" "$FX_ROOT" "$NOW")"; RC=$?
pf_assert "contradiction-internal-boundhead" "$OUT" "$RC" BLOCK 20

# ── 13. DEPENDENCY FAILURE — policy file absent → BLOCK dependency.unavailable / exit 20 ──────────────
D="$TMPROOT/dep"; mkdir -p "$D"; pf_build_positive "$D" AUTO
OUT="$( cd "$PROTO_ROOT" && "$PF_PY" -m verifier.pfverify --intent "$FX_INTENT" --bundle "$FX_BUNDLE" \
        --policy "$TMPROOT/does-not-exist.json" --evidence-root "$FX_ROOT" --now "$NOW" 2>/dev/null )"; RC=$?
pf_assert "dependency-missing-policy" "$OUT" "$RC" BLOCK 20
pf_assert_violation "dependency code" "$OUT" "dependency.unavailable"

# ── 14. FUTURE evidence — producedAt is AFTER now → BLOCK (contradiction.future-evidence) ─────────────
D="$TMPROOT/future"; mkdir -p "$D"; pf_build_positive "$D" AUTO
OUT="$(pf_verify "$FX_INTENT" "$FX_BUNDLE" "$FX_ROOT" "2026-07-10T08:00:00Z")"; RC=$?   # now BEFORE evidence
pf_assert "future-evidence" "$OUT" "$RC" BLOCK 20

# ── 15. AUTHENTICATED — resealing forger caught only WITH a key ───────────────────────────────────────
# Prove the honest MVP boundary: without a key a forger who reseals the digest gets ALLOW; with a key,
# the missing/invalid HMAC signature is a BLOCK. This is the load-bearing limitation, tested both ways.
D="$TMPROOT/auth"; mkdir -p "$D"; pf_build_positive "$D" CONFIRM
printf 'server-side-hmac-key-not-held-by-producer\n' > "$D/key.bin"
# forger flips CONFIRM -> AUTO and RESEALS the digest (no key)
pf_mutate "$FX_BUNDLE" "$D/reseal.json" "
for e in d['evidence']:
  if e['type']=='push-tier': e['claims']['tier']='AUTO'"
pf_seal "$D/reseal.json" "$FX_ROOT"     # digest recomputed to match the forgery
# (a) unauthenticated: digest matches → NOT caught (documented boundary)
OUT="$(pf_verify "$FX_INTENT" "$D/reseal.json" "$FX_ROOT" "$NOW")"; RC=$?
pf_assert "reseal-forger-unauthenticated (documented boundary)" "$OUT" "$RC" ALLOW 0
# (b) authenticated: key supplied, no valid signature → BLOCK
OUT="$(pf_verify "$FX_INTENT" "$D/reseal.json" "$FX_ROOT" "$NOW" --attestation-key-file "$D/key.bin")"; RC=$?
pf_assert "reseal-forger-authenticated" "$OUT" "$RC" BLOCK 20
pf_assert_violation "reseal-forger sig code" "$OUT" "integrity.signature-invalid"

# ── 16. PATH ESCAPE — artifact.path traverses outside the evidence root → BLOCK (defense-in-depth) ────
# A bundle must NOT be able to make the verifier hash arbitrary host files. We reseal WITHOUT recomputing
# artifact hashes so the digest stays valid — isolating the path-escape signal even under an unauthenticated
# run (this defense fires regardless of the B2 key boundary).
D="$TMPROOT/escape"; mkdir -p "$D"; pf_build_positive "$D" AUTO
printf 'SECRET OUTSIDE THE EVIDENCE ROOT\n' > "$TMPROOT/pf-outside-secret.txt"
pf_mutate "$FX_BUNDLE" "$D/escape.json" "d['evidence'][0]['artifact']['path']='../pf-outside-secret.txt'"
( cd "$PROTO_ROOT" && "$PF_PY" verifier/tools/seal_bundle.py --bundle "$D/escape.json" --evidence-root "$FX_ROOT" --no-recompute-artifacts >/dev/null )
OUT="$(pf_verify "$FX_INTENT" "$D/escape.json" "$FX_ROOT" "$NOW")"; RC=$?
pf_assert "artifact-path-escape" "$OUT" "$RC" BLOCK 20
pf_assert_violation "path-escape code" "$OUT" "artifact.path-escape"

# ── 17. AMBIGUOUS TIER — two push-tier items disagree (AUTO + CONFIRM) → BLOCK (no permissive pick) ───
# An attacker must not be able to smuggle in a second, more-permissive tier claim and have it chosen.
D="$TMPROOT/ambig"; mkdir -p "$D"; pf_build_positive "$D" AUTO
pf_mutate "$FX_BUNDLE" "$D/ambig.json" "
import copy
dup=copy.deepcopy([e for e in d['evidence'] if e['type']=='push-tier'][0])
dup['claims']['tier']='CONFIRM'
d['evidence'].append(dup)"
pf_seal "$D/ambig.json" "$FX_ROOT"
OUT="$(pf_verify "$FX_INTENT" "$D/ambig.json" "$FX_ROOT" "$NOW")"; RC=$?
pf_assert "ambiguous-tier-disagreement" "$OUT" "$RC" BLOCK 20
pf_assert_violation "ambiguous-tier code" "$OUT" "policy.tier-unresolved"

# ── 18. DETERMINISM — identical inputs produce byte-identical decision output ─────────────────────────
D="$TMPROOT/det"; mkdir -p "$D"; pf_build_positive "$D" AUTO
O1="$(pf_verify "$FX_INTENT" "$FX_BUNDLE" "$FX_ROOT" "$NOW")"
O2="$(pf_verify "$FX_INTENT" "$FX_BUNDLE" "$FX_ROOT" "$NOW")"
if [ "$O1" = "$O2" ]; then ok "determinism — identical decision bytes on repeat"; else bad "determinism — decision bytes differ across identical runs"; fi

echo ""
echo "verifier-decision: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

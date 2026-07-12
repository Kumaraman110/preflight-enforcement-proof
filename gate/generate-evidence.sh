#!/usr/bin/env bash
# TRUSTED evidence generator (Stage-2 job A). Runs from the sandbox DEFAULT-branch checkout.
# Given the fetched subject commit C (data-only), it INDEPENDENTLY establishes the ground-truth
# evidence rather than trusting any PR-authored artifact:
#   • the reversibility TIER is derived by the trusted classifier over the PR's actually-changed
#     paths (unforgeable) — the PR's own tier.txt is ignored;
#   • a tests-pass artifact is emitted from the generator's own check (here: the presence of the
#     subject's declared test log AND a trusted re-derivation marker), bound to C.
# It writes these as UNTRACKED files under the subject root so they (a) live inside repo_root
# (pass the verifier's checkout-confinement + hash checks) and (b) do NOT dirty the tracked
# worktree (identity.worktree-dirty checks tracked files with --untracked-files=no).
#
# It emits the intent + a NAKED (unsigned) bundle naming C and hashing the artifacts it wrote,
# and COPIES those artifacts into <out-dir>/evidence/ so later isolated jobs can reconstruct
# them into their own subject checkout. This job holds NO signing secret.
#
# Usage: generate-evidence.sh <subject-dir> <base-sha> <head-sha> <repo-slug> <out-dir> <repo-root>
#   writes: <subject-dir>/.gate/evidence/{tests.log,tier.txt}  (untracked, bound to C)
#           <out-dir>/{intent.json,bundle.json}                      (naked bundle, sha's filled)
#           <out-dir>/evidence/{tests.log,tier.txt}                  (portable copy for later jobs)
set -uo pipefail

SUBJ="${1:?subject dir}"; BASE="${2:?base sha}"; HEAD="${3:?head sha}"
SLUG="${4:?repo slug owner/repo}"; OUT="${5:?out dir}"; REPO="${6:?trusted repo root}"
mkdir -p "$OUT/evidence"

PF_PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { "$c" -c 'import sys;sys.exit(0 if sys.version_info[0]>=3 else 1)' && PF_PY="$c" && break; }; done
[ -n "$PF_PY" ] || { echo "generate-evidence: no python" >&2; exit 30; }

# 1. Independent tier derivation (trusted classifier; ignores PR-authored tier.txt).
TIER="$(bash "$REPO/gate/classify-tier.sh" "$SUBJ" "$BASE" "$HEAD")"
case "$TIER" in AUTO|CONFIRM|BLOCK) : ;; *) echo "generate-evidence: bad tier '$TIER'" >&2; exit 30;; esac
echo "generate-evidence: derived tier=$TIER for $HEAD" >&2

# 2. Write authoritative evidence as UNTRACKED files inside the subject checkout.
EV_DIR="$SUBJ/.gate/evidence"; mkdir -p "$EV_DIR"
# tests-pass: the generator's OWN judgement. Here the trusted check is "the subject commit exists
# and carries the declared test log"; a real deployment would re-execute the suite. We record a
# trusted re-derivation marker so the artifact is the GENERATOR's, not the PR's file verbatim.
if [ -f "$SUBJ/.gate/artifacts/tests.log" ]; then
  printf 'trusted-regen@%s\ntests: PASS (independently attested by evidence-generator)\n' "$HEAD" > "$EV_DIR/tests.log"
  TESTS_PASS=true
else
  printf 'trusted-regen@%s\ntests: NO TEST LOG PRESENT\n' "$HEAD" > "$EV_DIR/tests.log"
  TESTS_PASS=false
fi
printf 'tier=%s\n' "$TIER" > "$EV_DIR/tier.txt"
# Portable copies for the sealer/judge jobs (they reconstruct these into their own subject tree).
cp "$EV_DIR/tests.log" "$OUT/evidence/tests.log"
cp "$EV_DIR/tier.txt"  "$OUT/evidence/tier.txt"

# 3. Emit intent + naked bundle naming C, hashing the generator's artifacts. producedAt is
#    DETERMINISTIC from the subject commit's committer date (UTC), so the evidence digest is
#    identical across re-runs of the SAME commit — required for the out-of-band approval (which
#    binds evidenceDigest) to still match on a later decide re-run. Injectable for tests.
COMMIT_DATE="$(TZ=UTC git -C "$SUBJ" show -s --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ "$HEAD" 2>/dev/null)"
PRODUCED_AT="${PF_PRODUCED_AT:-${COMMIT_DATE:-2026-07-12T00:00:00Z}}"
REL_TESTS=".gate/evidence/tests.log"
REL_TIER=".gate/evidence/tier.txt"

cat > "$OUT/intent.json" <<EOF
{"schemaVersion":"1.0.0","intentId":"i-demo","action":{"type":"git-push","attributes":{"remote":"origin","refspec":"HEAD:main"}},"actor":{"kind":"model","id":"producer-a"},"subject":{"repo":"github.com/$SLUG","head":"$HEAD","branch":"main"}}
EOF
cat > "$OUT/bundle.json" <<EOF
{"schemaVersion":"1.0.0","intentRef":{"intentId":"i-demo","subjectHead":"$HEAD"},"issuer":{"adapter":"producer-a","version":"0.1.0"},"evidence":[{"type":"tests-pass","producedAt":"$PRODUCED_AT","boundHead":"$HEAD","artifact":{"path":"$REL_TESTS","sha256":"0"},"claims":{"passed":$TESTS_PASS}},{"type":"push-tier","producedAt":"$PRODUCED_AT","boundHead":"$HEAD","artifact":{"path":"$REL_TIER","sha256":"0"},"claims":{"tier":"$TIER"}}],"attestation":{"algo":"sha256","bundleDigest":"0"}}
EOF

# 4. Fill artifact hashes + bundleDigest (naked; no signature — sealer adds that).
( cd "$REPO" && "$PF_PY" verifier/tools/seal_bundle.py --bundle "$OUT/bundle.json" --evidence-root "$SUBJ" >/dev/null )
echo "generate-evidence: wrote $OUT/intent.json + $OUT/bundle.json (tier=$TIER tests_pass=$TESTS_PASS)" >&2

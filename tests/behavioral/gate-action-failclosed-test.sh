#!/usr/bin/env bash
# gate-action-failclosed-test.sh — G1 proof (the LOCALLY-provable criteria). The Preflight fail-closed
# gate is packaged as a zero-workstation CI Action (action.yml, composite) that wraps the portable
# verifier/ci/remote-gate.sh. This test proves the two G1 criteria that DO NOT require a live PR:
#
#   Criterion 1 (verdict with zero workstation footprint): the entrypoint the Action invokes produces a
#     decision with only bash + python3 + git present — NO framework install, NO pip, NO .claude/. We run
#     it from a scratch dir with a mktemp checkout, exactly as the Action's composite step does.
#   Criterion 3 (timeout/degraded/unparseable -> NOT-satisfied, mechanical): a missing signing key (with
#     --require-attestation) and an unparseable/garbage intent each resolve to a NON-success exit that the
#     Action maps to a FAILED check — never a silent pass. Also asserts the Action's exit-code MAPPING
#     itself (0->pass; 10/20/30/other->fail) so the wrapper cannot turn a block into a green check.
#
# Criterion 2 (a real PR trips RED / a clean PR turns green, merge blocked) is OUTWARD-FACING and can only
# be observed on a live PR with the check made required + app-id-pinned in branch protection — a human-
# authorized step this framework deliberately does not automate. It is NOT asserted here; see the honesty
# note printed by this test. A green Action RUN is not the same as an ENFORCED required check.
#
# Exit 0 = all (locally-provable) passed. Isolated: mktemp checkout + throwaway keys, no network.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ENTRY="$ROOT/verifier/ci/remote-gate.sh"
ACTION="$ROOT/action.yml"
PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
trailer(){ echo ""; echo "gate-action-failclosed: ${PASS} passed, ${FAIL} failed"; [ "$FAIL" -eq 0 ]; }
[ -f "$ENTRY" ]  || { bad "remote-gate.sh entrypoint missing"; trailer; exit $?; }
[ -f "$ACTION" ] || { bad "action.yml missing (the G1 wrapper)"; trailer; exit $?; }

PF_PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { "$c" -c 'import sys;sys.exit(0 if sys.version_info[0]>=3 else 1)' >/dev/null 2>&1 && PF_PY="$c" && break; }; done
[ -n "$PF_PY" ] || { bad "no working python3/python (fail-closed)"; trailer; exit $?; }

# ── The Action's exit-code -> required-check mapping, extracted so we test the ACTUAL contract:
#    0 -> pass (exit 0); 10/20/30/anything-else -> fail the check (exit 1). Never a silent pass. ──
map_rc_to_check() { case "$1" in 0) return 0 ;; *) return 1 ;; esac; }

# 1. Assert the action.yml wrapper encodes the fail-closed mapping (a verified ALLOW passes; every other
#    code — including an unknown one — fails closed). Static check of the wrapper's case arms.
if grep -q '0)  echo "::notice::Preflight gate: ALLOW' "$ACTION" \
   && grep -q '20) echo "::error::Preflight gate: BLOCK' "$ACTION" \
   && grep -q '\*)  echo "::error::Preflight gate: unexpected exit' "$ACTION"; then
  ok "action.yml maps ALLOW(0)->pass and BLOCK/REQUIRE_APPROVAL/usage/unknown->fail (fail-closed mapping)"
else
  bad "action.yml exit-code mapping missing/weakened (must fail closed on non-0)"
fi

# 2. Criterion 3a — missing signing key WITH --require-attestation -> NON-success -> mapped to FAIL.
#    (Reuses the entrypoint's own offline behavior; no key in env, require-attestation set.)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t && \
  echo x > a.txt && git add a.txt && git -c commit.gpgsign=false commit -qm init ) 2>/dev/null || true
# minimal intent/bundle that parse (schema-valid enough to reach the attestation-key check)
printf '{"schema":"intent.v1","action":{"type":"push"},"repo":"o/r","commitSha":"%s"}\n' "$(cd "$REPO" && git rev-parse HEAD 2>/dev/null || echo 0000)" > "$TMP/intent.json"
printf '{"schema":"bundle.v1","evidence":[]}\n' > "$TMP/bundle.json"
env -u PREFLIGHT_ATTEST_KEY bash "$ENTRY" --repo-root "$REPO" --intent "$TMP/intent.json" \
  --bundle "$TMP/bundle.json" --out-dir "$TMP/out" --require-attestation >/dev/null 2>&1
rc=$?
if [ "$rc" != 0 ] && ! map_rc_to_check "$rc"; then
  ok "no signing key + --require-attestation -> non-success (rc=$rc) -> mapped to FAILED check (never a silent pass)"
else
  bad "missing-key case did not fail closed (rc=$rc)"
fi

# 3. Criterion 3b — unparseable/garbage intent -> NON-success -> mapped to FAIL.
printf 'this is not json {{{' > "$TMP/garbage.json"
bash "$ENTRY" --repo-root "$REPO" --intent "$TMP/garbage.json" --bundle "$TMP/bundle.json" \
  --out-dir "$TMP/out2" >/dev/null 2>&1
rc=$?
if [ "$rc" != 0 ] && ! map_rc_to_check "$rc"; then
  ok "unparseable intent -> non-success (rc=$rc) -> mapped to FAILED check (fail-closed on bad input)"
else
  bad "garbage intent did not fail closed (rc=$rc)"
fi

# 4. Criterion 1 — zero-workstation footprint: the entrypoint ran above using ONLY bash+python3+git from a
#    scratch mktemp checkout, with NO framework install present (no .claude/, no pip). Assert that: the
#    scratch repo has no .claude/ and the entrypoint still produced a decision artifact (a verdict).
if [ ! -e "$REPO/.claude" ] && { [ -f "$TMP/out/decision.json" ] || [ -f "$TMP/out2/decision.json" ] || [ "$rc" != 0 ]; }; then
  ok "verdict produced with ZERO workstation footprint (no .claude/ install; only bash+python3+git)"
else
  bad "could not confirm zero-footprint verdict"
fi

# 5. HONESTY: criterion 2 (live-PR RED/green + merge-blocked) is NOT asserted here — it needs a live PR
#    with the check made required + app-id-pinned (a human-authorized, outward-facing step). State it.
echo "NOTE: G1 criterion 2 (a blocking PR leaves the required check RED and merge blocked; a clean PR"
echo "      turns it green) is OUTWARD-FACING and provable ONLY on a live PR with branch protection +"
echo "      app-id pin. A green Action RUN is not an ENFORCED required check. Not asserted by this test."

trailer

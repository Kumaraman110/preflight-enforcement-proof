#!/usr/bin/env bash
# Behavioral test for the pre-push-gate-check remote/repo guard (A1 fix).
#
# Proves, by feeding crafted Bash-tool JSON to the hook and reading the exit code +
# stderr, that:
#   INVERTED TOPOLOGY (the live SessionToken clone: branch.remote=origin, but origin
#   is the LEGACY-PROD repo and the real target is a DIFFERENT remote 'poc'):
#     I1. A push to a FORBIDDEN remote (origin=legacy) is BLOCKED with a de-steered
#         message that does NOT recommend a remote.
#     I2. A `gh pr create` resolving to the forbidden repo (no --repo → origin) is
#         BLOCKED (closes the pre-fix silent EXIT=0 hole), de-steered.
#     I3. A `gh pr create --repo <forbidden>` is BLOCKED, de-steered.
#     I4. NO block message recommends pushing to / targeting the legacy repo
#         (the original A1 dangerous-steering defect).
#   NORMAL TOPOLOGY (origin = the correct canonical target; a separate 'evil' remote
#   = a legacy-prod-like repo). Regression baseline — these must STILL fire:
#     N1. push to a non-canonical named remote → BLOCK.
#     N2. force-push to a protected branch → BLOCK.
#     N3. `gh pr create --repo <wrong>` → BLOCK.
#     N4. correct canonical push → NOT blocked by the remote guard (falls through to
#         the evidence gate).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/../../hooks/pre-push-gate-check"

if [ ! -x "$HOOK" ] && [ ! -f "$HOOK" ]; then
  echo "FAIL: hook not found at $HOOK" >&2
  exit 1
fi

LEGACY_URL="https://github.com/United-Airlines-Org/CPSL.git"        # forbidden / legacy prod
TARGET_URL="https://github.com/United-Airlines-Org/cyf.cpsl_core.git" # the real migration target
LEGACY_SLUG="United-Airlines-Org/CPSL"

PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# run_hook <command-string> → sets RC and OUT (stderr+stdout merged).
# The command strings used in this test contain no double-quotes or backslashes, so a
# direct interpolation into the JSON is valid — no per-call encoder subprocess (which,
# on this Windows/Git-Bash setup, costs ~1.5s each and dominates wall-clock).
run_hook() {
  local cmd="$1" json
  json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"${cmd}\"}}"
  OUT="$(printf '%s' "$json" | bash "$HOOK" 2>&1)"; RC=$?
}
# Does block output recommend a specific remote/repo (the A1 dangerous-steering defect)?
has_steer() { printf '%s' "$1" | grep -qiE "Use '?origin'?|Use --repo|Use ${LEGACY_SLUG}"; }

# ── Build the INVERTED-topology repo ─────────────────────────────────────────
INV="$(mktemp -d)/inverted"; mkdir -p "$INV"; ( cd "$INV"
  git init -q; git config user.email t@t; git config user.name t
  git remote add origin "$LEGACY_URL"     # origin = LEGACY PROD (forbidden)
  git remote add poc    "$TARGET_URL"     # poc    = the real target
  mkdir -p .preflight
  # branch.remote=origin is the WRONG (inverted) value the live consumer had; the
  # forbiddenRemotes/forbiddenRepos denylist is what makes the guard correct anyway.
  cat > .preflight/config.json <<JSON
{ "branch": { "base": "AccountLookUp_POC", "remote": "origin",
              "forbiddenRemotes": ["origin"],
              "forbiddenRepos": ["${LEGACY_SLUG}"] } }
JSON
  echo x > f; git add -A; git commit -qm init
  git checkout -q -b AccountLookUp_POC
) >/dev/null 2>&1

cd "$INV"
STEER_FOUND=0   # accumulates across I1–I3; asserted as I4 (no extra hook calls)

# I1: push to forbidden remote origin (=legacy) → BLOCK, de-steered.
run_hook 'git push origin HEAD:AccountLookUp_POC'
has_steer "$OUT" && { STEER_FOUND=1; echo "  steer in I1: $OUT" >&2; }
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'FORBIDDEN'; then
  ok "I1 inverted: push to forbidden 'origin' (legacy) is BLOCKED"
else bad "I1 inverted: expected BLOCK(2)+FORBIDDEN, got RC=$RC OUT=$OUT"; fi

# I2: gh pr create with NO --repo → resolves to origin (=legacy) → BLOCK.
# (Pre-fix this silently EXITED 0 — the most dangerous hole.)
run_hook 'gh pr create --base AccountLookUp_POC'
has_steer "$OUT" && { STEER_FOUND=1; echo "  steer in I2: $OUT" >&2; }
if [ "$RC" -eq 2 ]; then
  ok "I2 inverted: 'gh pr create' (no --repo → legacy origin) is BLOCKED (was a silent allow pre-fix)"
else bad "I2 inverted: expected BLOCK(2), got RC=$RC OUT=$OUT"; fi

# I3: gh pr create --repo <legacy> → BLOCK.
run_hook "gh pr create --repo ${LEGACY_SLUG} --base AccountLookUp_POC"
has_steer "$OUT" && { STEER_FOUND=1; echo "  steer in I3: $OUT" >&2; }
if [ "$RC" -eq 2 ]; then
  ok "I3 inverted: 'gh pr create --repo <legacy>' is BLOCKED"
else bad "I3 inverted: expected BLOCK(2), got RC=$RC OUT=$OUT"; fi

# I4: NO block message recommended the legacy remote/repo across I1–I3 (the A1 steer).
if [ "$STEER_FOUND" -eq 0 ]; then
  ok "I4 inverted: no block message recommends the legacy remote/repo (de-steered)"
else bad "I4 inverted: a block message still recommends the forbidden remote/repo"; fi

# ── Build the NORMAL-topology repo (regression baseline) ─────────────────────
NORM="$(mktemp -d)/normal"; mkdir -p "$NORM"; ( cd "$NORM"
  git init -q; git config user.email t@t; git config user.name t
  git remote add origin "$TARGET_URL"   # origin = correct canonical target
  git remote add evil   "$LEGACY_URL"   # a legacy-prod-like remote, NOT configured canonical
  mkdir -p .preflight
  cat > .preflight/config.json <<JSON
{ "branch": { "base": "main", "remote": "origin" } }
JSON
  echo x > f; git add -A; git commit -qm init
  git checkout -q -b feature/work
) >/dev/null 2>&1

cd "$NORM"

# N1: push to non-canonical named remote 'evil' → now CONFIRM (three-tier policy), not hard BLOCK.
# A non-canonical remote is consequential-but-human-may-proceed, so it escalates to
# permissionDecision:ask (AFTER the evidence gate) rather than a hard exit-2. WITHOUT gate evidence
# here, the evidence gate fires first (exit 2) and the tier logic is never reached — so we assert only
# that the remote guard NO LONGER hard-blocks with a 'non-canonical/configured remote' BLOCKED message;
# the full CONFIRM outcome is asserted in pre-push-bare-remote-test.sh (which sets up evidence). A remote
# on the explicit forbiddenRepos denylist stays a hard BLOCK — see I1; 'evil' is not listed.
run_hook 'git push evil HEAD:feature/work'
if printf '%s' "$OUT" | grep -qiE 'BLOCKED: push targets remote .* not the configured'; then
  bad "N1 normal: 'evil' was hard-BLOCKED by the old wrong-remote guard — should now be CONFIRM-tier, not exit-2 block. OUT=$OUT"
else
  ok "N1 normal: non-canonical remote 'evil' is no longer hard-blocked by the wrong-remote guard (now CONFIRM-tier; full ask-outcome asserted in pre-push-bare-remote-test)"
fi

# N2: force-push to protected branch main → BLOCK.
run_hook 'git push --force origin HEAD:main'
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'force-push'; then
  ok "N2 normal: force-push to protected 'main' still BLOCKED"
else bad "N2 normal: expected BLOCK(2)+force-push, got RC=$RC OUT=$OUT"; fi

# N3: gh pr create --repo <wrong> → BLOCK.
run_hook 'gh pr create --repo some/other-repo'
if [ "$RC" -eq 2 ]; then
  ok "N3 normal: 'gh pr create --repo <wrong>' still BLOCKED"
else bad "N3 normal: expected BLOCK(2), got RC=$RC OUT=$OUT"; fi

# N4: correct canonical push → NOT blocked by the remote guard. It falls through to
#     the evidence gate, which blocks for a DIFFERENT reason (no evidence files). We
#     assert the remote guard did not fire: the output must NOT mention FORBIDDEN or
#     'non-canonical'/'configured remote' — only the evidence-gate message.
run_hook 'git push origin HEAD:feature/work'
if printf '%s' "$OUT" | grep -qiE 'FORBIDDEN|non-canonical|configured remote'; then
  bad "N4 normal: correct canonical push was wrongly caught by the remote guard: $OUT"
else
  ok "N4 normal: correct canonical push passes the remote guard (falls through to evidence gate)"
fi

echo ""
echo "pre-push remote-guard tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

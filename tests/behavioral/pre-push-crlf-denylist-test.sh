#!/usr/bin/env bash
# Behavioral test for the CRLF fail-open in pre-push-gate-check's forbidden-destination denylist (G1).
#
# THE BUG (confirmed empirically on Git-Bash, jq-1.8.1): jq emits CRLF line endings, so
# `jq -r '.branch.forbiddenRemotes[]?'` produces `origin\r\nlegacy-prod\r\n`. Command substitution
# `$(...)` strips only the FINAL trailing \r\n — so every element EXCEPT THE LAST keeps a trailing \r.
# The denylist comparison then does `[ "origin\r" = "origin" ]` -> FALSE, so a forbidden/denylisted
# PROD remote listed ANYWHERE BUT LAST is NOT detected and the push is silently ALLOWED (fail-OPEN).
# A user denylists their prod remote, believes it protected, and under a multi-element-array condition
# the gate waves the push to prod through. The existing tests pass DESPITE this because they only use
# SINGLE-element denylists (one element = the last element, whose \r $() strips).
#
# THE PRINCIPLE (this whole fix family): a safety check that CANNOT verify its input (here: CRLF-corrupted
# denylist element) must FAIL CLOSED (block), never fail open (allow).
#
# RED->GREEN (the critical proof):
#   C1 — MULTI-element forbiddenRemotes, the NON-LAST element is the push target (carries \r):
#          RED  (current code): push ALLOWED (exit 0, permissionDecision:allow) — the fail-open bug.
#          GREEN (after fix)  : push BLOCKED (exit 2, FORBIDDEN) — denylist matches despite the CRLF.
#   C2 — MULTI-element forbiddenRepos, the NON-LAST slug is the push target (carries \r): same RED->GREEN.
#   C3 — regression: SINGLE-element forbiddenRemotes (the existing passing case) STILL blocks.
#   C4 — regression: a genuinely-SAFE remote not on any denylist STILL auto-allows (fix does not over-block).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/../../hooks/pre-push-gate-check"

[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# run_hook <command> -> sets RC and OUT (stderr+stdout merged). Body-direct (_PFG_WATCHDOG_CHILD=1)
# to bypass the Layer-1 self-watchdog re-exec — on this slow-spawn box a legitimate body exceeds the
# 8s watchdog deadline and would turn every outcome into a spurious exit-2 (the documented spawn tax);
# this drives the exact code that runs AS the watchdog child in production. (Same posture as
# pre-push-remote-guard-test.sh.)
run_hook() {
  local cmd="$1" json
  json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"${cmd}\"}}"
  OUT="$(printf '%s' "$json" | _PFG_WATCHDOG_CHILD=1 bash "$HOOK" 2>&1)"; RC=$?
}

# Build a repo with the given config JSON, fresh gate evidence at HEAD (so the evidence gate PASSES and
# the tier decision is actually reached), and an unprotected topic branch. Echoes the repo dir.
make_repo() {  # $1 = origin URL ; $2 = config JSON body (the .branch object contents)
  local url="$1" branchcfg="$2" d
  d="$(mktemp -d)/repo"; mkdir -p "$d"
  ( cd "$d"
    git init -q; git config user.email t@t; git config user.name t
    git remote add origin "$url"
    mkdir -p .preflight .preflight/gate
    printf '{ "branch": %s }\n' "$branchcfg" > .preflight/config.json
    echo x > f; git add -A; git commit -qm init
    git checkout -q -b topic-work          # unprotected branch (base is 'main')
    # Fresh evidence stamped at HEAD so pre-push-gate (evidence gate) returns 0 and we reach the tier.
    local head; head="$(git rev-parse HEAD)"
    printf 'HEAD=%s\n' "$head" > .preflight/gate/stage1-clean
    printf 'HEAD=%s\n' "$head" > .preflight/gate/tests-pass
  ) >/dev/null 2>&1
  printf '%s' "$d"
}

# ── C1: MULTI-element forbiddenRemotes, NON-LAST element ('origin') is the target ───────────────
# origin is element 1 of 2 -> jq emits "origin\r\n<decoy>\r\n" -> $() leaves "origin\r\n<decoy>" ->
# the loop sees "origin\r" (!= "origin") and MISSES it. branch.remote=origin and the URL is benign
# (non-prod), so with the bug the push falls through every CONFIRM check to AUTO -> ALLOW (fail-open).
R1="$(make_repo 'https://github.com/acme/app.git' \
  '{ "base": "main", "remote": "origin", "forbiddenRemotes": ["origin", "zzz-decoy-remote"], "forbiddenRepos": [] }')"
cd "$R1"
run_hook 'git push origin HEAD:topic-work'
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'FORBIDDEN'; then
  ok "C1: push to a NON-LAST CRLF-corrupted forbidden remote 'origin' is BLOCKED (denylist robust to CRLF)"
else
  bad "C1: FAIL-OPEN — push to a non-last forbidden remote was ALLOWED (RC=$RC, OUT=$OUT)"
fi

# ── C2: MULTI-element forbiddenRepos, NON-LAST slug ('acme/billing') is the target ──────────────
# origin URL resolves to slug 'acme/billing', element 1 of 2 in forbiddenRepos -> carries \r ->
# _pfg_url_to_slug("acme/billing\r") != "acme/billing" -> MISSED (fail-open). The slug is DELIBERATELY
# NOT a prod-pattern word (no prod/release/live/legacy segment), and branch.remote=origin (so the
# wrong-remote CONFIRM does not fire) with no safeRemotes (safelist inert) — so the forbiddenRepos B0
# denylist is the ONLY thing that can stop this push. With the CRLF bug it misses -> AUTO allow.
R2="$(make_repo 'https://github.com/acme/billing.git' \
  '{ "base": "main", "remote": "origin", "forbiddenRemotes": [], "forbiddenRepos": ["acme/billing", "acme/zzz-decoy"] }')"
cd "$R2"
run_hook 'git push origin HEAD:topic-work'
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'FORBIDDEN'; then
  ok "C2: push to a NON-LAST CRLF-corrupted forbidden REPO slug is BLOCKED (denylist robust to CRLF)"
else
  bad "C2: FAIL-OPEN — push to a non-last forbidden repo slug was ALLOWED (RC=$RC, OUT=$OUT)"
fi

# ── C3: regression — SINGLE-element forbiddenRemotes (the only element = last = \r-clean) STILL blocks ─
R3="$(make_repo 'https://github.com/acme/app.git' \
  '{ "base": "main", "remote": "origin", "forbiddenRemotes": ["origin"], "forbiddenRepos": [] }')"
cd "$R3"
run_hook 'git push origin HEAD:topic-work'
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'FORBIDDEN'; then
  ok "C3 regression: single-element forbidden remote STILL BLOCKED (no regression)"
else
  bad "C3 regression: single-element forbidden remote should BLOCK, got RC=$RC OUT=$OUT"
fi

# ── C4: regression — a genuinely-SAFE remote (not on any denylist, non-prod) STILL auto-allows ──────
# Proves the \r-strip does not over-block: the safe push must remain AUTO (exit 0, allow).
R4="$(make_repo 'https://github.com/acme/app.git' \
  '{ "base": "main", "remote": "origin", "forbiddenRemotes": ["other-remote", "zzz-decoy"], "forbiddenRepos": ["acme/somethingelse", "acme/zzz"] }')"
cd "$R4"
run_hook 'git push origin HEAD:topic-work'
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision":"allow"'; then
  ok "C4 regression: a safe remote not on any denylist STILL auto-allows (fix does not over-block)"
else
  bad "C4 regression: safe push should AUTO-allow (exit 0 + allow), got RC=$RC OUT=$OUT"
fi

echo ""
echo "pre-push-crlf-denylist tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

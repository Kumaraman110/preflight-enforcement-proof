#!/usr/bin/env bash
# Behavioral test for the structural push-arg parser (H1 + H2 fix) in pre-push-gate-check.
#
# THE BUGS (from .release-audit/FRAMEWORK-SCRUTINY-FINDINGS.md + H2-FIX-DESIGN.md):
#   H2 — the old regex detector required the literal adjacency `git\s+push`, so 17 of 21 invocation forms
#        (git -C … push, git -c k=v push, command git push, \git push, GIT_DIR=… git push, /usr/bin/git
#        push, (git push …), { git push …; }, eval 'git push', bash -c 'git push', xargs git push, …) ALL
#        evaded the gate → exit 0 ungated, bypassing forbidden-remote / force-to-protected / CONFIRM tiers.
#        The downstream extractor (grep 'git\s+push…') ALSO failed on those forms (empty arg list → the
#        forbidden checks silently skip), so detection AND extraction both had to be replaced.
#   H1 — a force-push via the '+' refspec shorthand (git push poc +main == refspec +main:main) was NOT
#        recognized as force (HAS_FORCE missed it) and TARGET_BRANCH kept the '+' ('+main' != 'main'), so a
#        forced rewrite of protected main was classified AUTO (silent allow).
#
# THE FIX: a structural tokenize-and-parse (_pfg_parse_push) replaces BOTH the regex detector and the grep
# extractor — it identifies the git program token (incl. command/\/env-prefix/abs-path), skips the global-
# option run via git's own option grammar, reads the subcommand, and parses the push args from ONE token
# list (so detection and extraction can't diverge). H1 is folded in: a '+'-source refspec OR --force/-f is
# FORCE, and a leading '+' is stripped before TARGET_BRANCH. A push that is PRESENT but unparseable (eval/
# bash -c/sh -c/xargs, or an unknown global option) FAILS CLOSED to CONFIRM, never a silent allow.
#
# THE PRINCIPLE: parse the STRUCTURE, not one surface spelling; and when a push can't be cleanly resolved,
# escalate (CONFIRM) rather than fall open (exit 0). Keyed on `git…push` TOKEN ORDER, not co-occurrence, so
# benign commands containing the word "push" are NOT over-blocked.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/../../hooks/pre-push-gate-engine"

[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# run_hook <command> -> sets RC and OUT. Body-direct (_PFG_WATCHDOG_CHILD=1) to bypass the Layer-1
# self-watchdog re-exec — on this slow-spawn box a legitimate body exceeds the 8s watchdog deadline (the
# documented G17 spawn tax) and would turn every outcome into a spurious exit-2; this drives the exact code
# that runs AS the watchdog child on a production host. (Same posture as the other pre-push-* tests.)
run_hook() {
  local cmd="$1" json
  json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"${cmd}\"}}"
  OUT="$(printf '%s' "$json" | _PFG_WATCHDOG_CHILD=1 bash "$HOOK" 2>&1)"; RC=$?
}

# Build a repo set up to REACH the guards: a FORBIDDEN remote 'poc', protected base 'main', fresh evidence
# (so the evidence gate passes and the tier decision is actually emitted), on an unprotected topic branch.
# Echoes the repo dir. The repo's own git dir is used via the command's `git -C <dir>` / `cd <dir>` form.
REPO="$(mktemp -d)/repo"; mkdir -p "$REPO"
( cd "$REPO"
  git init -q; git config user.email t@t; git config user.name t
  git remote add poc https://github.com/forbidden-org/prod-repo.git
  git remote add safe https://github.com/safe-org/app.git
  mkdir -p .preflight .preflight/gate
  cat > .preflight/config.json <<JSON
{ "branch": { "base": "main", "remote": "safe",
              "forbiddenRemotes": ["poc"], "forbiddenRepos": ["forbidden-org/prod-repo"] } }
JSON
  echo x > f; git add -A; git commit -qm init
  git checkout -q -b topic-work
  h="$(git rev-parse HEAD)"
  printf 'HEAD=%s\n' "$h" > .preflight/gate/stage1-clean
  printf 'HEAD=%s\n' "$h" > .preflight/gate/tests-pass
) >/dev/null 2>&1

# Helper: assert a command targeting the FORBIDDEN remote 'poc' is BLOCKED (exit 2 + FORBIDDEN). Each uses
# `git -C "$REPO"` / `cd "$REPO" &&` / etc. so PFG_TARGET_CWD anchors in the repo. The command runs from
# the repo dir too (the hook reads cwd as a fallback).
assert_block_forbidden() {  # $1 = label ; $2 = command (must target remote 'poc')
  run_hook "$2"
  if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'FORBIDDEN'; then
    ok "$1: BLOCKED (exit 2, forbidden-remote fires) — $2"
  else
    bad "$1: expected BLOCK(2)+FORBIDDEN, got RC=$RC OUT=$(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-120) — $2"
  fi
}

cd "$REPO"

echo "════════ Class 1 — global git options between git and push (the named H2 class) ════════"
assert_block_forbidden "C1a -C"          "git -C $REPO push --force poc main"
assert_block_forbidden "C1b -c k=v"      "git -c http.sslVerify=false push poc main"
assert_block_forbidden "C1c --git-dir="  "git --git-dir=$REPO/.git --work-tree=$REPO push poc main"
assert_block_forbidden "C1d -P"          "git -P push poc main"
assert_block_forbidden "C1e --bare"      "git --bare push poc main"
assert_block_forbidden "C1f combo"       "git -c a=b -C $REPO --no-pager push poc main"

echo "════════ Class 3 — command prefixes / alternate git spellings ════════"
assert_block_forbidden "C3a command git" "command git push poc main"
assert_block_forbidden "C3b env-prefix"  "GIT_DIR=$REPO/.git git push poc main"
# Note: \\git and /usr/bin/git forms are covered by the isolated parser unit-check in the test log; the
# end-to-end forbidden-remote assertion uses the forms most likely in an agent command.

echo "════════ Class 2 — shell grouping ════════"
assert_block_forbidden "C2a subshell"    "(git push poc main)"
assert_block_forbidden "C2b brace group" "{ git push poc main; }"

echo "════════ H1 — force via '+' refspec to a protected branch ════════"
# '+main' is a forced update of protected main. Must be recognized as force → force-to-protected HARD BLOCK
# (exit 2), NOT a silent AUTO allow. (Target the SAFE remote so it's the FORCE that blocks, not forbidden.)
run_hook "git push safe +main"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'force-push'; then
  ok "H1a: 'git push safe +main' (force via +refspec to protected main) -> BLOCKED (force-to-protected)"
else
  bad "H1a: expected BLOCK(2)+force-push, got RC=$RC OUT=$(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-120)"
fi
run_hook "git push safe +feature:main"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'force-push'; then
  ok "H1b: '+feature:main' (force, dest protected main) -> BLOCKED (force-to-protected)"
else
  bad "H1b: expected BLOCK(2)+force-push, got RC=$RC OUT=$(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-120)"
fi
# A '+'-refspec force to an UNPROTECTED branch must still be recognized as force (not silently AUTO) — it is
# not force-to-protected so it won't hard-block, but it must not be a silent allow on the forbidden remote.
assert_block_forbidden "H1c +unprotected on forbidden" "git push poc +topic-work"

echo "════════ Class 4 — indirection wrappers (FAIL-CLOSED → CONFIRM, not silent allow) ════════"
# A push wrapped in eval/bash -c/xargs cannot be parsed for its target → must CONFIRM (ask), never exit 0 allow.
run_hook "eval 'git push poc main'"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision":"ask"'; then
  ok "C4a eval: unparseable push -> CONFIRM (ask), not silent allow"
else
  bad "C4a eval: expected CONFIRM(ask), got RC=$RC OUT=$(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-160)"
fi
run_hook "bash -c 'git push poc main'"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision":"ask"'; then
  ok "C4b bash -c: unparseable push -> CONFIRM (ask), not silent allow"
else
  bad "C4b bash -c: expected CONFIRM(ask), got RC=$RC OUT=$(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-160)"
fi
run_hook "echo main | xargs git push poc"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision":"ask"'; then
  ok "C4c xargs: unparseable push -> CONFIRM (ask), not silent allow"
else
  bad "C4c xargs: expected CONFIRM(ask), got RC=$RC OUT=$(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-160)"
fi

echo "════════ NO-FALSE-POSITIVE set — benign commands must NOT be gated (exit 0, no ask/block) ════════"
# These contain the word 'push' or are git non-push commands; they must pass through (exit 0, not a push).
assert_passthrough() {  # $1 = label ; $2 = command
  run_hook "$2"
  # Not gated = exit 0 AND the output is not a CONFIRM/ask and not a BLOCK. (A non-push exits 0 with no JSON.)
  if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -qE '"permissionDecision"|BLOCKED'; then
    ok "$1: benign command passes through ungated (exit 0, no gate) — $2"
  else
    bad "$1: benign command was gated (RC=$RC OUT=$(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-120)) — $2"
  fi
}
assert_passthrough "NFP1 commit msg"   "git commit -m 'fix push bug'"
assert_passthrough "NFP2 npm push-docs" "npm run push-docs"
assert_passthrough "NFP3 echo push"     "echo do not push to prod"
assert_passthrough "NFP4 git status"    "git status"
assert_passthrough "NFP5 git -C status" "git -C $REPO status"
assert_passthrough "NFP6 git fetch"     "git fetch origin"
assert_passthrough "NFP7 git pushy"     "git pushy origin main"

echo "════════ Normal SAFE push still AUTO-allows (no regression to the happy path) ════════"
# Unprotected branch + the configured SAFE remote + non-force + fresh evidence → AUTO (permissionDecision:allow).
run_hook "git push safe topic-work"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision":"allow"'; then
  ok "AUTO: a safe push (unprotected branch, configured safe remote, non-force) still AUTO-allows"
else
  bad "AUTO: expected AUTO allow, got RC=$RC OUT=$(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-160)"
fi
# And the SAME safe push via the git -C form must ALSO AUTO-allow (the fix must not over-block the new forms).
run_hook "git -C $REPO push safe topic-work"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision":"allow"'; then
  ok "AUTO -C: a safe push via 'git -C <dir> push' also AUTO-allows (new form not over-blocked)"
else
  bad "AUTO -C: expected AUTO allow, got RC=$RC OUT=$(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-160)"
fi

echo "════════ Extractor correctness — the forbidden remote is parsed from the NEW forms ════════"
# Differential: the forbidden-remote BLOCK only fires if ARG_REMOTE was extracted correctly from `git -C …`.
# C1a above already proves it (BLOCK requires ARG_REMOTE=poc parsed); assert the message names 'poc'.
run_hook "git -C $REPO push poc main"
if printf '%s' "$OUT" | grep -q "FORBIDDEN destination 'poc'"; then
  ok "EXT: ARG_REMOTE extracted correctly from 'git -C <dir> push poc main' (message names 'poc')"
else
  bad "EXT: forbidden message did not name the parsed remote 'poc' — RC=$RC OUT=$(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-120)"
fi

echo ""
echo "pre-push-parser-bypass tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

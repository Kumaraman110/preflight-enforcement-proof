#!/usr/bin/env bash
# Behavioral test: ALTERNATE GIT-CONTEXT push handling (v0.10.0-rc.2 fix).
#
# THE BUG (v0.10.0-rc.1): `_pfg_target_cwd` resolved the effective repo from a leading `cd <dir>` ONLY. For
# `git -C <REPO> push` (and GIT_DIR=/GIT_WORK_TREE= env prefixes), PFG_TARGET_CWD fell back to the engine's
# own $PWD — an UNGOVERNED dir — so the evidence/tier gate read the wrong repo and FAILED OPEN (exit 0).
# A governed push to a real target repo was therefore ALLOWED via `git -C <dir> push`.  (The forbidden-
# REMOTE-NAME check reads the remote token structurally and already blocked those forms; the hole was the
# repo-SCOPED tier/evidence decision.)
#
# THE CONTRACT (mission Phase 3): resolve the effective repository from git -C / -C<dir> / --git-dir[=] /
# --work-tree[=] / GIT_DIR= / GIT_WORK_TREE= / leading `cd`, and apply that repo's normal policy; if a push
# is a governed candidate but the explicit git-context does NOT resolve to a directory → FAIL CLOSED
# (exit 2, unsupported-context), NEVER allow on ambiguity. Multiple pushes: the worst verdict wins.
#
# Deterministic + fast: uses _PFG_WATCHDOG_CHILD=1 (bypass the self-watchdog re-exec, like the sibling
# pre-push-* tests) and a repo staged to REACH the guards. Exit 0 = all passed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/../../hooks/pre-push-gate-engine"
[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK" >&2; exit 1; }
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
# Build the hook stdin JSON with jq so a command containing a Windows checkout path with BACKSLASHES
# (e.g. `git -C D:\a\repo\repo\... push`, as on a windows-latest CI checkout) is correctly ESCAPED. Raw
# "${cmd}" interpolation produced INVALID JSON there (\a \r are illegal JSON escapes) → the engine's
# jq extraction failed → raw-blob fallback → the git-push was not recognized (a spurious test FAIL, not a
# product defect). jq -n --arg is byte-safe for any path shape.
run_hook() { local cmd="$1" json; json="$(jq -n --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"; OUT="$(printf '%s' "$json" | _PFG_WATCHDOG_CHILD=1 bash "$HOOK" 2>&1)"; RC=$?; }

# Governed repo: forbidden remote 'poc', protected base 'main', safe remote 'safe'. No fresh evidence →
# a push to the SAFE remote on protected main is a governed decision (not a silent allow); a push to 'poc'
# is a forbidden-remote HARD BLOCK. Both guards are repo-scoped via PFG_TARGET_CWD.
REPO="$(mktemp -d)/repo"; mkdir -p "$REPO"
( cd "$REPO"
  git init -q; git config user.email t@t; git config user.name t; git config commit.gpgsign false
  git remote add poc  https://github.com/forbidden-org/prod-repo.git
  git remote add safe https://github.com/safe-org/app.git
  mkdir -p .preflight
  cat > .preflight/config.json <<JSON
{ "branch": { "base": "main", "remote": "safe", "forbiddenRemotes": ["poc"], "forbiddenRepos": ["forbidden-org/prod-repo"] } }
JSON
  git add -A; git commit -q -m init )

# A repo whose path CONTAINS A SPACE (Phase 3 requirement).
SPACEREPO="$(mktemp -d)/my repo"; mkdir -p "$SPACEREPO"
( cd "$SPACEREPO"; git init -q; git config user.email t@t; git config user.name t; git config commit.gpgsign false
  git remote add poc https://github.com/forbidden-org/prod-repo.git
  mkdir -p .preflight; printf '{"branch":{"base":"main","remote":"safe","forbiddenRemotes":["poc"],"forbiddenRepos":["forbidden-org/prod-repo"]}}' > .preflight/config.json
  git add -A; git commit -q -m init )

# ── A. FORBIDDEN-remote push must BLOCK across every git-context form (repo-scoped forbidden check) ──────
# Contract: an alt-context governed push must NEVER be a silent ALLOW. Acceptable: BLOCK(2) [forbidden
# OR unsupported OR fail-closed-config-unreachable]. It must be exit 2 here (the test fires from an
# outside cwd so config is unreachable → fail closed; OR the forbidden-name check fires → block).
assert_forbidden() { run_hook "$2"; [ "$RC" = 2 ] && ok "$1 → BLOCK(2) [not a silent allow]" || bad "$1 expected BLOCK(2), got RC=$RC — $2"; }
assert_forbidden "A1 git -C <sp>"        "git -C $REPO push poc main"
assert_forbidden "A2 git -C<dir>"        "git -C$REPO push poc main"
assert_forbidden "A3 --git-dir="         "git --git-dir=$REPO/.git push poc main"
assert_forbidden "A4 --git-dir <sp>"     "git --git-dir $REPO/.git push poc main"
assert_forbidden "A5 --git-dir + --work-tree" "git --git-dir=$REPO/.git --work-tree=$REPO push poc main"
assert_forbidden "A6 GIT_DIR= env"       "GIT_DIR=$REPO/.git git push poc main"
assert_forbidden "A7 combo -c -C"        "git -c a=b -C $REPO --no-pager push poc main"
assert_forbidden "A8 nested bash -c"     "bash -c 'git -C $REPO push poc main'"
assert_forbidden "A9 space path -C"      "git -C '$SPACEREPO' push poc main"
# multi-push, worst-wins: a safe-looking first push followed by a forbidden -C push must BLOCK overall.
assert_forbidden "A10 multi worst-wins"  "echo ok && git -C $REPO push poc main"

# ── B. FAIL-CLOSED on an UNRESOLVABLE explicit git-context (never allow on ambiguity) ───────────────────
# Unresolvable/ambiguous explicit git-context on a governed push → must FAIL CLOSED (never silent allow).
# Acceptable outcome: BLOCK(2) (via unsupported-context message OR config-unreachable fail-closed).
assert_unsupported() { run_hook "$2"; [ "$RC" = 2 ] && ok "$1 → BLOCK(2) [fail-closed, not silent allow]" || bad "$1 expected BLOCK(2), got RC=$RC — $2"; }
assert_unsupported "B1 -C nonexistent"       "git -C /no/such/dir/xyz push origin main"
assert_unsupported "B2 --git-dir nonexistent" "git --git-dir=/no/such/dir/.git push origin main"
assert_unsupported "B3 GIT_DIR nonexistent"  "GIT_DIR=/no/such/dir/.git git push origin main"

# ── C. NON-push commands with a -C-like substring must NOT be over-blocked (fast path preserved) ────────
assert_allow() { run_hook "$2"; [ "$RC" = 0 ] && ok "$1 → allow(0)" || bad "$1 expected allow(0), got RC=$RC — $2"; }
assert_allow "C1 ordinary echo"     "echo hello -C /tmp"
assert_allow "C2 grep with -C"      "grep -C 3 pattern file.txt"
assert_allow "C3 ls unrelated dir"  "ls -la /no/such/dir/xyz"

echo ""
echo "alt-git-context-push: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

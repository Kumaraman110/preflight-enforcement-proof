#!/usr/bin/env bash
# hook-arbitration-test.sh — the SINGLE ownership rule (lib/hook-arbitration.sh), unit-level.
#
# Deterministic (no engine spawn, no timing dependence): builds throwaway repo roots with different
# project-registration shapes and asserts pfa_classify_owner's verdict. This is the source-of-truth test
# for the "exactly one authoritative runtime per hook event" invariant; the full no-double-exec proof
# (no-duplicate-exec-test.sh) exercises the real dispatcher chain on top of this.
#
# CRITICAL: staleness is judged by whether the ACTUAL REGISTERED COMMAND TARGET exists — NOT by a guessed
# .claude/hooks/ path. So these fixtures register a command whose target file genuinely exists (or
# genuinely does not), modelling the real branch-stable layout (settings.local.json → an absolute
# .git/preflight/runtime/<sha>/hooks/run-hook.cmd, with .claude/hooks/ deliberately EMPTY). A test that
# planted a .claude/hooks/ file the real install never creates would be circular — this one does not.
#
# Exit 0 = all passed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LIB="$REPO/lib/hook-arbitration.sh"
UDISP="/fake/home/.claude/preflight/dispatcher.cmd"   # a stand-in stable user dispatcher path

PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
[ -f "$LIB" ] || { bad "lib/hook-arbitration.sh missing"; echo "hook-arbitration: 0/1"; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

# an opted-in repo root; .claude/hooks/ is created EMPTY (branch-stable installs never populate it)
new_root(){ local d; d="$(mktemp -d)/repo"; mkdir -p "$d/.preflight" "$d/.claude/hooks"; echo '{"mode":"generic"}' > "$d/.preflight/config.json"; echo "$d"; }
proj_settings(){ printf '%s' "$2" > "$1/.claude/settings.json"; }
proj_settings_local(){ printf '%s' "$2" > "$1/.claude/settings.local.json"; }

# Create a REAL branch-stable runtime target under <root>/.git/preflight/runtime/<sha>/hooks/run-hook.cmd
# and echo its absolute path (forward slashes). This is the file the registration will point at.
mk_runtime_target(){
  local root="$1" sha="${2:-727cda207f4c61c970ef0fc3c6bc4f835286b763}"
  local dir="$root/.git/preflight/runtime/$sha/hooks"
  mkdir -p "$dir"; printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/run-hook.cmd"
  printf '%s/run-hook.cmd' "$dir"
}
# a settings.local.json that registers the branch-stable Bash gate at an absolute runtime path
branch_stable_reg(){  # $1 = repo root ; $2 = absolute run-hook.cmd path
  proj_settings_local "$1" "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"\\\"$2\\\" pre-bash-risk-router \\\"\$TOOL_INPUT\\\"\"}]}]}}"
}

classify(){ pfa_classify_owner "$1" "$UDISP"; }   # sets PFA_OWNER / PFA_DUP_RISK / PFA_STALE / PFA_REASON

# ── 1. opted-in, NO project registration → USER (config alone is insufficient) ─────────────────────────
R="$(new_root)"
classify "$R"
[ "$PFA_OWNER" = USER ] && [ "$PFA_DUP_RISK" = no ] && ok "1 config-only (no registration) → USER" || bad "1 got $PFA_OWNER dup=$PFA_DUP_RISK"

# ── 2. VALID branch-stable project reg (settings.local → absolute runtime target that EXISTS) → PROJECT ─
#    .claude/hooks/ is EMPTY — this is the REAL branch-stable shape, not a planted-file fixture.
R="$(new_root)"; T="$(mk_runtime_target "$R")"; branch_stable_reg "$R" "$T"
classify "$R"
[ "$PFA_OWNER" = PROJECT ] && ok "2 branch-stable reg (target exists, .claude/hooks empty) → PROJECT" || bad "2 got $PFA_OWNER ($PFA_REASON)"

# ── 3. STALE: settings.local registers a runtime target that does NOT exist → AMBIGUOUS+stale (user owns) ─
R="$(new_root)"   # note: NO mk_runtime_target → the registered path is missing
branch_stable_reg "$R" "$R/.git/preflight/runtime/deadbeef/hooks/run-hook.cmd"
classify "$R"
[ "$PFA_OWNER" = AMBIGUOUS ] && [ "$PFA_STALE" = yes ] && ok "3 registered runtime target missing → AMBIGUOUS+stale (user owns)" || bad "3 got $PFA_OWNER stale=$PFA_STALE ($PFA_REASON)"

# ── 4. MALFORMED settings (invalid JSON), no confirmable project reg → AMBIGUOUS (user owns, safe) ──────
R="$(new_root)"
proj_settings "$R" '{ this is not json ,,, '
classify "$R"
[ "$PFA_OWNER" = AMBIGUOUS ] && ok "4 malformed settings → AMBIGUOUS (user owns safely)" || bad "4 got $PFA_OWNER ($PFA_REASON)"

# ── 5. DUPLICATE user runtime: project settings register the USER dispatcher → USER + dup risk ─────────
R="$(new_root)"
proj_settings "$R" "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"$UDISP user-preflight-router\"}]}]}}"
classify "$R"
[ "$PFA_OWNER" = USER ] && [ "$PFA_DUP_RISK" = yes ] && ok "5 project settings re-invoke USER runtime → USER + dup-risk" || bad "5 got $PFA_OWNER dup=$PFA_DUP_RISK"

# ── 6. DUPLICATED project hooks (two Bash registrations, both live) → PROJECT + dup risk ───────────────
R="$(new_root)"; T="$(mk_runtime_target "$R")"
proj_settings_local "$R" "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"\\\"$T\\\" pre-bash-risk-router\"}]},{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"\\\"$T\\\" pre-bash-risk-router\"}]}]}}"
classify "$R"
[ "$PFA_OWNER" = PROJECT ] && [ "$PFA_DUP_RISK" = yes ] && ok "6 duplicated live project registrations → PROJECT + dup-risk" || bad "6 got $PFA_OWNER dup=$PFA_DUP_RISK"

# ── 7. UNRELATED hooks only (a Write linter, no Bash Preflight) → USER (not fooled by foreign hooks) ────
R="$(new_root)"
proj_settings "$R" '{"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"run-hook.cmd coupled-edit-gate"}]}]}}'
classify "$R"
[ "$PFA_OWNER" = USER ] && [ "$PFA_DUP_RISK" = no ] && ok "7 unrelated Write hook only → USER (not PROJECT)" || bad "7 got $PFA_OWNER dup=$PFA_DUP_RISK ($PFA_REASON)"

# ── 8. registration lives in settings.local.json (not settings.json), target exists → PROJECT ──────────
#    (already the branch-stable shape; assert explicitly that settings.local alone suffices)
R="$(new_root)"; T="$(mk_runtime_target "$R")"; branch_stable_reg "$R" "$T"
[ -f "$R/.claude/settings.json" ] && bad "8 setup: settings.json should be absent" || true
classify "$R"
[ "$PFA_OWNER" = PROJECT ] && ok "8 registration in settings.local.json only → PROJECT" || bad "8 got $PFA_OWNER"

# ── 9. incidental substring in a NOTE field (not a Bash command) → NOT project (USER) ──────────────────
R="$(new_root)"
proj_settings "$R" '{"note":"we used pre-bash-risk-router once","hooks":{}}'
classify "$R"
[ "$PFA_OWNER" = USER ] && ok "9 incidental substring in a note → USER (no false PROJECT yield)" || bad "9 got $PFA_OWNER ($PFA_REASON)"

# ── 10. space-path repo root with a valid branch-stable registration → PROJECT (path quoting safe) ─────
SP="$(mktemp -d)/my repo"; mkdir -p "$SP/.preflight" "$SP/.claude/hooks"; echo '{"mode":"generic"}' > "$SP/.preflight/config.json"
T="$(mk_runtime_target "$SP")"; branch_stable_reg "$SP" "$T"
classify "$SP"
[ "$PFA_OWNER" = PROJECT ] && ok "10 space-path repo + valid registration → PROJECT" || bad "10 got $PFA_OWNER ($PFA_REASON)"

# ── 11. PILOT SHAPE: settings.local → absolute .git/preflight/runtime/<sha>/hooks/run-hook.cmd that
#    EXISTS, .claude/hooks/ EMPTY → PROJECT (not a user-runtime dup, not stale). The exact real shape. ──
R="$(new_root)"; T="$(mk_runtime_target "$R" "aaaabbbbccccdddd1111222233334444aaaabbbb")"; branch_stable_reg "$R" "$T"
# assert .claude/hooks/ is genuinely empty (no planted file masking the check)
[ -z "$(ls -A "$R/.claude/hooks" 2>/dev/null)" ] || bad "11 setup: .claude/hooks should be EMPTY"
classify "$R"
[ "$PFA_OWNER" = PROJECT ] && [ "$PFA_DUP_RISK" = no ] && ok "11 branch-stable .git/preflight/runtime (empty .claude/hooks) → PROJECT (not user-dup, not stale)" || bad "11 got $PFA_OWNER dup=$PFA_DUP_RISK stale=$PFA_STALE ($PFA_REASON)"

# ── 12. ${CLAUDE_PROJECT_DIR}-relative registration whose target exists → PROJECT (var expansion) ──────
R="$(new_root)"; mkdir -p "$R/.claude/hooks"; printf '#!/usr/bin/env bash\nexit 0\n' > "$R/.claude/hooks/run-hook.cmd"
proj_settings "$R" '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\"${CLAUDE_PROJECT_DIR}/.claude/hooks/run-hook.cmd\" pre-bash-risk-router \"$TOOL_INPUT\""}]}]}}'
classify "$R"
[ "$PFA_OWNER" = PROJECT ] && ok "12 \${CLAUDE_PROJECT_DIR}-relative reg with existing target → PROJECT" || bad "12 got $PFA_OWNER ($PFA_REASON)"

# ── 13. Write/Edit-only project settings + a Bash gate that is actually a user-dup → USER (matcher-aware) ─
#    A repo whose ONLY Bash matcher re-invokes the user runtime, plus non-Bash gates → USER + dup, never
#    PROJECT (the Write/Edit gates must not be counted as a Bash owner).
R="$(new_root)"
proj_settings "$R" "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Write\",\"hooks\":[{\"type\":\"command\",\"command\":\"run-hook.cmd coupled-edit-gate\"}]},{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"$UDISP user-preflight-router\"}]}]}}"
classify "$R"
[ "$PFA_OWNER" = USER ] && [ "$PFA_DUP_RISK" = yes ] && ok "13 Write gate + Bash user-dup → USER+dup (matcher-aware, Write not counted)" || bad "13 got $PFA_OWNER dup=$PFA_DUP_RISK"

echo ""
echo "hook-arbitration: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

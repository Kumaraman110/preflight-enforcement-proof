#!/usr/bin/env bash
# hook-arbitration-test.sh — the SINGLE ownership rule (lib/hook-arbitration.sh), unit-level.
#
# Deterministic (no engine spawn, no timing dependence): builds throwaway repo roots with different
# project-registration shapes and asserts pfa_classify_owner's verdict. This is the source-of-truth test
# for the "exactly one authoritative runtime per hook event" invariant; the full no-double-exec proof
# (tests/user-install + no-duplicate-exec-test) exercises the real dispatcher chain on top of this.
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

# helpers to build repo roots
new_root(){ local d; d="$(mktemp -d)/repo"; mkdir -p "$d/.preflight" "$d/.claude/hooks"; echo '{"mode":"generic"}' > "$d/.preflight/config.json"; echo "$d"; }
proj_hookfile(){ printf '#!/usr/bin/env bash\nexit 0\n' > "$1/.claude/hooks/pre-bash-risk-router"; }  # non-empty real hook
proj_settings(){ printf '%s' "$2" > "$1/.claude/settings.json"; }

classify(){ pfa_classify_owner "$1" "$UDISP"; }   # sets PFA_OWNER / PFA_DUP_RISK / PFA_STALE / PFA_REASON

# ── 1. opted-in, NO project registration → USER (config alone is insufficient) ─────────────────────────
R="$(new_root)"
classify "$R"
[ "$PFA_OWNER" = USER ] && [ "$PFA_DUP_RISK" = no ] && ok "1 config-only (no registration) → USER" || bad "1 got $PFA_OWNER dup=$PFA_DUP_RISK"

# ── 2. VALID project registration (settings names router + real hook file present) → PROJECT ───────────
R="$(new_root)"; proj_hookfile "$R"
proj_settings "$R" '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"run-hook.cmd pre-bash-risk-router"}]}]}}'
classify "$R"
[ "$PFA_OWNER" = PROJECT ] && ok "2 valid project registration + hook file → PROJECT" || bad "2 got $PFA_OWNER ($PFA_REASON)"

# ── 3. STALE: settings registers a project router but NO hook file present → AMBIGUOUS (user owns, safe) ─
R="$(new_root)"   # note: no proj_hookfile
proj_settings "$R" '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"run-hook.cmd pre-bash-risk-router"}]}]}}'
classify "$R"
[ "$PFA_OWNER" = AMBIGUOUS ] && [ "$PFA_STALE" = yes ] && ok "3 stale registration (no hook file) → AMBIGUOUS+stale (user owns)" || bad "3 got $PFA_OWNER stale=$PFA_STALE"

# ── 4. MALFORMED settings (invalid JSON), no confirmable project reg → AMBIGUOUS (user owns, safe) ──────
R="$(new_root)"; proj_hookfile "$R"
proj_settings "$R" '{ this is not json ,,, '
classify "$R"
[ "$PFA_OWNER" = AMBIGUOUS ] && ok "4 malformed settings → AMBIGUOUS (user owns safely)" || bad "4 got $PFA_OWNER ($PFA_REASON)"

# ── 5. DUPLICATE user runtime: project settings register the USER dispatcher → USER + dup risk ─────────
R="$(new_root)"
proj_settings "$R" "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"$UDISP user-preflight-router\"}]}]}}"
classify "$R"
[ "$PFA_OWNER" = USER ] && [ "$PFA_DUP_RISK" = yes ] && ok "5 project settings re-invoke USER runtime → USER + dup-risk" || bad "5 got $PFA_OWNER dup=$PFA_DUP_RISK"

# ── 6. DUPLICATED project hooks (two Bash project registrations) → PROJECT + dup risk ──────────────────
R="$(new_root)"; proj_hookfile "$R"
proj_settings "$R" '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"run-hook.cmd pre-bash-risk-router"}]},{"matcher":"Bash","hooks":[{"type":"command","command":"run-hook.cmd pre-bash-risk-router"}]}]}}'
classify "$R"
[ "$PFA_OWNER" = PROJECT ] && [ "$PFA_DUP_RISK" = yes ] && ok "6 duplicated project registrations → PROJECT + dup-risk" || bad "6 got $PFA_OWNER dup=$PFA_DUP_RISK"

# ── 7. UNRELATED hooks only (a Write linter, no Bash Preflight) → USER (not fooled by foreign hooks) ────
R="$(new_root)"
proj_settings "$R" '{"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"my-linter.sh"}]}]}}'
classify "$R"
[ "$PFA_OWNER" = USER ] && [ "$PFA_DUP_RISK" = no ] && ok "7 unrelated Write hook only → USER (not PROJECT)" || bad "7 got $PFA_OWNER dup=$PFA_DUP_RISK"

# ── 8. settings.local.json carries the project registration (not settings.json) → PROJECT ──────────────
R="$(new_root)"; proj_hookfile "$R"
printf '%s' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"run-hook.cmd pre-bash-risk-router"}]}]}}' > "$R/.claude/settings.local.json"
classify "$R"
[ "$PFA_OWNER" = PROJECT ] && ok "8 registration in settings.local.json → PROJECT" || bad "8 got $PFA_OWNER"

# ── 9. incidental substring in a NOTE field (not a command) + empty stub hook → NOT project (USER) ─────
R="$(new_root)"; : > "$R/.claude/hooks/pre-bash-risk-router"   # empty stub (0 bytes)
proj_settings "$R" '{"note":"we used pre-bash-risk-router once","hooks":{}}'
classify "$R"
[ "$PFA_OWNER" = USER ] && ok "9 incidental substring + empty stub → USER (no false PROJECT yield)" || bad "9 got $PFA_OWNER ($PFA_REASON)"

# ── 10. space-path repo root with a valid project registration → PROJECT (path quoting safe) ───────────
SP="$(mktemp -d)/my repo"; mkdir -p "$SP/.preflight" "$SP/.claude/hooks"; echo '{"mode":"generic"}' > "$SP/.preflight/config.json"
proj_hookfile "$SP"
proj_settings "$SP" '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"run-hook.cmd pre-bash-risk-router"}]}]}}'
classify "$SP"
[ "$PFA_OWNER" = PROJECT ] && ok "10 space-path repo + valid registration → PROJECT" || bad "10 got $PFA_OWNER"

# ── 11. PILOT-SHAPED: branch-stable PROJECT runtime under .git/preflight/runtime/<sha>/ → PROJECT ───────
#    Regression lock: a project install can register run-hook.cmd from <repo>/.git/preflight/runtime/<sha>/
#    — that path contains "preflight/runtime/" but is a PROJECT owner, NOT the user runtime. It must NOT be
#    misclassified as a duplicate user-runtime (the real CPSL pilot has exactly this shape).
R="$(new_root)"; proj_hookfile "$R"
proj_settings "$R" '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\"C:/Users/x/Source_Code/.git/preflight/runtime/727cda207f4c61c970ef0fc3c6bc4f835286b763/hooks/run-hook.cmd\" pre-bash-risk-router \"$TOOL_INPUT\""}]}]}}'
classify "$R"
[ "$PFA_OWNER" = PROJECT ] && [ "$PFA_DUP_RISK" = no ] && ok "11 branch-stable .git/preflight/runtime project reg → PROJECT (not user-dup)" || bad "11 got $PFA_OWNER dup=$PFA_DUP_RISK ($PFA_REASON)"

echo ""
echo "hook-arbitration: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

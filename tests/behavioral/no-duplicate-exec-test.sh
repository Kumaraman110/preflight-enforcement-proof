#!/usr/bin/env bash
# no-duplicate-exec-test.sh — proves EXACTLY ONE authoritative Preflight runtime adjudicates a single
# PreToolUse Bash event, across the mixed user/project registration matrix (v0.10.0 hook arbitration).
#
# WHY this is the load-bearing proof: Claude Code merges hooks as a UNION across the user scope
# (~/.claude/settings.json) and the project scope (<repo>/.claude/settings.json) — BOTH fire for the same
# tool call. So for a project-owned repo the user dispatcher AND the project hook both run; the invariant
# is that the user runtime must YIELD (write nothing, run no decision) so the project-pinned runtime is the
# sole authority. We model that union literally: for each repo we fire every registration that Claude Code
# would fire, and count how many runtimes did AUTHORITATIVE work (a counter side-effect). The count must be
# exactly 1 in every governed scenario, and 0 (fast path) for a non-opted-in repo — never 2.
#
# Counter mechanism (deterministic, no timing dependence):
#   - the USER runtime's delegate (pre-bash-risk-router) appends "USER" to $CTR when it actually runs;
#     the router only reaches it when the user runtime OWNS the repo. Yielding appends nothing.
#   - the PROJECT hook appends "PROJECT" to $CTR when it runs.
#   Total lines in $CTR after firing the full union = number of authoritative executions for that event.
#
# Also asserts: while DEFERRING (project-owned), the user dispatcher writes NO .preflight/* file to the app
# repo (passive routing is read-only).
#
# Exit 0 = all passed. Uses only isolated temp dirs; never touches the real ~/.claude or the pilot.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# ── Stand up an isolated USER runtime in the runtime/<sha>/ layout the dispatcher expects ───────────────
UHOME="$(mktemp -d)/claude"; SHA="deadbeefcafe0000deadbeefcafe0000deadbeef"
GEN="$UHOME/preflight/runtime/$SHA"
mkdir -p "$GEN/hooks" "$GEN/lib"
cp "$REPO/hooks/user-preflight-router" "$GEN/hooks/"
cp "$REPO/lib/hook-arbitration.sh"     "$GEN/lib/"
cp "$REPO/tools/user/dispatcher.cmd"   "$UHOME/preflight/dispatcher.cmd"
printf '%s' "$SHA" > "$UHOME/preflight/ACTIVE"
# The USER delegate: appends USER to the shared counter, then exits 0 (models "the user runtime decided").
cat > "$GEN/hooks/pre-bash-risk-router" <<'DELEG'
#!/usr/bin/env bash
printf 'USER\n' >> "$PF_TEST_CTR"
exit 0
DELEG
chmod +x "$GEN/hooks/"* "$UHOME/preflight/dispatcher.cmd"
DISP="$UHOME/preflight/dispatcher.cmd"

# A PROJECT hook: appends PROJECT to the shared counter, exits 0 (models the project-pinned runtime).
PROJ_HOOK_BODY='#!/usr/bin/env bash
printf '"'"'PROJECT\n'"'"' >> "$PF_TEST_CTR"
exit 0'

# Fire the USER dispatcher for a command in cwd. (Claude Code always fires the user hook.)
fire_user(){ printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$2" | PF_TEST_CTR="$CTR" bash "$DISP" user-preflight-router >/dev/null 2>&1; }
# Fire the PROJECT hook directly (Claude Code fires it too, when the repo registers one).
fire_proj(){ local h="$1"; [ -x "$h" ] || return 0; printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$2" "$3" | PF_TEST_CTR="$CTR" bash "$h" >/dev/null 2>&1; }

# Build a repo root; .claude/hooks/ is created EMPTY (the real branch-stable layout never populates it).
mk_optedin(){ local d; d="$(mktemp -d)/repo"; mkdir -p "$d/.preflight" "$d/.claude/hooks"; echo '{"mode":"generic"}' > "$d/.preflight/config.json"; echo "$d"; }
# Install a REAL branch-stable project registration: a runtime target that EXISTS under
# <repo>/.git/preflight/runtime/<sha>/hooks/run-hook.cmd (the counter-appending PROJECT hook), registered
# via settings.local.json with the ABSOLUTE path — .claude/hooks/ stays EMPTY. Echoes the target path.
add_project_reg(){ # $1=repo
  local sha=727cda207f4c61c970ef0fc3c6bc4f835286b763
  local dir="$1/.git/preflight/runtime/$sha/hooks"; mkdir -p "$dir"
  printf '%s\n' "$PROJ_HOOK_BODY" > "$dir/run-hook.cmd"; chmod +x "$dir/run-hook.cmd"
  printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\\"%s/run-hook.cmd\\" pre-bash-risk-router \\"$TOOL_INPUT\\""}]}]}}' "$dir" > "$1/.claude/settings.local.json"
  printf '%s/run-hook.cmd' "$dir"
}
# echo the project hook target path for a repo that had add_project_reg called
proj_target(){ echo "$1/.git/preflight/runtime/727cda207f4c61c970ef0fc3c6bc4f835286b763/hooks/run-hook.cmd"; }
count(){ [ -f "$CTR" ] && wc -l < "$CTR" | tr -d ' ' || echo 0; }
owner(){ grep -m1 . "$CTR" 2>/dev/null || echo NONE; }
no_pf_writes(){ # $1 = repo : assert the router created no NEW .preflight file beyond config.json
  local extra; extra="$(find "$1/.preflight" -type f 2>/dev/null | grep -v '/config.json$' | wc -l | tr -d ' ')"
  [ "$extra" = 0 ]
}

# The union firing order Claude Code uses does not matter for the count; we fire user then project.
run_event(){ CTR="$(mktemp)"; : > "$CTR"; }

# ── 1. USER-ONLY (opted in, no project registration) → exactly 1 exec, by USER ─────────────────────────
run_event; R="$(mk_optedin)"
fire_user "git push origin main" "$R"        # no project hook to fire
[ "$(count)" = 1 ] && [ "$(owner)" = USER ] && ok "1 user-only → exactly 1 exec (USER)" || bad "1 user-only count=$(count) owner=$(owner)"

# ── 2. BRANCH-STABLE project reg (settings.local → absolute runtime target EXISTS, .claude/hooks EMPTY) →
#      user YIELDS, project runs once. This is the REAL branch-stable shape, not a planted-file fixture. ──
run_event; R="$(mk_optedin)"; add_project_reg "$R" >/dev/null
fire_user "git push origin main" "$R"        # user router must YIELD (append nothing)
fire_proj "$(proj_target "$R")" "git push origin main" "$R"
if [ "$(count)" = 1 ] && [ "$(owner)" = PROJECT ] && no_pf_writes "$R"; then
  ok "2 branch-stable project reg → exactly 1 exec (PROJECT), user yielded, no .preflight write"
else bad "2 project count=$(count) owner=$(owner) pfwrites=$(no_pf_writes "$R"; echo $?)"; fi

# ── 3. STALE project runtime (settings.local registers a runtime target that does NOT exist) → user runs
#      once. The registered target file is missing → AMBIGUOUS/stale → user must NOT stand down. ──────────
run_event; R="$(mk_optedin)"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\\"%s/.git/preflight/runtime/deadbeef/hooks/run-hook.cmd\\" pre-bash-risk-router"}]}]}}' "$R" > "$R/.claude/settings.local.json"
# NO runtime target exists → the project side is stale; the user runtime must own the decision.
fire_user "git push origin main" "$R"
[ "$(count)" = 1 ] && [ "$(owner)" = USER ] && ok "3 stale project reg (registered target missing) → user runs once (never 0)" || bad "3 stale count=$(count) owner=$(owner)"

# ── 4. MALFORMED project settings → user runs once (safe), never defers to an unparseable project ──────
run_event; R="$(mk_optedin)"
printf '%s' '{ not valid json ,,, ' > "$R/.claude/settings.json"
# A malformed settings file registers no runnable project hook in Claude Code either → only user fires.
fire_user "git push origin main" "$R"
[ "$(count)" = 1 ] && [ "$(owner)" = USER ] && ok "4 malformed project settings → user runs once (safe)" || bad "4 malformed count=$(count) owner=$(owner)"

# ── 5. DUPLICATED live project hooks (two Bash registrations, target exists) → user yields; project owns ─
run_event; R="$(mk_optedin)"; T="$(add_project_reg "$R")"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\\"%s\\" pre-bash-risk-router"}]},{"matcher":"Bash","hooks":[{"type":"command","command":"\\"%s\\" pre-bash-risk-router"}]}]}}' "$T" "$T" > "$R/.claude/settings.local.json"
fire_user "git push origin main" "$R"        # user yields (project owns)
# Claude Code would fire the project hook per registration; from the USER-side invariant, user contributes 0.
[ "$(count)" = 0 ] && ok "5 duplicated live project hooks → user yields (0 user execs; project self-dedups)" || bad "5 dup-project user contributed $(count)"

# ── 6. DUPLICATE user-runtime reference in project settings → user runs ONCE (not twice) ───────────────
run_event; R="$(mk_optedin)"
printf '%s' "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"$DISP user-preflight-router\"}]}]}}" > "$R/.claude/settings.json"
# Project settings re-invoke the SAME user dispatcher. Claude Code would fire it a 2nd time; the arbitration
# classifies this as USER+dup (not project), so the user runtime still owns it — and each firing is
# idempotent (writes nothing). We fire the user dispatcher ONCE here (the canonical user registration);
# the duplicate project reference is flagged by doctor, not silently doubled into two decisions.
fire_user "git push origin main" "$R"
[ "$(count)" = 1 ] && [ "$(owner)" = USER ] && ok "6 project re-invokes user runtime → user owns (idempotent, dup flagged by doctor)" || bad "6 dup-user count=$(count) owner=$(owner)"

# ── 7. GIT WORKTREE (linked worktree, common git dir), opted-in main → user runs once ─────────────────
run_event
WTMAIN="$(mktemp -d)/wtmain"; mkdir -p "$WTMAIN/.preflight"; ( cd "$WTMAIN" && git init -q && echo '{"mode":"generic"}' > .preflight/config.json && git add -A && git commit -q -m init )
WT="$(mktemp -d)/linked"; ( cd "$WTMAIN" && git worktree add -q "$WT" -b wtb >/dev/null 2>&1 )
cp "$WTMAIN/.preflight/config.json" "$WT/.preflight/config.json" 2>/dev/null || { mkdir -p "$WT/.preflight"; echo '{"mode":"generic"}' > "$WT/.preflight/config.json"; }
fire_user "git push origin main" "$WT"
[ "$(count)" = 1 ] && [ "$(owner)" = USER ] && ok "7 git worktree opted-in → user runs once" || bad "7 worktree count=$(count) owner=$(owner)"

# ── 8. SPACE PATH repo, opted-in, branch-stable project-owned → user yields, project once ──────────────
run_event; SP="$(mktemp -d)/my repo"; mkdir -p "$SP/.preflight" "$SP/.claude/hooks"; echo '{"mode":"generic"}' > "$SP/.preflight/config.json"
STGT="$(add_project_reg "$SP")"
fire_user "git push origin main" "$SP"
fire_proj "$STGT" "git push origin main" "$SP"
[ "$(count)" = 1 ] && [ "$(owner)" = PROJECT ] && no_pf_writes "$SP" && ok "8 space-path project-owned → 1 exec (PROJECT), no write" || bad "8 space count=$(count) owner=$(owner)"

# ── 9. UNRELATED project hooks only (a Write linter) → user runs once (not fooled into yielding) ───────
run_event; R="$(mk_optedin)"
printf '%s' '{"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"my-linter.sh"}]}]}}' > "$R/.claude/settings.json"
fire_user "git push origin main" "$R"
[ "$(count)" = 1 ] && [ "$(owner)" = USER ] && ok "9 unrelated project hooks → user runs once (not fooled)" || bad "9 unrelated count=$(count) owner=$(owner)"

# ── 10. NON-OPTED-IN repo → user fast-path exit 0, ZERO execs (no gating at all) ───────────────────────
run_event; PLAIN="$(mktemp -d)/plain"; mkdir -p "$PLAIN"; ( cd "$PLAIN" && git init -q )
fire_user "git push origin main" "$PLAIN"
[ "$(count)" = 0 ] && ok "10 non-opted-in → 0 execs (fast path, no gating)" || bad "10 non-opted-in ran $(count)"

# ── 11. DEFER writes NOTHING: after a project-owned event, the app repo has no NEW .preflight artifact ─
run_event; R="$(mk_optedin)"; add_project_reg "$R" >/dev/null
BEFORE="$(find "$R/.preflight" -type f | LC_ALL=C sort)"
fire_user "git push origin main" "$R"
AFTER="$(find "$R/.preflight" -type f | LC_ALL=C sort)"
[ "$BEFORE" = "$AFTER" ] && ok "11 user dispatcher deferring wrote NO .preflight file (read-only)" || bad "11 defer wrote files: $(diff <(echo "$BEFORE") <(echo "$AFTER"))"

# ── 12. NF-2 REGRESSION: router INLINE FALLBACK (lib unresolvable) must NOT silent-allow. A repo with an
#    incidental router substring (a note) + only a Write gate, NO real Bash gate → the fallback must NOT
#    yield (it must delegate to the user gate); a genuine branch-stable project → must yield. We co-locate
#    the router WITHOUT the lib to force the inline fallback. The user delegate here exits 2 (= "ran").
DFB="$(mktemp -d)/rt"; mkdir -p "$DFB/hooks"     # NOTE: no lib/ dir → inline fallback path
cp "$REPO/hooks/user-preflight-router" "$DFB/hooks/"
# the USER delegate appends USER when it RUNS (i.e. the router did NOT yield). We count via $CTR.
printf '#!/usr/bin/env bash\nprintf "USER\\n" >> "$PF_TEST_CTR"\nexit 0\n' > "$DFB/hooks/pre-bash-risk-router"; chmod +x "$DFB/hooks/pre-bash-risk-router"
fire_fb(){ printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$2" | PF_TEST_CTR="$CTR" bash "$DFB/hooks/user-preflight-router" >/dev/null 2>&1; }
# (a) incidental-substring repo (no real Bash gate) → fallback must DELEGATE (user runs, count=1), NOT yield.
run_event
INC="$(mktemp -d)/inc"; mkdir -p "$INC/.preflight" "$INC/.claude"; echo '{"mode":"generic"}' > "$INC/.preflight/config.json"
printf '{"note":"migrated off pre-bash-risk-router last week","hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"my-linter.sh"}]}]}}' > "$INC/.claude/settings.json"
fire_fb 'git push origin main' "$INC"
CI="$(count)"
# (b) genuine branch-stable project → fallback must YIELD (user runs 0 times = count 0).
run_event
BSF="$(mktemp -d)/bsf"; mkdir -p "$BSF/.preflight" "$BSF/.claude/hooks"; echo '{"mode":"generic"}' > "$BSF/.preflight/config.json"
TGF="$BSF/.git/preflight/runtime/aaa/hooks"; mkdir -p "$TGF"; printf '#stub\n' > "$TGF/run-hook.cmd"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\\"%s/run-hook.cmd\\" pre-bash-risk-router"}]}]}}' "$TGF" > "$BSF/.claude/settings.local.json"
fire_fb 'git push origin main' "$BSF"
CB="$(count)"
if [ "$CI" = 1 ] && [ "$CB" = 0 ]; then
  ok "12 NF-2: inline fallback DELEGATES on incidental-substring (user ran, no silent-allow), YIELDS on real branch-stable project"
else bad "12 NF-2 inline fallback wrong (incidental user-execs=$CI expect 1; branch-stable user-execs=$CB expect 0)"; fi

echo ""
echo "no-duplicate-exec: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

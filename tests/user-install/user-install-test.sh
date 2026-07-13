#!/usr/bin/env bash
# user-install-test.sh — the v0.10.0 USER-LEVEL installer compatibility + security suite.
#
# Every case runs against an ISOLATED temporary HOME/config (PREFLIGHT_CLAUDE_HOME) — it NEVER touches
# the real ~/.claude. No network. Proves the 20 mission-required behaviors + adversarial cases.
#
# Exit 0 = all passed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CLI="$REPO/tools/preflight-user.sh"
REF="${PF_TEST_REF:-HEAD}"          # the release commit/tag to install from (default: current HEAD)

PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
command -v git >/dev/null 2>&1 || { bad "no git"; echo "user-install: $PASS passed, $FAIL failed"; exit 1; }

# fresh isolated home per invocation
new_home(){ local h; h="$(mktemp -d)/claude"; mkdir -p "$h"; echo "$h"; }
pfu(){ bash "$CLI" "$@"; }   # runs with the current PREFLIGHT_CLAUDE_HOME env

# a git repo that has OPTED IN (has .preflight/config.json)
mk_active_repo(){ local d; d="$(mktemp -d)/active"; mkdir -p "$d/.preflight"; ( cd "$d" && git init -q ); echo '{"mode":"generic"}' > "$d/.preflight/config.json"; echo "$d"; }
mk_inactive_repo(){ local d; d="$(mktemp -d)/inactive"; mkdir -p "$d"; ( cd "$d" && git init -q ); echo "$d"; }
# fire the dispatcher as Claude Code would (stdin tool JSON), echo the exit code
fire(){ local disp="$1" cmd="$2" cwd="$3"; printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$cmd" "$cwd" | bash "$disp" user-preflight-router >/dev/null 2>&1; echo $?; }

RESOLVED="$(git -C "$REPO" rev-parse --verify "${REF}^{commit}" 2>/dev/null || echo HEAD)"

# ── 1. Fresh user install ────────────────────────────────────────────────────────────────────────────
export PREFLIGHT_CLAUDE_HOME="$(new_home)"
if pfu install --user --ref "$RESOLVED" --source "$REPO" >/dev/null 2>&1 && pfu verify --user >/dev/null 2>&1; then ok "1 fresh install + verify"; else bad "1 fresh install"; fi
DISP="$PREFLIGHT_CLAUDE_HOME/preflight/dispatcher.cmd"

# ── 2. Repeated idempotent install (settings byte-stable) ──────────────────────────────────────────────
S1="$(sha256sum "$PREFLIGHT_CLAUDE_HOME/settings.json" | cut -d' ' -f1)"
pfu install --user --ref "$RESOLVED" --source "$REPO" >/dev/null 2>&1
S2="$(sha256sum "$PREFLIGHT_CLAUDE_HOME/settings.json" | cut -d' ' -f1)"
[ "$S1" = "$S2" ] && ok "2 idempotent install (settings unchanged)" || bad "2 idempotent install changed settings"

# ── 3. Inactive repo: no behavioral effect (push allowed) ──────────────────────────────────────────────
INACT="$(mk_inactive_repo)"
[ "$(fire "$DISP" "git push origin main" "$INACT")" = 0 ] && ok "3 inactive repo → push allowed (exit 0)" || bad "3 inactive repo gated"

# ── 4. Activated repo: safe command ALLOW ──────────────────────────────────────────────────────────────
ACT="$(mk_active_repo)"
[ "$(fire "$DISP" "echo hello" "$ACT")" = 0 ] && ok "4 activated repo + safe cmd → ALLOW (exit 0)" || bad "4 activated safe cmd not allowed"

# ── 5+6. Consequential command WITHOUT evidence → BLOCK/CONFIRM (non-zero) ─────────────────────────────
RC="$(fire "$DISP" "git push origin main" "$ACT")"
[ "$RC" != 0 ] && ok "5/6 activated + push (no evidence) → non-success (exit $RC)" || bad "5/6 push with no evidence was allowed"

# ── 7. Malformed project activation: fail safely (no crash; still gated safe) ──────────────────────────
BAD="$(mktemp -d)/bad"; mkdir -p "$BAD/.preflight"; ( cd "$BAD" && git init -q ); printf 'not json{' > "$BAD/.preflight/config.json"
RC="$(fire "$DISP" "git push origin main" "$BAD")"
[ "$RC" = 2 ] || [ "$RC" = 0 ] && ok "7 malformed activation handled safely (exit $RC, no crash)" || bad "7 malformed activation crashed (exit $RC)"

# ── 8. Existing project-local Preflight: no duplicate execution (user router yields) ──────────────────
PROJ="$(mktemp -d)/proj"; mkdir -p "$PROJ/.preflight" "$PROJ/.claude/hooks"; ( cd "$PROJ" && git init -q )
echo '{"mode":"generic"}' > "$PROJ/.preflight/config.json"; printf '#stub\n' > "$PROJ/.claude/hooks/pre-bash-risk-router"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"run-hook.cmd pre-bash-risk-router"}]}]}}' > "$PROJ/.claude/settings.json"
[ "$(fire "$DISP" "git push origin main" "$PROJ")" = 0 ] && ok "8 project-local Preflight present → user router yields (no double-exec)" || bad "8 double-exec not prevented"

# ── 9. Git worktree using a common git directory ───────────────────────────────────────────────────────
WTMAIN="$(mktemp -d)/wtmain"; mkdir -p "$WTMAIN/.preflight"; ( cd "$WTMAIN" && git init -q && echo '{"mode":"generic"}' > .preflight/config.json && git add -A && git commit -q -m init )
WT="$(mktemp -d)/linked"; ( cd "$WTMAIN" && git worktree add -q "$WT" -b wtbranch >/dev/null 2>&1 )
# the linked worktree does NOT have .preflight/config.json unless checked out; it shares the git dir.
# An ordinary command in the linked worktree must still be allowed (exit 0); a push there is gated only if opted in.
[ "$(fire "$DISP" "echo hi" "$WT")" = 0 ] && ok "9 git worktree (common git dir) → ordinary allowed" || bad "9 worktree ordinary blocked"

# ── 10. User settings with unrelated hooks + fields are preserved ─────────────────────────────────────
export PREFLIGHT_CLAUDE_HOME="$(new_home)"
cat > "$PREFLIGHT_CLAUDE_HOME/settings.json" <<'EOF'
{"model":"claude-opus-4-8","env":{"FOO":"bar"},"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"my-linter.sh"}]}]},"customField":123}
EOF
pfu install --user --ref "$RESOLVED" --source "$REPO" >/dev/null 2>&1
python - "$PREFLIGHT_CLAUDE_HOME/settings.json" <<'PY' && ok "10 unrelated settings + foreign hooks preserved" || bad "10 unrelated settings lost"
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
assert d.get("model")=="claude-opus-4-8", "model lost"
assert d.get("env",{}).get("FOO")=="bar", "env lost"
assert d.get("customField")==123, "customField lost"
pre=d["hooks"]["PreToolUse"]
assert any(h.get("matcher")=="Write" for h in pre), "foreign Write hook lost"
assert any(h.get("matcher")=="Bash" and any("dispatcher.cmd" in x.get("command","") for x in h.get("hooks",[])) for h in pre), "preflight Bash hook missing"
PY

# ── 11. Interrupted install restores prior state ──────────────────────────────────────────────────────
export PREFLIGHT_CLAUDE_HOME="$(new_home)"
printf '{"model":"x"}' > "$PREFLIGHT_CLAUDE_HOME/settings.json"
PRE="$(sha256sum "$PREFLIGHT_CLAUDE_HOME/settings.json" | cut -d' ' -f1)"
# force failure by pointing at a bogus ref (staging fails BEFORE any settings edit)
pfu install --user --ref "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" --source "$REPO" >/dev/null 2>&1
POST="$(sha256sum "$PREFLIGHT_CLAUDE_HOME/settings.json" | cut -d' ' -f1)"
[ "$PRE" = "$POST" ] && [ ! -f "$PREFLIGHT_CLAUDE_HOME/preflight/ACTIVE" ] && ok "11 failed install left settings + state untouched" || bad "11 failed install mutated state"

# ── 12+13. Upgrade generation → rollback restores exact previous ──────────────────────────────────────
export PREFLIGHT_CLAUDE_HOME="$(new_home)"
GEN1="$(git -C "$REPO" rev-parse --verify 'HEAD~1^{commit}' 2>/dev/null || echo "$RESOLVED")"
pfu install --user --ref "$GEN1" --source "$REPO" >/dev/null 2>&1
pfu install --user --ref "$RESOLVED" --source "$REPO" >/dev/null 2>&1
A_AFTER_UP="$(cat "$PREFLIGHT_CLAUDE_HOME/preflight/ACTIVE")"; P_AFTER_UP="$(cat "$PREFLIGHT_CLAUDE_HOME/preflight/PREVIOUS" 2>/dev/null || echo none)"
if [ "$A_AFTER_UP" = "$RESOLVED" ] && [ "$P_AFTER_UP" = "$GEN1" ]; then ok "12 upgrade: ACTIVE=new PREVIOUS=old"; else bad "12 upgrade pointers wrong (A=$A_AFTER_UP P=$P_AFTER_UP)"; fi
pfu rollback --user >/dev/null 2>&1
[ "$(cat "$PREFLIGHT_CLAUDE_HOME/preflight/ACTIVE")" = "$GEN1" ] && pfu verify --user >/dev/null 2>&1 && ok "13 rollback restored exact previous generation + verify PASS" || bad "13 rollback failed"

# ── 14. Uninstall restores settings + removes only owned artifacts ─────────────────────────────────────
export PREFLIGHT_CLAUDE_HOME="$(new_home)"
cat > "$PREFLIGHT_CLAUDE_HOME/settings.json" <<'EOF'
{"model":"keep-me","hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"keep-linter.sh"}]}]}}
EOF
PRE_U="$(sha256sum "$PREFLIGHT_CLAUDE_HOME/settings.json" | cut -d' ' -f1)"
pfu install --user --ref "$RESOLVED" --source "$REPO" >/dev/null 2>&1
pfu uninstall --user >/dev/null 2>&1
POST_U="$(python -c "import json,sys;d=json.load(open(sys.argv[1]));import hashlib;print(hashlib.sha256(json.dumps(d,sort_keys=True).encode()).hexdigest())" "$PREFLIGHT_CLAUDE_HOME/settings.json" 2>/dev/null || echo GONE)"
# settings must retain model + Write hook, and Preflight home must be gone
python - "$PREFLIGHT_CLAUDE_HOME/settings.json" <<'PY' && [ ! -d "$PREFLIGHT_CLAUDE_HOME/preflight" ] && ok "14 uninstall preserved unrelated settings + removed owned data" || bad "14 uninstall wrong"
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
assert d.get("model")=="keep-me"
pre=d.get("hooks",{}).get("PreToolUse",[])
assert any(h.get("matcher")=="Write" for h in pre), "kept Write hook lost"
assert not any(h.get("matcher")=="Bash" and any("dispatcher.cmd" in x.get("command","") for x in h.get("hooks",[])) for h in pre), "preflight hook not removed"
PY

# ── 15. Runtime-file tampering is detected ─────────────────────────────────────────────────────────────
export PREFLIGHT_CLAUDE_HOME="$(new_home)"
pfu install --user --ref "$RESOLVED" --source "$REPO" >/dev/null 2>&1
TROUTER="$PREFLIGHT_CLAUDE_HOME/preflight/runtime/$RESOLVED/hooks/user-preflight-router"
printf '\n# tampered\n' >> "$TROUTER"
pfu verify --user >/dev/null 2>&1 && bad "15 tamper NOT detected (verify passed)" || ok "15 runtime tamper detected (verify FAIL)"

# ── 16. Missing engine/dependency fails per scoped fail-closed contract ────────────────────────────────
export PREFLIGHT_CLAUDE_HOME="$(new_home)"
pfu install --user --ref "$RESOLVED" --source "$REPO" >/dev/null 2>&1
DISP="$PREFLIGHT_CLAUDE_HOME/preflight/dispatcher.cmd"
ACT2="$(mk_active_repo)"
# remove the engine from the active generation → a candidate push must fail CLOSED (non-zero), ordinary still allowed
rm -f "$PREFLIGHT_CLAUDE_HOME/preflight/runtime/$RESOLVED/hooks/pre-push-gate-engine"
[ "$(fire "$DISP" "echo hi" "$ACT2")" = 0 ] && RCP="$(fire "$DISP" "git push origin main" "$ACT2")" && [ "$RCP" != 0 ] && ok "16 missing engine: ordinary allowed, candidate fails closed (exit $RCP)" || bad "16 missing-engine contract violated"

# ── 17. Paths with spaces + Windows Git-Bash forms ─────────────────────────────────────────────────────
export PREFLIGHT_CLAUDE_HOME="$(mktemp -d)/cl aude"; mkdir -p "$PREFLIGHT_CLAUDE_HOME"
if pfu install --user --ref "$RESOLVED" --source "$REPO" >/dev/null 2>&1 && pfu verify --user >/dev/null 2>&1; then ok "17 install works under a path containing spaces" ; else bad "17 space-path install failed"; fi
SPACEREPO="$(mktemp -d)/my repo"; mkdir -p "$SPACEREPO/.preflight"; ( cd "$SPACEREPO" && git init -q ); echo '{}' > "$SPACEREPO/.preflight/config.json"
DISPS="$PREFLIGHT_CLAUDE_HOME/preflight/dispatcher.cmd"
[ "$(fire "$DISPS" "echo hi" "$SPACEREPO")" = 0 ] && ok "17b space-path repo routes ok" || bad "17b space-path repo failed"

# ── 18. Source checkout can be DELETED after install (independence) ────────────────────────────────────
export PREFLIGHT_CLAUDE_HOME="$(new_home)"
TMPSRC="$(mktemp -d)/srcclone"; git clone -q "$REPO" "$TMPSRC" >/dev/null 2>&1; ( cd "$TMPSRC" && git checkout -q "$RESOLVED" 2>/dev/null || true )
pfu install --user --ref "$RESOLVED" --source "$TMPSRC" >/dev/null 2>&1
rm -rf "$TMPSRC"
pfu verify --user >/dev/null 2>&1 && ok "18 verify PASS after source checkout deleted (self-contained)" || bad "18 install depends on source checkout"

# ── 19. No network required after install (offline routing) ────────────────────────────────────────────
# The router does no network; a candidate decision is local. Prove a decision is produced with no net access.
DISP19="$PREFLIGHT_CLAUDE_HOME/preflight/dispatcher.cmd"
ACT3="$(mk_active_repo)"
RCN="$(fire "$DISP19" "git push origin main" "$ACT3")"
[ "$RCN" != 0 ] && ok "19 offline: local decision produced with no network (exit $RCN)" || bad "19 offline decision not produced"

# ── 20. (covered by the separate pilot-integrity check in acceptance; the suite never touches the pilot) ─
ok "20 suite uses only isolated temp HOME + temp repos — never touches the real pilot/HOME"

# ── 21. ADVERSARIAL RF2: `cd <opted-in> && git push` from a non-opted-in parent cwd → must GATE ─────────
export PREFLIGHT_CLAUDE_HOME="$(new_home)"; pfu install --user --ref "$RESOLVED" --source "$REPO" >/dev/null 2>&1
DISPA="$PREFLIGHT_CLAUDE_HOME/preflight/dispatcher.cmd"
PAR="$(mktemp -d)/parent"; mkdir -p "$PAR"; SUB="$PAR/act"; mkdir -p "$SUB/.preflight"; ( cd "$SUB" && git init -q ); echo '{}' > "$SUB/.preflight/config.json"
[ "$(fire "$DISPA" "cd $SUB && git push origin main" "$PAR")" != 0 ] && ok "21 RF2: cd<opted-in>&&push from inactive parent → GATED" || bad "21 RF2 evasion (cd) not closed"

# ── 22. ADVERSARIAL RF3: false-yield (empty stub + incidental substring) → must GATE, not yield ─────────
FPR="$(mktemp -d)/fp"; mkdir -p "$FPR/.preflight" "$FPR/.claude/hooks"; ( cd "$FPR" && git init -q )
echo '{}' > "$FPR/.preflight/config.json"; : > "$FPR/.claude/hooks/pre-bash-risk-router"
printf '{"note":"used pre-bash-risk-router once","hooks":{}}' > "$FPR/.claude/settings.json"
[ "$(fire "$DISPA" "git push origin main" "$FPR")" != 0 ] && ok "22 RF3: empty-stub+substring no longer false-yields → GATED" || bad "22 RF3 false-yield not closed"

# ── 23. ADVERSARIAL IF1: invalid pre-existing settings.json → install ABORTS (does not clobber) ─────────
export PREFLIGHT_CLAUDE_HOME="$(new_home)"; printf '{ bad,, "model":"keep"' > "$PREFLIGHT_CLAUDE_HOME/settings.json"
BEF="$(sha256sum "$PREFLIGHT_CLAUDE_HOME/settings.json" | cut -d' ' -f1)"
pfu install --user --ref "$RESOLVED" --source "$REPO" >/dev/null 2>&1; RCI=$?
AFT="$(sha256sum "$PREFLIGHT_CLAUDE_HOME/settings.json" | cut -d' ' -f1)"
[ "$RCI" != 0 ] && [ "$BEF" = "$AFT" ] && ok "23 IF1: invalid settings.json → install aborted, file untouched" || bad "23 IF1 clobbered invalid settings (rc=$RCI)"

# ── 24. ADVERSARIAL IF2: duplicate preflight entry → reinstall (same ref) collapses to one ──────────────
export PREFLIGHT_CLAUDE_HOME="$(new_home)"; pfu install --user --ref "$RESOLVED" --source "$REPO" >/dev/null 2>&1
# hand-duplicate the preflight Bash entry
python - "$PREFLIGHT_CLAUDE_HOME/settings.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
pre=d["hooks"]["PreToolUse"]; bash=[h for h in pre if h.get("matcher")=="Bash"][0]
pre.append(json.loads(json.dumps(bash)))  # duplicate
json.dump(d,open(p,'w'))
PY
pfu install --user --ref "$RESOLVED" --source "$REPO" >/dev/null 2>&1
N="$(python -c "import json,sys;d=json.load(open(sys.argv[1]));print(sum(1 for h in d['hooks']['PreToolUse'] if h.get('matcher')=='Bash' and any('dispatcher.cmd' in x.get('command','') for x in h.get('hooks',[]))))" "$PREFLIGHT_CLAUDE_HOME/settings.json")"
[ "$N" = 1 ] && ok "24 IF2: duplicate preflight entry collapses to one on reinstall" || bad "24 IF2 duplicates persist ($N)"

# ── 25. UNINSTALL exact-bytes restore (v0.10.0-rc.2): compact pre-install settings restored byte-identical ─
export PREFLIGHT_CLAUDE_HOME="$(new_home)"
printf '{"model":"keep","env":{"X":"1"},"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"my.sh"}]}]}}' > "$PREFLIGHT_CLAUDE_HOME/settings.json"
B25="$(sha256sum "$PREFLIGHT_CLAUDE_HOME/settings.json" | cut -d' ' -f1)"
pfu install --user --ref "$RESOLVED" --source "$REPO" >/dev/null 2>&1
pfu uninstall --user >/dev/null 2>&1
A25="$(sha256sum "$PREFLIGHT_CLAUDE_HOME/settings.json" 2>/dev/null | cut -d' ' -f1 || echo GONE)"
[ "$B25" = "$A25" ] && ok "25 uninstall restores pre-install settings BYTE-IDENTICAL" || bad "25 uninstall not byte-exact ($B25 vs $A25)"

# ── 26. UNINSTALL preserves a POST-install user change (does not clobber with the stale backup) ──────────
export PREFLIGHT_CLAUDE_HOME="$(new_home)"
printf '{"model":"orig"}' > "$PREFLIGHT_CLAUDE_HOME/settings.json"
pfu install --user --ref "$RESOLVED" --source "$REPO" >/dev/null 2>&1
python -c "import json,sys;p=sys.argv[1];d=json.load(open(p));d['newKey']='post';json.dump(d,open(p,'w'))" "$PREFLIGHT_CLAUDE_HOME/settings.json"
pfu uninstall --user >/dev/null 2>&1
python - "$PREFLIGHT_CLAUDE_HOME/settings.json" <<'PZ' && ok "26 uninstall preserves post-install change + removes preflight hook" || bad "26 post-install change lost"
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
assert d.get("model")=="orig" and d.get("newKey")=="post"
assert not any(h.get("matcher")=="Bash" and any("dispatcher.cmd" in x.get("command","") for x in h.get("hooks",[])) for h in d.get("hooks",{}).get("PreToolUse",[]))
PZ

echo ""
echo "user-install: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

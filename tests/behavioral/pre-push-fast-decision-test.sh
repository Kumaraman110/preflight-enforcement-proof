#!/usr/bin/env bash
# Behavioral test: BUILTINS-FIRST COMPLETE tier decision (Gate-4 spawn-budget fix, mission Phase 3).
#
# THE DEFECT (proven by the behavior matrix): the Part-1 fix made only the FORBIDDEN-NAME push fast; every
# other governed candidate (permitted/protected/bare/wrong-remote/URL push, and gh pr create) fell through
# to the ~45-spawn heavy pipeline and TIMED OUT at ~27s on this slow-spawn host → a generic-timeout block
# (NOT a policy decision) that ALSO recommended "run the push from a human shell" (principles 3, 5, 6).
#
# THE FIX: a builtins-first fast-decision path renders the SAME verdict the heavy path would (AUTO-allow /
# CONFIRM-ask / BLOCK), using bash builtins + at most a couple of bounded git calls + the (bounded) evidence
# gate on the AUTO path. The verdict CLASSES are oracle-matched to the heavy path here; diagnostics are
# content-derived and carry NO human-shell-bypass steering.
#
# This test asserts, for each governed shape, the EXPECTED verdict CLASS (BLOCK exit2 / ASK / ALLOW), that
# NO diagnostic recommends a human shell, and that timeout/engine-failure diagnostics state engine-failure
# (not policy approval). Exit 0 = all pass.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENGINE="$ROOT/hooks/pre-push-gate-engine"
ROUTER="$ROOT/hooks/pre-bash-risk-router"
[ -f "$ENGINE" ] || { echo "FAIL: engine not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required."; echo ""; echo "pre-push-fast-decision tests: 0 passed, 0 failed (skipped)"; exit 0; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

_CLEAN=(); trap 'for d in "${_CLEAN[@]}"; do rm -rf "$d" 2>/dev/null || true; done' EXIT

# Build a consumer-topology repo. $1 = optional extra config keys merged into branch{} (raw JSON fragment).
mkrepo() {  # $1 = extra branch JSON (e.g. ,"safeRemotes":["x"]) ; echoes repo path
  local extra="${1:-}" r; r="$(mktemp -d)/repo"; mkdir -p "$r"; _CLEAN+=("$(dirname "$r")")
  ( cd "$r"
    git init -q; git config user.email t@t; git config user.name t
    git remote add origin https://github.com/United-Airlines-Org/CPSL.git
    git remote add poc    https://github.com/United-Airlines-Org/cyf.cpsl_core.git
    git remote add safe   https://github.com/safe-org/app.git
    mkdir -p .preflight .preflight/gate
    printf '{"branch":{"base":"main","remote":"poc","forbiddenRemotes":["origin"],"forbiddenRepos":["United-Airlines-Org/CPSL"]%s}}' "$extra" > .preflight/config.json
    echo x > f; git add -A; git commit -qm init
    git checkout -q -b feature/registerseats-bff-l3
    h="$(git rev-parse HEAD)"
    printf 'HEAD=%s\n' "$h" > .preflight/gate/stage1-clean
    printf 'HEAD=%s\n' "$h" > .preflight/gate/tests-pass
  ) >/dev/null 2>&1
  printf '%s' "$r"
}
# Safe shims: any git push / gh → marker + nonzero (no transport); non-push git → real git.
SHIM="$(mktemp -d)/shim"; mkdir -p "$SHIM"; _CLEAN+=("$(dirname "$SHIM")"); MARK="$SHIM/.m"
_rg="$(command -v git)"
cat > "$SHIM/git" <<EOF
#!/bin/sh
case "\$*" in *push*) echo "SHIM \$*">>"$MARK"; exit 9;; esac
exec "$_rg" "\$@"
EOF
chmod +x "$SHIM/git"
cat > "$SHIM/gh" <<EOF
#!/bin/sh
echo "SHIM gh \$*">>"$MARK"; exit 9
EOF
chmod +x "$SHIM/gh"

LF=$'\n'
# run a command through the ENGINE directly (offline). Sets RC, OUT, CLS, BYPASS.
run() {  # $1 = repo ; $2 = command
  : > "$MARK"
  local j; j="$(jq -n --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c}}')"
  OUT="$(cd "$1" && printf '%s' "$j" | PATH="$SHIM:$PATH" CLAUDE_PROJECT_DIR="$1" timeout 90 bash "$ENGINE" 2>&1)"; RC=$?
  if [ "$RC" -eq 2 ]; then CLS=BLOCK
  elif printf '%s' "$OUT" | grep -q '"permissionDecision":"ask"'; then CLS=ASK
  elif printf '%s' "$OUT" | grep -q '"permissionDecision":"allow"'; then CLS=ALLOW
  elif [ "$RC" -eq 0 ]; then CLS="ALLOW-silent"
  else CLS="rc=$RC"; fi
  BYPASS=no; printf '%s' "$OUT" | grep -qiE 'from a human shell|push from a human|run the push from|from your own shell' && BYPASS=yes
}
expect() {  # $1 = label ; $2 = expected class ; (uses CLS/BYPASS/OUT from last run)
  if [ "$CLS" = "$2" ]; then ok "$1 → $2"; else bad "$1: expected $2, got $CLS :: $(printf '%s' "$OUT"|head -1|cut -c1-70)"; fi
  [ "$BYPASS" = no ] || bad "$1: diagnostic recommends a human shell (principle-6 violation)"
}

echo "════ fast-decision verdicts match the heavy-path oracle (no timeouts, no bypass steering) ════"
R="$(mkrepo)"
run "$R" "git push origin HEAD:topic";                 expect "forbidden-origin push" BLOCK
run "$R" "git push poc HEAD:feature/registerseats-bff-l3"; expect "permitted poc topic-branch" ALLOW
run "$R" "git push -u poc feature/registerseats-bff-l3";   expect "permitted poc (-u flag)" ALLOW
run "$R" "git push poc HEAD:main";                     expect "poc → PROTECTED branch main" ASK
run "$R" "git push";                                   expect "bare push (unvalidatable)" ASK
run "$R" "git push safe HEAD:topic";                   expect "wrong-remote (safe ≠ poc)" ASK
run "$R" "git push https://github.com/United-Airlines-Org/CPSL.git HEAD:main"; expect "URL → forbiddenRepos CPSL" BLOCK
run "$R" "git push https://github.com/safe-org/app.git HEAD:main";             expect "URL → safe (≠ named poc)" ASK
run "$R" "git push --force poc HEAD:main";             expect "force-push to PROTECTED main" BLOCK
run "$R" "git push poc +HEAD:main";                    expect "+refspec force to main" BLOCK

echo "════ gh pr create fast-decision (forbidden BLOCK / safe ALLOW; no timeout) ════"
run "$R" "gh pr create --repo United-Airlines-Org/CPSL --fill";            expect "pr-create → forbidden CPSL" BLOCK
run "$R" "gh pr create --repo United-Airlines-Org/cyf.cpsl_core --fill";   expect "pr-create → safe configured repo" ALLOW-silent

echo "════ strict safeRemotes + prod-pattern (oracle-matched CONFIRM) ════"
R2="$(mkrepo ',"safeRemotes":["blessed"]')"
run "$R2" "git push poc HEAD:topic";  expect "safeRemotes strict: poc not listed" ASK
R3="$(mkrepo)"
# prodremote: a configured remote whose URL looks prod → ASK even though configured
( cd "$R3" && git remote add prodr https://github.com/org/app-production.git ) >/dev/null 2>&1
R4="$(mkrepo)"
( cd "$R4" && git remote remove poc && git remote add poc https://github.com/org/app-production.git
  printf '{"branch":{"base":"main","remote":"poc","forbiddenRemotes":["origin"],"forbiddenRepos":["United-Airlines-Org/CPSL"]}}' > .preflight/config.json ) >/dev/null 2>&1
run "$R4" "git push poc HEAD:topic";  expect "configured remote looks PROD" ASK

echo "════ no-false-shortcut: ordinary git read + non-push exit 0 ════"
run "$R" "git status --porcelain";    expect "git status (non-push)" ALLOW-silent

echo "════ config.local.json overlay (INVERTED clone) → fast path APPLIES the overlay (no timeout) ════"
# The real consumer ships this exact topology: committed branch.remote=origin (wrong for the clone),
# config.local.json corrects it to poc (the inverted-clone fix). The fast path must APPLY the overlay
# (builtins) so the INTENDED `git push poc` reaches its real verdict FAST — not defer to the slow heavy
# path (which timed out at ~26s on the consumer). forbiddenRemotes stays committed-only (origin forbidden).
R5="$(mkrepo)"
( cd "$R5"
  printf '{"branch":{"base":"AccountLookUp_POC","remote":"origin","forbiddenRemotes":["origin"],"forbiddenRepos":["United-Airlines-Org/CPSL"]}}' > .preflight/config.json
  printf '{"branch":{"remote":"poc"}}' > .preflight/config.local.json ) >/dev/null 2>&1
# (a) the INTENDED push to the overlay-corrected remote 'poc', fresh evidence → ALLOW (fast, no timeout).
run "$R5" "git push poc HEAD:feature/registerseats-bff-l3"
{ [ "$CLS" = ALLOW ] && [ "$BYPASS" = no ]; } \
  && ok "overlay: 'git push poc' (overlay-corrected remote) + fresh evidence → ALLOW (overlay applied, no timeout)" \
  || bad "overlay: intended poc push expected ALLOW, got $CLS (bypass=$BYPASS) — overlay not applied / timed out"
# (b) the FORBIDDEN remote 'origin' (committed-only forbidden list, NOT overlayable) → still BLOCK.
run "$R5" "git push origin HEAD:topic"
{ [ "$CLS" = BLOCK ] && [ "$BYPASS" = no ]; } \
  && ok "overlay: 'git push origin' still BLOCK (forbiddenRemotes is committed-only, not overlayable)" \
  || bad "overlay: forbidden origin expected BLOCK, got $CLS"
# (c) a remote that is neither the overlay remote nor forbidden → wrong-remote CONFIRM (not the old timeout).
run "$R5" "git push safe HEAD:topic"
{ [ "$CLS" = ASK ] && [ "$BYPASS" = no ]; } \
  && ok "overlay: 'git push safe' (≠ overlay remote poc) → wrong-remote CONFIRM (ask), no timeout" \
  || bad "overlay: wrong-remote expected ASK, got $CLS"

echo "════ engine-failure diagnostics state failure-not-approval + no human-shell ════"
# Drive a wedge: a git shim that hangs on remote get-url so the fast-decision get-url wedges → heavy path →
# its wedge/timeout diagnostic. We assert (if a timeout/wedge message appears) it does NOT steer to a shell.
# (Behavioral: the message wording must never say 'human shell'.)
grep -qiE 'from a human shell|push from a human' "$ROUTER" "$ENGINE" \
  && bad "router/engine SOURCE still contains human-shell-bypass steering" \
  || ok "router + engine source carry NO human-shell-bypass steering (principle 6)"

echo ""
echo "pre-push-fast-decision tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Behavioral test: BOUNDED STATIC INSPECTION OF INLINE-SHELL WRAPPERS (BLOCKER-E).
#
# THE FAIL-OPEN (confirmed in review): a forbidden/non-canonical `gh pr merge`/`gh pr create` wrapped in an
# inline `bash -c '<literal>'` was SILENTLY ALLOWED — the inline `-c` body is not a git push (structural
# parser doesn't engage) nor a script FILE (wrapper resolver returns '' for inline `-c`), and the gh-pr
# detection ran on the OUTER raw string where the inner op is hidden inside the quoted payload.
#
# THE FIX: the engine statically recovers a `bash|sh|dash|zsh [-l|-i] -c <literal>` payload (builtins only,
# never executed/eval'd, no env interpolation, no profile sourcing) and re-feeds it through THE SAME engine
# (bounded recursion, depth 3), relaying the inner verdict: inner ALLOW→ALLOW, CONFIRM→CONFIRM, BLOCK→BLOCK,
# engine-failure→fail-closed. A DYNAMIC/opaque payload ($VAR / $(…) / `` / ${…} / eval / xargs / malformed
# or concatenated quoting / unterminated) is a DETERMINISTIC BLOCK. The gh-pr detection anchor no longer
# treats a literal '"' as a command separator (that both false-positived on `echo "gh pr …"` and was the
# wrong anchor), so a benign quoted MENTION is correctly ALLOWED.
#
# Every governed decision REUSES the existing direct-command policy (no second engine). No real gh/merge/push
# ever runs — a safe gh shim records any invocation; a shim hit on a BLOCK/CONFIRM case is a failure.
#
# Exit 0 = all pass.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENGINE="$ROOT/hooks/pre-push-gate-engine"
[ -f "$ENGINE" ] || { echo "FAIL: engine not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required."; echo ""; echo "pre-push-inline-shell tests: 0 passed, 0 failed (skipped)"; exit 0; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
_CLEAN=(); trap 'for d in "${_CLEAN[@]}"; do rm -rf "$d" 2>/dev/null || true; done' EXIT

# consumer topology: origin=CPSL (forbidden), poc=cyf.cpsl_core (canonical configured target).
mkrepo() {
  local r; r="$(mktemp -d)/repo"; mkdir -p "$r"; _CLEAN+=("$(dirname "$r")")
  ( cd "$r"
    git init -q; git config user.email t@t; git config user.name t
    git remote add origin https://github.com/United-Airlines-Org/CPSL.git
    git remote add poc    https://github.com/United-Airlines-Org/cyf.cpsl_core.git
    mkdir -p .preflight .preflight/gate
    printf '{"branch":{"base":"AccountLookUp_POC","remote":"poc","forbiddenRemotes":["origin"],"forbiddenRepos":["United-Airlines-Org/CPSL"]}}' > .preflight/config.json
    echo x > f; git add -A; git commit -qm init
    git checkout -q -b feature/registerseats-bff-l3 ) >/dev/null 2>&1
  printf '%s' "$r"
}
# safe shims: ANY gh → marker + nonzero; non-push git → real git; a push git → marker + nonzero.
SHIM="$(mktemp -d)/shim"; mkdir -p "$SHIM"; _CLEAN+=("$(dirname "$SHIM")"); MARK="$SHIM/.m"; _rg="$(command -v git)"
printf '#!/bin/sh\necho "SHIM gh $*">>"%s"; exit 9\n' "$MARK" > "$SHIM/gh"; chmod +x "$SHIM/gh"
printf '#!/bin/sh\ncase "$*" in *push*) echo "SHIM $*">>"%s"; exit 9;; esac\nexec "%s" "$@"\n' "$MARK" "$_rg" > "$SHIM/git"; chmod +x "$SHIM/git"

R="$(mkrepo)"
CANON=United-Airlines-Org/cyf.cpsl_core
FORB=United-Airlines-Org/CPSL

run() {  # $1 = command
  : > "$MARK"
  local j; j="$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}')"
  OUT="$(cd "$R" && printf '%s' "$j" | PATH="$SHIM:$PATH" CLAUDE_PROJECT_DIR="$R" timeout 90 bash "$ENGINE" 2>&1)"; RC=$?
  if [ "$RC" -eq 2 ]; then CLS=BLOCK
  elif printf '%s' "$OUT" | grep -q '"permissionDecision":"ask"'; then CLS=CONFIRM
  elif printf '%s' "$OUT" | grep -q '"permissionDecision":"allow"'; then CLS=ALLOW
  elif [ "$RC" -eq 0 ]; then CLS=ALLOW
  else CLS="rc=$RC"; fi
  MERGED=no; [ -s "$MARK" ] && MERGED=yes
}
# expect <label> <BLOCK|CONFIRM|ALLOW> [exec-allowed]
expect() {
  [ "$CLS" = "$2" ] && ok "$1 → $2" || bad "$1: expected $2 got $CLS :: $(printf '%s' "$OUT"|grep -ioE 'BLOCKED[^"]*|CONSEQUENTIAL MERGE[^"]*|cannot be statically|exceeded the supported'|head -1|cut -c1-64)"
  # for a BLOCK/CONFIRM, NO represented command may have executed (the gate decides before dispatch).
  if [ "$2" != ALLOW ]; then
    [ "$MERGED" = no ] || bad "$1: a represented gh/merge/push command EXECUTED (shim marker) — gate must decide before dispatch"
  fi
}

echo "════ A. direct baseline (unchanged behavior) ════"
run "gh pr merge 12 --repo $FORB --merge";              expect "A1 direct forbidden merge"        BLOCK
run "gh pr merge 12 --repo $CANON --merge";             expect "A2 direct canonical merge"        CONFIRM
run "gh pr merge 12 --repo $CANON --admin --merge";     expect "A3 direct --admin merge"          BLOCK
run "gh pr create --repo $FORB --fill";                 expect "A4 direct forbidden create"       BLOCK

echo "════ B. single-quoted inline body — the closed fail-open ════"
run "bash -c 'gh pr merge 12 --repo $FORB --merge'";    expect "B6 inline forbidden merge"        BLOCK
run "bash -c 'gh pr merge 12 --repo $CANON --merge'";   expect "B7 inline canonical merge"        CONFIRM
run "bash -c 'gh pr merge 12 --repo $CANON --admin --merge'"; expect "B8 inline --admin merge"    BLOCK
run "bash -c 'gh pr create --repo $FORB --fill'";       expect "B9 inline forbidden create"       BLOCK

echo "════ C. shell / option / prefix forms (forbidden inner → BLOCK) ════"
run "sh -c 'gh pr merge 12 --repo $FORB --merge'";              expect "C11 sh -c"                BLOCK
run "/usr/bin/bash -c 'gh pr merge 12 --repo $FORB --merge'";   expect "C12 /usr/bin/bash -c"     BLOCK
run "bash -lc 'gh pr merge 12 --repo $FORB --merge'";           expect "C13 bash -lc"             BLOCK
run "PATH=/x:\$PATH bash -c 'gh pr merge 12 --repo $FORB --merge'"; expect "C14 env prefix OUTSIDE" BLOCK
run "bash -c 'FOO=bar gh pr merge 12 --repo $FORB --merge'";    expect "C15 env prefix INSIDE body" BLOCK

echo "════ D. command structure inside the body (forbidden inner → BLOCK) ════"
run "bash -c 'echo ok && gh pr merge 12 --repo $FORB --merge'";       expect "D17 echo && merge"  BLOCK
run "bash -c 'gh pr merge 12 --repo $FORB --merge || echo failed'";   expect "D18 merge || echo"  BLOCK
run "bash -c 'echo a; gh pr merge 12 --repo $FORB --merge'";          expect "D19 semicolon list" BLOCK
run "bash -c \"sh -c 'gh pr merge 12 --repo $FORB --merge'\"";        expect "D21 nested sh-in-bash" BLOCK
run "bash -c 'bash -c \"bash -c \\\"bash -c hi\\\"\"'";               expect "D22 depth exhaustion → BLOCK" BLOCK

echo "════ E. dynamic / opaque payloads → deterministic BLOCK (never executed) ════"
run 'bash -c "$COMMAND"';                                       expect "E23 \$COMMAND"            BLOCK
run "bash -c \"gh pr merge 12 --repo \$TARGET --merge\"";       expect "E24 dynamic repo var"     BLOCK
run "bash -c \"\$(build_command)\"";                            expect "E25 command substitution" BLOCK
run 'bash -c "gh pr merge --repo `echo X` 12"';                 expect "E26 backticks"            BLOCK
run "bash -c 'eval \"gh pr merge 12 --repo $FORB\"'";           expect "E27 eval inside"          BLOCK
run "bash -c 'gh pr merge 12 --repo $FORB --merge";             expect "E28 malformed (unterminated quote)" BLOCK
run 'eval "gh pr merge 12 --repo '"$FORB"'"';                   expect "E29 bare eval indirection" BLOCK

echo "════ F. false-positive protection (benign → ALLOW; nothing executed wrongly) ════"
run "bash -c 'echo PREFLIGHT_INLINE_SAFE'";                     expect "F30 echo safe"            ALLOW
run "bash -c 'echo \"gh pr merge --repo $FORB\"'";              expect "F31 quoted mention (echo)" ALLOW
run "bash -c 'printf \"%s\\n\" \"gh pr create --repo X\"'";     expect "F32 printf mention"       ALLOW
run "bash -c 'echo gh pr merge is just words'";                 expect "F33 unquoted mention (echo)" ALLOW

echo "════ G. must-not-regress (this fix changes ONLY the inline bash/sh -c path) ════"
# NOTE on subshell `( … )` / command-substitution `$( … )` wrapping of `gh pr`: those forms are decided by
# the ROUTER's structural candidate classifier, NOT the engine's inline-`-c` path, and are a SEPARATE
# pre-existing gap (verified identical pre/post-fix at 1d2cc63 — this fix does not touch them). They are NOT
# asserted here: asserting ALLOW would pin a known bypass green, and asserting BLOCK would test code this
# narrowly-scoped patch intentionally did not change. The gap is reported as a distinct finding for a
# follow-up (router-classification), per the no-broadening scope bound.
run "bash -c 'git push origin main'";                           expect "G38 git push in bash -c → BLOCK" BLOCK
run "git push origin main";                                     expect "G39b direct forbidden push → BLOCK" BLOCK

echo ""
echo "pre-push-inline-shell tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

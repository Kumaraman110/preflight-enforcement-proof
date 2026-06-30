#!/usr/bin/env bash
# Behavioral test: QUOTE-AWARE INSPECTION OF SHELL GROUPING `( … )`, COMMAND-SUBSTITUTION `$( … )`, and
# BACKTICK `` ` … ` `` (BLOCKER-G).
#
# THE FAIL-OPEN (confirmed live, in real Claude-Code Bash-tool acceptance): a forbidden/non-canonical/
# protected `gh pr merge`/`gh pr create` wrapped in a subshell grouping `( gh pr merge … )`, a command-
# substitution `$(gh pr merge …)` / `echo "$(gh pr merge …)"`, or a backtick `` `gh pr merge …` `` was
# ALLOWED end-to-end. The inline-`-c` stage only inspects a LEADING `bash -c`; the engine's gh-pr detectors
# anchor on `(^|&&|\|\||;)` and never matched a `gh pr` preceded by `(`, `$(`, or `"`; and the router did
# not segment on the backtick, so a backtick-wrapped op never even reached the engine.
#
# THE FIX: (1) the engine runs a QUOTE-AWARE single-pass scanner (`_pfg_grouping_scan`, bash builtins only,
# never executes/evals/sources/interpolates) that recovers every LIVE grouping/substitution body plus a
# SKELETON (each live region replaced by an inert placeholder), and re-feeds each BODY and the SKELETON
# through THE SAME engine (bounded recursion, shared PREFLIGHT_INLINE_DEPTH). Verdicts combine WORST-WINS:
# any inner BLOCK → outer BLOCK; else any inner CONFIRM → outer CONFIRM; else ALLOW. A command substitution
# runs its body BEFORE the surrounding command, and the PreToolUse gate decides before the tool dispatches,
# so a forbidden inner op is BLOCKed before it could execute. Single-quoted text, `\$ \( \``, comments, and
# `$(( ))` / `(( ))` arithmetic are NOT live (correctly ALLOWed as mentions). A malformed/unterminated live
# group or unterminated quote is OPAQUE → deterministic BLOCK. (2) the router (`pre-bash-risk-router`)
# segments on the backtick too, so a backtick-wrapped `gh pr` is classified a candidate and routed.
#
# Every governed decision REUSES the existing direct-command policy (no second engine). No real gh/merge/
# push ever runs — a safe gh/git shim records any invocation; a shim hit on a BLOCK/CONFIRM case is a failure
# (the gate must decide BEFORE dispatch, which for a command substitution means before the body executes).
#
# Exit 0 = all pass.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENGINE="$ROOT/hooks/pre-push-gate-engine"
ROUTER="$ROOT/hooks/pre-bash-risk-router"
[ -f "$ENGINE" ] || { echo "FAIL: engine not found" >&2; exit 1; }
[ -f "$ROUTER" ] || { echo "FAIL: router not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required."; echo ""; echo "pre-push-grouping-subst tests: 0 passed, 0 failed (skipped)"; exit 0; }

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

# run-through-ROUTER: this is the production path. The router classifies, then relays to the engine. A
# subshell/cmd-subst/backtick form must be ROUTED (else it would reach the tool ungated), so driving the
# router (not the engine directly) also proves the router-classification half of the fix.
run() {  # $1 = command
  : > "$MARK"
  local j; j="$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}')"
  OUT="$(cd "$R" && printf '%s' "$j" | PATH="$SHIM:$PATH" CLAUDE_PROJECT_DIR="$R" timeout 120 bash "$ROUTER" 2>&1)"; RC=$?
  if [ "$RC" -eq 2 ]; then CLS=BLOCK
  elif printf '%s' "$OUT" | grep -q '"permissionDecision":"ask"'; then CLS=CONFIRM
  elif printf '%s' "$OUT" | grep -q '"permissionDecision":"allow"'; then CLS=ALLOW
  elif [ "$RC" -eq 0 ]; then CLS=ALLOW
  else CLS="rc=$RC"; fi
  MERGED=no; [ -s "$MARK" ] && MERGED=yes
}
# expect <label> <BLOCK|CONFIRM|ALLOW>
expect() {
  [ "$CLS" = "$2" ] && ok "$1 → $2" || bad "$1: expected $2 got $CLS :: $(printf '%s' "$OUT"|grep -ioE 'BLOCKED[^"]*|CONSEQUENTIAL MERGE[^"]*|malformed or unterminated|exceeded the supported'|head -1|cut -c1-70)"
  # for a BLOCK/CONFIRM, NO represented command may have executed (the gate decides before dispatch — and for
  # a command substitution that means before the substitution body runs).
  if [ "$2" != ALLOW ]; then
    [ "$MERGED" = no ] || bad "$1: a represented gh/merge/push command EXECUTED (shim marker) — gate must decide before dispatch"
  fi
}

echo "════ A. subshell grouping ( … ) — forbidden inner → BLOCK ════"
run "( gh pr merge 12 --repo $FORB --merge )";              expect "A1 ( forbidden merge )"          BLOCK
run "(gh pr merge 12 --repo $FORB --merge)";                expect "A2 (forbidden merge) no-space"   BLOCK
run "( gh pr merge 12 --repo $CANON --merge )";             expect "A3 ( canonical merge )"          CONFIRM
run "( gh pr merge 12 --repo $CANON --admin --merge )";     expect "A4 ( --admin merge )"            BLOCK
run "( gh pr create --repo $FORB --fill )";                 expect "A5 ( forbidden create )"         BLOCK
run "( echo hello )";                                       expect "A6 safe ( echo hello )"          ALLOW

echo "════ B. command substitution \$( … ) — body runs BEFORE surround → decide first ════"
run "echo \"\$(gh pr merge 12 --repo $FORB --merge)\"";     expect "B7 echo \$(forbidden merge)"     BLOCK
run "echo \"\$(gh pr merge 12 --repo $CANON --merge)\"";    expect "B8 echo \$(canonical merge)"     CONFIRM
run "\$(gh pr create --repo $FORB --fill)";                 expect "B9 bare \$(forbidden create)"    BLOCK
run "echo \"\$(printf safe)\"";                             expect "B10 safe echo \$(printf safe)"   ALLOW
run "echo \"\$(\$BUILD_CMD)\"";                             expect "B11 dynamic \$(\$VAR) subst"     ALLOW

echo "════ C. backtick \` … \` (router must segment on backtick) ════"
run "echo \`gh pr merge 12 --repo $FORB --merge\`";         expect "C12 backtick forbidden merge"    BLOCK
run "echo \`gh pr merge 12 --repo $CANON --merge\`";        expect "C13 backtick canonical merge"    CONFIRM
run "echo \"\`gh pr merge 12 --repo $FORB --merge\`\"";     expect "C14 dq-backtick forbidden"       BLOCK

echo "════ D. composition / nesting (bounded recursion) ════"
run "( bash -c 'gh pr merge 12 --repo $FORB --merge' )";    expect "D15 ( bash -c forbidden )"       BLOCK
run "bash -c '( gh pr merge 12 --repo $FORB --merge )'";    expect "D16 bash -c '( forbidden )'"     BLOCK
run "echo \"\$(bash -c 'gh pr merge 12 --repo $FORB --merge')\""; expect "D17 echo \$(bash -c forbidden)" BLOCK
run "( bash -c 'gh pr merge 12 --repo $CANON --merge' )";   expect "D18 nested canonical → CONFIRM"  CONFIRM

echo "════ E. worst-wins: an OUTER governed op dominates a benign/inner body ════"
run "gh pr merge 12 --repo $FORB --merge \"\$(echo safe)\""; expect "E19 outer-forbidden + benign body" BLOCK
run "gh pr merge 12 --repo $FORB --merge \"\$(gh pr merge 12 --repo $CANON --merge)\""; expect "E20 outer-forbidden + inner-canonical" BLOCK

echo "════ F. opaque / malformed live grouping → deterministic BLOCK ════"
run "echo \"\$(gh pr merge 12 --repo $FORB";                expect "F21 unterminated subst → opaque" BLOCK
run "( gh pr merge 12 --repo $FORB --merge";                expect "F22 unterminated subshell → opaque" BLOCK

echo "════ G. false-positive protection (literal / mention / arithmetic / comment → ALLOW) ════"
run "echo '( gh pr merge 12 --repo $FORB --merge )'";       expect "G23 single-quoted group literal" ALLOW
run "echo '\$(gh pr merge 12 --repo $FORB --merge)'";       expect "G24 single-quoted subst literal" ALLOW
run "echo \"gh pr merge 12 --repo $FORB\"";                 expect "G25 double-quoted mention"       ALLOW
run "echo \$(( 1 + 2 ))";                                   expect "G26 \$(( arithmetic ))"          ALLOW
run "echo ok # \$(gh pr merge --repo $FORB)";               expect "G27 comment with subst text"     ALLOW

echo "════ H. git push wrapped in grouping/subst (must-not-regress structural detection) ════"
run "( git push origin main )";                             expect "H28 git push in ( )"             BLOCK
run "echo \"\$(git push origin main)\"";                    expect "H29 git push in \$( )"           BLOCK

echo "════ I. direct + inline-\`-c\` baselines unchanged (no regression from this stage) ════"
run "gh pr merge 12 --repo $FORB --merge";                  expect "I30 direct forbidden merge"      BLOCK
run "gh pr merge 12 --repo $CANON --merge";                 expect "I31 direct canonical merge"      CONFIRM
run "bash -c 'gh pr merge 12 --repo $FORB --merge'";        expect "I32 inline -c forbidden merge"   BLOCK
run "echo hello world";                                     expect "I33 plain command stays ALLOW"   ALLOW

echo ""
echo "pre-push-grouping-subst tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

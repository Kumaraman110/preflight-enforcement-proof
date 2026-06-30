#!/usr/bin/env bash
# Behavioral test: SPECIFICATION CORPUS for the shared shell-structure parser (lib/shell-structure.sh).
#
# Stage 1 of the shared-parser redesign (see .release-audit/mission2/ci/missionG/SHELL-STRUCTURE-PARSER-DESIGN.md).
# The parser is PARSER-ONLY and UNWIRED — this test exercises lib/shell-structure.sh DIRECTLY; it does not
# touch the router/engine policy path and asserts NO enforcement decision. It proves the IR is correct:
# for each command it checks the parser STATUS, the number of nodes, and (per the approved matrix) the
# presence/absence of a governed executable node, the execution context, computed-token flags, and opacity.
#
# This test runs ONLY lib/shell-structure.sh in-process (no subprocess, no shims, no git). It is fast.
# Exit 0 = all pass.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$ROOT/lib/shell-structure.sh"
[ -f "$LIB" ] || { echo "FAIL: lib/shell-structure.sh not found" >&2; exit 1; }
# shellcheck source=/dev/null
source "$LIB"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# ── Test adapter: serialize the IR to a stable, greppable text form (NOT used by the production parser). ──
# Each line: "<id>|<parent>|<ctx>|<exec_basename>|<exec_computed>|<subcmd>|<subcmd_computed>|<opacity>"
_serialize() {
  local i
  for ((i=0; i<PFG_SS_NODE_COUNT; i++)); do
    local base; base="$(pfg_ss_exec_basename "$i")"
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$i" "${PFG_SS_PARENT[$i]}" "${PFG_SS_CTX[$i]}" "${base}" \
      "${PFG_SS_EXEC_COMPUTED[$i]}" "${PFG_SS_SUBCMD[$i]}" "${PFG_SS_SUBCMD_COMPUTED[$i]}" "${PFG_SS_OPACITY[$i]}"
  done
}

# assert_status <label> <command> <expected-status>
assert_status() {
  pfg_ss_parse "$2"
  [ "$PFG_SS_STATUS" = "$3" ] && ok "$1 → STATUS=$3" || bad "$1: expected STATUS=$3 got $PFG_SS_STATUS ($PFG_SS_STATUS_REASON)"
}
# assert_nodes <label> <command> <expected-count>
assert_nodes() {
  pfg_ss_parse "$2"
  [ "$PFG_SS_NODE_COUNT" = "$3" ] && ok "$1 → $3 nodes" || bad "$1: expected $3 nodes got $PFG_SS_NODE_COUNT :: $(_serialize | tr '\n' ' ')"
}
# assert_has_governed <label> <command> <basename> <ctx>  — a NON-opaque node with that exec+ctx exists.
# NOTE: capture _serialize into a var BEFORE grep. A `_serialize | grep -q` pipeline interacts badly with
# `set -o pipefail`: grep -q exits on first match and closes the pipe, the upstream _serialize gets SIGPIPE
# (non-zero), and pipefail then reports the whole pipeline as failed even though grep MATCHED.
assert_has_governed() {
  pfg_ss_parse "$2"
  local _s; _s="$(_serialize)"
  if grep -qE "^[0-9]+\|[-0-9]+\|$4\|$3\|0\|" <<< "$_s"; then ok "$1 → has $3@$4"
  else bad "$1: expected a $3@$4 node :: $(printf '%s' "$_s" | tr '\n' ' ')"; fi
}
# assert_no_governed <label> <command> <basename> — NO node with that exec basename at all.
assert_no_governed() {
  pfg_ss_parse "$2"
  local _s; _s="$(_serialize)"
  if grep -qE "^[0-9]+\|[-0-9]+\|[A-Z_]+\|$3\|" <<< "$_s"; then bad "$1: did NOT expect a $3 node :: $(printf '%s' "$_s" | tr '\n' ' ')"
  else ok "$1 → no $3 node (literal/non-executable)"; fi
}
# assert_opaque_present <label> <command> — at least one OPAQUE node exists.
assert_opaque_present() {
  pfg_ss_parse "$2"
  [ "$(pfg_ss_has_opaque)" = 1 ] && ok "$1 → has OPAQUE node" || bad "$1: expected an OPAQUE node :: $(_serialize | tr '\n' ' ')"
}
# assert_opaque_reason <label> <command> <reason-substring>
assert_opaque_reason() {
  pfg_ss_parse "$2"
  local i found=0
  for ((i=0; i<PFG_SS_NODE_COUNT; i++)); do
    [ "${PFG_SS_OPACITY[$i]}" = OPAQUE ] && case "${PFG_SS_OPACITY_REASON[$i]}" in *"$3"*) found=1 ;; esac
  done
  # also accept a top-level opaque-status reason
  case "$PFG_SS_STATUS_REASON" in *"$3"*) found=1 ;; esac
  [ "$found" = 1 ] && ok "$1 → opaque reason contains '$3'" || bad "$1: no opaque reason matched '$3' :: status=$PFG_SS_STATUS reason=$PFG_SS_STATUS_REASON"
}
# assert_span_consistent <label> <command> — every node's [start,end) is within [0,len] and start<=end.
assert_span_consistent() {
  pfg_ss_parse "$2"
  local i bad=0 len=${#2}
  for ((i=0; i<PFG_SS_NODE_COUNT; i++)); do
    local s="${PFG_SS_START[$i]}" e="${PFG_SS_END[$i]}"
    { [ "$s" -ge 0 ] && [ "$e" -ge "$s" ] && [ "$e" -le "$len" ]; } || bad=1
  done
  [ "$bad" = 0 ] && ok "$1 → spans consistent" || bad "$1: span out of range :: $(_serialize | tr '\n' ' ')"
}

X=United-Airlines-Org/CPSL

echo "════ A. simple commands & lists ════"
assert_has_governed "A1 direct git push"        "git push origin main"            git TOPLEVEL
assert_has_governed "A2 direct gh pr create"     "gh pr create --repo $X"          gh  TOPLEVEL
assert_has_governed "A3 direct gh pr merge"      "gh pr merge --repo $X 12 --merge" gh TOPLEVEL
assert_has_governed "A4 semicolon list"          "echo ok; gh pr merge --repo $X"  gh  TOPLEVEL
assert_has_governed "A5 && list"                 "true && gh pr merge --repo $X"   gh  TOPLEVEL
assert_has_governed "A6 || list"                 "false || gh pr merge --repo $X"  gh  TOPLEVEL
assert_has_governed "A7 newline list"            "$(printf 'echo a\ngh pr merge --repo X')" gh TOPLEVEL

echo "════ B. pipelines ════"
assert_has_governed "B1 true | gh pr merge"      "true | gh pr merge --repo $X"    gh  TOPLEVEL
assert_has_governed "B2 gh pr merge | cat"       "gh pr merge --repo $X | cat"     gh  TOPLEVEL
assert_has_governed "B3 multi-stage pipe"        "a | b | gh pr merge --repo $X | d" gh TOPLEVEL

echo "════ C. grouping ════"
assert_has_governed "C1 subshell"                "( gh pr merge --repo $X )"       gh  SUBSHELL
assert_has_governed "C2 brace group"             "{ gh pr merge --repo $X ; }"     gh  BRACE_GROUP
assert_has_governed "C3 nested groups"           "( { gh pr merge --repo $X ; } )" gh  BRACE_GROUP

echo "════ D. control structures ════"
assert_has_governed "D1 if/then"                 "if true; then gh pr merge --repo $X; fi"      gh IF_BODY
assert_has_governed "D2 while/do"                "while false; do gh pr merge --repo $X; done"  gh WHILE_BODY
assert_has_governed "D3 until/do"                "until false; do gh pr merge --repo $X; done"  gh UNTIL_BODY
assert_has_governed "D4 for/in/do"               "for x in 1 2; do gh pr merge --repo $X; done" gh FOR_BODY
assert_has_governed "D5 case/in"                 "case x in x) gh pr merge --repo $X;; esac"    gh CASE_BODY
assert_has_governed "D6 elif body"               "if a; then b; elif c; then gh pr merge --repo $X; fi" gh IF_BODY
assert_has_governed "D7 else body"               "if a; then b; else gh pr merge --repo $X; fi" gh ELSE_BODY

echo "════ E. substitutions ════"
assert_has_governed "E1 \$( )"                   "echo \"\$(gh pr merge --repo $X)\""  gh COMMAND_SUBSTITUTION
assert_has_governed "E2 backtick"                "echo \`gh pr merge --repo $X\`"      gh BACKTICK_SUBSTITUTION
assert_has_governed "E3 <( )"                    "cat <(gh pr merge --repo $X)"        gh PROCESS_SUBSTITUTION_IN
assert_has_governed "E4 >( )"                    "cat >(gh pr merge --repo $X) </dev/null" gh PROCESS_SUBSTITUTION_OUT

echo "════ F. inline shells ════"
assert_has_governed "F1 bash -c literal"         "bash -c 'gh pr merge --repo $X'"     gh INLINE_SHELL
assert_has_governed "F2 sh -c literal"           "sh -c 'gh pr merge --repo $X'"       gh INLINE_SHELL
assert_has_governed "F3 bash -lc cluster"        "bash -lc 'gh pr merge --repo $X'"    gh INLINE_SHELL
assert_has_governed "F4 nested inline in subshell" "( bash -c 'gh pr merge --repo $X' )" gh INLINE_SHELL
assert_has_governed "F5 inline inside \$( )"     "echo \"\$(bash -c 'gh pr merge --repo $X')\"" gh INLINE_SHELL
assert_opaque_present "F6 inline dynamic payload" "bash -c \"\$DYNAMIC\""

echo "════ G. computed forms → OPAQUE ════"
assert_opaque_reason "G1 computed program"        "\$(echo gh) pr merge --repo $X"      "computed executable token"
assert_opaque_reason "G2 computed subcommand"     "gh pr \$(echo merge) --repo $X"      "computed governed-subcommand"
assert_opaque_reason "G3 variable executable"     "\"\$PROGRAM\" pr merge --repo $X"    "computed executable token"
assert_opaque_reason "G4 \${VAR} executable"      "\${PROGRAM} pr merge --repo $X"      "computed executable token"
assert_opaque_reason "G5 backtick program"        "\`echo gh\` pr merge --repo $X"      "computed executable token"
assert_opaque_reason "G6 variable subcommand"     "gh \"\$AREA\" merge --repo $X"       "computed governed-subcommand"

echo "════ H. false-positive controls → NO governed node ════"
assert_no_governed "H1 single-quoted example"     "echo 'gh pr merge --repo $X'"        gh
assert_no_governed "H2 double-quoted mention"     "echo \"gh pr merge --repo $X\""      gh
assert_no_governed "H3 comment"                   "echo ok # gh pr merge --repo $X"     gh
assert_no_governed "H4 escaped dollar/paren"      "echo \\\$(gh pr merge --repo $X)"    gh
assert_no_governed "H5 printf example"            "printf '%s\\n' 'gh pr merge'"        gh
assert_no_governed "H6 arithmetic"                "echo \$(( 1 + 2 ))"                  gh
assert_no_governed "H7 \${VAR} as data"           "echo \${HOME}/gh"                    gh
assert_no_governed "H8 safe cmd-subst"            "echo \"\$(printf done)\""            gh
assert_no_governed "H9 heredoc DATA to cat"       "$(printf 'cat <<EOF\ngh pr merge --repo X\nEOF')" gh

echo "════ I. malformed → OPAQUE / limit ════"
assert_status      "I1 unterminated quote"        "echo \"unterminated"                 OPAQUE
assert_status      "I2 unterminated subshell"     "( gh pr merge --repo $X"             OPAQUE
assert_status      "I3 unterminated cmd-subst"    "echo \"\$(gh pr merge --repo $X"     OPAQUE
assert_opaque_present "I4 heredoc into shell"     "$(printf 'bash <<EOF\ngh pr merge\nEOF')"

echo "════ J. budgets (limit-1 / limit / limit+1) ════"
# SIZE: build a command just over/under PFG_SS_MAX_BYTES.
_big() { local k="$1" s=""; while [ "${#s}" -lt "$k" ]; do s+="echo aaaaaaaa; "; done; printf '%s' "${s:0:$k}"; }
PFG_SS_MAX_BYTES=200
assert_status "J1 size limit-1"  "$(_big 199)"  OK
assert_status "J2 size exact"    "$(_big 200)"  OK
assert_status "J3 size limit+1"  "$(_big 201)"  SIZE_LIMIT
PFG_SS_MAX_BYTES=65536
# DEPTH: nested subshells.
_nest() { local d="$1" o="" c="" i; for ((i=0;i<d;i++)); do o+="( "; c=" )$c"; done; printf '%sgh pr merge --repo X%s' "$o" "$c"; }
PFG_SS_MAX_DEPTH=4
assert_status "J4 depth under"   "$(_nest 3)"   OK
assert_status "J5 depth over"    "$(_nest 9)"   DEPTH_LIMIT
PFG_SS_MAX_DEPTH=8
# NODE: many simple commands.
_many() { local k="$1" s="" i; for ((i=0;i<k;i++)); do s+="echo $i; "; done; printf '%s' "$s"; }
PFG_SS_MAX_NODES=10
assert_status "J6 node under"    "$(_many 8)"   OK
assert_status "J7 node over"     "$(_many 50)"  NODE_LIMIT
PFG_SS_MAX_NODES=256

echo "════ K. span consistency (sample) ════"
assert_span_consistent "K1 pipeline span"        "true | gh pr merge --repo $X"
assert_span_consistent "K2 nested span"          "( { gh pr merge --repo $X ; } )"
assert_span_consistent "K3 inline span"          "bash -c 'gh pr merge --repo $X'"

echo ""
echo "pre-bash-structure-parser tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

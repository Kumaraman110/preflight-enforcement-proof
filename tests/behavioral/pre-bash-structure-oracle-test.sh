#!/usr/bin/env bash
# Behavioral test: DIFFERENTIAL EXECUTION ORACLE for the shared shell-structure parser (lib/shell-structure.sh).
#
# Stage 1 of the shared-parser redesign. The parser is PARSER-ONLY and UNWIRED — this test exercises
# lib/shell-structure.sh DIRECTLY and asserts NO enforcement decision. It compares, for each command:
#   (A) REAL BASH: does a governed shim actually EXECUTE? (gh / git push marker shims; no network, isolated)
#   (B) PARSER: does the IR contain a governed executable node (gh/git push) OR an OPAQUE executable node?
# and FAILS on the dangerous mismatch — real bash runs a governed shim that the parser neither identified
# as that governed op nor marked OPAQUE. It also checks the structural-spec side: for a statically-present
# governed command position, the parser must emit the node (or OPAQUE) even when a runtime guard happens to
# prevent execution in THIS literal run (e.g. `while false; do gh …; done`) — the execution marker alone is
# insufficient, so the spec column drives those.
#
# This is the regression backstop that would have caught all of the command-position fail-opens. It NEVER
# runs a real gh/git network op (marker shims exit nonzero, append to a marker), NEVER touches the consumer,
# and uses only an isolated temp repo. It is portable to Linux Bash and Windows Git-Bash.
#
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
_CLEAN=(); trap 'for d in "${_CLEAN[@]}"; do rm -rf "$d" 2>/dev/null || true; done' EXIT

# ── Isolated sandbox + marker shims (no network, no consumer, no real remote/credentials) ────────────────
SB="$(mktemp -d)"; _CLEAN+=("$SB"); MARK="$SB/.mark"; _rg="$(command -v git || true)"
cat > "$SB/gh" <<EOF
#!/bin/sh
echo "GH \$*" >> "$MARK"
exit 9
EOF
cat > "$SB/git" <<EOF
#!/bin/sh
case "\$*" in *push*) echo "GITPUSH \$*" >> "$MARK"; exit 9;; esac
exit 0
EOF
chmod +x "$SB/gh" "$SB/git"

# (A) real-bash oracle: returns GH | GITPUSH | NONE  (which governed shim executed, if any)
oracle() {
  : > "$MARK"
  ( cd "$SB" && PATH="$SB:/usr/bin:/bin" timeout 8 bash -c "$1" ) >/dev/null 2>&1 || true
  if grep -q '^GH ' "$MARK" 2>/dev/null; then echo GH
  elif grep -q '^GITPUSH ' "$MARK" 2>/dev/null; then echo GITPUSH
  else echo NONE; fi
}

# (B) parser view: returns one of
#   GOV-gh | GOV-git | OPAQUE | NONE  (does the IR contain a non-opaque gh/git-push node? an opaque node? neither?)
parser_view() {
  pfg_ss_parse "$1"
  if [ "$PFG_SS_STATUS" != OK ]; then echo OPAQUE; return; fi   # top-level opaque/limit → caller fails closed
  local i gov="" opq=0
  for ((i=0; i<PFG_SS_NODE_COUNT; i++)); do
    [ "${PFG_SS_OPACITY[$i]}" = OPAQUE ] && opq=1
    local b; b="$(pfg_ss_exec_basename "$i")"
    if [ "${PFG_SS_OPACITY[$i]}" != OPAQUE ]; then
      case "$b" in
        gh)  case " ${PFG_SS_SUBCMD[$i]} " in *" pr "*) gov="gh" ;; esac ;;
        git) case " ${PFG_SS_SUBCMD[$i]} " in *" push "*) gov="git" ;; esac ;;
      esac
    fi
  done
  if [ -n "$gov" ]; then echo "GOV-$gov"; elif [ "$opq" = 1 ]; then echo OPAQUE; else echo NONE; fi
}

# classify(cmd, spec) — spec ∈ {EXEC_GOV, NO_EXEC, OPAQUE_EXPECTED}
#   EXEC_GOV       : a governed op is statically present (must be GOV-* or OPAQUE; and if real-bash EXEC it
#                    must NOT be NONE — that is a MISSED fail-open).
#   NO_EXEC        : literal/non-executable (real bash NOEXEC; parser must NOT emit a governed node →
#                    NONE or OPAQUE acceptable, but NOT GOV-*; a GOV-* here would be a FALSE_POSITIVE).
#   OPAQUE_EXPECTED: an ambiguous/computed/here-doc-exec structure (parser must be OPAQUE; real-bash may EXEC).
classify() {  # $1 label  $2 cmd  $3 spec
  local o p; o="$(oracle "$2")"; p="$(parser_view "$2")"
  case "$3" in
    EXEC_GOV)
      # the dangerous mismatch: real bash executed a governed shim but the parser saw NONE.
      if [ "$o" != NONE ] && [ "$p" = NONE ]; then bad "$1: MISSED — real-bash=$o but parser=NONE (fail-open)"; return; fi
      # structural requirement: a statically-present governed op must be GOV-* or OPAQUE.
      case "$p" in GOV-*|OPAQUE) ok "$1: FOUND (real-bash=$o, parser=$p)" ;; *) bad "$1: parser=$p, expected GOV-*/OPAQUE (real-bash=$o)" ;; esac ;;
    NO_EXEC)
      if [ "$o" != NONE ]; then bad "$1: oracle expected NO_EXEC but real-bash=$o (test spec wrong?)"; return; fi
      case "$p" in GOV-*) bad "$1: FALSE_POSITIVE — parser emitted $p for non-executed/literal text" ;; *) ok "$1: NO_EXECUTION (parser=$p)" ;; esac ;;
    OPAQUE_EXPECTED)
      case "$p" in OPAQUE) ok "$1: OPAQUE_BLOCK_EXPECTED (real-bash=$o, parser=OPAQUE)" ;; *) bad "$1: expected parser=OPAQUE got $p (real-bash=$o)" ;; esac ;;
  esac
}

X=United-Airlines-Org/CPSL

echo "════ governed op in every command POSITION → must be FOUND (GOV-* or OPAQUE), never MISSED ════"
classify "1  direct merge"          "gh pr merge --repo $X 12 --merge"                 EXEC_GOV
classify "2  list ;"                "echo ok; gh pr merge --repo $X 12 --merge"        EXEC_GOV
classify "3  &&"                    "true && gh pr merge --repo $X 12 --merge"         EXEC_GOV
classify "4  ||"                    "false || gh pr merge --repo $X 12 --merge"        EXEC_GOV
classify "5  pipeline |"            "true | gh pr merge --repo $X 12 --merge"          EXEC_GOV
classify "6  subshell ( )"          "( gh pr merge --repo $X 12 --merge )"             EXEC_GOV
classify "7  brace { }"             "{ gh pr merge --repo $X 12 --merge ; }"           EXEC_GOV
classify "8  if/then"               "if true; then gh pr merge --repo $X 12 --merge; fi" EXEC_GOV
classify "9  while/do"              "while false; do gh pr merge --repo $X 12 --merge; done" EXEC_GOV
classify "10 for/do"                "for x in 1; do gh pr merge --repo $X 12 --merge; done"  EXEC_GOV
classify "11 case"                  "case x in x) gh pr merge --repo $X 12 --merge;; esac"   EXEC_GOV
classify "12 \$( )"                 "echo \"\$(gh pr merge --repo $X 12 --merge)\""    EXEC_GOV
classify "13 backtick"              "echo \`gh pr merge --repo $X 12 --merge\`"        EXEC_GOV
classify "14 <( )"                  "cat <(gh pr merge --repo $X 12 --merge)"          EXEC_GOV
classify "15 >( )"                  "cat >(gh pr merge --repo $X 12 --merge) </dev/null" EXEC_GOV
classify "16 bash -c"               "bash -c 'gh pr merge --repo $X 12 --merge'"       EXEC_GOV
classify "17 ( bash -c )"           "( bash -c 'gh pr merge --repo $X 12 --merge' )"   EXEC_GOV
classify "18 git push pipeline"     "true | git push origin main"                      EXEC_GOV
classify "19 git push in ( )"       "( git push origin main )"                         EXEC_GOV

echo "════ computed tokens → OPAQUE (real bash executes; parser must fail closed) ════"
classify "20 computed program"      "\$(echo gh) pr merge --repo $X 12 --merge"        OPAQUE_EXPECTED
classify "21 computed subcommand"   "gh pr \$(echo merge) --repo $X 12 --merge"        OPAQUE_EXPECTED
classify "22 heredoc into shell"    "$(printf 'bash <<EOF\ngh pr merge --repo X\nEOF')" OPAQUE_EXPECTED

echo "════ literal / non-executable → NO_EXECUTION, no FALSE_POSITIVE ════"
classify "23 single-quoted"         "echo 'gh pr merge --repo $X'"                     NO_EXEC
classify "24 double-quoted mention" "echo \"gh pr merge --repo $X\""                   NO_EXEC
classify "25 comment"               "echo ok # gh pr merge --repo $X"                  NO_EXEC
classify "26 arithmetic"            "echo \$(( 1 + 2 ))"                               NO_EXEC
classify "27 safe cmd-subst"        "echo \"\$(printf done)\""                         NO_EXEC
classify "28 printf literal"        "printf '%s\\n' 'gh pr merge --repo $X'"           NO_EXEC
classify "29 heredoc DATA to cat"   "$(printf 'cat <<EOF\ngh pr merge --repo X\nEOF')"  NO_EXEC

echo ""
echo "pre-bash-structure-oracle tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

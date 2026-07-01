#!/usr/bin/env bash
# Behavioral test: FIELD-FOR-FIELD EQUIVALENCE of the AWK-backed parser against the FROZEN Stage-1 Bash
# parser (tests/behavioral/fixtures/shell-structure-stage1-frozen.sh).
#
# Stage 2A. The production parser (lib/shell-structure.sh) now uses the POSIX-AWK lexer. This test proves it
# produces IDENTICAL IR — every field — to the committed Stage-1 pure-Bash parser, across the full corpus
# command set PLUS adversarial inputs not in the corpus (quoting/escapes/CRLF/nesting/heredocs/limits). The
# frozen reference is sourced in a clean subshell so its symbols don't collide with the live library.
#
# A single divergence FAILS. This is the gate that guarantees the AWK backend is a drop-in replacement.
# Exit 0 = all pass.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIVE="$ROOT/lib/shell-structure.sh"
FROZEN="$ROOT/tests/behavioral/fixtures/shell-structure-stage1-frozen.sh"
[ -f "$LIVE" ]   || { echo "FAIL: lib/shell-structure.sh not found" >&2; exit 1; }
[ -f "$FROZEN" ] || { echo "FAIL: frozen Stage-1 reference not found ($FROZEN)" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# full IR serialization for a command using the library at $1, in a clean subshell.
# NOTE: run under LC_ALL=C (byte-offset semantics — the Phase-6 contract; without it the frozen Bash
# parser's ${#cmd} counts CHARACTERS in a UTF-8 locale, giving char offsets, while the AWK path always
# reports bytes). Do NOT use `set -u` here: the frozen Stage-1 parser has a latent unbound-var read
# (`local a2="$2"` at analyze_simple when a governed command has a single arg token, e.g. `git push`)
# that ABORTS the frozen parser under `set -u` but is harmless in normal (non-set-u) invocation — which is
# how pfg_ss_parse is actually called. The AWK port does not have that bug; matching the real invocation
# context (LC_ALL=C, no set -u) is the correct equivalence baseline.
serialize_with() {  # $1 lib  $2 command  [$3 maxbytes $4 maxdepth $5 maxnodes]
  LC_ALL=C bash -c '
    set -o pipefail
    source "$1"
    [ -n "$3" ] && PFG_SS_MAX_BYTES="$3"; [ -n "$4" ] && PFG_SS_MAX_DEPTH="$4"; [ -n "$5" ] && PFG_SS_MAX_NODES="$5"
    pfg_ss_parse "$2"
    printf "STATUS=%s NODES=%s\n" "$PFG_SS_STATUS" "$PFG_SS_NODE_COUNT"
    for ((i=0;i<PFG_SS_NODE_COUNT;i++)); do
      b="$(pfg_ss_exec_basename "$i")"
      printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
        "$i" "${PFG_SS_PARENT[$i]}" "${PFG_SS_CTX[$i]}" "${PFG_SS_START[$i]}" "${PFG_SS_END[$i]}" \
        "$b" "${PFG_SS_EXEC_COMPUTED[$i]}" "${PFG_SS_SUBCMD[$i]}" "${PFG_SS_SUBCMD_COMPUTED[$i]}" \
        "${PFG_SS_ENV[$i]}" "${PFG_SS_OPACITY[$i]}" "${PFG_SS_OPACITY_REASON[$i]}"
    done
  ' _ "$1" "$2" "${3:-}" "${4:-}" "${5:-}"
}

eq() {  # $1 label  $2 command  [budgets...]
  local a b
  a="$(serialize_with "$FROZEN" "$2" "${3:-}" "${4:-}" "${5:-}" 2>/dev/null)"
  b="$(serialize_with "$LIVE"   "$2" "${3:-}" "${4:-}" "${5:-}" 2>/dev/null)"
  if [ "$a" = "$b" ]; then ok "$1"
  else bad "$1 :: DIVERGENCE"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sed 's/^/    /' >&2; fi
}

X=United-Airlines-Org/CPSL

# ── full corpus command set (mirrors the specification corpus) ──────────────────────────────────────────
eq "A1" "git push origin main"
eq "A2" "gh pr create --repo $X"
eq "A3" "gh pr merge --repo $X 12 --merge"
eq "A4" "echo ok; gh pr merge --repo $X"
eq "A5" "true && gh pr merge --repo $X"
eq "A6" "false || gh pr merge --repo $X"
eq "A7" "$(printf 'echo a\ngh pr merge --repo X')"
eq "B1" "true | gh pr merge --repo $X"
eq "B2" "gh pr merge --repo $X | cat"
eq "B3" "a | b | gh pr merge --repo $X | d"
eq "C1" "( gh pr merge --repo $X )"
eq "C2" "{ gh pr merge --repo $X ; }"
eq "C3" "( { gh pr merge --repo $X ; } )"
eq "D1" "if true; then gh pr merge --repo $X; fi"
eq "D2" "while false; do gh pr merge --repo $X; done"
eq "D3" "until false; do gh pr merge --repo $X; done"
eq "D4" "for x in 1 2; do gh pr merge --repo $X; done"
eq "D5" "case x in x) gh pr merge --repo $X;; esac"
eq "D6" "if a; then b; elif c; then gh pr merge --repo $X; fi"
eq "D7" "if a; then b; else gh pr merge --repo $X; fi"
eq "E1" "echo \"\$(gh pr merge --repo $X)\""
eq "E2" "echo \`gh pr merge --repo $X\`"
eq "E3" "cat <(gh pr merge --repo $X)"
eq "E4" "cat >(gh pr merge --repo $X) </dev/null"
eq "F1" "bash -c 'gh pr merge --repo $X'"
eq "F2" "sh -c 'gh pr merge --repo $X'"
eq "F3" "bash -lc 'gh pr merge --repo $X'"
eq "F4" "( bash -c 'gh pr merge --repo $X' )"
eq "F5" "echo \"\$(bash -c 'gh pr merge --repo $X')\""
eq "F6" "bash -c \"\$DYNAMIC\""
eq "G1" "\$(echo gh) pr merge --repo $X"
eq "G2" "gh pr \$(echo merge) --repo $X"
eq "G3" "\"\$PROGRAM\" pr merge --repo $X"
eq "G4" "\${PROGRAM} pr merge --repo $X"
eq "G5" "\`echo gh\` pr merge --repo $X"
eq "G6" "gh \"\$AREA\" merge --repo $X"
eq "H1" "echo 'gh pr merge --repo $X'"
eq "H2" "echo \"gh pr merge --repo $X\""
eq "H3" "echo ok # gh pr merge --repo $X"
eq "H4" "echo \\\$(gh pr merge --repo $X)"
eq "H5" "printf '%s\\n' 'gh pr merge'"
eq "H6" "echo \$(( 1 + 2 ))"
eq "H7" "echo \${HOME}/gh"
eq "H8" "echo \"\$(printf done)\""
eq "H9" "$(printf 'cat <<EOF\ngh pr merge --repo X\nEOF')"
eq "I1" "echo \"unterminated"
eq "I2" "( gh pr merge --repo $X"
eq "I3" "echo \"\$(gh pr merge --repo $X"
eq "I4" "$(printf 'bash <<EOF\ngh pr merge\nEOF')"

# ── adversarial inputs beyond the corpus (byte-fidelity, structure, edge cases) ─────────────────────────
eq "Z-empty"            ""
eq "Z-space"            " "
eq "Z-semis"            ";;;"
eq "Z-trailnl"          "gh pr merge"$'\n'
eq "Z-leadnl"           $'\n'"gh pr merge"
eq "Z-crlf"             "echo a"$'\r'$'\n'"gh pr merge"
eq "Z-cr-in-arg"        "gh pr merge --title a"$'\r'"b"
eq "Z-tabs"             $'\t'"gh"$'\t'"pr"$'\t'"merge"
eq "Z-multispace"       "gh    pr     merge   --repo $X"
eq "Z-esc-space"        "gh pr merge --title a\\ b"
eq "Z-esc-semi"         "echo a\\; gh pr merge"
eq "Z-nested-cs"        "echo \$(echo \$(gh pr merge))"
eq "Z-cs-in-dq"         "echo \"outer \$(gh pr merge) tail\""
eq "Z-bt-in-dq"         "echo \"\`gh pr merge\`\""
eq "Z-deep-parens"      "((((echo hi))))"
eq "Z-mixed-group"      "{ ( gh pr merge ); }"
eq "Z-pipe-heavy"       "a|b|c|gh pr merge|d|e"
eq "Z-andor"            "a && b || c && gh pr merge"
eq "Z-env2"             "FOO=bar BAZ=qux gh pr merge --repo $X"
eq "Z-env-eqval"        "FOO=a=b gh pr merge"
eq "Z-command-pfx"      "command gh pr merge --repo $X"
eq "Z-exec-pfx"         "exec gh pr merge"
eq "Z-env-tool"         "env FOO=bar gh pr merge"
eq "Z-env-tool-opts"    "env -i -u PATH FOO=x gh pr merge"
eq "Z-quoted-prog"      "'gh' pr merge"
eq "Z-dq-prog"          "\"gh\" pr merge"
eq "Z-path-prog"        "/usr/bin/gh pr merge"
eq "Z-exe-suffix"       "gh.exe pr merge"
eq "Z-computed-arg"     "gh pr merge --title \$(date)"
eq "Z-var-repo"         "gh pr merge --repo \$REPO"
eq "Z-herestring"       "cat <<< 'gh pr merge'"
eq "Z-heredoc-cat"      "$(printf 'cat <<END\ngh pr merge\nEND\n')"
eq "Z-heredoc-dash"     "$(printf 'cat <<-END\n\tgh pr merge\n\tEND\n')"
eq "Z-heredoc-bash"     "$(printf 'bash <<END\ngh pr merge\nEND\n')"
eq "Z-case-multi"       "case \$x in a) gh pr merge;; b) git push;; esac"
eq "Z-while-read"       "while read l; do gh pr merge; done"
eq "Z-until"            "until false; do git push; done"
eq "Z-for-cstyle"       "for ((i=0;i<3;i++)); do gh pr merge; done"
eq "Z-func"             "f() { gh pr merge; }"
eq "Z-nested-inline"    "bash -c 'sh -c \"gh pr merge\"'"
eq "Z-inline-lc"        "bash -lc 'gh pr merge'"
eq "Z-inline-nopay"     "bash -c"
eq "Z-redir-out"        "gh pr merge > /tmp/x"
eq "Z-redir-in"         "gh pr merge < /tmp/x"
eq "Z-redir-fd"         "gh pr merge 2>&1"
eq "Z-arith"            "echo \$((1+2*3))"
eq "Z-param-default"    "echo \${VAR:-default}"
eq "Z-param-nested"     "echo \${VAR:-\${OTHER}}"
eq "Z-subshell-bg"      "( gh pr merge & )"
eq "Z-trail-bg"         "gh pr merge &"
eq "Z-comment-only"     "# just a comment"
eq "Z-comment-after"    "gh pr merge # trailing comment"
eq "Z-hash-midword"     "echo a#b"
eq "Z-many-quotes"      "echo 'a'\"b\"'c'"
eq "Z-unterm-sq"        "echo 'open"
eq "Z-unterm-cs"        "echo \$(open"
eq "Z-unterm-bt"        "echo \`open"
eq "Z-unterm-bp"        "echo \${open"
eq "Z-unterm-arith"     "echo \$((1+"
eq "Z-empty-subshell"   "( )"
eq "Z-empty-brace"      "{ }"
eq "Z-special"          "gh pr merge --body 'a!@#%^*()b'"
eq "Z-utf8"             "gh pr merge --title 'café résumé'"
eq "Z-backslash-path"   "echo C:\\\\Users\\\\x"
eq "Z-dollar-end"       "echo \$"
eq "Z-git-c-url"        "git -c remote.origin.url=x push"
eq "Z-double-computed"  "\$(echo gh) \$(echo pr) merge"
# budget edges (matching the corpus J-series budgets)
eq "Z-size201"          "$(s=""; while [ "${#s}" -lt 201 ]; do s+="echo aaaaaaaa; "; done; printf '%s' "${s:0:201}")" 200 8 256
eq "Z-nest9"            "$(o=""; c=""; for ((i=0;i<9;i++)); do o+="( "; c=" )$c"; done; printf '%sgh pr merge --repo X%s' "$o" "$c")" 65536 4 256
eq "Z-many50"           "$(s=""; for ((i=0;i<50;i++)); do s+="echo $i; "; done; printf '%s' "$s")" 65536 8 10

echo ""
echo "pre-bash-structure-equivalence tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

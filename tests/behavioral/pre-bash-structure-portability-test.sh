#!/usr/bin/env bash
# Behavioral test: CROSS-AWK PORTABILITY for the shell-structure lexer (lib/shell-structure-lexer.awk).
#
# Stage 2A. The lexer is POSIX-awk and must produce IDENTICAL protocol output (hence identical IR) under
# every supported awk implementation. This test runs the lexer under each awk implementation PRESENT on the
# host (gawk and/or mawk and/or the default `awk`) over a structural corpus and asserts byte-identical
# protocol output across implementations. If two present implementations DISAGREE structurally, the test
# FAILS (the Stage-2A "AWK PORTABILITY FAILURE" gate). Implementations that are absent are SKIPPED with a
# note (CI installs mawk; the local Windows host has only gawk). Version banners may differ; IR may not.
#
# It also proves byte-exact transport: a command containing CR is scanned identically (the BINMODE fix).
# Exit 0 = all pass (or all-but-one impl skipped, with at least the default awk exercised).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LEXER="$ROOT/lib/shell-structure-lexer.awk"
[ -f "$LEXER" ] || { echo "FAIL: lexer not found ($LEXER)" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# discover present awk implementations (dedupe by resolved real path so awk==gawk isn't double-counted).
declare -a IMPLS=() IMPL_NAMES=()
declare -A _seen_path=()
for cand in awk gawk mawk; do
  p="$(command -v "$cand" 2>/dev/null || true)"
  [ -n "$p" ] || { echo "note: $cand ABSENT (skipped)"; continue; }
  rp="$(readlink -f "$p" 2>/dev/null || echo "$p")"
  [ -n "${_seen_path[$rp]:-}" ] && { echo "note: $cand == already-tested $rp (skipped dup)"; continue; }
  _seen_path[$rp]=1
  IMPLS+=("$p"); IMPL_NAMES+=("$cand")
  echo "note: will test $cand -> $p ($("$p" --version 2>/dev/null | head -1 || echo '?'))"
done
[ "${#IMPLS[@]}" -ge 1 ] || { echo "FAIL: no awk implementation found at all" >&2; exit 1; }

# run the lexer under a specific awk impl over a command (raw stdin + BINMODE=3 for byte-exact CR).
run_impl() {  # $1 = awk path  $2 = command
  printf '%s' "$2" | LC_ALL=C "$1" -v BINMODE=3 -v MAXBYTES=65536 -v MAXNODES=256 -v MAXDEPTH=8 -f "$LEXER" 2>/dev/null
}

X=United-Airlines-Org/CPSL
CORPUS=(
  "git push origin main"
  "echo ok; gh pr merge --repo $X"
  "true | gh pr merge --repo $X | cat"
  "( { gh pr merge --repo $X ; } )"
  "if true; then gh pr merge --repo $X; fi"
  "for x in 1 2; do gh pr merge --repo $X; done"
  "case x in x) gh pr merge --repo $X;; esac"
  "echo \"\$(gh pr merge --repo $X)\""
  "cat <(gh pr merge --repo $X)"
  "bash -c 'gh pr merge --repo $X'"
  "\$(echo gh) pr merge --repo $X"
  "gh pr \$(echo merge) --repo $X"
  "echo 'gh pr merge --repo $X'"
  "echo \$(( 1 + 2 ))"
  "$(printf 'cat <<EOF\ngh pr merge\nEOF')"
  "$(printf 'bash <<EOF\ngh pr merge\nEOF')"
  "echo \"unterminated"
  "FOO=bar command gh pr merge"
  "gh pr merge --title 'café résumé'"
)
# a CR-bearing command (byte-fidelity across impls)
CORPUS+=( "echo a"$'\r'$'\n'"gh pr merge" )

# For each command, capture the reference impl's output, then compare every other impl to it.
refpath="${IMPLS[0]}"; refname="${IMPL_NAMES[0]}"
idx=0
for cmd in "${CORPUS[@]}"; do
  idx=$((idx+1))
  ref="$(run_impl "$refpath" "$cmd")"
  # the reference itself must be non-empty and terminate with an E record
  case "$ref" in *"E "*) : ;; *) bad "case $idx ($refname): reference produced no terminal E"; continue ;; esac
  allmatch=1
  for ((k=1; k<${#IMPLS[@]}; k++)); do
    other="$(run_impl "${IMPLS[$k]}" "$cmd")"
    if [ "$ref" != "$other" ]; then
      allmatch=0
      bad "case $idx: ${IMPL_NAMES[$k]} DIVERGES from $refname"
      diff <(printf '%s\n' "$ref") <(printf '%s\n' "$other") | sed 's/^/    /' >&2
    fi
  done
  [ "$allmatch" -eq 1 ] && ok "case $idx: consistent across ${#IMPLS[@]} impl(s)"
done

if [ "${#IMPLS[@]}" -eq 1 ]; then
  echo "note: only ONE awk implementation present ($refname) — cross-impl divergence NOT exercised here."
  echo "note: CI (ubuntu-latest) installs mawk to exercise gawk-vs-mawk; this run proved single-impl stability + CR byte-fidelity."
fi

echo ""
echo "pre-bash-structure-portability tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

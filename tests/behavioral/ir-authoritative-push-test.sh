#!/usr/bin/env bash
# Behavioral test: IR-AUTHORITATIVE git-push identification (Stage 2B) for hooks/pre-push-gate-engine.
#
# The shared shell-structure IR is now AUTHORITATIVE for identifying git-push command positions. This suite
# drives the ENGINE with crafted tool JSON in isolated mktemp repos (string-only remotes, no network, no
# consumer) and asserts the AUTHORITATIVE contract:
#   • static git push in EVERY command position → governed (BLOCK/CONFIRM/AUTO per policy),
#   • MULTIPLE pushes → worst-wins (a forbidden 2nd push BLOCKs even if the 1st is safe — the closed fail-open),
#   • computed executable / computed subcommand / opaque / parser-failure → deterministic BLOCK,
#   • false-positive controls (quoted/comment/heredoc-data/arith) → NOT blocked,
#   • policy regression cases (stale/fresh evidence, forbidden, protected, safe AUTO) preserved,
#   • every BLOCK/CONFIRM case proves the git shim did NOT execute (a marker file stays absent).
#
# Exit 0 = all pass.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$ROOT/hooks/pre-push-gate-engine"
[ -f "$HOOK" ] || { echo "FAIL: engine not found ($HOOK)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; echo "ir-authoritative-push tests: 0 passed, 0 failed"; exit 0; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ── Isolated workspace with a git SHIM on PATH: a real `git push` would touch MARKER; a BLOCK/CONFIRM must
# leave MARKER absent (proving the represented push never executed). git non-push ops fall through to real git.
SHIMDIR="$T/shim"; mkdir -p "$SHIMDIR"; MARKER="$T/pushed.marker"
REALGIT="$(command -v git)"
cat > "$SHIMDIR/git" <<EOF
#!/bin/sh
for a in "\$@"; do [ "\$a" = push ] && { echo pushed >> "$MARKER"; exit 0; }; done
exec "$REALGIT" "\$@"
EOF
chmod +x "$SHIMDIR/git"

mk_ws() {  # $1 name  $2 branch  $3 evidence(fresh|stale) → ws path
  local ws="$T/$1"; mkdir -p "$ws/.preflight/gate"
  ( cd "$ws" && "$REALGIT" init -q && "$REALGIT" commit -q --allow-empty -m init && "$REALGIT" checkout -q -b "$2" 2>/dev/null || (cd "$ws" && "$REALGIT" branch -m "$2") )
  if [ "$3" = fresh ]; then
    local h; h="$(cd "$ws" && "$REALGIT" rev-parse HEAD)"
    for ev in tests-pass stage1-clean; do printf 'HEAD=%s\nts=now\n' "$h" > "$ws/.preflight/gate/$ev"; done
  fi
  printf '{"branch":{"base":"main","remote":"origin","forbiddenRemotes":["evil"],"forbiddenRepos":["Org/PROD"],"safeRemotes":[]}}' > "$ws/.preflight/config.json"
  echo "$ws"
}
WS="$(mk_ws optedin feature/x fresh)"
WS_PROT="$(mk_ws onprot main fresh)"
WS_STALE="$(mk_ws stale feature/x stale)"

# verdict(ws, cmd) → sets RC + DEC; and detects shim execution (EXECD=1 if MARKER grew)
verdict() {
  local ws="$1" cmd="$2" js o
  : > "$MARKER"
  js="$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)")"
  o="$(cd "$ws" && printf '%s' "$js" | PATH="$SHIMDIR:$PATH" CLAUDE_PROJECT_DIR="$ws" timeout "${PROBE_TO:-200}" bash "$HOOK" "$js" 2>/dev/null)"; RC=$?
  DEC="$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision//""' 2>/dev/null || echo "")"
  EXECD=0; [ -s "$MARKER" ] && EXECD=1
}

# expect_block(label, ws, cmd): RC=2 AND shim did not execute
expect_block() { verdict "$2" "$3"; if [ "$RC" = 2 ] && [ "$EXECD" = 0 ]; then ok "$1 → BLOCK, shim not run"; else bad "$1 → expected BLOCK+no-exec, got RC=$RC DEC=$DEC EXECD=$EXECD"; fi; }
# expect_confirm(label, ws, cmd): RC=0 DEC=ask AND shim did not execute (the ask is pre-execution)
expect_confirm() { verdict "$2" "$3"; if [ "$RC" = 0 ] && [ "$DEC" = ask ] && [ "$EXECD" = 0 ]; then ok "$1 → CONFIRM, shim not run"; else bad "$1 → expected CONFIRM+no-exec, got RC=$RC DEC=$DEC EXECD=$EXECD"; fi; }
# expect_allow(label, ws, cmd): RC=0 DEC=allow (a push AUTO). (shim may run — that's the point of allow, but the
# hook returns before Claude executes; we just assert the verdict.)
expect_allow() { verdict "$2" "$3"; if [ "$RC" = 0 ] && [ "$DEC" = allow ]; then ok "$1 → AUTO allow"; else bad "$1 → expected AUTO allow, got RC=$RC DEC=$DEC"; fi; }
# expect_nonpush(label, ws, cmd): RC=0 and NO decision JSON (ordinary command passes ungated)
expect_nonpush() { verdict "$2" "$3"; if [ "$RC" = 0 ] && [ -z "$DEC" ]; then ok "$1 → non-push pass"; else bad "$1 → expected non-push pass, got RC=$RC DEC=$DEC"; fi; }

echo "════ A. direct + options (policy preserved) ════"
expect_allow   "A1 direct safe push"        "$WS"      "git push origin HEAD:feature/x"
expect_block   "A2 forbidden remote"        "$WS"      "git push evil HEAD:feature/x"
expect_block   "A3 forbidden repo url"      "$WS"      "git push https://github.com/Org/PROD.git main"
expect_confirm "A4 canonical protected"     "$WS"      "git push origin HEAD:main"
expect_block   "A5 force to protected"      "$WS_PROT" "git push --force origin HEAD:main"
expect_allow   "A6 absolute git exe"        "$WS"      "$REALGIT push origin HEAD:feature/x"
expect_allow   "A7a env prefix"             "$WS"      "GIT_TRACE=0 git push origin HEAD:feature/x"
expect_allow   "A7b command prefix"         "$WS"      "command git push origin HEAD:feature/x"
expect_confirm "A9 git -c url push protected" "$WS"    "git -c http.sslVerify=false push origin HEAD:main"

echo "════ structural positions — a FORBIDDEN push in each position must BLOCK ════"
expect_block   "S10 semicolon 2nd forbidden" "$WS"     "git push origin HEAD:feature/x; git push evil HEAD:main"
expect_block   "S11 && 2nd forbidden"        "$WS"     "git push origin HEAD:feature/x && git push evil main"
expect_block   "S12 || forbidden"            "$WS"     "false || git push evil HEAD:main"
expect_block   "S14 pipeline forbidden"      "$WS"     "true | git push evil HEAD:main"
expect_block   "S15 subshell forbidden"      "$WS"     "( git push evil HEAD:main )"
expect_block   "S16 brace forbidden"         "$WS"     "{ git push evil HEAD:main ; }"
expect_block   "S17 if forbidden"            "$WS"     "if true; then git push evil HEAD:main; fi"
expect_block   "S18 while forbidden"         "$WS"     "while false; do git push evil HEAD:main; done"
expect_block   "S20 for forbidden"           "$WS"     "for x in 1; do git push evil HEAD:main; done"
expect_block   "S21 case forbidden"          "$WS"     "case x in x) git push evil HEAD:main;; esac"

echo "════ computed / opaque → deterministic BLOCK ════"
expect_block   "C28 computed program"        "$WS"     "\$(echo git) push evil HEAD:main"
expect_block   "C30 computed subcommand"     "$WS"     "git \$(echo push) evil HEAD:main"
expect_block   "C31 var subcommand"          "$WS"     "git \"\$SUB\" evil HEAD:main"
expect_block   "C33 unterminated quote"      "$WS"     "git push evil \"unterminated"

echo "════ false-positive controls → NOT blocked ════"
expect_nonpush "F41 quoted mention"          "$WS"     "echo 'git push evil'"
expect_nonpush "F42 comment"                 "$WS"     "ls # git push evil"
expect_nonpush "F45 arithmetic"              "$WS"     "echo \$(( 1 + 2 ))"
expect_nonpush "F47 ordinary non-push"       "$WS"     "echo hello world"

echo "════ policy regression ════"
expect_block   "P48 stale evidence"          "$WS_STALE" "git push origin HEAD:feature/x"
expect_allow   "P49 fresh evidence AUTO"     "$WS"      "git push origin HEAD:feature/y"
expect_confirm "P51 non-canonical CONFIRM"   "$WS"      "git push other HEAD:feature/x"
expect_allow   "P53b two safe pushes AUTO"   "$WS"      "git push origin HEAD:feature/x; git push origin HEAD:feature/y"

echo "════ parser-dependency failure → deterministic BLOCK (awk abnormal) ════"
# A fake awk earlier in PATH that exits nonzero simulates a broken/abnormal awk. The IR parse then reports
# ERROR → the authoritative gate fails CLOSED → a push candidate BLOCKs (never a silent legacy allow).
# (Stripping awk from PATH entirely is not portable on this Git-Bash host — symlinking `timeout` breaks its
# shared-lib load — so a nonzero-exit fake awk is the clean, portable way to exercise the abnormal path.)
FAKEAWK="$T/fakeawk"; mkdir -p "$FAKEAWK"; printf '#!/bin/sh\nexit 3\n' > "$FAKEAWK/awk"; chmod +x "$FAKEAWK/awk"
: > "$MARKER"
_jsp="$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' 'git push origin HEAD:feature/x' | jq -Rs .)")"
_op="$(cd "$WS" && printf '%s' "$_jsp" | PATH="$FAKEAWK:$PATH" CLAUDE_PROJECT_DIR="$WS" timeout "${PROBE_TO:-200}" bash "$HOOK" "$_jsp" 2>/dev/null)"; _rcp=$?
_execp=0; [ -s "$MARKER" ] && _execp=1
{ [ "$_rcp" = 2 ] && [ "$_execp" = 0 ]; } && ok "P38 awk-abnormal + push → BLOCK, shim not run (fail-closed)" || bad "P38 awk-abnormal push should BLOCK+no-exec, got RC=$_rcp EXECD=$_execp"

echo ""
echo "ir-authoritative-push tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Behavioral test: SCRIPT-WRAPPER INSPECTION (mission Phase 4) — governed operations hidden inside a local
# script must NOT bypass policy.
#
# THE GAP: `bash /tmp/x.sh` (sh/dash/zsh/source/.) hides any governed op (git push / gh pr create / sentinel
# mint) INSIDE the file, invisible to the router's raw-command substring globs. The router now routes such
# shapes to the engine, which READS the script's contents (builtins only — NEVER executes/sources/evals it)
# and applies the SAME policy: FORBIDDEN→block (naming the underlying op+target), SAFE→allow (+TOCTOU
# snapshot via updatedInput), ASK→content-derived confirm, OPAQUE→fail-closed confirm that instructs
# expanding into directly-inspectable commands (no human-shell steering).
#
# Exit 0 = all pass. Uses controlled fixtures only — NEVER reads/modifies the real
# /c/Users/v173617/AppData/Local/Temp/rs_pr119_round2.sh (reproduced as a fixture of the same shape).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENGINE="$ROOT/hooks/pre-push-gate-engine"
ROUTER="$ROOT/hooks/pre-bash-risk-router"
[ -f "$ENGINE" ] || { echo "FAIL: engine not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required."; echo ""; echo "pre-push-script-wrapper tests: 0 passed, 0 failed (skipped)"; exit 0; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
_CLEAN=(); trap 'for d in "${_CLEAN[@]}"; do rm -rf "$d" 2>/dev/null || true; done' EXIT

REPO="$(mktemp -d)/repo"; mkdir -p "$REPO/scripts"; _CLEAN+=("$(dirname "$REPO")")
( cd "$REPO"
  git init -q; git config user.email t@t; git config user.name t
  git remote add origin https://github.com/United-Airlines-Org/CPSL.git
  git remote add poc    https://github.com/United-Airlines-Org/cyf.cpsl_core.git
  mkdir -p .preflight .preflight/gate
  printf '{"branch":{"base":"main","remote":"poc","forbiddenRemotes":["origin"],"forbiddenRepos":["United-Airlines-Org/CPSL"]}}' > .preflight/config.json
  echo x > f; git add -A; git commit -qm init
  git checkout -q -b feature/registerseats-bff-l3
  h="$(git rev-parse HEAD)"
  printf 'HEAD=%s\n' "$h" > .preflight/gate/stage1-clean
  printf 'HEAD=%s\n' "$h" > .preflight/gate/tests-pass
) >/dev/null 2>&1

# Fixtures (controlled). NOTE: the real rs_pr119_round2.sh is NEVER touched — we reproduce its SHAPE.
S="$REPO/scripts"
printf '#!/usr/bin/env bash\necho hi\ngit status\nls -la\ncat README.md\n'                 > "$S/safe.sh"
printf '#!/usr/bin/env bash\necho deploying\ngit push origin HEAD:refs/heads/probe\n'        > "$S/forbidden_push.sh"
printf '#!/usr/bin/env bash\ngit push poc HEAD:feature/registerseats-bff-l3\n'               > "$S/safe_remote_push.sh"
printf '#!/usr/bin/env bash\necho x > notes.txt\nrm -f stale.tmp\nmkdir -p out\n'            > "$S/mutate.sh"
printf '#!/usr/bin/env bash\nx=$(git config user.name)\necho "$x"\n'                          > "$S/cmdsubst.sh"
printf '#!/usr/bin/env bash\neval "git push origin main"\n'                                   > "$S/eval.sh"
printf '#!/usr/bin/env bash\ncat <<HERE\nstuff\nHERE\n'                                        > "$S/heredoc.sh"
printf '#!/usr/bin/env bash\ndeploy() { git push origin main; }\ndeploy\n'                     > "$S/function.sh"
printf '#!/usr/bin/env bash\nfor r in origin poc; do git push $r main; done\n'                > "$S/loop.sh"
printf '#!/usr/bin/env bash\nif true; then git push origin main; fi\n'                         > "$S/conditional.sh"
printf '#!/usr/bin/env bash\n( cd /tmp && git push origin main )\n'                            > "$S/subshell.sh"
printf '#!/usr/bin/env bash\nP=push\ngit $P origin main\n'                                     > "$S/varbuilt.sh"
printf '#!/usr/bin/env bash\necho Z2l0IHB1c2g= | base64 -d | bash\n'                           > "$S/decode.sh"
printf '#!/usr/bin/env bash\necho step\nbash scripts/inner_forbidden.sh\n'                     > "$S/nested.sh"
printf '#!/usr/bin/env bash\ngit push origin HEAD:x\n'                                         > "$S/inner_forbidden.sh"
printf '#!/usr/bin/env bash\n# reproduction of the reported invocation SHAPE only (benign content)\necho round2\ngit status\ngit diff --stat\n' > "$S/rs_pr119_round2.sh"
# a script with a quoted path containing spaces
mkdir -p "$REPO/with space"; printf '#!/usr/bin/env bash\necho ok\nls\n' > "$REPO/with space/sp.sh"
# oversized script
{ echo '#!/usr/bin/env bash'; for i in $(seq 1 5000); do echo "echo line$i"; done; } > "$S/oversize.sh"
# binary script
printf '#!/usr/bin/env bash\n\x00\x01\x02 echo hi\n' > "$S/binary.sh"

# Safe shims: git push / gh → marker (no transport); non-push git → real git.
SHIM="$(mktemp -d)/shim"; mkdir -p "$SHIM"; _CLEAN+=("$(dirname "$SHIM")"); MARK="$SHIM/.m"; _rg="$(command -v git)"
cat > "$SHIM/git" <<EOF
#!/bin/sh
case "\$*" in *push*) echo "SHIM \$*">>"$MARK"; exit 9;; esac
exec "$_rg" "\$@"
EOF
chmod +x "$SHIM/git"

run() {  # $1 = command
  : > "$MARK"
  local j; j="$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}')"
  OUT="$(cd "$REPO" && printf '%s' "$j" | PATH="$SHIM:$PATH" CLAUDE_PROJECT_DIR="$REPO" timeout 90 bash "$ENGINE" 2>&1)"; RC=$?
  if [ "$RC" -eq 2 ]; then CLS=BLOCK
  elif printf '%s' "$OUT" | grep -q '"permissionDecision":"ask"'; then CLS=ASK
  elif printf '%s' "$OUT" | grep -q '"permissionDecision":"allow"'; then CLS=ALLOW
  elif [ "$RC" -eq 0 ]; then CLS=ALLOW-silent
  else CLS="rc=$RC"; fi
  SHIMHIT=no; [ -s "$MARK" ] && SHIMHIT=yes
  BYPASS=no; printf '%s' "$OUT" | grep -qiE 'from a human shell|push from a human' && BYPASS=yes
}
exp() {  # $1 label ; $2 expected class
  if [ "$CLS" = "$2" ]; then ok "$1 → $2"; else bad "$1: expected $2 got $CLS :: $(printf '%s' "$OUT"|grep -ioE 'BLOCKED[^"]*|CONFIRM[^"]*'|head -1|cut -c1-60)"; fi
  [ "$SHIMHIT" = no ] || bad "$1: a represented command EXECUTED (shim marker present) — inspection must never run the script"
  [ "$BYPASS" = no ] || bad "$1: diagnostic recommends a human shell (principle-6 violation)"
}

echo "════ forbidden / safe / mutation / consequential ════"
run "bash scripts/forbidden_push.sh";    exp "forbidden push in script" BLOCK
printf '%s' "$OUT" | grep -qiE "git push origin|destination 'origin'" && ok "forbidden diag NAMES the underlying op+target (origin)" || bad "forbidden diag did not name origin"
run "bash scripts/safe.sh";              exp "safe read-only script" ALLOW
printf '%s' "$OUT" | grep -q 'updatedInput' && ok "SAFE script allow carries a TOCTOU snapshot (updatedInput)" || bad "SAFE allow has no updatedInput snapshot"
run "bash scripts/safe_remote_push.sh";  exp "safe-remote push in script (consequential)" ASK
run "bash scripts/mutate.sh";            exp "local mutation script" ASK
printf '%s' "$OUT" | grep -qi 'mutating' && ok "mutation ASK reason describes the action" || bad "mutation ASK lacks action description"

echo "════ dynamic / unsupported constructs → DETERMINISTIC BLOCK (BLOCKER 1: never ask, never silent-allow) ════"
# BLOCKER 1: an opaque/un-analyzable wrapper must be a hard BLOCK (exit 2), NOT an approval prompt. Asking
# the user to approve an opaque wrapper recreates approval friction and lets an un-inspectable governed op
# through on one click. Each construct below must BLOCK; the diagnostic must NEVER recommend a human shell.
for f in cmdsubst eval heredoc function loop conditional subshell varbuilt decode; do
  run "bash scripts/$f.sh"
  [ "$CLS" = BLOCK ] && ok "opaque construct '$f' → DETERMINISTIC BLOCK (not ask, not silent-allow)" \
                     || bad "opaque '$f': expected BLOCK, got $CLS"
done
# the opaque BLOCK diagnostic must (a) instruct expanding into inspectable commands, (b) state nothing
# executed, (c) NOT ask for approval, (d) NOT display only a bare `bash <path>` as the meaningful reason.
run "bash scripts/eval.sh"
printf '%s' "$OUT" | grep -qiE 'dynamic command construction|could not.*resolve|EXPAND|expand the script' \
  && ok "opaque BLOCK reason states the unsupported construct + expand-guidance" || bad "opaque BLOCK reason missing construct/expand-guidance"
printf '%s' "$OUT" | grep -qiE 'No command was executed|no represented command executed' \
  && ok "opaque BLOCK states no command executed" || bad "opaque BLOCK does not state no-execution"
printf '%s' "$OUT" | grep -qi '"permissionDecision":"ask"' \
  && bad "opaque BLOCK wrongly emitted an ask (must be a hard block, exit 2)" || ok "opaque BLOCK did NOT emit an approval prompt"
# the reason must be content-aware, not a bare 'bash <path>' echo.
if printf '%s' "$OUT" | grep -qiE 'dynamic command construction|eval|command-substitution|could not be (safely )?(read|resolved)'; then
  ok "opaque BLOCK reason is content-aware (names the construct/failure, not a bare 'bash <path>')"
else
  bad "opaque BLOCK reason is not content-aware"
fi

echo "════ nested forbidden / missing / oversize / binary / quoted-path ════"
run "bash scripts/nested.sh";            exp "nested script with forbidden push" BLOCK
run "bash scripts/nonexistent.sh";       exp "missing script (no file → nothing executes → not a governed op)" ALLOW-silent
run "bash scripts/oversize.sh";          exp "oversize script → DETERMINISTIC BLOCK" BLOCK
run "bash scripts/binary.sh";            exp "binary script → DETERMINISTIC BLOCK" BLOCK
run "bash 'with space/sp.sh'";           exp "quoted path with spaces (safe)" ALLOW
# a script-exec shape whose quoted path is unrecoverable/unreadable → __UNRESOLVED__ → BLOCK (not ask).
run "bash 'no such dir/missing.sh'";     exp "unresolvable quoted script path → BLOCK" BLOCK

echo "════ exact reported invocation SHAPE (controlled fixture, benign) ════"
run "bash scripts/rs_pr119_round2.sh";   exp "rs_pr119_round2-shape (benign read-only)" ALLOW
printf '%s' "$OUT" | grep -qv 'Approve bash' && ok "decision is content-aware, not a bare 'Approve bash <path>'" || bad "decision was a bare wrapper approval"

echo "════ ordinary 'bash --version' / 'bash -c' are NOT script-wrapper-inspected (no false routing) ════"
run "bash --version";                    { [ "$CLS" = ALLOW-silent ] || [ "$CLS" = ALLOW ]; } && ok "'bash --version' not treated as a script wrapper (allowed)" || bad "'bash --version' wrongly gated: $CLS"

echo ""
echo "pre-push-script-wrapper tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

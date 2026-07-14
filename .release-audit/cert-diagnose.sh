#!/usr/bin/env bash
# cert-diagnose.sh — RUN ON THE CERTIFICATION RUNNER ONLY. Reproduces the exact failing case-types from the
# rc.4 full-suite certification and dumps byte-level intermediate state so the bash-5.3.9-cygwin behavior
# (vs the local bash-5.2-msys dev host) can be diagnosed from CI logs. Read-only; always exits 0 (evidence
# only, never a gate).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$ROOT/hooks/pre-push-gate-engine"
echo "=================== CERT DIAGNOSE ==================="
echo "bash:  $(bash --version | head -1)"
echo "awk:   $(awk --version 2>/dev/null | head -1)"
echo "jq:    $(jq --version 2>/dev/null)"
echo ""
_cr=$'\r'; _lf=$'\n'; bs='\'

# ── forbidden-remote repo fixture (origin+poc forbidden; canonical target 'poc' configured) ──
REPO="$(mktemp -d)/repo"; mkdir -p "$REPO"
FORB=forbidden-org/prod-repo
( cd "$REPO"
  git init -q; git config user.email t@t; git config user.name t
  git remote add origin https://github.com/forbidden-org/legacy-prod.git
  git remote add poc https://github.com/forbidden-org/prod-repo.git
  mkdir -p .preflight .preflight/gate
  printf '%s\n' '{ "branch": { "base": "main", "remote": "safe", "forbiddenRemotes": ["poc","origin"], "forbiddenRepos": ["forbidden-org/prod-repo","forbidden-org/legacy-prod"] } }' > .preflight/config.json
  git remote add safe https://github.com/safe-org/app.git
  echo x > f; git add -A; git commit -qm init; git checkout -q -b topic
  h="$(git rev-parse HEAD)"; printf 'HEAD=%s\n' "$h" > .preflight/gate/stage1-clean; printf 'HEAD=%s\n' "$h" > .preflight/gate/tests-pass
) >/dev/null 2>&1
# safe shims: any gh / any git push → record + nonzero (a shim hit on a BLOCK/CONFIRM = the gate let it run)
SHIM="$(mktemp -d)"; MARK="$SHIM/.m"; _rg="$(command -v git)"
printf '#!/bin/sh\necho "SHIM gh $*">>"%s"; exit 9\n' "$MARK" > "$SHIM/gh"; chmod +x "$SHIM/gh"
printf '#!/bin/sh\ncase "$*" in *push*) echo "SHIM $*">>"%s"; exit 9;; esac\nexec "%s" "$@"\n' "$MARK" "$_rg" > "$SHIM/git"; chmod +x "$SHIM/git"

decide() {  # $1 label ; $2 command-string ; prints rc + decision + whether a shim executed
  local json out rc dec execd; : > "$MARK"
  json="$(jq -n --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c}}')"
  out="$(cd "$REPO" && printf '%s' "$json" | PATH="$SHIM:$PATH" _PFG_WATCHDOG_CHILD=1 CLAUDE_PROJECT_DIR="$REPO" PREFLIGHT_ENGINE_DEADLINE=60 bash "$ENGINE" 2>&1)"; rc=$?
  if [ "$rc" = 2 ]; then dec=BLOCK
  elif printf '%s' "$out" | grep -q '"permissionDecision":"ask"'; then dec=CONFIRM
  elif printf '%s' "$out" | grep -q '"permissionDecision":"allow"'; then dec=ALLOW
  elif [ "$rc" = 0 ]; then dec=ALLOW-noDecision; else dec="rc=$rc"; fi
  execd=no; [ -s "$MARK" ] && execd=yes
  printf '  [%-32s] rc=%s dec=%-16s shim-exec=%s\n' "$1" "$rc" "$dec" "$execd"
}

echo "───────── CRLF / continuation (expect BLOCK forbidden) ─────────"
decide "single-line forbidden push"  "git push origin main"
decide "LF continuation push"        "git ${bs}${_lf}push origin main"
decide "CRLF continuation push"      "git ${bs}${_cr}${_lf}push origin main"

echo "───────── inline bash -c forbidden (BLOCKER-E: expect BLOCK) ─────────"
decide "bash -c forbidden merge"     "bash -c 'gh pr merge 12 --repo $FORB --merge'"
decide "sh -c forbidden push"        "sh -c 'git push origin main'"
decide "bash -lc forbidden push"     "bash -lc 'git push origin main'"

echo "───────── compound 2nd-position forbidden (expect BLOCK) ─────────"
decide "semicolon 2nd push"          "echo ok; git push origin main"
decide "&& 2nd push"                 "true && git push origin main"
decide "if forbidden"                "if true; then git push origin main; fi"

echo "───────── MULTI-PUSH: safe 1st + forbidden 2nd (S10/S11 shape; expect BLOCK) ─────────"
# 'safe' is the configured remote (AUTO), 'origin' is forbidden. The authoritative per-node loop must
# worst-wins across BOTH push nodes and BLOCK on the 2nd. IR push-count is dumped for these.
decide "multipush ; safe-then-forbidden" "git push safe main; git push origin main"
decide "multipush && safe-then-forbidden" "git push safe main && git push origin main"
decide "subshell forbidden push"          "( git push origin main )"
# IR push-count + per-node trace for the multi-push semicolon case. Instrument a copy of the engine that
# PRESERVES lib resolution: mirror hooks/ + lib/ into a temp dir so the copy's ../lib/ resolves the IR
# (a bare mktemp copy would set _PFG_SELF_DIR to a dir with no ../lib → spurious UNAVAIL).
echo "  --- IR push-count + per-node trace (multipush ;) ---"
IDIR="$(mktemp -d)"; mkdir -p "$IDIR/hooks" "$IDIR/lib"
cp "$ROOT/hooks/pre-push-gate-engine" "$IDIR/hooks/pre-push-gate-engine"
cp "$ROOT"/lib/*.sh "$ROOT"/lib/*.awk "$IDIR/lib/" 2>/dev/null || true
# trace: IR push count/status right after identify, and each per-node span slice in the authoritative loop.
awk '
  /^_pfg_ir_identify$/ && !t1 {print $0; print "printf '\''  DIAG@ir push=%s status=%s opq=%s cmp=%s\\n'\'' \"$_PFG_IR_PUSH_COUNT\" \"$_PFG_IR_STATUS\" \"$_PFG_IR_HAS_OPAQUE\" \"$_PFG_IR_HAS_COMPUTED\" >&2"; t1=1; next}
  /for _pfg_span in "\$\{_PFG_IR_PUSH_SPANS\[@\]\}"; do/ && !t2 {print $0; print "printf '\''  DIAG@node span=%s\\n'\'' \"$_pfg_span\" >&2"; t2=1; next}
  {print}
' "$ROOT/hooks/pre-push-gate-engine" > "$IDIR/hooks/pre-push-gate-engine"
_mpj="$(jq -n --arg c 'git push safe main; git push origin main' '{tool_name:"Bash",tool_input:{command:$c}}')"
( cd "$REPO" && printf '%s' "$_mpj" | PATH="$SHIM:$PATH" _PFG_WATCHDOG_CHILD=1 CLAUDE_PROJECT_DIR="$REPO" PREFLIGHT_ENGINE_DEADLINE=60 bash "$IDIR/hooks/pre-push-gate-engine" 2>&1 | grep -aE 'DIAG@|BLOCKED|permissionDecision' | head -6 | sed 's/^/  /' )
rm -rf "$IDIR" 2>/dev/null || true

# DIRECT LEXER PROBE (bypass the engine): dump PFG_SS_NODE_COUNT + each git-push node + the raw PUSH lines the
# engine's IR-identify would ingest. This isolates whether gawk 5.4 emits 2 push nodes or 1 for a `;` list.
echo "  --- direct lexer node dump for 'git push safe main; git push origin main' ---"
bash -c '
  set +e
  source "'"$ROOT"'/lib/shell-structure.sh" 2>/dev/null || { echo "  (lib source failed)"; exit 0; }
  pfg_ss_parse "git push safe main; git push origin main"
  echo "  STATUS=$PFG_SS_STATUS NODE_COUNT=$PFG_SS_NODE_COUNT"
  for ((i=0; i<PFG_SS_NODE_COUNT; i++)); do
    b="$(pfg_ss_exec_basename "$i" 2>/dev/null)"
    printf "  node %s: base=%s subcmd=[%s] ctx=%s opacity=%s span=%s:%s\n" "$i" "$b" "${PFG_SS_SUBCMD[$i]:-}" "${PFG_SS_CTX[$i]:-}" "${PFG_SS_OPACITY[$i]:-}" "${PFG_SS_START[$i]:-}" "${PFG_SS_END[$i]:-}"
  done
' 2>&1 | head -12

echo "───────── benign literal MENTIONS of gh/git (expect ALLOW — over-block check) ─────────"
decide "single-quoted group literal" "echo '( gh pr merge 12 --repo $FORB --merge )'"
decide "single-quoted subst literal" "echo '\$(gh pr merge 12 --repo $FORB --merge)'"
decide "comment with subst text"     "echo ok # \$(gh pr merge --repo $FORB)"

echo "───────── hook-arbitration JSON parse on this jq ($(jq --version)) ─────────"
AR="$ROOT/lib/hook-arbitration.sh"
if [ -f "$AR" ]; then
  D="$(mktemp -d)/repo"; mkdir -p "$D/.preflight" "$D/.claude/hooks"
  echo '{"mode":"generic"}' > "$D/.preflight/config.json"
  # a VALID settings.json that registers a project hook
  printf '%s' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":".claude/hooks/router"}]}]}}' > "$D/.claude/settings.json"
  ( set +u; . "$AR" 2>/dev/null
    if command -v pfa_classify_owner >/dev/null 2>&1; then
      pfa_classify_owner "$D" "somewhere/user-runtime" 2>/dev/null
      printf '  [valid project settings.json] OWNER=%s DUP=%s STALE=%s REASON=%s\n' "${PFA_OWNER:-?}" "${PFA_DUP_RISK:-?}" "${PFA_STALE:-?}" "${PFA_REASON:-?}" | head -1
    else echo "  (pfa_classify_owner not defined after sourcing)"; fi
    # direct jq parse sanity on the same file:
    printf '  jq parse of the same settings.json: '; jq -e . "$D/.claude/settings.json" >/dev/null 2>&1 && echo "VALID" || echo "jq REPORTS INVALID (jq $(jq --version))"
  )
  rm -rf "$(dirname "$D")" 2>/dev/null || true
else echo "  (hook-arbitration.sh absent)"; fi

rm -rf "$(dirname "$REPO")" "$SHIM" 2>/dev/null || true
echo "=================== END DIAGNOSE ==================="
exit 0

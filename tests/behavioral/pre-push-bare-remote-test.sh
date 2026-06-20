#!/usr/bin/env bash
# Behavioral test for the pre-push-gate-check THREE-TIER reversibility policy (AUTO / CONFIRM / BLOCK).
#
# THE POLICY: each push is classified MECHANICALLY (from PROTECTED_BRANCHES / configured REMOTE /
# FORBIDDEN_* / HAS_FORCE / ARG_REMOTE — never agent judgement) into:
#   AUTO    — exit 0 + permissionDecision:allow → reversible (named SAFE remote, UNPROTECTED branch,
#             non-force): the agent pushes, NO human handoff. (the friction being removed)
#   CONFIRM — exit 0 + permissionDecision:ask → consequential but a human MAY proceed: bare push
#             (unvalidatable target), non-canonical/prod remote, or a PROTECTED-branch push. The platform
#             prompts the user; the agent cannot self-approve.
#   BLOCK   — exit 2 → never-OK: force-push to a protected branch, or a remote on the explicit
#             forbidden denylist (an opt-in 'never push here' that is stronger than CONFIRM).
# Claude Code PreToolUse protocol: exit 0 + JSON XOR exit 2 (JSON ignored on exit 2) — verified against
# the hooks docs. CONFIRM/AUTO emit JSON after the evidence gate passes; BLOCK exits 2.
#
# Tests feed crafted Bash-tool JSON to the hook with HEAD-fresh gate evidence (so the run reaches the
# tier logic past the evidence gate) and read the exit code + permissionDecision (via jq, MSYS-safe).
#
# Proves:
#   B1 — bare 'git push' (opted in)                     -> CONFIRM (0 + ask).
#   B2 — 'git push -u' (no positional remote)           -> CONFIRM (0 + ask).
#   B3 — bare 'git push --force' (unprotected target)   -> CONFIRM (0 + ask).
#   B4 — named push, safe remote, UNPROTECTED branch    -> AUTO (0 + allow) — friction removed.
#   B5 — non-canonical remote 'evil' (!= configured)    -> CONFIRM (0 + ask) — was hard-BLOCK, reclassified.
#   B6 — push to PROTECTED branch 'main'                -> CONFIRM (0 + ask).
#   B7 — force-push to PROTECTED 'main'                 -> BLOCK (2) — preserved.
#   B8 — configured remote on forbiddenRepos (=prod)    -> BLOCK (2) — GAP-A close (was silent allow).
#   B9 — FAIL-OPEN: bare push, NO config (not opted in) -> NOT gated (0, decision != ask).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$ROOT/hooks/pre-push-gate-check"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$HOOK" ]; then
  bad "hook not found at $HOOK"; echo ""; echo "pre-push-bare-remote tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Build a workspace with HEAD-fresh evidence (so the evidence gate passes and we reach remote logic).
mk_ws() {
  local name="$1" with_config="$2"
  local ws="$T/$name"
  mkdir -p "$ws/.preflight/gate"
  # Start on an UNPROTECTED feature branch so a bare push resolves to a non-protected current branch
  # (otherwise the git-init default 'master' is in PROTECTED_BRANCHES and a bare force would BLOCK as
  # force-to-protected — a different, correct path tested explicitly in B3p/B7).
  ( cd "$ws" && git init -q && git commit -q --allow-empty -m init && git checkout -q -b feature/topic-x )
  local head; head="$(cd "$ws" && git rev-parse HEAD)"
  printf 'HEAD=%s\nts=now\n' "$head" > "$ws/.preflight/gate/tests-pass"
  printf 'HEAD=%s\nts=now\n' "$head" > "$ws/.preflight/gate/stage1-clean"
  if [ "$with_config" = "with-config" ]; then
    printf '{"branch":{"base":"main","remote":"origin","forbiddenRemotes":[],"forbiddenRepos":[]}}' > "$ws/.preflight/config.json"
  fi
  echo "$ws"
}

# Run the hook in a workspace with a crafted push command. Sets:
#   RC      = exit code
#   DEC     = permissionDecision from the JSON on stdout ("allow"/"ask"/"" if none), via jq (MSYS-safe)
#   ERR1    = first stderr line (for BLOCK-message assertions)
probe() {
  local ws="$1" cmd="$2"
  local json; json="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd")"
  local outf errf; outf="$(mktemp)"; errf="$(mktemp)"
  # Per-probe timeout: on this Git-Bash box the hook's git/jq subprocesses can intermittently wedge under
  # heavy concurrent load (an environmental flake in the pre-push-gate chain, NOT in the tier logic — it
  # runs clean unloaded). The timeout makes a wedge surface as a clear FAIL (RC=124) instead of hanging
  # the whole suite. 60s is far above the normal sub-second runtime.
  ( cd "$ws" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$ws" timeout 60 bash "$HOOK" "$json" >"$outf" 2>"$errf" ); RC=$?
  DEC="$(jq -r '.hookSpecificOutput.permissionDecision // ""' "$outf" 2>/dev/null || echo "")"
  ERR1="$(head -1 "$errf")"
  rm -f "$outf" "$errf"
}

WS="$(mk_ws optedin with-config)"
# Workspace branch is git's init default (master/main); config base is 'main'. Pushing to feature/x is
# UNPROTECTED. No 'origin' remote is configured, so a named-remote slug won't resolve to a forbidden repo
# (kept out of the forbidden list) — so a named push to the configured remote is the AUTO case.

# ── Three-tier outcomes ──
# B1 — bare push (opted in): CONFIRM (exit 0 + permissionDecision:ask), names the unvalidatable target.
probe "$WS" 'git push'
if [ "$RC" = "0" ] && [ "$DEC" = "ask" ]; then
  ok "B1: bare 'git push' (opted in) -> CONFIRM (exit 0 + permissionDecision:ask)"
else bad "B1: bare push should be CONFIRM (0/ask), got RC=$RC DEC=$DEC"; fi

# B2 — 'git push -u' (still no positional remote): CONFIRM.
probe "$WS" 'git push -u'
[ "$RC" = "0" ] && [ "$DEC" = "ask" ] && ok "B2: 'git push -u' (no positional remote) -> CONFIRM (ask)" \
                                       || bad "B2: should be CONFIRM (0/ask), got RC=$RC DEC=$DEC"

# B3 — bare 'git push --force' on an UNPROTECTED branch (feature/topic-x): force is NOT to a protected
# branch -> not the hard BLOCK; but it is a bare push (no named remote) -> CONFIRM.
probe "$WS" 'git push --force'
[ "$RC" = "0" ] && [ "$DEC" = "ask" ] && ok "B3: bare 'git push --force' (unprotected current branch) -> CONFIRM (ask)" \
                                       || bad "B3: should be CONFIRM (0/ask), got RC=$RC DEC=$DEC"

# B3p — bare 'git push --force' while ON a PROTECTED branch -> hard BLOCK (force-to-protected). Separate
# workspace checked out on 'main' (a protected branch) to exercise this path distinctly from B3.
WS_PROT="$T/onprotected"; mkdir -p "$WS_PROT/.preflight/gate"
( cd "$WS_PROT" && git init -q && git commit -q --allow-empty -m init && git checkout -q -b main 2>/dev/null || (cd "$WS_PROT" && git branch -m main) )
_ph="$(cd "$WS_PROT" && git rev-parse HEAD)"
for ev in tests-pass stage1-clean; do printf 'HEAD=%s\nts=now\n' "$_ph" > "$WS_PROT/.preflight/gate/$ev"; done
printf '{"branch":{"base":"main","remote":"origin","forbiddenRemotes":[],"forbiddenRepos":[]}}' > "$WS_PROT/.preflight/config.json"
probe "$WS_PROT" 'git push --force'
[ "$RC" = "2" ] && printf '%s' "$ERR1" | grep -qi 'force-push' \
  && ok "B3p: bare 'git push --force' while ON protected 'main' -> BLOCK (2, force-to-protected)" \
  || bad "B3p: bare force on protected branch should BLOCK(2), got RC=$RC ERR1=$ERR1"

# B4 — AUTO: named push to the configured safe remote, UNPROTECTED branch, non-force -> proceed silently.
probe "$WS" 'git push origin HEAD:feature/x'
if [ "$RC" = "0" ] && [ "$DEC" = "allow" ]; then
  ok "B4: AUTO — named push to safe remote, unprotected branch, non-force -> permissionDecision:allow (friction removed)"
else bad "B4: should be AUTO (0/allow), got RC=$RC DEC=$DEC — friction-removal broken"; fi

# B5 — CONFIRM: a named NON-canonical remote ('evil' != configured 'origin') -> ask (was a hard BLOCK).
probe "$WS" 'git push evil HEAD:feature/x'
[ "$RC" = "0" ] && [ "$DEC" = "ask" ] && ok "B5: non-canonical remote 'evil' -> CONFIRM (ask), was hard-BLOCK (reclassified)" \
                                       || bad "B5: should be CONFIRM (0/ask), got RC=$RC DEC=$DEC"

# B6 — CONFIRM: push to a PROTECTED branch ('main' = config base), safe remote, non-force -> ask.
probe "$WS" 'git push origin HEAD:main'
[ "$RC" = "0" ] && [ "$DEC" = "ask" ] && ok "B6: push to PROTECTED branch 'main' -> CONFIRM (ask)" \
                                       || bad "B6: protected-branch push should be CONFIRM (0/ask), got RC=$RC DEC=$DEC"

# B7 — BLOCK preserved: force-push to a PROTECTED branch ('main') -> hard exit 2 (never auto, never ask).
probe "$WS" 'git push --force origin HEAD:main'
[ "$RC" = "2" ] && printf '%s' "$ERR1" | grep -qi 'force-push' \
  && ok "B7: BLOCK preserved — force-push to protected 'main' -> exit 2 (hard block)" \
  || bad "B7: force-to-protected should BLOCK(2), got RC=$RC ERR1=$ERR1"

# B8 — GAP A close: a named push to a remote on the forbiddenRepos denylist -> hard BLOCK (exit 2). An
# explicit operator denylist is a deliberate 'never push here' — stronger than CONFIRM by design.
WS_FORBID="$T/forbid"; mkdir -p "$WS_FORBID/.preflight/gate"
( cd "$WS_FORBID" && git init -q && git commit -q --allow-empty -m init && git remote add origin https://github.com/Org/PROD.git )
_fh="$(cd "$WS_FORBID" && git rev-parse HEAD)"
for ev in tests-pass stage1-clean; do printf 'HEAD=%s\nts=now\n' "$_fh" > "$WS_FORBID/.preflight/gate/$ev"; done
printf '{"branch":{"base":"main","remote":"origin","forbiddenRemotes":[],"forbiddenRepos":["Org/PROD"]}}' > "$WS_FORBID/.preflight/config.json"
probe "$WS_FORBID" 'git push origin HEAD:feature/x'
[ "$RC" = "2" ] && printf '%s' "$ERR1" | grep -qi 'FORBIDDEN' \
  && ok "B8: GAP-A — configured remote on forbiddenRepos denylist (=prod) -> hard BLOCK (exit 2), not silent allow" \
  || bad "B8: forbidden-repo push should BLOCK(2)+FORBIDDEN, got RC=$RC ERR1=$ERR1"

# B9 — FAIL-OPEN: bare push with NO config (not opted in) + evidence present -> NOT gated (AUTO/allow).
WS_NOCFG="$(mk_ws noconfig no-config)"
probe "$WS_NOCFG" 'git push'
[ "$RC" = "0" ] && [ "$DEC" != "ask" ] && ok "B9: FAIL-OPEN — bare push, NO config (not opted in) -> NOT gated (RC=0, decision='$DEC' not ask)" \
                                        || bad "B9: no-config bare push should fail-open (not ask), got RC=$RC DEC=$DEC"

echo ""
echo "pre-push-bare-remote tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

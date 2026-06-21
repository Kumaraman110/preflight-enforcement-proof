#!/usr/bin/env bash
# Behavioral test for GAP-A hardening in pre-push-gate-check.
#
# GAP-A (pre-hardening): a CONFIGURED remote that is PROD but is NOT on branch.forbiddenRepos, pushed on an
# UNPROTECTED branch, non-force, classified AUTO (permissionDecision:allow) — the agent silently auto-pushed
# to prod. The denylist closed it only when the operator opted in.
#
# Hardening (this test proves it): for the configured-remote AUTO path, two new signals flip AUTO -> CONFIRM
# (permissionDecision:ask — never BLOCK; a human may still push to prod deliberately, just never SILENTLY):
#   G1 — PROD-PATTERN heuristic (ALWAYS ON, no opt-in): the resolved slug/URL carries a high-confidence prod
#        token as a WHOLE SEGMENT (prod/production/prd/release/live/legacy + branch.prodPatterns).
#   G2 — SAFE-REMOTES allowlist (OPT-IN strict mode): when branch.safeRemotes is set, a configured remote NOT
#        on it -> CONFIRM. Absent -> INERT (AUTO preserved; no friction regression).
#
# PRESERVES the AUTO tier for genuinely-safe pushes:
#   G3 — a configured safe remote (no prod token, no safeRemotes list) -> still AUTO (allow).
#   G4 — the real migration TARGET 'cyf.cpsl_core' must NOT false-positive as prod -> still AUTO.
#
# Driven BODY-DIRECT (_PFG_WATCHDOG_CHILD=1) to isolate decision logic from this box's subprocess-spawn tax
# (see .release-audit/SPAWN-TAX-DIAGNOSIS.md); the watchdog's own fail-closed behavior is covered separately
# in pre-push-wedge-failclosed-test.sh.
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
  bad "hook not found at $HOOK"; echo ""; echo "pre-push-gapa-prod-pattern tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Build a workspace whose configured remote 'origin' resolves to a given URL, with HEAD-fresh evidence and a
# given config JSON, on an UNPROTECTED feature branch (so only the remote-classification path is exercised).
#   mk_ws <name> <origin-url> <config-json>
mk_ws() {
  local name="$1" url="$2" cfg="$3"
  local ws="$T/$name"
  mkdir -p "$ws/.preflight/gate"
  ( cd "$ws" && git init -q && git commit -q --allow-empty -m init && git checkout -q -b feature/topic-x \
      && git remote add origin "$url" )
  local head; head="$(cd "$ws" && git rev-parse HEAD)"
  for ev in tests-pass stage1-clean; do printf 'HEAD=%s\nts=now\n' "$head" > "$ws/.preflight/gate/$ev"; done
  printf '%s' "$cfg" > "$ws/.preflight/config.json"
  echo "$ws"
}

# probe <ws> <push-cmd> -> RC, DEC (permissionDecision via jq)
probe() {
  local ws="$1" cmd="$2" json outf; json="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd")"
  outf="$(mktemp)"
  ( cd "$ws" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$ws" _PFG_WATCHDOG_CHILD=1 \
      timeout 90 bash "$HOOK" "$json" >"$outf" 2>/dev/null ); RC=$?
  DEC="$(jq -r '.hookSpecificOutput.permissionDecision // ""' "$outf" 2>/dev/null || echo "")"
  rm -f "$outf"
}

# ── G1: configured remote whose URL matches a PROD pattern, NOT on forbiddenRepos -> CONFIRM (was AUTO). ──
CFG_PLAIN='{"branch":{"base":"main","remote":"origin","forbiddenRemotes":[],"forbiddenRepos":[]}}'
WS_PROD="$(mk_ws prod 'https://github.com/myorg/production-api.git' "$CFG_PLAIN")"
probe "$WS_PROD" 'git push origin HEAD:feature/x'
if [ "$RC" = "0" ] && [ "$DEC" = "ask" ]; then
  ok "G1: configured PROD-pattern remote (production-api), not denylisted -> CONFIRM (ask) — was silent AUTO"
else bad "G1: prod-pattern configured remote should be CONFIRM (0/ask), got RC=$RC DEC=$DEC"; fi

# ── G1b: another prod token as a whole segment (app-prod). ──
WS_PROD2="$(mk_ws prod2 'https://github.com/myorg/app-prod.git' "$CFG_PLAIN")"
probe "$WS_PROD2" 'git push origin HEAD:feature/x'
[ "$RC" = "0" ] && [ "$DEC" = "ask" ] && ok "G1b: configured remote 'app-prod' -> CONFIRM (ask)" \
                                      || bad "G1b: 'app-prod' should be CONFIRM (0/ask), got RC=$RC DEC=$DEC"

# ── G3: configured SAFE remote (no prod token, no safeRemotes list) -> still AUTO (allow). Friction preserved-off. ──
WS_SAFE="$(mk_ws safe 'https://github.com/myorg/my-app.git' "$CFG_PLAIN")"
probe "$WS_SAFE" 'git push origin HEAD:feature/x'
if [ "$RC" = "0" ] && [ "$DEC" = "allow" ]; then
  ok "G3: configured SAFE remote (my-app), no prod token, no allowlist -> still AUTO (allow) — friction NOT re-introduced"
else bad "G3: safe configured remote should stay AUTO (0/allow), got RC=$RC DEC=$DEC"; fi

# ── G4: the real migration TARGET 'cyf.cpsl_core' must NOT false-positive (it is the SAFE destination). ──
WS_TARGET="$(mk_ws target 'https://github.com/United-Airlines-Org/cyf.cpsl_core.git' "$CFG_PLAIN")"
probe "$WS_TARGET" 'git push origin HEAD:feature/x'
if [ "$RC" = "0" ] && [ "$DEC" = "allow" ]; then
  ok "G4: real migration target 'cyf.cpsl_core' -> still AUTO (allow) — no prod false-positive on the safe target"
else bad "G4: 'cyf.cpsl_core' should stay AUTO (0/allow), got RC=$RC DEC=$DEC (false-positive prod match)"; fi

# ── G2: SAFE-REMOTES allowlist opt-in. Remote NOT on the list -> CONFIRM, even if the name is bland. ──
CFG_ALLOW='{"branch":{"base":"main","remote":"origin","forbiddenRemotes":[],"forbiddenRepos":[],"safeRemotes":["myorg/blessed-repo"]}}'
WS_NOTLISTED="$(mk_ws notlisted 'https://github.com/myorg/some-other-repo.git' "$CFG_ALLOW")"
probe "$WS_NOTLISTED" 'git push origin HEAD:feature/x'
if [ "$RC" = "0" ] && [ "$DEC" = "ask" ]; then
  ok "G2: strict mode on (safeRemotes set), remote NOT on allowlist -> CONFIRM (ask)"
else bad "G2: non-allowlisted remote in strict mode should be CONFIRM (0/ask), got RC=$RC DEC=$DEC"; fi

# ── G2b: SAFE-REMOTES allowlist — remote ON the list -> AUTO (allow), even though strict mode is on. ──
WS_LISTED="$(mk_ws listed 'https://github.com/myorg/blessed-repo.git' "$CFG_ALLOW")"
probe "$WS_LISTED" 'git push origin HEAD:feature/x'
if [ "$RC" = "0" ] && [ "$DEC" = "allow" ]; then
  ok "G2b: strict mode on, remote ON the allowlist (blessed-repo) -> AUTO (allow)"
else bad "G2b: allowlisted remote should be AUTO (0/allow), got RC=$RC DEC=$DEC"; fi

# ── G5: operator-supplied branch.prodPatterns extends the net (e.g. an internal codename). ──
CFG_EXTRA='{"branch":{"base":"main","remote":"origin","forbiddenRemotes":[],"forbiddenRepos":[],"prodPatterns":["mainframe"]}}'
WS_EXTRA="$(mk_ws extra 'https://github.com/myorg/mainframe-bridge.git' "$CFG_EXTRA")"
probe "$WS_EXTRA" 'git push origin HEAD:feature/x'
[ "$RC" = "0" ] && [ "$DEC" = "ask" ] && ok "G5: operator prodPatterns ['mainframe'] flips 'mainframe-bridge' -> CONFIRM (ask)" \
                                      || bad "G5: prodPatterns match should be CONFIRM (0/ask), got RC=$RC DEC=$DEC"

echo ""
echo "pre-push-gapa-prod-pattern tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Behavioral test for the pre-push-gate-check BARE-PUSH guard (the unvalidatable-target hole).
#
# THE HOLE (confirmed empirically; was a silent EXIT=0): a `git push` with NO named remote resolves to
# git's DEFAULT/upstream remote — a target the guard never sees — so the forbidden-destination (B0) and
# wrong-remote (B) checks are SILENTLY SKIPPED. On an inverted clone where the default remote is legacy
# PROD, that is an ungated push-to-prod. The fix: when a repo has OPTED IN to push-gating (config with
# branch.remote present), a bare push is BLOCKED with a require-named-remote message so the target becomes
# validatable. Fail-open otherwise (no config / no configured remote -> not opted in -> not blocked).
#
# These tests feed crafted Bash-tool JSON to the hook and read the exit code, with HEAD-fresh gate
# evidence present so the run reaches the remote logic (past the evidence gate).
#
# Proves:
#   B1 — bare 'git push' (opted in, remote set)        -> BLOCKED (2), names the unvalidatable-target reason.
#   B2 — 'git push -u' (still no positional remote)     -> BLOCKED (2).
#   B3 — 'git push --force' (bare + force)              -> BLOCKED (2) (force to default target, unvalidatable).
#   B4 — 'git push origin HEAD:feature/x' (named canon) -> NOT blocked by this guard (0) — normal flow intact.
#   B5 — 'git push evil HEAD:feature/x' (named, wrong)  -> BLOCKED (2) by the existing wrong-remote guard (regression check).
#   B6 — FAIL-OPEN: bare push with NO config (not opted in) + evidence present -> NOT blocked (0).
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
  ( cd "$ws" && git init -q && git commit -q --allow-empty -m init )
  local head; head="$(cd "$ws" && git rev-parse HEAD)"
  printf 'HEAD=%s\nts=now\n' "$head" > "$ws/.preflight/gate/tests-pass"
  printf 'HEAD=%s\nts=now\n' "$head" > "$ws/.preflight/gate/stage1-clean"
  if [ "$with_config" = "with-config" ]; then
    printf '{"branch":{"base":"main","remote":"origin","forbiddenRemotes":[],"forbiddenRepos":[]}}' > "$ws/.preflight/config.json"
  fi
  echo "$ws"
}

# Run the hook from inside a workspace with a crafted push command; echo "<exit> <stderr>".
probe() {
  local ws="$1" cmd="$2"
  local json; json="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd")"
  local out rc
  out="$( cd "$ws" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$ws" bash "$HOOK" "$json" 2>&1 )"; rc=$?
  printf '%s\n%s' "$rc" "$out"
}
ec() { printf '%s' "$1" | head -1; }
msg() { printf '%s' "$1" | tail -n +2; }

WS="$(mk_ws optedin with-config)"

R="$(probe "$WS" 'git push')"
if [ "$(ec "$R")" = "2" ] && printf '%s' "$(msg "$R")" | grep -qiE 'bare|no named remote|unvalidatable'; then
  ok "B1: bare 'git push' (opted in) -> BLOCKED (2), names the unvalidatable-target reason"
else bad "B1: bare push should BLOCK(2) with reason, got ec=$(ec "$R")"; fi

R="$(probe "$WS" 'git push -u')"
[ "$(ec "$R")" = "2" ] && ok "B2: 'git push -u' (no positional remote) -> BLOCKED (2)" || bad "B2: should BLOCK(2), got $(ec "$R")"

R="$(probe "$WS" 'git push --force')"
[ "$(ec "$R")" = "2" ] && ok "B3: 'git push --force' (bare + force) -> BLOCKED (2)" || bad "B3: should BLOCK(2), got $(ec "$R")"

R="$(probe "$WS" 'git push origin HEAD:feature/x')"
[ "$(ec "$R")" = "0" ] && ok "B4: named canonical push 'git push origin HEAD:feature/x' -> NOT blocked (0); normal flow intact" \
                       || bad "B4: canonical push should pass (0), got $(ec "$R") — NORMAL FLOW BROKEN"

R="$(probe "$WS" 'git push evil HEAD:feature/x')"
[ "$(ec "$R")" = "2" ] && ok "B5: named wrong remote 'git push evil ...' -> BLOCKED (2) by existing wrong-remote guard (regression check)" \
                       || bad "B5: wrong-remote should BLOCK(2), got $(ec "$R")"

WS_NOCFG="$(mk_ws noconfig no-config)"
R="$(probe "$WS_NOCFG" 'git push')"
[ "$(ec "$R")" = "0" ] && ok "B6: FAIL-OPEN — bare push, NO config (not opted in), evidence present -> NOT blocked (0)" \
                       || bad "B6: no-config bare push should fail-open (0), got $(ec "$R") — additive-guard posture violated"

echo ""
echo "pre-push-bare-remote tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Behavioral test: PUSH SHADOW ISOLATION + VERDICT IDENTITY for hooks/pre-push-gate-engine (Stage 2A).
#
# The non-authoritative push shadow (PFG_PUSH_SHADOW) compares the AWK-backed IR's git-push facts against
# the legacy authoritative parser and records the comparison — but it MUST NEVER change the user-facing
# verdict. Driving the ENGINE with the same workspace+evidence+config setup the other push tests use, this
# proves:
#   (1) VERDICT IDENTITY: for AUTO-allow / CONFIRM / BLOCK inputs, the engine's exit code AND decision
#       (permissionDecision) are IDENTICAL with the shadow OFF (default) vs ON (PFG_PUSH_SHADOW=1).
#   (2) SHADOW RECORDS on ALLOW/CONFIRM, and records a category we can read back.
#   (3) FAILURE ISOLATION: a BROKEN awk (fake awk earlier in PATH that errors) during shadow leaves the
#       verdict byte-identical to the shadow-off run (records SHADOW_ERROR, never propagates).
#
# Isolated only: ephemeral mktemp git repos, string-only remotes, no network, no consumer. Exit 0 = pass.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$ROOT/hooks/pre-push-gate-engine"
[ -f "$HOOK" ] || { echo "FAIL: engine not found ($HOOK)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; echo "pre-push-shadow-isolation tests: 0 passed, 0 failed"; exit 0; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# workspace with HEAD-fresh evidence + config (mirrors pre-push-bare-remote-test mk_ws)
mk_ws() {
  local name="${1:-ws}" branch="${2:-feature/topic-x}" ws="$T/${1:-ws}"
  mkdir -p "$ws/.preflight/gate"
  ( cd "$ws" && git init -q && git commit -q --allow-empty -m init && git checkout -q -b "$branch" 2>/dev/null || (cd "$ws" && git branch -m "$branch") )
  local head; head="$(cd "$ws" && git rev-parse HEAD)"
  printf 'HEAD=%s\nts=now\n' "$head" > "$ws/.preflight/gate/tests-pass"
  printf 'HEAD=%s\nts=now\n' "$head" > "$ws/.preflight/gate/stage1-clean"
  printf '{"branch":{"base":"main","remote":"origin","forbiddenRemotes":[],"forbiddenRepos":["Org/PROD"]}}' > "$ws/.preflight/config.json"
  echo "$ws"
}

# run the engine; echo "RC=<n> DEC=<allow|ask|>" (the machine-verdict). $3.. = extra env.
verdict() {
  local ws="$1" cmd="$2"; shift 2
  local json outf; json="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd")"; outf="$(mktemp)"
  local rc dec
  ( cd "$ws" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$ws" "$@" timeout "${PREFLIGHT_TIER_PROBE_TIMEOUT:-300}" bash "$HOOK" "$json" >"$outf" 2>/dev/null ); rc=$?
  dec="$(jq -r '.hookSpecificOutput.permissionDecision // ""' "$outf" 2>/dev/null || echo "")"
  rm -f "$outf"
  printf 'RC=%s DEC=%s' "$rc" "$dec"
}

WS="$(mk_ws optedin feature/topic-x)"
X=United-Airlines-Org/CPSL

# ── (1) verdict identity: shadow OFF == ON, across tiers ──
identity() {  # $1 label  $2 command
  local off on log="$T/shadow_${PASS}_${FAIL}.log"
  off="$(verdict "$WS" "$2")"
  on="$(verdict "$WS" "$2" env PFG_PUSH_SHADOW=1 "PFG_PUSH_SHADOW_LOG=$log")"
  if [ "$off" = "$on" ]; then ok "$1: verdict identical off==on ($off)"
  else bad "$1: verdict CHANGED by shadow — off=[$off] on=[$on]"; fi
}
echo "════ (1) verdict identity: shadow OFF == ON across tiers ════"
identity "AUTO named-safe"        "git push origin HEAD:feature/x"
identity "CONFIRM protected"      "git push origin HEAD:main"
identity "CONFIRM non-canonical"  "git push evil HEAD:feature/x"
identity "CONFIRM bare"           "git push"
identity "non-push benign"        "echo hello world"

# ── (2) shadow records a category on an ALLOW/CONFIRM path ──
echo "════ (2) shadow records a comparison category on ALLOW/CONFIRM ════"
LOG="$T/rec.log"
verdict "$WS" "git push origin HEAD:feature/x" env PFG_PUSH_SHADOW=1 "PFG_PUSH_SHADOW_LOG=$LOG" >/dev/null 2>&1
if [ -f "$LOG" ] && grep -qE 'cat=(MATCH|LEGACY_ONLY|IR_ONLY|BOTH_OPAQUE|IR_OPAQUE|SHADOW_ERROR|SHADOW_LIMIT|SHADOW_SKIPPED)' "$LOG"; then
  cat_line="$(grep 'PFG_PUSH_SHADOW' "$LOG" | head -1)"
  # MATCH is the goal under normal load; SHADOW_ERROR/SHADOW_SKIPPED is an acceptable RECORD when the 6s
  # shadow budget is exceeded on a thrashed host (isolation still holds — the verdict is unchanged). The
  # gate here is that a VALID category is recorded, never that it is specifically MATCH (host-load-sensitive).
  ok "shadow recorded a valid category on AUTO: ${cat_line#PFG_PUSH_SHADOW }"
else
  bad "shadow did not record a valid category on AUTO path (log empty/invalid)"
fi

# ── (3) failure isolation: BROKEN awk during shadow must not change the verdict ──
echo "════ (3) failure isolation: broken awk during shadow ════"
FAKE="$T/fakeawk"; mkdir -p "$FAKE"
cat > "$FAKE/awk" <<'EOF'
#!/bin/sh
exit 3
EOF
chmod +x "$FAKE/awk"
identity_broken() {  # $1 label  $2 cmd
  local off on log="$T/brk_${PASS}_${FAIL}.log"
  off="$(verdict "$WS" "$2")"
  on="$(verdict "$WS" "$2" env PFG_PUSH_SHADOW=1 "PFG_PUSH_SHADOW_LOG=$log" "PATH=$FAKE:$PATH")"
  if [ "$off" = "$on" ]; then ok "$1: verdict identical with BROKEN awk ($off)"
  else bad "$1: broken-awk shadow CHANGED verdict — off=[$off] on=[$on]"; fi
}
identity_broken "broken-awk AUTO"      "git push origin HEAD:feature/x"
identity_broken "broken-awk CONFIRM"   "git push origin HEAD:main"

echo ""
echo "pre-push-shadow-isolation tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

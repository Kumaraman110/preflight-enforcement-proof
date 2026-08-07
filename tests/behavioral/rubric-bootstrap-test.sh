#!/usr/bin/env bash
# rubric-bootstrap-test.sh — G2 proof: zero-config rubric bootstrap. A freshly installed repo on ANY
# stack gets a working Stage-1 review WITHOUT hand-authoring, because the rubric-validity-gate falls
# back to the shipped stack-neutral base rubric (defaults/base-rubric.md) when no rubric is configured —
# WHILE a configured-but-broken rubric path still fails closed (the fallback must not introduce a
# fail-open).
#
# BACKGROUND: pre-G2, the gate BLOCKED (exit 2) on "no config" and "no rubric key", so a fresh install
# could not even SPAWN the code-reviewer — the day-0 review loop was dead, not degraded (the agent's
# prose "fall back to rubric-generic-dotnet.md" was unreachable because the gate fires first).
#
# Proves (feeding the gate its real stdin interface; exit 2 = block, 0 = allow):
#   1. FRESH REPO (no config) -> ALLOW (exit 0) via the base rubric — day-0 usefulness (criterion 1).
#   2. CONFIG WITH NO RUBRIC KEY -> ALLOW (exit 0) via the base rubric (still no INTENDED rubric).
#   3. CONFIGURED-BUT-BROKEN rubric path -> BLOCK (exit 2) — the fallback does NOT hide a typo (fail-closed).
#   4. VALID configured rubric -> ALLOW (exit 0) — unchanged behavior.
#   5. STACK-NEUTRAL: the shipped base rubric contains NO .NET-specific tokens (proves it is not
#      .NET-shaped, so it loads/fires identically on a non-.NET repo — criterion 3).
#   6. USEFUL (not a no-op): the base rubric defines >=3 concrete detection rules, each with a
#      structured **Source:** provenance line (so it is a real floor, not an empty placeholder;
#      supports criterion 2 — a self-review can surface a finding from it).
#
# Exit 0 = all passed. Isolated: drives the SOURCE gate in throwaway temp repos; no real install.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GATE="$ROOT/hooks/rubric-validity-gate"
BASE="$ROOT/defaults/base-rubric.md"
PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
trailer(){ echo ""; echo "rubric-bootstrap: ${PASS} passed, ${FAIL} failed"; [ "$FAIL" -eq 0 ]; }
[ -f "$GATE" ] || { bad "rubric-validity-gate missing"; trailer; exit $?; }
[ -f "$BASE" ] || { bad "shipped base rubric missing ($BASE)"; trailer; exit $?; }

SPAWN='{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","prompt":"review"}}'
# run_gate <workdir> -> echoes exit code (gate is run FROM workdir so its cwd-relative config lookup applies)
run_gate(){ ( cd "$1" && printf '%s' "$SPAWN" | bash "$GATE" >/dev/null 2>&1; echo $? ); }

# 1. FRESH REPO (no config at all) -> ALLOW via base fallback
D1="$(mktemp -d)"
rc="$(run_gate "$D1")"
[ "$rc" = 0 ] && ok "fresh repo (no config) -> ALLOW via base rubric (day-0 usefulness; was BLOCK pre-G2)" \
  || bad "fresh repo did not allow via base fallback (rc=$rc, expected 0)"
rm -rf "$D1"

# 2. CONFIG WITH NO RUBRIC KEY -> ALLOW via base fallback
D2="$(mktemp -d)"; mkdir -p "$D2/.preflight"; printf '{"mode":"migration"}\n' > "$D2/.preflight/config.json"
rc="$(run_gate "$D2")"
[ "$rc" = 0 ] && ok "config with no 'rubric' key -> ALLOW via base rubric (no intended rubric)" \
  || bad "no-rubric-key config did not allow via base fallback (rc=$rc, expected 0)"
rm -rf "$D2"

# 3. CONFIGURED-BUT-BROKEN rubric path -> BLOCK (fail-closed; fallback must NOT hide a typo)
D3="$(mktemp -d)"; mkdir -p "$D3/.preflight"
printf '{"rubric":"rubrics/does-not-exist-typo.md"}\n' > "$D3/.preflight/config.json"
rc="$(run_gate "$D3")"
[ "$rc" = 2 ] && ok "configured-but-broken rubric path -> BLOCK (fail-closed; no silent degrade to base)" \
  || bad "broken rubric path did NOT block (rc=$rc, expected 2) — the fallback introduced a fail-open!"
rm -rf "$D3"

# 4. VALID configured rubric -> ALLOW
D4="$(mktemp -d)"; mkdir -p "$D4/.preflight"
printf 'x\n' > "$D4/my-rubric.md"
printf '{"rubric":"my-rubric.md"}\n' > "$D4/.preflight/config.json"
rc="$(run_gate "$D4")"
[ "$rc" = 0 ] && ok "valid configured rubric -> ALLOW (unchanged behavior)" \
  || bad "valid configured rubric did not allow (rc=$rc, expected 0)"
rm -rf "$D4"

# 5. STACK-NEUTRAL: base rubric has NO .NET-specific tokens (not .NET-shaped -> loads on any stack)
DOTNET_TOKENS='\.Result|\.Wait\(|CancellationToken|IHttpClientFactory|services\.Configure|\[MaxLength\]|IServiceScopeFactory|IDisposable|\.csproj| ILogger|IActionResult'
if grep -qE "$DOTNET_TOKENS" "$BASE"; then
  bad "base rubric contains .NET-specific tokens (not stack-neutral): $(grep -oE "$DOTNET_TOKENS" "$BASE" | sort -u | tr '\n' ' ')"
else
  ok "base rubric is STACK-NEUTRAL (no .NET-specific detection tokens — loads/fires on any stack)"
fi

# 6. USEFUL: >=3 concrete rules, each with a structured **Source:** provenance line
RULE_COUNT="$(grep -cE '^### §BASE' "$BASE" || true)"
SRC_COUNT="$(grep -cE '^\*\*Source:\*\*' "$BASE" || true)"
if [ "$RULE_COUNT" -ge 3 ] && [ "$SRC_COUNT" -ge "$RULE_COUNT" ]; then
  ok "base rubric is a real floor ($RULE_COUNT rules, each with a **Source:** provenance line — not a no-op)"
else
  bad "base rubric too thin/unprovenanced ($RULE_COUNT rules, $SRC_COUNT Source lines; need >=3 rules each sourced)"
fi

trailer

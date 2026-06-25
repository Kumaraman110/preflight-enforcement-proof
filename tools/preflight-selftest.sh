#!/usr/bin/env bash
# preflight-selftest.sh — liveness self-test for all shipping gates.
#
# Each gate must be able to BLOCK known-bad input. A gate that exits 0
# on known-bad input is DEAD (present but not enforcing) — exactly the
# registered-but-dead failure mode documented in the framework.
#
# Usage:
#   bash tools/preflight-selftest.sh          # run all gate self-tests
#   bash tools/preflight-selftest.sh --quiet  # only print failures
#
# Exit 0 = all gates alive (block what they should)
# Exit 1 = one or more gates DEAD (warning)
# Exit 2 = selftest itself failed to run (critical)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
QUIET=false
if [ "${1:-}" = "--quiet" ]; then QUIET=true; fi

PASS=0; FAIL=0; SKIP=0; DEAD_GATES=""
TESTED_GATES=""   # (M12) space-padded basenames of every gate test_gate() exercised — for the coverage assertion

ok() { $QUIET || printf '\033[32m  ALIVE\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
dead() { printf '\033[31m  DEAD \033[0m %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); DEAD_GATES="$DEAD_GATES $1"; }
skp() { $QUIET || printf '\033[33m  SKIP \033[0m %s — %s\n' "$1" "$2"; SKIP=$((SKIP+1)); }

# ─── Test driver: pipe crafted input to hook, assert exit code ───
# $1 = hook path, $2 = stdin JSON, $3 = expected exit code, $4 = label, $5 = "optional" (omit for MANDATORY)
test_gate() {
  local hook="$1" input="$2" expected="$3" label="$4" optional="${5:-}"
  TESTED_GATES="$TESTED_GATES ${hook##*/} "   # record the gate basename as covered
  if [ ! -f "$hook" ]; then
    # (M12) A MISSING gate file is DEAD, not SKIP. PRE-FIX every missing hook hit `skp` (SKIP++) which
    # left FAIL at 0 → a deleted/renamed mandatory gate read as GREEN (exit 0). The sibling
    # preflight-selfcheck.sh already reports a missing hook as DEAD; this aligns them. SKIP is now opt-in
    # per-hook (pass "optional") and reserved for the genuinely-optional helper (dependency-map-validator).
    if [ "$optional" = "optional" ]; then
      skp "$label" "optional helper absent (not a registered blocking gate): $hook"
    else
      dead "$label" "MANDATORY hook file MISSING: $hook — a deleted/renamed gate is DEAD, not skipped"
    fi
    return
  fi
  local OUT RC
  OUT="$(printf '%s' "$input" | timeout 10 bash "$hook" 2>&1)" ; RC=$?
  # timeout returns 124 on timeout — treat as dead
  if [ "$RC" -eq 124 ]; then
    dead "$label" "timed out (10s) — gate hung on crafted input"
    return
  fi
  [ "$RC" -eq 255 ] && RC=1  # some bash versions return 255 for exit 255
  if [ "$RC" -eq "$expected" ]; then
    ok "$label"
  else
    dead "$label" "expected exit $expected (block), got $RC"
  fi
}

$QUIET || echo "══════════════════════════════════════════════════"
$QUIET || echo "  preflight gate liveness self-test"
$QUIET || echo "══════════════════════════════════════════════════"
$QUIET || echo ""

# Create a minimal temp workspace for gates that need one
WORK="$(mktemp -d)"
ORIG_DIR="$(pwd)"
cd "$WORK"
git init -q . 2>/dev/null || true
mkdir -p .preflight/gate

# ─── Gate self-tests ────────────────────────────────────────────────

# 1. coupled-edit-gate: wrong-shape groups file should BLOCK
printf '%s' '{"not-an-array":true}' > .preflight/gate/active-groups.json
test_gate "$REPO_ROOT/hooks/coupled-edit-gate" \
  '{"tool_name":"Edit","tool_input":{"file_path":"Svc.cs","old_string":"a","new_string":"b"}}' \
  2 "coupled-edit-gate (wrong-shape groups)"
rm -f .preflight/gate/active-groups.json

# 2. bootstrap-write-gate: write to CLAUDE.md should BLOCK
mkdir -p .claude
printf '%s' '# CLAUDE.md — test' > CLAUDE.md
test_gate "$REPO_ROOT/hooks/bootstrap-write-gate" \
  '{"tool_name":"Write","tool_input":{"file_path":"CLAUDE.md","content":"# overwritten"}}' \
  2 "bootstrap-write-gate (CLAUDE.md overwrite)"

# 3. adjudication-output-gate: empty/malformed adjudications should BLOCK
test_gate "$REPO_ROOT/hooks/adjudication-output-gate" \
  '{"tool_name":"Write","tool_input":{"file_path":".preflight/adjudications/verdict.json","content":"{\"verdicts\":[]}"}}' \
  2 "adjudication-output-gate (wrong top key)"

# 4. rubric-validity-gate: no config file should BLOCK
test_gate "$REPO_ROOT/hooks/rubric-validity-gate" \
  '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","prompt":"review"}}' \
  2 "rubric-validity-gate (no config)"

# 5. pre-bash-risk-router: the REGISTERED Bash PreToolUse gate (P0 split). LIVENESS is probed with an
#    ORDINARY command — the router answers it on its builtins-only fast path with exit 0 (allow), instantly
#    and with ZERO external spawns. This is the right granularity for a liveness self-test: it proves the
#    registered gate is present and responsive WITHOUT driving the heavy engine (whose full candidate
#    adjudication can exceed this driver's 10s probe cap on a slow-spawn host — and whose forbidden-push
#    BLOCK behavior is exhaustively covered by the pre-push-* behavioral suites, not here). A router that
#    fast-allows an ordinary command is exactly the P0 autonomy property; a hung/dead router would time out.
test_gate "$REPO_ROOT/hooks/pre-bash-risk-router" \
  '{"tool_name":"Bash","tool_input":{"command":"echo selftest-liveness"}}' \
  0 "pre-bash-risk-router (ordinary cmd → fast allow)"

# 5b. pre-push-gate-check: the compatibility SHIM delegates to the router; same ordinary-command liveness.
#     Not a registered gate anymore, but a stale install may still invoke this name — keep it honest + fast.
test_gate "$REPO_ROOT/hooks/pre-push-gate-check" \
  '{"tool_name":"Bash","tool_input":{"command":"echo selftest-liveness"}}' \
  0 "pre-push-gate-check shim (ordinary cmd → fast allow via router)"

# 6. write-gate-evidence: malformed sentinel should BLOCK
mkdir -p .preflight/gate
test_gate "$REPO_ROOT/hooks/write-gate-evidence" \
  '{"tool_name":"Write","tool_input":{"file_path":".preflight/gate/parity-clean","content":"INVALID_SENTINEL"}}' \
  2 "write-gate-evidence (malformed sentinel)"

# 7. behavioral-contract-gate: a spec-analyst spawn with no Behavioral Contract in CLAUDE.md should BLOCK.
#    (M12) Previously OMITTED from the selftest entirely though it is a registered PreToolUse gate on the
#    Agent|Task matcher — the coverage assertion below would now catch that omission; this closes it.
#    WORK has a git-init'd CLAUDE.md only if a prior test wrote one; ensure none exists so the gate blocks.
rm -f CLAUDE.md
test_gate "$REPO_ROOT/hooks/behavioral-contract-gate" \
  '{"tool_name":"Agent","tool_input":{"subagent_type":"spec-analyst","prompt":"extract the parity baseline"}}' \
  2 "behavioral-contract-gate (no Behavioral Contract)"

# 8. dependency-map-validator: empty file should BLOCK. This is an OPTIONAL helper (not a registered
#    PreToolUse gate in hooks.json — validated via lib/), so it is the one gate allowed to SKIP when absent.
test_gate "$REPO_ROOT/hooks/dependency-map-validator" \
  '{"tool_name":"Write","tool_input":{"file_path":"dependency-map.json","content":""}}' \
  2 "dependency-map-validator (empty input)" optional

# ─── (M12) COVERAGE ASSERTION: every registered PreToolUse gate must be in the tested set ─────────────
# CLASS this closes: a NEW gate added to hooks.json but never wired into this selftest reads as green
# (untested == not-failing). Enumerate the gate basenames invoked by every PreToolUse command in
# hooks/hooks.json and assert each appears in TESTED_GATES. SessionStart hooks (session-start,
# drift-detector) are intentionally excluded — they are non-blocking. Fail CLOSED if hooks.json can't be read.
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
if [ ! -f "$HOOKS_JSON" ]; then
  dead "hooks.json coverage" "hooks/hooks.json not found at $HOOKS_JSON — cannot verify gate coverage"
elif command -v jq &>/dev/null; then
  # Extract the gate token: the first argument after run-hook.cmd in each PreToolUse command string.
  REGISTERED="$(jq -r '
    .hooks.PreToolUse[]?.hooks[]?.command // ""
  ' "$HOOKS_JSON" 2>/dev/null \
    | sed -n 's/.*run-hook\.cmd"[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p' \
    | sort -u)"
  if [ -z "$REGISTERED" ]; then
    dead "hooks.json coverage" "could not parse any PreToolUse gate from hooks.json — failing closed"
  else
    MISSING=""
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      case "$TESTED_GATES" in
        *" $g "*) ;;                       # covered
        *) MISSING="$MISSING $g" ;;
      esac
    done <<< "$REGISTERED"
    if [ -n "$MISSING" ]; then
      dead "hooks.json coverage" "registered PreToolUse gate(s) NOT exercised by this selftest:$MISSING — add a self-test (a registered-but-untested gate reads as green)"
    else
      ok "hooks.json coverage (every registered PreToolUse gate is self-tested)"
    fi
  fi
else
  # No jq: cannot mechanically enumerate — say so rather than silently pass (honest, non-fatal note).
  skp "hooks.json coverage" "jq unavailable — cannot enumerate registered gates to verify coverage"
fi

# ─── Cleanup ──────────────────────────────────────────────────────

cd "$ORIG_DIR"
rm -rf "$WORK"

# ─── Results ──────────────────────────────────────────────────────

echo ""
$QUIET || echo "══════════════════════════════════════════════════"
echo "  Gate liveness: $PASS alive, $FAIL dead, $SKIP skipped"
if [ -n "$DEAD_GATES" ]; then
  echo "  ⚠️  DEAD GATES:$DEAD_GATES"
  echo "  These gates are registered but not enforcing."
  echo "  Check hooks.json registration and the hook files themselves."
fi
$QUIET || echo "══════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0

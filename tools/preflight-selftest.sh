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

ok() { $QUIET || printf '\033[32m  ALIVE\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
dead() { printf '\033[31m  DEAD \033[0m %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); DEAD_GATES="$DEAD_GATES $1"; }
skp() { $QUIET || printf '\033[33m  SKIP \033[0m %s — %s\n' "$1" "$2"; SKIP=$((SKIP+1)); }

# ─── Test driver: pipe crafted input to hook, assert exit code ───
# $1 = hook path, $2 = stdin JSON, $3 = expected exit code, $4 = label
test_gate() {
  local hook="$1" input="$2" expected="$3" label="$4"
  if [ ! -f "$hook" ]; then
    skp "$label" "hook file not found: $hook"
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

# 5. pre-push-gate-check: push to forbidden remote should BLOCK
test_gate "$REPO_ROOT/hooks/pre-push-gate-check" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}' \
  2 "pre-push-gate-check (force push)"

# 6. write-gate-evidence: malformed sentinel should BLOCK
mkdir -p .preflight/gate
test_gate "$REPO_ROOT/hooks/write-gate-evidence" \
  '{"tool_name":"Write","tool_input":{"file_path":".preflight/gate/parity-clean","content":"INVALID_SENTINEL"}}' \
  2 "write-gate-evidence (malformed sentinel)"

# 7. dependency-map-validator: empty file should BLOCK (if hook exists)
if [ -f "$REPO_ROOT/hooks/dependency-map-validator" ]; then
  test_gate "$REPO_ROOT/hooks/dependency-map-validator" \
    '{"tool_name":"Write","tool_input":{"file_path":"dependency-map.json","content":""}}' \
    2 "dependency-map-validator (empty input)"
else
  skp "dependency-map-validator" "not a standalone hook — validated via lib/"
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

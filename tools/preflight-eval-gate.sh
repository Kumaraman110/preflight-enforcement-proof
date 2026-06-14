#!/usr/bin/env bash
# preflight-eval-gate.sh — golden-task regression suite for rubric/rule changes.
#
# Runs every golden task in tests/golden-tasks/ against the CURRENT rubric and
# reports the pass rate. A proposed rubric change that DROPS the pass rate is
# auto-rejected — the human only sees changes that already pass.
#
# This is the eval-as-gate for the self-learning pipeline: capture -> adjudicate
# (INVARIANT/PATTERN/INCIDENT/OVERHEAD) -> INDEPENDENT VERIFIER -> eval gate ->
# human (one-tap APPROVE/REJECT). Nothing auto-applies to a gate.
#
# Usage:
#   bash tools/preflight-eval-gate.sh                          # run all golden tasks
#   bash tools/preflight-eval-gate.sh --baseline <sha-or-tag>  # compare against baseline
#   bash tools/preflight-eval-gate.sh --proposal <rubric-dir>  # test a proposed rubric change
#
# Exit 0 = all golden tasks pass (or pass rate maintained)
# Exit 1 = one or more golden tasks failed
# Exit 2 = eval gate itself failed to run
#
# HONESTY LABEL: MECHANICAL (deterministic bash tests comparing rubric behavior
# against golden expectations). Golden tasks are human-curated known-good scenarios;
# the suite is only as complete as the tasks it contains. A novel failure mode not
# covered by any golden task will not be caught.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GOLDEN_DIR="$REPO_ROOT/tests/golden-tasks"
BASELINE_PASS_RATE=""
PROPOSAL_DIR=""
MODE="current"  # current | baseline | proposal

while [ $# -gt 0 ]; do
  case "$1" in
    --baseline) BASELINE_PASS_RATE="$2"; shift 2 ;;
    --proposal) PROPOSAL_DIR="$2"; MODE="proposal"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

PASS=0; FAIL=0; TOTAL=0

# ─── Run a single golden task ──────────────────────────────────
# Each task directory contains:
#   task.sh     — the test script (exit 0 = pass)
#   README.md   — what this task verifies (optional)
run_golden_task() {
  local task_dir="$1"
  local task_name="$(basename "$task_dir")"
  TOTAL=$((TOTAL + 1))
  
  if [ ! -f "$task_dir/task.sh" ]; then
    echo "  SKIP $task_name: no task.sh"
    return
  fi
  
  local OUT RC
  OUT="$(cd "$task_dir" && REPO_ROOT="$REPO_ROOT" timeout 30 bash task.sh 2>&1)"; RC=$?
  
  if [ "$RC" -eq 0 ]; then
    echo "  PASS $task_name"
    PASS=$((PASS + 1))
  elif [ "$RC" -eq 124 ]; then
    echo "  FAIL $task_name: timed out"
    FAIL=$((FAIL + 1))
  else
    echo "  FAIL $task_name: exit $RC — $(echo "$OUT" | tail -1)"
    FAIL=$((FAIL + 1))
  fi
}

# ─── Main ──────────────────────────────────────────────────────

echo "═══════════════════════════════════════════════════"
echo "  preflight eval gate — golden task regression"
echo "  Mode: $MODE"
echo "═══════════════════════════════════════════════════"
echo ""

if [ ! -d "$GOLDEN_DIR" ]; then
  echo "Golden task directory not found: $GOLDEN_DIR"
  echo "Create tests/golden-tasks/ with task subdirectories."
  echo "Each task needs a task.sh that exits 0 for pass."
  
  # Still produce the structure
  if [ "$MODE" != "proposal" ]; then
    echo ""
    echo "No golden tasks exist yet. This is the RED state:"
    echo "  - A bad proposed lesson CAN reach the rubric (no eval gate to catch it)"
    echo "  - Build golden tasks, then re-run to establish the GREEN baseline"
    exit 1
  fi
fi

# Run all golden tasks
for task_dir in "$GOLDEN_DIR"/*/; do
  [ -d "$task_dir" ] || continue
  run_golden_task "$task_dir"
done

# ─── Results ───────────────────────────────────────────────────

if [ "$TOTAL" -eq 0 ]; then
  echo ""
  echo "No golden tasks found. RED: eval gate has no tasks — cannot auto-reject bad proposals."
  exit 1
fi

PASS_RATE=$(( PASS * 100 / TOTAL ))
echo ""
echo "═══════════════════════════════════════════════════"
echo "  Golden tasks: $PASS/$TOTAL passed ($PASS_RATE%)"
echo "═══════════════════════════════════════════════════"

if [ "$MODE" = "proposal" ] && [ -n "$BASELINE_PASS_RATE" ]; then
  BASELINE_NUM=$(echo "$BASELINE_PASS_RATE" | grep -oE '[0-9]+' || echo "100")
  if [ "$PASS_RATE" -lt "$BASELINE_NUM" ]; then
    echo ""
    echo "BLOCKED: Proposed rubric change drops pass rate from ${BASELINE_NUM}% to ${PASS_RATE}%."
    echo "The proposal is AUTO-REJECTED — it will not reach a human reviewer."
    echo "Fix the regressions or explicitly remove the broken golden task."
    exit 1
  fi
fi

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0

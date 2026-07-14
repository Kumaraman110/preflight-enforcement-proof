#!/usr/bin/env bash
# cert-diagnose-tail.sh — RUN ON THE RUNNER. Runs each of the remaining-failing behavioral tests individually
# and prints its FULL output (ANSI-stripped) so every failing assertion's context is captured in ONE run,
# avoiding many slow per-test runner cycles. Read-only; always exits 0 (evidence only).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "=================== CERT DIAGNOSE TAIL ==================="
echo "bash: $(bash --version | head -1)   jq: $(jq --version)   awk: $(awk --version 2>/dev/null | head -1)"
echo "RUNNER_TEMP=${RUNNER_TEMP:-unset}  HOME=$HOME  PWD=$ROOT"
echo ""
# TMPDIR outside the repo (same anchor as verify-full-suite.sh) so mktemp scratch dirs are non-git.
export TMPDIR="${RUNNER_TEMP:-$HOME}/.pf-tail-tmp"; mkdir -p "$TMPDIR"
STRIP="s/\x1b\[[0-9;]*m//g"

run_one() {  # $1 = test basename (without -test.sh)
  local t="$1" f="$ROOT/tests/behavioral/$1-test.sh"
  echo "════════════════════════════════════ $t ════════════════════════════════════"
  [ -f "$f" ] || { echo "(missing $f)"; return 0; }
  # run with a bounded timeout; strip ANSI; show FAIL lines + the trailer + a little context.
  ( cd "$ROOT" && timeout 240 bash "$f" 2>&1 ) | sed "$STRIP" | grep -aE 'FAIL|PASS|passed, [0-9]+ failed|expected|got|ERROR|SKIP|precondition|not valid|INTEGRITY|drama' | head -40
  echo ""
}

for t in alt-git-context-push no-duplicate-exec sentinel-tripwire bootstrap-write-gate hook-arbitration \
         resolve-config router-structural-classify selfcheck-liveness source-of-truth-check \
         source-of-truth-jq-absent install-prune-confinement; do
  run_one "$t"
done

echo "════════════════════════════════════ suite__protocol ════════════════════════════════════"
( cd "$ROOT" && timeout 240 bash tests/run-all-tests.sh protocol 2>&1 ) | sed "$STRIP" | grep -aE 'FAIL|expected|got|violation|permissions|workflow_run|Stage-2' | head -30

echo "=================== END DIAGNOSE TAIL ==================="
exit 0

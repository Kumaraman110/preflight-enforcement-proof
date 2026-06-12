#!/usr/bin/env bash
# pre-branch-cut cleanliness check (G4) — warns/errors on uncommitted
# .claude/ or .preflight/ drift in the tree (the thing that forced
# stash-surgery during the SessionToken migration branch-cut).
#
# Usage:
#   bash lib/pre-branch-cut-check.sh [--fail] [--check-claude] [--check-preflight]
#     --fail           exit 1 on any drift (default: warn only, exit 0)
#     --check-claude   also check for uncommitted .claude/ (default: on)
#     --check-preflight also check for uncommitted .preflight/ (default: on)
#
# Exit: 0 = clean or warn-only · 1 = drift found with --fail · 2 = usage error
#
# This is a MECHANICAL check (git status + path matching) — no LLM involved.
# The SessionToken run forced backup/stash/conflict-surgery because pre-existing
# uncommitted .claude/ + .preflight/ tooling drift existed in the working tree.
# This check prevents that class of friction.

set -uo pipefail

FAIL_MODE=false
CHECK_CLAUDE=true
CHECK_PREFLIGHT=true

while [ $# -gt 0 ]; do
  case "$1" in
    --fail) FAIL_MODE=true ;;
    --check-claude) CHECK_CLAUDE=true ;;
    --no-check-claude) CHECK_CLAUDE=false ;;
    --check-preflight) CHECK_PREFLIGHT=true ;;
    --no-check-preflight) CHECK_PREFLIGHT=false ;;
    *) echo "Usage: $0 [--fail] [--check-claude|--no-check-claude] [--check-preflight|--no-check-preflight]" >&2; exit 2 ;;
  esac
  shift
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: not in a git repository" >&2
  exit 2
fi

DRIFT_FOUND=false
DRIFT_DETAILS=""

# Check .claude/ drift
if [ "$CHECK_CLAUDE" = true ]; then
  CLAUDE_DRIFT=$(git status --porcelain -- .claude/ 2>/dev/null | grep -v '^??' || true)
  if [ -n "$CLAUDE_DRIFT" ]; then
    DRIFT_FOUND=true
    DRIFT_DETAILS="${DRIFT_DETAILS}Uncommitted .claude/ changes:\n$CLAUDE_DRIFT\n\n"
  fi
  # Also check for untracked .claude/ files that aren't in .gitignore
  CLAUDE_UNTRACKED=$(git status --porcelain -- .claude/ 2>/dev/null | grep '^??' || true)
  if [ -n "$CLAUDE_UNTRACKED" ]; then
    DRIFT_FOUND=true
    DRIFT_DETAILS="${DRIFT_DETAILS}Untracked .claude/ files (not in .gitignore?):\n$CLAUDE_UNTRACKED\n\n"
  fi
fi

# Check .preflight/ drift
if [ "$CHECK_PREFLIGHT" = true ]; then
  PREFLIGHT_DRIFT=$(git status --porcelain -- .preflight/ 2>/dev/null | grep -v '^??' || true)
  if [ -n "$PREFLIGHT_DRIFT" ]; then
    DRIFT_FOUND=true
    DRIFT_DETAILS="${DRIFT_DETAILS}Uncommitted .preflight/ changes:\n$PREFLIGHT_DRIFT\n\n"
  fi
  # Untracked .preflight/ files that aren't runtime state (runtime state is gitignored)
  PREFLIGHT_UNTRACKED=$(git status --porcelain -- .preflight/ 2>/dev/null | grep '^??' | grep -vE '^\?\? \.preflight/(cache|derived|gate|metrics\.json|migrate-checkpoint\.json|config\.local\.json)' || true)
  if [ -n "$PREFLIGHT_UNTRACKED" ]; then
    DRIFT_FOUND=true
    DRIFT_DETAILS="${DRIFT_DETAILS}Untracked .preflight/ files (not runtime state, not in .gitignore?):\n$PREFLIGHT_UNTRACKED\n\n"
  fi
fi

if [ "$DRIFT_FOUND" = true ]; then
  echo "⚠ PRE-BRANCH-CUT CLEANLINESS CHECK: drift detected" >&2
  echo "" >&2
  printf '%b' "$DRIFT_DETAILS" >&2
  echo "Resolve by: commit the drift, stash it, or add to .gitignore (for untracked)." >&2
  if [ "$FAIL_MODE" = true ]; then
    echo "FAIL: --fail specified — exiting 1" >&2
    exit 1
  fi
else
  echo "✓ PRE-BRANCH-CUT CLEANLINESS CHECK: clean"
fi

exit 0

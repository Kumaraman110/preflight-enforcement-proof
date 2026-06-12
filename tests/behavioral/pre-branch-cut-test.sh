#!/usr/bin/env bash
# Behavioral test for lib/pre-branch-cut-check.sh (G4).
#
# Proves:
#   C1. clean tree → exit 0, "clean" message
#   C2. uncommitted .claude/ changes → drift detected, exit 0 (warn)
#   C3. uncommitted .preflight/ changes → drift detected, exit 0 (warn)
#   C4. --fail mode with drift → exit 1
#   C5. --fail mode clean → exit 0
#   C6. untracked .claude/ files not in gitignore → drift detected
#   C6b. untracked .preflight/ files not runtime state → drift detected
#   C7. runtime-state untracked files (cache, derived, gate, etc.) → ignored
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../../lib/pre-branch-cut-check.sh"

PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$CHECK" ]; then
  bad "check script not found at $CHECK"
  echo ""; echo "pre-branch-cut tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi

# ── Build temp repo ──
REPO="$(mktemp -d)/repo"
mkdir -p "$REPO"
(cd "$REPO"
  git init -q; git config user.email t@t; git config user.name t
  echo 'init' > README.md; git add README.md; git commit -qm init
  # Ensure .gitignore covers preflight runtime state
  mkdir -p .preflight
  echo 'cache/
derived/
gate/
metrics.json
migrate-checkpoint.json
config.local.json' > .preflight/.gitignore
  git add .preflight/.gitignore; git commit -qm "add gitignore"
) >/dev/null 2>&1

cd "$REPO"

# C1: clean tree
bash "$CHECK" >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "C1 clean tree → exit 0"
else bad "C1 clean tree: expected 0, got $RC"; fi

# C2: uncommitted .claude/ changes
mkdir -p .claude
echo 'x' > .claude/test.md
git add .claude/test.md; git commit -qm "add"
echo 'y' > .claude/test.md  # modify
bash "$CHECK" >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "C2 uncommitted .claude/ → drift detected (warn, exit 0)"
else bad "C2 expected exit 0 (warn), got $RC"; fi
git checkout .claude/test.md

# C3: uncommitted .preflight/ changes
mkdir -p .preflight
echo 'x' > .preflight/settings.json
git add .preflight/settings.json; git commit -qm "add"
echo 'y' > .preflight/settings.json
bash "$CHECK" >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "C3 uncommitted .preflight/ → drift detected (warn, exit 0)"
else bad "C3 expected exit 0 (warn), got $RC"; fi
git checkout .preflight/settings.json

# C4: --fail mode with drift
echo 'z' > .claude/test.md
bash "$CHECK" --fail >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 1 ]; then
  ok "C4 --fail with drift → exit 1"
else bad "C4 expected exit 1, got $RC"; fi
git checkout .claude/test.md

# C5: --fail mode clean
bash "$CHECK" --fail >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "C5 --fail clean → exit 0"
else bad "C5 expected exit 0, got $RC"; fi

# C6: untracked .claude/ not in gitignore
echo 'x' > .claude/untracked.md
bash "$CHECK" >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "C6 untracked .claude/ not gitignored → drift detected"
else bad "C6 expected exit 0 (warn), got $RC"; fi
rm .claude/untracked.md

# C6b: untracked .preflight/ not runtime state
echo 'x' > .preflight/untracked-config.json
bash "$CHECK" >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "C6b untracked .preflight/ non-runtime → drift detected"
else bad "C6b expected exit 0 (warn), got $RC"; fi
rm .preflight/untracked-config.json

# C7: runtime-state untracked files are ignored
mkdir -p .preflight/cache .preflight/derived .preflight/gate
echo 'x' > .preflight/cache/foo
echo 'y' > .preflight/derived/bar
echo 'z' > .preflight/gate/baz
echo 'w' > .preflight/metrics.json
echo 'v' > .preflight/migrate-checkpoint.json
echo 'u' > .preflight/config.local.json
bash "$CHECK" >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "C7 runtime-state untracked (cache/derived/gate/metrics/migrate-checkpoint/config.local) → ignored"
else bad "C7 expected exit 0 (clean), got $RC"; fi

# Cleanup
rm -rf .preflight/cache .preflight/derived .preflight/gate .preflight/metrics.json .preflight/migrate-checkpoint.json .preflight/config.local.json

rm -rf "$(dirname "$REPO")"
echo ""
echo "pre-branch-cut tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

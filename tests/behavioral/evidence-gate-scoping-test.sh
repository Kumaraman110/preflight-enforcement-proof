#!/usr/bin/env bash
# Behavioral test for the evidence-gate session-root scoping fix (NEW-3 / gap #28).
#
# Defect: hooks/write-gate-evidence and hooks/pre-push-gate resolved
# ".preflight/gate" relative to the CALLER'S CWD, not the repo root. Writer and
# reader could disagree on the evidence location depending on where each ran:
#   - evidence written from a subdir landed at <subdir>/.preflight/gate/ where
#     the gate never looks → push falsely BLOCKED on "missing" evidence;
#   - the gate run from a subdir cwd missed root-level evidence (same false
#     block), and run from a different repo's cwd it would read THAT repo's
#     evidence (cross-repo confusion).
# Fix: both hooks anchor GATE_DIR at `git rev-parse --show-toplevel` (pwd
# fallback outside a repo), mirroring pre-push-gate-check's PFG_TARGET_CWD idiom.
#
# Proves, with real exit codes in a temp git repo:
#   S1. (was RED) write-gate-evidence run from a SUBDIR writes the evidence file
#       at the REPO ROOT (.preflight/gate/), nothing under the subdir.
#   S2. (was RED) with root-level evidence, pre-push-gate run from a SUBDIR cwd
#       finds it → exit 0 (pre-fix: exit 2 false block).
#   S3. (regression) root-cwd write + root-cwd read still exits 0.
#   S4. (staleness untouched) move HEAD two commits past the evidence stamp →
#       gate BLOCKS with exit 2 and a "stale" message, from root AND subdir cwd.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRITER="${SCRIPT_DIR}/../../hooks/write-gate-evidence"
GATE="${SCRIPT_DIR}/../../hooks/pre-push-gate"

for f in "$WRITER" "$GATE"; do
  if [ ! -f "$f" ]; then echo "FAIL: hook not found at $f" >&2; exit 1; fi
done

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# ── Build the temp repo (root .preflight/config.json + a nested subdir) ───────
REPO="$(mktemp -d)/repo"; mkdir -p "$REPO/src/deep"
( cd "$REPO"
  git init -q; git config user.email t@t; git config user.name t
  mkdir -p .preflight
  printf '%s\n' '{ "branch": { "base": "main", "remote": "origin" } }' > .preflight/config.json
  echo x > f; git add -A; git commit -qm init
) >/dev/null 2>&1

# S1: write from SUBDIR → evidence lands at repo root, NOT under the subdir.
( cd "$REPO/src/deep" && bash "$WRITER" tests-pass && bash "$WRITER" stage1-clean ) >/dev/null 2>&1
if [ -f "$REPO/.preflight/gate/tests-pass" ] && [ ! -e "$REPO/src/deep/.preflight" ]; then
  ok "S1 subdir write lands at repo root (no stray <subdir>/.preflight)"
else
  bad "S1 subdir write misplaced: root-file=$([ -f "$REPO/.preflight/gate/tests-pass" ] && echo yes || echo NO) stray-subdir=$([ -e "$REPO/src/deep/.preflight" ] && echo YES || echo no)"
fi

# S2: gate run from SUBDIR cwd finds the root evidence → exit 0 (was 2 pre-fix).
OUT="$( cd "$REPO/src/deep" && bash "$GATE" 2>&1 )"; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "S2 gate from subdir cwd sees root evidence (exit 0)"
else
  bad "S2 gate from subdir cwd: expected 0, got RC=$RC OUT=$OUT"
fi

# S3: regression — root-cwd write + root-cwd read still passes.
rm -rf "$REPO/.preflight/gate"
( cd "$REPO" && bash "$WRITER" tests-pass && bash "$WRITER" stage1-clean ) >/dev/null 2>&1
OUT="$( cd "$REPO" && bash "$GATE" 2>&1 )"; RC=$?
if [ "$RC" -eq 0 ] && [ -f "$REPO/.preflight/gate/tests-pass" ]; then
  ok "S3 regression: root-cwd write+read still exits 0"
else
  bad "S3 regression: expected 0 + root evidence, got RC=$RC OUT=$OUT"
fi

# S4: staleness logic untouched — move HEAD TWO commits past the evidence stamp
# (one commit would land in the legitimate stamp→commit→push HEAD^ window; two
# puts the evidence beyond HEAD^ → the classic stale block must fire), from
# root AND subdir cwd.
( cd "$REPO"
  echo y >> f; git add f; git commit -qm move1
  echo z >> f; git add f; git commit -qm move2
) >/dev/null 2>&1
OUT="$( cd "$REPO" && bash "$GATE" 2>&1 )"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'stale'; then
  ok "S4a staleness from root cwd: HEAD moved 2 commits → BLOCK(2, stale)"
else
  bad "S4a staleness from root cwd: expected BLOCK(2)+stale, got RC=$RC OUT=$OUT"
fi
OUT="$( cd "$REPO/src/deep" && bash "$GATE" 2>&1 )"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'stale'; then
  ok "S4b staleness from subdir cwd: same stale BLOCK(2)"
else
  bad "S4b staleness from subdir cwd: expected BLOCK(2)+stale, got RC=$RC OUT=$OUT"
fi

rm -rf "$(dirname "$REPO")"

echo ""
echo "evidence-gate scoping tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

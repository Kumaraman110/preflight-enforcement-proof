#!/usr/bin/env bash
# Behavioral test for the rubric-source-check --added git-failure fail-open (M5).
#
# THE BUG (FRAMEWORK-SCRUTINY-FINDINGS M5): in --added mode the changed-file list came from
# `git diff … 2>/dev/null | grep … || true`, where the 2>/dev/null + trailing `|| true` SWALLOWED any git
# failure (bad/unknown base-ref, not-a-git-repo, shallow clone, detached state) -> empty list ->
# "no changed rubric files … (CLEAN)" exit 0. A provenance gate that COULD NOT RUN reported clean.
#
# THE FIX: run git SEPARATELY, check its real $? BEFORE the grep; git failure -> exit 2 (could-not-run),
# DISTINCT from a legitimately-empty diff (no rubric changed -> exit 0 CLEAN).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RSC="$ROOT/lib/rubric-source-check.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

[ -f "$RSC" ] || { bad "missing $RSC"; echo ""; echo "rubric-source-added-failclosed tests: ${PASS} passed, ${FAIL} failed"; exit 1; }

echo "════════ M5 — --added git failure must FAIL CLOSED (exit 2), not report CLEAN ════════"
# A non-git directory (git diff cannot run).
NG="$(mktemp -d)"
( cd "$NG" && bash "$RSC" --added HEAD ) >/tmp/m5_nongit.out 2>&1; RC=$?
{ [ "$RC" -eq 2 ] && grep -qi 'FAILED' /tmp/m5_nongit.out; } \
  && ok "M5 --added in a non-git dir -> exit 2 (could-not-run), names the git failure" \
  || bad "M5 non-git: expected exit 2, got $RC ($(head -1 /tmp/m5_nongit.out))"

# A real git repo but a bad/unknown base-ref.
GR="$(mktemp -d)/repo"; mkdir -p "$GR"
( cd "$GR" && git init -q && git config user.email t@t && git config user.name t && echo x > f && git add -A && git commit -qm c1 ) >/dev/null 2>&1
( cd "$GR" && bash "$RSC" --added does-not-exist-ref-xyz ) >/tmp/m5_badref.out 2>&1; RC=$?
{ [ "$RC" -eq 2 ] && grep -qi 'FAILED' /tmp/m5_badref.out; } \
  && ok "M5 --added with a bad base-ref -> exit 2 (could-not-run)" \
  || bad "M5 bad-ref: expected exit 2, got $RC ($(head -1 /tmp/m5_badref.out))"

echo "──── M5 NO-FALSE-POSITIVE (an empty diff is NOT a failure — must stay CLEAN exit 0) ────"
# Valid base-ref, no rubric files changed -> CLEAN exit 0. Build a repo with TWO commits, no rubric .md.
GR2="$(mktemp -d)/repo2"; mkdir -p "$GR2"
( cd "$GR2" && git init -q && git config user.email t@t && git config user.name t \
  && echo a > app.txt && git add -A && git commit -qm c1 \
  && echo b > app.txt && git add -A && git commit -qm c2 ) >/dev/null 2>&1
( cd "$GR2" && bash "$RSC" --added HEAD~1 ) >/tmp/m5_clean.out 2>&1; RC=$?
{ [ "$RC" -eq 0 ] && grep -qi 'nothing to check (CLEAN)' /tmp/m5_clean.out; } \
  && ok "M5-NFP valid base-ref, no rubric .md changed -> CLEAN exit 0 (empty diff != git failure)" \
  || bad "M5-NFP empty-diff: expected CLEAN(0), got $RC ($(head -1 /tmp/m5_clean.out))"
# HEAD vs HEAD (empty diff) -> CLEAN exit 0.
( cd "$GR2" && bash "$RSC" --added HEAD ) >/tmp/m5_head.out 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "M5-NFP --added HEAD (empty diff vs self) -> CLEAN exit 0" \
               || bad "M5-NFP HEAD: expected CLEAN(0), got $RC"

echo ""
echo "rubric-source-added-failclosed tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

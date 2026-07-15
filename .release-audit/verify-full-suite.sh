#!/usr/bin/env bash
# verify-full-suite.sh — PORTABLE, RESUMABLE full-suite verifier for Preflight v0.10.0-rc.4.
#
# WHY THIS EXISTS: on the primary dev host (Windows/Git-Bash + CrowdStrike scan-on-exec + concurrent Claude
# Code sessions) every process is killed at ~2 minutes, while the heavy push-gate/router tests each need
# 3-8 minutes (the engine is invoked dozens of times, each spawn AV-scanned). The aggregate
# tests/run-all-tests.sh therefore cannot complete in one window inside Claude Code. Run THIS script directly
# from a normal terminal (Git Bash or PowerShell) — with NO 2-minute limit — to complete the full-suite gate.
#
# It enumerates EVERY test the aggregate runner invokes exactly once (the N external behavioral/*-test.sh
# scripts + the 7 in-file suites), runs each in its own shard with its own result+log, and is RESUMABLE (a
# shard with a recorded PASS is skipped; a FAIL/TIMEOUT/MISSING shard is re-run). It records exit code,
# duration, assertion counts, and a log hash per shard. A TIMEOUT is NEVER counted as pass. At the end it
# writes a manifest proving all shards ran exactly once and exits:
#     0  = every shard PASSED exactly once (109/109, zero failures)   ← the gate is GREEN
#     1  = at least one shard FAILED / TIMED OUT / is MISSING / DUPLICATED   ← gate not green
#
# USAGE (from Git Bash):      bash .release-audit/verify-full-suite.sh [OUTDIR]
# USAGE (from PowerShell):    bash .release-audit/verify-full-suite.sh [OUTDIR]     # needs Git-Bash `bash` on PATH
#   OUTDIR defaults to a stable dir under $HOME (survives /tmp cleanup). Re-run the SAME command to resume.
#
# HEAVY tests get a 15-minute (900s) per-shard cap; others get 5 minutes (300s). Override with
#   PF_HEAVY_TIMEOUT / PF_LIGHT_TIMEOUT (seconds). Set PF_FORCE=1 to re-run even PASSED shards.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${1:-$HOME/.preflight-fullsuite-verify}"
RES="$OUT/results"; LOGS="$OUT/logs"; mkdir -p "$RES" "$LOGS"
# TMPDIR must be OUTSIDE the git checkout. Several tests create a `mktemp -d` scratch dir and assert it is
# NOT inside any git repo (install-cwd-independence's "scratch cwd must not be in a git repo" precondition;
# rubric-source-check's "--added in a non-git dir must exit 2"). When OUT is inside the repo checkout (as in
# CI, where OUT=$GITHUB_WORKSPACE/verify-out), a TMPDIR under OUT would make every mktemp scratch dir a
# DESCENDANT of the repo, so `git rev-parse` walks up and finds .git → those tests spuriously FAIL. Anchor
# TMPDIR under $RUNNER_TEMP (CI) or $HOME (local) — never under the repo — and confirm it is non-git.
_PF_TMP_BASE="${RUNNER_TEMP:-$HOME}"
export TMPDIR="$_PF_TMP_BASE/.pf-fullsuite-tmp"; mkdir -p "$TMPDIR"
MANIFEST="$OUT/MANIFEST.tsv"
HEAVY_TO="${PF_HEAVY_TIMEOUT:-900}"     # 15 min for heavy engine tests
LIGHT_TO="${PF_LIGHT_TIMEOUT:-300}"     # 5 min otherwise

# ── Sanity: the product commit this verifier is meant to certify (informational; the script tests the tree it
#    is IN, so run it from a checkout of the rc.4 commit 0f6660c or the stable commit cut from it). ──
CUR_COMMIT="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "verify-full-suite: REPO=$REPO"
echo "  tree commit: $CUR_COMMIT"
echo "  OUT:         $OUT"
echo "  timeouts:    heavy=${HEAVY_TO}s light=${LIGHT_TO}s   (resume: re-run this same command)"

command -v git  >/dev/null 2>&1 || { echo "FATAL: git not on PATH" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || echo "  (note: no sha256sum/shasum — log hashes will be 'n/a')"
_hash(){ if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | cut -d' ' -f1; elif command -v shasum >/dev/null 2>&1; then shasum -a256 "$1" 2>/dev/null | cut -d' ' -f1; else echo n/a; fi; }

# ── HEAVY test set (each drives the push engine many times) — gets the 15-min cap. ──
case_heavy() {  # $1 = shard id ; 0 = heavy
  case "$1" in
    beh__pre-push-*|beh__router-*|beh__ir-push-*|beh__alt-git-context-push-test|beh__pre-bash-structure-*|\
    beh__wrapper-taxonomy-test|beh__wrapper-prefix-failopen-test|beh__no-duplicate-exec-test|\
    beh__spec-divergence-*|beh__install-*|beh__artifact-cli-packaging-test|beh__branch-stable-runtime-test|beh__runtime-*|\
    beh__cli-usability-test|beh__resolve-config-test|beh__review-thread-resolution-test|\
    beh__coverage-gap-detection-test|beh__detector-test|suite__*) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Enumerate EVERY shard exactly once (deterministic order): behavioral scripts, then in-file suites. ──
mapfile -t BEH < <(cd "$REPO" && ls tests/behavioral/*-test.sh 2>/dev/null | sort)
INFILE=(stage1 operative coupling crosscheck scan-profiles dependency-map-validator protocol)
declare -A SEEN=()   # duplicate guard

run_shard() {  # $1 id ; $2 kind ; $3.. command
  local id="$1" kind="$2"; shift 2
  if [ -n "${SEEN[$id]:-}" ]; then echo "FATAL: duplicate shard id '$id'" >&2; exit 2; fi
  SEEN["$id"]=1
  local rf="$RES/$id.result" log="$LOGS/$id.log"
  # resume: a recorded PASS is skipped unless PF_FORCE
  if [ "${PF_FORCE:-0}" != 1 ] && [ -s "$rf" ] && [ "$(cut -f2 "$rf" 2>/dev/null)" = PASS ]; then
    echo "  [skip] $id (already PASS)"; return 0
  fi
  local to=$LIGHT_TO; case_heavy "$id" && to=$HEAVY_TO
  local t0 t1 rc dur; t0=$(date +%s 2>/dev/null || echo 0)
  ( cd "$REPO" && timeout "$to" "$@" ) >"$log" 2>&1 </dev/null; rc=$?
  t1=$(date +%s 2>/dev/null || echo 0); dur=$(( t1 - t0 ))
  # parse ONLY the canonical trailer "<n> passed, <m> failed" (grep -a = text mode; anchored so a stray
  # number can never be read as a count). Absence of the trailer with rc!=0 is a FAIL, not a pass.
  local summ pass fail; summ="$(grep -aE '[0-9]+ passed, [0-9]+ failed' "$log" | tail -1)"
  pass="$(printf '%s' "$summ" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+')"; [ -n "$pass" ] || pass=0
  fail="$(printf '%s' "$summ" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+')"; [ -n "$fail" ] || fail=0
  local status
  if   [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then status=TIMEOUT      # NEVER a pass
  elif [ "$fail" -gt 0 ]; then status=FAIL
  elif [ "$rc" -ne 0 ]; then status=FAIL                                # nonzero rc with no failed-count = error
  elif [ -z "$summ" ]; then status=FAIL                                 # no canonical trailer = inconclusive → FAIL
  else status=PASS; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$status" "$pass" "$fail" "$rc" "$dur" "$(_hash "$log")" > "$rf"
  echo "  [$status] $id  (${pass}p/${fail}f rc=$rc ${dur}s)"
}

echo ""
echo "── running behavioral shards (${#BEH[@]}) ──"
for f in "${BEH[@]}"; do run_shard "beh__$(basename "$f" .sh)" behavioral bash "$f"; done
echo "── running in-file suites (${#INFILE[@]}) ──"
for s in "${INFILE[@]}"; do run_shard "suite__$s" infile bash tests/run-all-tests.sh "$s"; done

# ── Combined manifest + verdict ──────────────────────────────────────────────────────────────────────────
EXPECTED=$(( ${#BEH[@]} + ${#INFILE[@]} ))
{
  printf '# Preflight v0.10.0 full-suite verification manifest\n'
  printf '# tree commit: %s   generated-by: verify-full-suite.sh\n' "$CUR_COMMIT"
  printf 'SHARD\tSTATUS\tPASSED\tFAILED\tRC\tDURATION_S\tLOG_SHA256\n'
  cat "$RES"/*.result 2>/dev/null | LC_ALL=C sort
} > "$MANIFEST"

RECORDED=$(ls "$RES"/*.result 2>/dev/null | wc -l | tr -d ' ')
PASSN=$(awk -F'\t' '$2=="PASS"{n++}END{print n+0}' "$MANIFEST")
FAILN=$(awk -F'\t' '$2=="FAIL"{n++}END{print n+0}' "$MANIFEST")
TON=$(awk -F'\t' '$2=="TIMEOUT"{n++}END{print n+0}' "$MANIFEST")
SUMP=$(awk -F'\t' '$3 ~ /^[0-9]+$/{p+=$3}END{print p+0}' "$MANIFEST")
SUMF=$(awk -F'\t' '$4 ~ /^[0-9]+$/{f+=$4}END{print f+0}' "$MANIFEST")
# duplicate detection: a shard id appearing more than once in the manifest body
DUPS=$(awk -F'\t' '/^(beh__|suite__)/{c[$1]++}END{d=0;for(k in c)if(c[k]>1)d++;print d}' "$MANIFEST")

echo ""
echo "════════════════ FULL-SUITE VERIFICATION MANIFEST ════════════════"
echo "  tree commit : $CUR_COMMIT"
echo "  shards      : recorded $RECORDED / expected $EXPECTED"
echo "  status      : PASS=$PASSN  FAIL=$FAILN  TIMEOUT=$TON  duplicates=$DUPS"
echo "  assertions  : $SUMP passed, $SUMF failed (summed)"
echo "  manifest    : $MANIFEST"
if [ "$RECORDED" -eq "$EXPECTED" ] && [ "$PASSN" -eq "$EXPECTED" ] && [ "$FAILN" -eq 0 ] && [ "$TON" -eq 0 ] && [ "$DUPS" -eq 0 ] && [ "$SUMF" -eq 0 ]; then
  echo "  VERDICT     : GREEN — all $EXPECTED shards PASSED exactly once, zero failures."
  exit 0
fi
echo "  VERDICT     : NOT GREEN — re-run this command to resume incomplete/failed shards."
echo "  incomplete/failed shards:"
awk -F'\t' '$2!="PASS" && /^(beh__|suite__)/{print "    "$1"  ("$2")"}' "$MANIFEST"
# also list shards that were never recorded at all
for f in "${BEH[@]}"; do id="beh__$(basename "$f" .sh)"; [ -s "$RES/$id.result" ] || echo "    $id  (MISSING)"; done
for s in "${INFILE[@]}"; do id="suite__$s"; [ -s "$RES/$id.result" ] || echo "    $id  (MISSING)"; done
exit 1

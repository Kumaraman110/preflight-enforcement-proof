#!/usr/bin/env bash
# Behavioral test for the detector.sh failed-state-write fail-open (M8).
#
# THE BUG (FRAMEWORK-SCRUTINY-FINDINGS M8): the state-file write was
#   generate_json > "$OUTPUT_PATH.tmp" && mv "$OUTPUT_PATH.tmp" "$OUTPUT_PATH"
#   exit 0          # <- UNCONDITIONAL
# so if the redirect/mv failed (ENOSPC, unwritable path, a .tmp left as a directory by a crashed run,
# an un-creatable parent dir) the detector exited 0 with NO state.json written — a stale prior file was
# retained and reported as "current". Contradicts the docstring "exit 0 on success, exit 1 on critical failure".
#
# THE FIX: guard the mkdir, and wrap the generate/mv chain in if/then exit 0 else exit 1 — the exit code now
# honestly tracks whether state.json was actually written. A failed write -> exit 1 + diagnostic + no stale
# .tmp left behind. A normal write still -> exit 0 with state.json present (no false positive).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DET="$ROOT/lib/detector.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

[ -f "$DET" ] || { bad "missing $DET"; echo ""; echo "detector-write-failclosed tests: ${PASS} passed, ${FAIL} failed"; exit 1; }

echo "════════ M8 — a failed state-file write must FAIL CLOSED (exit 1), not exit 0 ════════"
# Work in a throwaway dir so the detector inspects an empty repo (deterministic 'default' output).
WD="$(mktemp -d)/work"; mkdir -p "$WD"

# (1) Redirect failure: make the .tmp target a DIRECTORY so `generate_json > OUT.tmp` cannot write.
OUT1="$WD/state1.json"
mkdir -p "$OUT1.tmp"     # OUT.tmp is now a directory -> the redirect fails
( cd "$WD" && bash "$DET" "$OUT1" ) >/tmp/m8_redir.out 2>&1; RC=$?
{ [ "$RC" -eq 1 ] && [ ! -f "$OUT1" ] && grep -qi 'FAILED to write state' /tmp/m8_redir.out; } \
  && ok "M8 redirect failure (.tmp is a dir) -> exit 1, no state.json written, diagnostic emitted" \
  || bad "M8 redirect-fail: expected exit1+no-file+diag, got RC=$RC file-exists=$([ -f "$OUT1" ] && echo yes || echo no) ($(head -1 /tmp/m8_redir.out))"

# (2) Un-creatable parent dir: point OUTPUT_PATH under a path whose parent is a regular FILE.
BLOCK="$WD/afile"; echo x > "$BLOCK"   # afile is a file, so afile/sub cannot be mkdir'd
OUT2="$BLOCK/sub/state2.json"
( cd "$WD" && bash "$DET" "$OUT2" ) >/tmp/m8_mkdir.out 2>&1; RC=$?
{ [ "$RC" -eq 1 ] && [ ! -f "$OUT2" ]; } \
  && ok "M8 un-creatable parent dir -> exit 1, no state.json written" \
  || bad "M8 mkdir-fail: expected exit 1 + no file, got RC=$RC ($(head -1 /tmp/m8_mkdir.out))"

# (3) Stale-file guard: a PRIOR state.json must NOT survive as 'current' after a failed write.
OUT3="$WD/state3.json"
echo '{"stale":"prior-run"}' > "$OUT3"
mkdir -p "$OUT3.tmp"     # force the write to fail
( cd "$WD" && bash "$DET" "$OUT3" ) >/tmp/m8_stale.out 2>&1; RC=$?
# The fix does not silently overwrite a stale file with a fresh one on failure; it must NOT exit 0.
[ "$RC" -eq 1 ] \
  && ok "M8 failed write with a stale prior state.json present -> exit 1 (not a false-green 0)" \
  || bad "M8 stale-present: expected exit 1, got RC=$RC"

echo "──── M8 NO-FALSE-POSITIVE (a normal successful write must still exit 0 with state.json) ────"
OUT4="$WD/nested/state4.json"   # parent does not yet exist; mkdir -p should create it
( cd "$WD" && bash "$DET" "$OUT4" ) >/tmp/m8_ok.out 2>&1; RC=$?
{ [ "$RC" -eq 0 ] && [ -f "$OUT4" ] && [ ! -e "$OUT4.tmp" ]; } \
  && ok "M8-NFP normal run -> exit 0, state.json written, no leftover .tmp" \
  || bad "M8-NFP normal: expected exit0+file+no-tmp, got RC=$RC file=$([ -f "$OUT4" ] && echo yes || echo no)"
# The written file must be valid JSON (the write produced a real artifact, not a truncated one).
if [ -f "$OUT4" ]; then
  if command -v node >/dev/null 2>&1; then
    node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$OUT4" >/dev/null 2>&1 \
      && ok "M8-NFP written state.json is valid JSON" \
      || bad "M8-NFP written state.json is NOT valid JSON"
  else
    echo "SKIP: node not available for JSON-validity assertion"
  fi
fi

echo ""
echo "detector-write-failclosed tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

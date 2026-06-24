#!/usr/bin/env bash
# Behavioral test for the jq-absent fail-open in lib/source-of-truth-check.sh (G5).
#
# THE BUG (self-review G5): when --json is supplied but `jq` is NOT on PATH, the entire JSON-extraction
# block (an `if command -v jq` with NO else) is SILENTLY SKIPPED — the json-declared required[] sources are
# never added to the requirement set, with no diagnostic. In a MIXED call
# (`--json desc.json --require file:present`), the CLI source is processed but ALL json-declared sources are
# dropped; if the CLI subset happens to be present, the empty-set fail-safe does NOT fire (there IS a
# requirement) and the tool emits PROCEED (exit 0) on a STRICT SUBSET of the operator-declared sources —
# a fail-OPEN for a fail-CLOSED gate (the tool-may-be-absent class CLAUDE.md flags, and a direct violation
# of this file's own thesis: lines 51-53, "never silently PROCEEDs").
#
# THE PRINCIPLE (this fix family): a source-of-truth gate that CANNOT read the operator's declared sources
# (its parser, jq, is unavailable) must FAIL CLOSED (ESCALATE — "can't verify, can't proceed"), never
# silently PROCEED on whatever subset it happened to parse.
#
# METHOD: jq lives ONLY in a dedicated dir on this box; we run the hook with that dir DROPPED from PATH so
# jq is genuinely absent while bash/grep/sed/git remain intact. (PATH-stripping the whole tree breaks bash;
# dropping just the jq dir is the reliable isolation.) If jq is found on a multi-dir PATH the test SKIPs
# loudly rather than silently passing for the wrong reason.
#
# RED->GREEN:
#   J1 — MIXED --json(an ABSENT source) + --require(a PRESENT source), jq absent:
#          RED  (pre-fix): PROCEED (exit 0) — json sources silently dropped, subset-PROCEED (fail-open).
#          GREEN (post-fix): ESCALATE (exit 3) — cannot parse declared sources, fail closed.
#   J2 — JSON-only(an ABSENT source), jq absent: must ESCALATE (was already safe via the empty-set guard,
#          must STAY ESCALATE under the explicit jq-absent handling — no regression in the safe direction).
#   J3 — control: jq PRESENT, the same MIXED call -> ESCALATE (proves the json source is normally checked;
#          the bug is specifically the jq-absent path, and the normal path is unchanged).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOT="$ROOT/lib/source-of-truth-check.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

[ -f "$SOT" ] || { bad "missing $SOT"; echo ""; echo "source-of-truth-jq-absent tests: ${PASS} passed, ${FAIL} failed"; exit 1; }

# Locate the dir(s) that contain jq; build a PATH with ALL of them removed (jq genuinely absent), keeping
# every other dir so bash/grep/sed/git still resolve.
JQ_BIN="$(command -v jq 2>/dev/null || true)"
if [ -z "$JQ_BIN" ]; then
  echo "SKIP: jq not present in this environment — the jq-absent path is the default here; nothing to isolate."
  echo ""; echo "source-of-truth-jq-absent tests: ${PASS} passed, ${FAIL} failed"; exit 0
fi
JQ_DIR="$(cd "$(dirname "$JQ_BIN")" && pwd)"
NOJQ_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$JQ_DIR" | paste -sd: -)"
# Verify the isolation actually removed jq AND kept bash; if not, SKIP loudly (don't pass for wrong reason).
if PATH="$NOJQ_PATH" command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is on more than one PATH dir; cannot cleanly isolate jq-absent here. (Not a pass.)"
  echo ""; echo "source-of-truth-jq-absent tests: ${PASS} passed, ${FAIL} failed"; exit 0
fi
if ! PATH="$NOJQ_PATH" command -v bash >/dev/null 2>&1; then
  echo "SKIP: removing the jq dir also removed bash — cannot isolate jq-absent on this layout. (Not a pass.)"
  echo ""; echo "source-of-truth-jq-absent tests: ${PASS} passed, ${FAIL} failed"; exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf 'real present content\n' > "$T/present.txt"
cat > "$T/desc.json" <<JSON
{ "agent":"spec-analyst", "required":[ {"kind":"file","label":"absent legacy baseline","path":"$T/ABSENT.json"} ] }
JSON

# v_nojq / v_jq <args...> -> RC + first output line in V (run with jq absent / present respectively).
v_nojq() { local out; out="$(PATH="$NOJQ_PATH" bash "$SOT" "$@" 2>/dev/null)"; RC=$?; V="$(printf '%s' "$out" | head -1)"; }
v_jq()   { local out; out="$(bash "$SOT" "$@" 2>/dev/null)"; RC=$?; V="$(printf '%s' "$out" | head -1)"; }

# ── J1 (RED->GREEN): MIXED, jq absent, json source ABSENT, cli source PRESENT -> must ESCALATE ──
v_nojq --json "$T/desc.json" --require "file:present cli source:$T/present.txt"
if [ "$RC" -eq 3 ] && [ "$V" = "ESCALATE" ]; then
  ok "J1: MIXED sources with jq ABSENT -> ESCALATE (exit 3) — does not silently PROCEED on the cli subset"
else
  bad "J1: FAIL-OPEN — jq-absent mixed call did not fail closed (RC=$RC V=$V; pre-fix this is PROCEED/0)"
fi

# ── J2: JSON-only, jq absent -> ESCALATE (the empty-set fail-safe; must stay safe) ──
v_nojq --json "$T/desc.json"
[ "$RC" -eq 3 ] && [ "$V" = "ESCALATE" ] && ok "J2: JSON-only with jq ABSENT -> ESCALATE (fail-safe preserved)" \
                                         || bad "J2: JSON-only jq-absent should ESCALATE(3), got RC=$RC V=$V"

# ── J3 (control): jq PRESENT, same MIXED call -> ESCALATE (the json ABSENT source IS checked normally) ──
v_jq --json "$T/desc.json" --require "file:present cli source:$T/present.txt"
[ "$RC" -eq 3 ] && [ "$V" = "ESCALATE" ] && ok "J3 control: with jq PRESENT the json-declared ABSENT source is checked -> ESCALATE (normal path unchanged)" \
                                         || bad "J3 control: jq-present mixed call should ESCALATE(3) on the absent json source, got RC=$RC V=$V"

echo ""
echo "source-of-truth-jq-absent tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

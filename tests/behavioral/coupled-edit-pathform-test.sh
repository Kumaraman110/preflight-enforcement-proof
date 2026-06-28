#!/usr/bin/env bash
# Behavioral test for the coupled-edit-gate input-shape fail-opens (H3 + H4).
#
# THE BUGS (FRAMEWORK-SCRUTINY-FINDINGS H3+H4; design in .release-audit/H3-H4-FIX-DESIGN.md):
#   H3 — membership compared the incoming file_path by EXACT string (only \->/ normalization). The real
#        Edit/Write tool sends an ABSOLUTE path while active-groups.json stores repo-RELATIVE paths, so an
#        absolute or ./-prefixed incoming path MISSED -> UNACKED=0 -> silent ALLOW on every coupled block.
#   H4 — the jq selector `select(.acknowledged == false)` treats a MISSING field as null (null==false is
#        false), so a group object omitting `acknowledged` was NOT counted unacknowledged -> silent ALLOW.
#
# THE FIX:
#   H3 — canonicalize the incoming path to repo-relative (lexical: \->/, strip repo-root prefix, strip ./,
#        strip leading /), then match by exact-equality OR /-anchored-suffix against each (likewise-
#        canonicalized) stored path. The /-anchor rejects a shared-basename false positive.
#   H4 — a group counts as unacknowledged unless acknowledged is the explicit boolean true (jq `!= true`,
#        python `is not True`, grep all-true-count). The writer (write-active-groups) also normalizes a
#        missing/non-boolean acknowledged -> false at the chokepoint.
#   Both applied across ALL backends (jq / python / grep) for parity.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$ROOT/hooks/coupled-edit-gate"
WAG="$ROOT/hooks/write-active-groups"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

for f in "$GATE" "$WAG"; do
  [ -f "$f" ] || { bad "missing $f"; echo ""; echo "coupled-edit-pathform tests: ${PASS} passed, ${FAIL} failed"; exit 1; }
done

# A workspace with a git repo (so the gate's `git rev-parse --show-toplevel` resolves a real REPO_TOP).
WS="$(mktemp -d)/repo"; mkdir -p "$WS/.preflight/gate"
( cd "$WS" && git init -q ) >/dev/null 2>&1

# set_group <json-array>  — writes active-groups.json directly (bypassing the writer, to test raw shapes the
# writer would normalize away — H4 consumer-side shapes must fail closed even on a hand-authored/legacy file).
set_group() { printf '%s' "$1" > "$WS/.preflight/gate/active-groups.json"; }

# edit_rc <file_path> [PATH_OVERRIDE] — drive the gate with an Edit on file_path; echo the exit code.
# PORTABILITY FIX: build the JSON with jq so the file_path is PROPERLY ESCAPED. The old raw string-interp
# (`"file_path":"$fp"`) produced INVALID JSON for the backslash case — a literal `Services\TokenProvider.cs`
# embeds `\T`, an illegal JSON escape. jq then errored on extraction and the gate fell through; on Windows a
# fallback happened to still BLOCK, but on Linux it passed through (exit 0) → a spurious cross-platform FAIL.
# A backslash path is a legitimate Windows file_path the gate MUST still canonicalize+block, so the test must
# send it as VALID JSON (jq encodes the lone backslash as `\\`). jq -n --arg is byte-exact and portable. If
# jq is unavailable the gate is skipped at the top of this file, so jq is always present here.
edit_rc() {
  local fp="$1" pe="${2:-}"
  local json; json="$(jq -nc --arg fp "$fp" '{tool_name:"Edit",tool_input:{file_path:$fp,old_string:"a",new_string:"b"}}')"
  if [ -n "$pe" ]; then ( cd "$WS" && printf '%s' "$json" | PATH="$pe" bash "$GATE" >/dev/null 2>&1; echo $? )
  else                  ( cd "$WS" && printf '%s' "$json" | bash "$GATE" >/dev/null 2>&1; echo $? ); fi
}

# assert_block / assert_allow <label> <file_path> [PATH_OVERRIDE]
assert_block() { local rc; rc=$(edit_rc "$2" "${3:-}"); [ "$rc" = 2 ] && ok "$1 (BLOCK exit 2)" || bad "$1: expected BLOCK(2), got $rc"; }
assert_allow() { local rc; rc=$(edit_rc "$2" "${3:-}"); [ "$rc" = 0 ] && ok "$1 (ALLOW exit 0)" || bad "$1: expected ALLOW(0), got $rc"; }

GROUP_REL='[{"files":["Services/TokenProvider.cs","Clients/AccountClient.cs"],"findings":["x"],"acknowledged":false}]'

echo "════════ H3 — path-form membership (group acknowledged:false, member edited) ════════"
set_group "$GROUP_REL"
assert_block "H3 relative 'Services/TokenProvider.cs'"            "Services/TokenProvider.cs"
assert_block "H3 absolute '<abs>/Services/TokenProvider.cs'"      "$WS/Services/TokenProvider.cs"
assert_block "H3 ./-prefixed './Services/TokenProvider.cs'"       "./Services/TokenProvider.cs"
assert_block "H3 backslash 'Services\\\\TokenProvider.cs'"        "Services\\\\TokenProvider.cs"
echo "──── H3 NO-FALSE-POSITIVE (must ALLOW — the load-bearing anti-regression) ────"
assert_allow "H3-NFP shared-basename '<abs>/OtherDir/TokenProvider.cs'"   "$WS/OtherDir/TokenProvider.cs"
assert_allow "H3-NFP basename-superstring '<abs>/Services/TokenProviderTests.cs'" "$WS/Services/TokenProviderTests.cs"
assert_allow "H3-NFP unrelated file"                              "$WS/Other/Unrelated.cs"

echo "════════ H4 — malformed acknowledged shapes (edit A.cs, member of the group) ════════"
set_group '[{"files":["A.cs"],"findings":["x"]}]';                 assert_block "H4 missing acknowledged"      "A.cs"
set_group '[{"files":["A.cs"],"findings":["x"],"acknowledged":"false"}]'; assert_block "H4 string \"false\""    "A.cs"
set_group '[{"files":["A.cs"],"findings":["x"],"acknowledged":null}]';    assert_block "H4 null"                "A.cs"
set_group '[{"files":["A.cs"],"findings":["x"],"acknowledged":0}]';       assert_block "H4 numeric 0"           "A.cs"
set_group '[{"files":["A.cs"],"findings":["x"],"acknowledged":false}]';   assert_block "H4 explicit false"      "A.cs"
set_group '[{"files":["A.cs"],"findings":["x"],"acknowledged":true}]';    assert_allow "H4 explicit true (the only clear)" "A.cs"

echo "════════ Writer (write-active-groups) schema-normalizes acknowledged -> false ════════"
WW="$(mktemp -d)/w"; mkdir -p "$WW"
( cd "$WW" && bash "$WAG" '[{"files":["A.cs"],"findings":["x"]}]' ) >/dev/null 2>&1
if grep -q '"acknowledged"' "$WW/.preflight/gate/active-groups.json" 2>/dev/null \
   && ! grep -qE '"acknowledged"[[:space:]]*:[[:space:]]*true' "$WW/.preflight/gate/active-groups.json"; then
  ok "Writer: a group missing acknowledged is normalized to an explicit acknowledged:false"
else
  bad "Writer: missing acknowledged was not normalized to false — $(tr -d '\n ' < "$WW/.preflight/gate/active-groups.json" 2>/dev/null)"
fi
# Writer rejects a schema-invalid group (no files[]) — fail closed, no corrupt state written.
( cd "$WW" && bash "$WAG" '[{"findings":["x"]}]' ) >/dev/null 2>&1; WRC=$?
[ "$WRC" = 1 ] && ok "Writer: a group with no files[] is REJECTED (exit 1), gate state not corrupted" \
               || bad "Writer: schema-invalid group should exit 1, got $WRC"

echo "════════ BACKEND PARITY — python path (jq removed from PATH) must match jq verdicts ════════"
JQ_BIN="$(command -v jq 2>/dev/null || true)"
if [ -z "$JQ_BIN" ]; then
  echo "SKIP: jq not present — python is already the default; parity is trivially the same path."
else
  JQ_DIR="$(cd "$(dirname "$JQ_BIN")" && pwd)"
  NOJQ="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$JQ_DIR" | paste -sd: -)"
  if PATH="$NOJQ" command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq on >1 PATH dir — cannot cleanly isolate the python path. (Not a pass.)"
  elif ! PATH="$NOJQ" command -v python >/dev/null 2>&1 && ! PATH="$NOJQ" command -v python3 >/dev/null 2>&1; then
    echo "SKIP: removing jq's dir also removed python — cannot isolate the python backend. (Not a pass.)"
  else
    set_group "$GROUP_REL"
    assert_block "PARITY py H3 absolute"        "$WS/Services/TokenProvider.cs" "$NOJQ"
    assert_block "PARITY py H3 ./-prefixed"     "./Services/TokenProvider.cs"   "$NOJQ"
    assert_allow "PARITY py H3-NFP shared-base" "$WS/OtherDir/TokenProvider.cs" "$NOJQ"
    set_group '[{"files":["A.cs"],"findings":["x"]}]';                 assert_block "PARITY py H4 missing"  "A.cs" "$NOJQ"
    set_group '[{"files":["A.cs"],"findings":["x"],"acknowledged":true}]'; assert_allow "PARITY py H4 true"   "A.cs" "$NOJQ"
  fi
fi

echo ""
echo "coupled-edit-pathform tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

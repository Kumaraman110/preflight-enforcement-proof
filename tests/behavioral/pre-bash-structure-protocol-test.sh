#!/usr/bin/env bash
# Behavioral test: PROTOCOL VALIDATION + FAILURE ISOLATION for the AWK-backed shared shell-structure parser.
#
# Stage 2A. The parser (lib/shell-structure.sh) invokes a fixed POSIX-AWK lexer (lib/shell-structure-lexer.awk)
# over stdin and reconstructs the IR by VALIDATING (never eval'ing) the lexer's record protocol. This test
# proves the wrapper FAILS CLOSED (PFG_SS_STATUS=ERROR) on every malformed/abnormal lexer condition, and
# that a fake `awk` earlier in PATH cannot smuggle output past validation. It also proves AWK-absence →
# ERROR (which the push shadow maps to SHADOW_ERROR with the legacy verdict unchanged).
#
# Exit 0 = all pass.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$ROOT/lib/shell-structure.sh"
LEXER="$ROOT/lib/shell-structure-lexer.awk"
[ -f "$LIB" ] || { echo "FAIL: lib/shell-structure.sh not found" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

_CLEAN=(); trap 'for d in "${_CLEAN[@]}"; do rm -rf "$d" 2>/dev/null || true; done' EXIT

# Run the parser with a FAKE awk that emits exactly $1 on stdout and exits with code $2. Returns via the
# PFG_SS_* globals. The fake awk is a shim that ignores its args, drains stdin, prints the canned protocol.
run_with_fake_awk() {  # $1 = canned stdout  $2 = exit code
  local canned="$1" code="$2" d; d="$(mktemp -d)"; _CLEAN+=("$d")
  # a fake `awk` shim: drain stdin, print the canned bytes, exit with the given code.
  cat > "$d/awk" <<EOF
#!/bin/sh
cat >/dev/null 2>&1
printf '%s' '$(printf '%s' "$canned" | sed "s/'/'\\\\''/g")'
exit $code
EOF
  chmod +x "$d/awk"
  # source the lib in a subshell with PATH prefixed by the fake awk, parse, echo the result.
  bash -c '
    set -uo pipefail
    export PATH="'"$d"':$PATH"
    source "'"$LIB"'"
    pfg_ss_parse "echo hello"
    printf "%s|%s\n" "$PFG_SS_STATUS" "$PFG_SS_NODE_COUNT"
  '
}

# assert the fake-awk-driven parse yields STATUS == $3
assert_fake() {  # $1 label  $2 canned-stdout  $3 exit-code  $4 expected-status
  local r; r="$(run_with_fake_awk "$2" "$3")"
  local st="${r%%|*}"
  [ "$st" = "$4" ] && ok "$1 → STATUS=$4" || bad "$1: expected STATUS=$4 got '$r'"
}

VALID='V 1
M 65536 256 8
N 0 -1 1 0 10 1 0 0 0
X 0 6768
E 1 0'

echo "════ valid protocol (control) ════"
assert_fake "P0 well-formed"            "$VALID"                              0  OK

echo "════ abnormal exit → ERROR ════"
assert_fake "P1 nonzero exit"           "$VALID"                              2  ERROR
assert_fake "P2 exit 1 empty out"       ""                                     1  ERROR

echo "════ truncated / missing terminal → ERROR ════"
assert_fake "P3 no terminal E"          "V 1
M 65536 256 8
N 0 -1 1 0 10 1 0 0 0"                                                        0  ERROR
assert_fake "P4 empty output"           ""                                     0  ERROR
assert_fake "P5 only version"           "V 1"                                  0  ERROR

echo "════ malformed records → ERROR ════"
assert_fake "P6 bad version"            "V 9
E 0 0"                                                                        0  ERROR
assert_fake "P7 missing V"              "M 65536 256 8
E 0 0"                                                                        0  ERROR
assert_fake "P8 N wrong field count"    "V 1
M 65536 256 8
N 0 -1 1 0 10
E 1 0"                                                                        0  ERROR
assert_fake "P9 N non-numeric"          "V 1
M 65536 256 8
N x -1 1 0 10 1 0 0 0
E 1 0"                                                                        0  ERROR
assert_fake "P10 N bad ctx enum"        "V 1
M 65536 256 8
N 0 -1 99 0 10 1 0 0 0
E 1 0"                                                                        0  ERROR
assert_fake "P11 N id not monotonic"    "V 1
M 65536 256 8
N 5 -1 1 0 10 1 0 0 0
E 1 0"                                                                        0  ERROR
assert_fake "P12 forward parent ref"    "V 1
M 65536 256 8
N 0 7 1 0 10 1 0 0 0
E 1 0"                                                                        0  ERROR
assert_fake "P13 span end<start"        "V 1
M 65536 256 8
N 0 -1 1 10 2 1 0 0 0
E 1 0"                                                                        0  ERROR
assert_fake "P14 E count mismatch"      "V 1
M 65536 256 8
N 0 -1 1 0 10 1 0 0 0
E 5 0"                                                                        0  ERROR
assert_fake "P15 record after terminal" "V 1
M 65536 256 8
E 0 0
N 0 -1 1 0 10 1 0 0 0"                                                        0  ERROR
assert_fake "P16 unknown record type"   "V 1
M 65536 256 8
Z 0 0 0
E 0 0"                                                                        0  ERROR
assert_fake "P17 X unknown node"        "V 1
M 65536 256 8
X 3 6768
E 0 0"                                                                        0  ERROR
assert_fake "P18 X bad hex"             "V 1
M 65536 256 8
N 0 -1 1 0 10 1 0 0 0
X 0 zzzz
E 1 0"                                                                        0  ERROR
assert_fake "P19 E bad status code"     "V 1
M 65536 256 8
E 0 9"                                                                        0  ERROR

echo "════ excessive output (node budget) → ERROR ════"
# emit MAXNODES+ N records without honoring the wrapper's monotonic/budget guard beyond the cap
_over="V 1
M 65536 3 8"
for i in 0 1 2 3; do _over="$_over
N $i -1 1 0 10 1 0 0 0"; done
_over="$_over
E 4 0"
assert_fake "P20 exceeds node budget"   "$_over"                              0  ERROR

echo "════ transport byte-fidelity → fail CLOSED on the corrupting inputs ════"
# a literal 0x1C (the record separator) must NOT be silently dropped (offset-shift/structure-change); the
# lexer fails CLOSED to ERROR on multi-record input. Driven through the REAL awk (not a fake), via the lib.
_real_parse_status() {  # $1 = command → echoes PFG_SS_STATUS through the real lexer
  bash -c 'set -uo pipefail; source "'"$LIB"'"; pfg_ss_parse "$1"; printf "%s" "$PFG_SS_STATUS"' _ "$1" 2>/dev/null
}
r="$(_real_parse_status "$(printf 'gh \034 pr merge')")"
[ "$r" = "ERROR" ] && ok "P22 literal 0x1C → ERROR (fail closed, not dropped)" || bad "P22: 0x1C should fail closed to ERROR, got '$r'"
# a normal command with high UTF-8 bytes under the wrapper's LC_ALL=C parses as BYTES (OK), not ERROR.
r="$(_real_parse_status "gh pr merge --title 'café'")"
[ "$r" = "OK" ] && ok "P23 UTF-8 bytes under LC_ALL=C → OK (byte-parsed, not char-mode ERROR)" || bad "P23: UTF-8 arg should be OK, got '$r'"

echo "════ AWK absence → ERROR (maps to SHADOW_ERROR later) ════"
# empty PATH so `command -v awk` fails
r="$(bash -c 'set -uo pipefail; export PATH=""; source "'"$LIB"'"; pfg_ss_parse "echo hi"; printf "%s" "$PFG_SS_STATUS"' 2>/dev/null || true)"
[ "$r" = "ERROR" ] && ok "P21 awk-absent → ERROR" || bad "P21: expected ERROR got '$r'"

echo ""
echo "pre-bash-structure-protocol tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

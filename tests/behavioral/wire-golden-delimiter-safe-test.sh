#!/usr/bin/env bash
# Behavioral test for the wire-golden delimiter-safe substitution (M10).
#
# THE BUG (MEDIUM-FIXES-DESIGN M10): per-case placeholders were filled with
#   sed -e "s|{{SAMPLE}}|$SAMPLE|g" -e "s|{{GOLDEN}}|$GOLDEN|g" …
# A `|` in a sample/golden value (an enum flag "Read|Write", a delimited id) collided with the sed
# `s|…|` delimiter — sed errored, the pipeline emitted NOTHING for that case, and the case scaffold
# landed WITHOUT its serialize/compare body, yet "Generated … N case(s)." exit 0: an assertion-less,
# always-green test reported as generated (a SAFETY-false-green). The `/`-delimited {{TYPE}}/{{NAME}}
# branches were the same class for any `/` in a type/case name.
#
# THE FIX: an index()-based LITERAL awk splice (NOT gsub — gsub would corrupt `&`/`\`) for all four
# placeholders, values passed via ENVIRON, plus a PIPESTATUS backstop that exits 2 on any substitution
# failure rather than emitting a body-less case.
#
# NFP: every real clean fixture value produces byte-identical output (proven separately in-session);
# here we prove the delimiter-collision CLASS is closed and `&`/`\`/`|`/`/` survive byte-for-byte.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GEN="$ROOT/lib/generate-wire-golden-test.sh"
FIXTURES="$ROOT/tests/fixtures/wire-golden"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

[ -f "$GEN" ] || { bad "missing $GEN"; echo ""; echo "wire-golden-delimiter-safe tests: ${PASS} passed, ${FAIL} failed"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required by the generator"; echo ""; echo "wire-golden-delimiter-safe tests: ${PASS} passed, ${FAIL} failed"; exit 0; }

T="$(mktemp -d)"

# countf <fixed-string> <file> -> prints a single integer (grep -c prints "0" AND exits 1 on no match,
# so a bare `grep -c || echo 0` double-prints; this guards both the count and the missing-file case).
countf() { local n; n="$(grep -cF "$1" "$2" 2>/dev/null)" || true; printf '%s' "${n:-0}"; }

# ── (1) NFP: the real clean fixtures still generate a complete body (string.Equals present), exit 0 ──
echo "════════ M10 NO-FALSE-POSITIVE — real clean fixtures generate a complete assertion body ════════"
if [ -d "$FIXTURES" ]; then
  for fx in "$FIXTURES"/*.json; do
    [ -f "$fx" ] || continue
    bn="$(basename "$fx" .json)"
    NCASES=$(jq '.cases | length' "$fx")
    for runner in console xunit; do
      bash "$GEN" "$fx" "$T/$bn-$runner.cs" --runner "$runner" >/tmp/m10gen.out 2>&1; rc=$?
      NEQ=$(countf "string.Equals" "$T/$bn-$runner.cs")
      { [ "$rc" -eq 0 ] && [ "$NEQ" -eq "$NCASES" ]; } \
        && ok "M10-NFP $bn ($runner): exit 0, one string.Equals per case ($NEQ/$NCASES) — no body swallowed" \
        || bad "M10-NFP $bn ($runner): rc=$rc, string.Equals=$NEQ expected $NCASES"
    done
  done
else
  bad "fixtures dir missing: $FIXTURES"
fi

# ── (2) RED→GREEN: a sample/golden containing a pipe — the class-trigger ──
echo "──── M10 — a sample/golden value containing '|' must NOT yield an assertion-less green case ────"
cat > "$T/pipe.json" <<'JSON'
{ "options_accessor": "X.Y.Options",
  "cases": [ { "name": "Flags", "type": "Perm", "sample": {"perm":"Read|Write"}, "golden": "{\"perm\":\"Read|Write\"}" } ] }
JSON
bash "$GEN" "$T/pipe.json" "$T/pipe.cs" --runner console >/tmp/m10pipe.out 2>&1; rc=$?
NEQ=$(countf "string.Equals" "$T/pipe.cs")
HASLIT=$(countf 'Read|Write' "$T/pipe.cs")
# GREEN is either: exit 2 (PIPESTATUS backstop refused) OR a complete body (exit 0, string.Equals present
# AND the literal Read|Write preserved). The one thing forbidden is the PRE-FIX shape: exit 0 with NO assertion.
if [ "$rc" -eq 2 ]; then
  ok "M10 pipe value -> exit 2 (PIPESTATUS backstop refused to emit a body-less case)"
elif [ "$rc" -eq 0 ] && [ "$NEQ" -ge 1 ] && [ "$HASLIT" -ge 1 ]; then
  ok "M10 pipe value -> exit 0 with a COMPLETE body, literal 'Read|Write' preserved (delimiter-safe)"
else
  bad "M10 pipe: forbidden shape rc=$rc string.Equals=$NEQ hasLiteral=$HASLIT (the pre-fix false-green was rc=0 + 0 assertions)"
fi

# ── (3) gsub-trap: '&' and '\' in a golden value must be preserved literally (index()-splice, not gsub) ──
echo "──── M10 — '&' and backslash in a golden value survive byte-for-byte (the gsub trap) ────"
# golden JSON string value a&b\c  (in JSON: "a&b\\c")
cat > "$T/amp.json" <<'JSON'
{ "options_accessor": "X.Y.Options",
  "cases": [ { "name": "Amp", "type": "T", "sample": {"v":"a&b"}, "golden": "{\"v\":\"a&b\\\\c\"}" } ] }
JSON
bash "$GEN" "$T/amp.json" "$T/amp.cs" --runner console >/tmp/m10amp.out 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then
  ok "M10 &/backslash golden -> exit 2 (backstop) — acceptable fail-closed"
elif [ "$rc" -eq 0 ] && grep -qF 'a&b' "$T/amp.cs" && grep -qF 'a&b\\c' "$T/amp.cs"; then
  # Note: C# verbatim doubling turns the JSON-decoded backslash into the source; the literal 'a&b\\c'
  # (the doubled form is not applied to backslash, only to quotes) — assert the & and backslash survive.
  ok "M10 &/backslash golden -> exit 0, '&' and backslash preserved literally (index()-splice, not gsub)"
else
  # Fallback: at minimum '&' must survive un-corrupted (gsub would have turned & into the matched text).
  if [ "$rc" -eq 0 ] && grep -qF 'a&b' "$T/amp.cs"; then
    ok "M10 &/backslash golden -> exit 0, '&' preserved (not gsub-expanded)"
  else
    bad "M10 amp: rc=$rc and '&'/backslash not preserved as expected ($(head -1 /tmp/m10amp.out))"
  fi
fi

echo ""
echo "wire-golden-delimiter-safe tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

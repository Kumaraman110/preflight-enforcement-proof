#!/usr/bin/env bash
# Behavioral test for the adjudication-output-gate citation regex (M2).
#
# THE BUG (FRAMEWORK-SCRUTINY-FINDINGS / MEDIUM-FIXES-DESIGN M2): the citedEvidence CITES regex was
# simultaneously too LOOSE and too TIGHT.
#   - too loose: the file:line branch `\.[A-Za-z0-9]+:[0-9]+` matched ANY word:digit token, so a DEFENDED
#     verdict citing prose with a ratio ("2.5:1"), version ("v1.2:3"), or timestamp ("2024.10:00") PASSED
#     (exit 0) with no real citation — a SAFETY-false-green.
#   - too tight: the rule-id branch `§[0-9]+` REJECTED a genuine letter-prefixed rule id (§G2.1, §M4.3,
#     §D1, §M3) that actually appears in the repo (FRAMEWORK.md, scan-profiles, rubric-edit-process).
#
# THE FIX (M2): file:line branch anchored to a real source/spec extension allow-list at a token boundary;
# rule branch widened to §[A-Za-z]*[0-9][A-Za-z0-9.]*. Named-artifact branches unchanged. Lexical gate
# (a file:line-shaped token suffices; substantive support is the downstream human-audit layer).
#
# NFP artifacts are drawn from REAL repo locations (re-derived read-only), NOT crafted-to-flatter:
#   genuine file:line — Legacy/SessionTokenService.cs:142 (tests/fixtures/.../PR99-abc1234.json),
#                       lib/resolve-config.sh:58 (CLAUDE.md), TokenService.cs:142 (deck/demo).
#   genuine §-ids     — §G2.1 / §M4.3 (FRAMEWORK.md:125-126), §D1 (scan-profiles), §M3 (rubric-edit-process),
#                       §17 / §2.2 (digit ids — must still work).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$ROOT/hooks/adjudication-output-gate"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

[ -f "$GATE" ] || { bad "missing $GATE"; echo ""; echo "adjudication-citation-regex tests: ${PASS} passed, ${FAIL} failed"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node required (gate fails closed without it)"; echo ""; echo "adjudication-citation-regex tests: ${PASS} passed, ${FAIL} failed"; exit 0; }

# Build a Write-tool stdin for an adjudication record with a single DEFENDED entry citing $1.
# JSON-escape the citation: backslash then double-quote (none of our citations contain backslashes).
defended() {
  local cite="$1"; local esc="${cite//\"/\\\"}"
  printf '{"tool_name":"Write","tool_input":{"file_path":".preflight/adjudications/pr-1.json","content":"{\\"adjudications\\":[{\\"commentId\\":\\"c1\\",\\"parentVerdict\\":\\"DEFENDED\\",\\"citedEvidence\\":\\"%s\\"}]}"}}' "$esc"
}
# expect_exit <expected> <citation> <label>
expect_exit() {
  local want="$1" cite="$2" label="$3"
  defended "$cite" | bash "$GATE" >/tmp/m2_case.out 2>&1; local rc=$?
  [ "$rc" -eq "$want" ] && ok "$label (exit $rc)" || bad "$label: expected exit $want, got $rc ($(head -1 /tmp/m2_case.out))"
}

echo "════════ M2 — prose with a word:digit token must BLOCK (was a false-green allow) ════════"
expect_exit 2 "2.5:1 retry ratio"        "ratio prose 2.5:1 -> BLOCK"
expect_exit 2 "behaves at v1.2:3 in prod" "version prose v1.2:3 -> BLOCK"
expect_exit 2 "since 2024.10:00 deploy"   "timestamp prose 2024.10:00 -> BLOCK"
expect_exit 2 "verified manually"         "bare prose 'verified manually' -> BLOCK"
expect_exit 2 "reviewed it, looks fine"   "bare prose 'reviewed it, looks fine' -> BLOCK"

echo "──── M2 NFP: genuine file:line citations (REAL repo artifacts) must ALLOW (exit 0) ────"
expect_exit 0 "Legacy/SessionTokenService.cs:142" "real fixture file:line (.cs) -> ALLOW"
expect_exit 0 "lib/resolve-config.sh:58"          "real .sh file:line (CLAUDE.md) -> ALLOW"
expect_exit 0 "TokenService.cs:142"               "real demo file:line -> ALLOW"
expect_exit 0 "see path/Bar.java:88 for the cast" ".java file:line embedded in a sentence -> ALLOW"

echo "──── M2 NFP: genuine rule ids — letter-prefixed NEWLY accepted, digit ids still accepted ────"
expect_exit 0 "per rubric §G2.1"   "letter-prefix §G2.1 (FRAMEWORK.md) -> ALLOW (newly correct)"
expect_exit 0 "see §M4.3"          "letter-prefix §M4.3 (FRAMEWORK.md) -> ALLOW (newly correct)"
expect_exit 0 "scan-profile §D1"   "letter-prefix §D1 (scan-profiles) -> ALLOW (newly correct)"
expect_exit 0 "process §M3"        "letter-prefix §M3 no-dot (rubric-edit-process) -> ALLOW (newly correct)"
expect_exit 0 "rubric §17"         "digit id §17 -> ALLOW (unchanged)"
expect_exit 0 "rule §2.2"          "digit id §2.2 -> ALLOW (unchanged)"

echo "──── M2 NFP: named-artifact citations (unchanged branches) must ALLOW ────"
expect_exit 0 "per MIGRATION_PATTERNS.md"   "MIGRATION_PATTERNS.md -> ALLOW"
expect_exit 0 "behavior-spec-current.json"  "behavior-spec* -> ALLOW"
expect_exit 0 "the dependency-map.json"     "dependency-map.json -> ALLOW"
expect_exit 0 "legacy-db-name-contract"     "legacy-db-name-contract -> ALLOW"

echo ""
echo "adjudication-citation-regex tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

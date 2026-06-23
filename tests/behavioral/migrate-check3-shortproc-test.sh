#!/usr/bin/env bash
# Behavioral test for migrate Check-3 short-named REACHABLE proc fail-open (M15).
#
# THE BUG (MEDIUM-FIXES-DESIGN M15): Check-3's proc loop had `[ ${#PROC} -lt 5 ] && continue`, which
# dropped any contracted identifier under 5 chars from the existence check. A genuinely-absent REACHABLE
# proc like `usp` (3 chars) was never checked -> "CHECK 3 PASS" exit 0: a SAFETY-false-green. The skip was
# also asymmetric (proc loop only; the param loop never had it).
#
# THE FIX: (1) DELETE the `<5` skip; (2) replace the noisy `grep -oP '(?<=\| )...'` scrape (which harvested
# header words, reachability markers, and call-chain words from columns 2-3) with a STRUCTURED column-1
# extraction so deleting the length gate cannot spike false MISSING on a long call-chain word (CPSLToken).
# The denylist remains as a backstop for a stray column-1 header.
#
# This test runs the REAL shipped Check-3 snippet, extracted from skills/migrate/SKILL.md (the ```bash block
# containing "CHECK 3"), against crafted name-contracts whose rows use the documented format example
# (SKILL.md: `| <proc> | REACHABLE|NOT REACHABLE | <path> |`).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL="$ROOT/skills/migrate/SKILL.md"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

[ -f "$SKILL" ] || { bad "missing $SKILL"; echo ""; echo "migrate-check3-shortproc tests: ${PASS} passed, ${FAIL} failed"; exit 1; }

WORK="$(mktemp -d)"
SNIP="$WORK/check3.sh"

# Extract the ```bash fenced block whose body contains "CHECK 3" (the Check-3 reconciliation snippet).
awk '
  /^```bash$/ { inblk=1; buf=""; next }
  /^```$/     { if (inblk) { if (buf ~ /CHECK 3/) { printf "%s", buf; exit } inblk=0 } next }
  inblk       { buf = buf $0 "\n" }
' "$SKILL" > "$SNIP"

[ -s "$SNIP" ] || { bad "could not extract the Check-3 bash block from $SKILL"; echo ""; echo "migrate-check3-shortproc tests: ${PASS} passed, ${FAIL} failed"; exit 1; }
bash -n "$SNIP" || { bad "extracted Check-3 block has a bash syntax error"; echo ""; echo "migrate-check3-shortproc tests: ${PASS} passed, ${FAIL} failed"; exit 1; }

# run_check3 <contract-markdown> <migrated-source-content> -> sets RC, OUT.
# The snippet expects: SERVICE_NAME, SERVICE_DIR, and a CONTRACT at .preflight/$SERVICE_NAME/legacy-db-name-contract.md.
run_check3() {
  local contract="$1" src="$2"
  local d; d="$(mktemp -d)"
  mkdir -p "$d/.preflight/svc" "$d/src"
  printf '%s\n' "$contract" > "$d/.preflight/svc/legacy-db-name-contract.md"
  printf '%s\n' "$src" > "$d/src/Service.cs"
  OUT="$(cd "$d" && SERVICE_NAME="svc" SERVICE_DIR="src" bash "$SNIP" 2>&1)"; RC=$?
}

# The documented format-example rows (SKILL.md) + a synthetic 3-char REACHABLE `usp` repro row + a header.
CONTRACT_WITH_USP='# Legacy DB name contract

| Name | Reachable | Path |
| --- | --- | --- |
| cpsl_setCCToken_v2 | REACHABLE | CPSLToken controller -> Token Manager -> CreateSessionToken -> proc |
| cpsl_setMPToken_v1 | NOT REACHABLE | Only via SharedServicesController (gated IsMPToken=true; CPSLToken never sets this). Exists in shared DB layer. |
| usp | REACHABLE | CPSLToken controller -> repo -> usp |'

# A migrated source that IMPLEMENTS the long reachable proc but NOT `usp`.
SRC_NO_USP='public class Service { void M() { var x = "cpsl_setCCToken_v2"; } }'
# A migrated source that implements BOTH.
SRC_WITH_USP='public class Service { void M() { var a = "cpsl_setCCToken_v2"; var b = "usp"; } }'

echo "════════ M15 — a genuinely-absent REACHABLE short proc (usp, 3 chars) must FAIL Check 3 ════════"
run_check3 "$CONTRACT_WITH_USP" "$SRC_NO_USP"
{ [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qi 'MISSING' && printf '%s' "$OUT" | grep -qw 'usp' && printf '%s' "$OUT" | grep -qi 'CHECK 3 FAIL'; } \
  && ok "M15 absent REACHABLE 'usp' -> CHECK 3 FAIL exit 1, names usp (was a false-green PASS)" \
  || bad "M15 usp-absent: expected FAIL+exit1 naming usp, got RC=$RC ($(printf '%s' "$OUT" | grep -i 'CHECK 3\|MISSING' | head -1))"

echo "──── M15 NO-FALSE-POSITIVE: header words and call-chain words must NOT be reported MISSING ────"
run_check3 "$CONTRACT_WITH_USP" "$SRC_WITH_USP"
# With both real procs + usp present, the ONLY identifiers checked should be the three column-1 procs;
# header 'Name' and call-chain 'CPSLToken'/'NOT'/'Only' must not appear as MISSING.
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qi 'CHECK 3 PASS'; then
  ok "M15-NFP all REACHABLE present (incl. usp) -> CHECK 3 PASS exit 0"
else
  bad "M15-NFP all-present: expected PASS+exit0, got RC=$RC ($(printf '%s' "$OUT" | grep -i 'MISSING\|CHECK 3' | head -2 | tr '\n' ' '))"
fi
# Explicit: no header/chain-word false MISSING even when usp is absent (the RC=1 case above).
run_check3 "$CONTRACT_WITH_USP" "$SRC_NO_USP"
NOISE="$(printf '%s' "$OUT" | grep -i 'MISSING' | grep -iE "'(Name|Reachable|Path|CPSLToken|NOT|Only|controller|repo|proc)'" || true)"
[ -z "$NOISE" ] \
  && ok "M15-NFP no header/marker/call-chain word reported MISSING (structured column-1 extraction holds)" \
  || bad "M15-NFP noise: a non-proc token was reported MISSING -> $NOISE"

echo "──── M15 regression: a long absent REACHABLE proc still FAILs; NOT-REACHABLE short proc skipped ────"
# Long absent REACHABLE proc -> MISSING (unchanged behavior).
CONTRACT_LONG_ABSENT='| Name | Reachable | Path |
| --- | --- | --- |
| cpsl_setCCToken_v2 | REACHABLE | CPSLToken -> proc |'
run_check3 "$CONTRACT_LONG_ABSENT" 'public class S { void M() {} }'
{ [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qw 'cpsl_setCCToken_v2'; } \
  && ok "M15-reg long absent REACHABLE proc -> CHECK 3 FAIL (unchanged)" \
  || bad "M15-reg long-absent: expected FAIL naming cpsl_setCCToken_v2, got RC=$RC"
# A short NOT-REACHABLE proc (usp marked NOT REACHABLE) absent from source -> correctly SKIPPED (PASS).
CONTRACT_USP_NR='| Name | Reachable | Path |
| --- | --- | --- |
| cpsl_setCCToken_v2 | REACHABLE | CPSLToken -> proc |
| usp | NOT REACHABLE | gated; never reached from this entry point |'
run_check3 "$CONTRACT_USP_NR" 'public class S { void M() { var a = "cpsl_setCCToken_v2"; } }'
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qi 'CHECK 3 PASS'; } \
  && ok "M15-reg short NOT-REACHABLE 'usp' absent -> correctly SKIPPED, CHECK 3 PASS (length-independent membership)" \
  || bad "M15-reg usp-NR: expected PASS+exit0, got RC=$RC ($(printf '%s' "$OUT" | grep -i 'MISSING\|CHECK 3' | head -2 | tr '\n' ' '))"

echo "──── M15 HEADING-FORM (adversarial-found defect): a REACHABLE proc declared ONLY as a ### heading ────"
# The contract is dual-format — procs appear as table rows AND as ### `<proc>` headings (the param-exclusion
# sed depends on the heading form). A REACHABLE heading-only proc absent from source must FAIL Check 3.
# Kill-shot: heading-only, NO params (so the param loop cannot incidentally rescue it), absent from source.
CONTRACT_HEADING_ONLY='# Legacy DB name contract

| Name | Reachable | Path |
| --- | --- | --- |
| cpsl_setCCToken_v2 | REACHABLE | controller -> proc |

## Parameter detail

### `usp_HeadingOnlyReachable`
REACHABLE — controller -> repo -> usp_HeadingOnlyReachable (no params)'
run_check3 "$CONTRACT_HEADING_ONLY" 'public class S { void M() { var a = "cpsl_setCCToken_v2"; } }'
{ [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qw 'usp_HeadingOnlyReachable' && printf '%s' "$OUT" | grep -qi 'CHECK 3 FAIL'; } \
  && ok "M15 heading-only REACHABLE proc absent -> CHECK 3 FAIL naming it (dual-format bypass closed)" \
  || bad "M15 heading-only: expected FAIL+exit1 naming usp_HeadingOnlyReachable, got RC=$RC ($(printf '%s' "$OUT" | grep -i 'CHECK 3\|MISSING' | head -1))"

# Heading-form proc PRESENT in source -> PASS (no false MISSING on a heading proc that exists).
run_check3 "$CONTRACT_HEADING_ONLY" 'public class S { void M() { var a = "cpsl_setCCToken_v2"; var b = "usp_HeadingOnlyReachable"; } }'
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qi 'CHECK 3 PASS'; } \
  && ok "M15 heading-form REACHABLE proc PRESENT in source -> CHECK 3 PASS (no false MISSING)" \
  || bad "M15 heading-present: expected PASS+exit0, got RC=$RC"

# Heading-form NOT REACHABLE proc (NR marker ON THE HEADING LINE) absent from source -> correctly SKIPPED.
# Line-scoped NR detection: the documented skip form is the marker on the heading line itself.
CONTRACT_HEADING_NR='# Legacy DB name contract

| Name | Reachable | Path |
| --- | --- | --- |
| cpsl_setCCToken_v2 | REACHABLE | controller -> proc |

### `usp_HeadingNotReachable` (NOT REACHABLE)
only via SharedServicesController, gated; this entry point never reaches it'
run_check3 "$CONTRACT_HEADING_NR" 'public class S { void M() { var a = "cpsl_setCCToken_v2"; } }'
# Assert no MISSING line for it (it may legitimately appear in the "Skipping NOT REACHABLE items" echo).
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qi 'CHECK 3 PASS' && ! printf '%s' "$OUT" | grep -qi "MISSING: 'usp_HeadingNotReachable'"; } \
  && ok "M15 heading-line NOT-REACHABLE proc absent -> correctly SKIPPED (NR on heading line, no false MISSING)" \
  || bad "M15 heading-NR: expected PASS+exit0 with no MISSING for usp_HeadingNotReachable, got RC=$RC ($(printf '%s' "$OUT" | grep -i 'MISSING\|CHECK 3' | head -2 | tr '\n' ' '))"

echo "──── M15 SAFE-DIRECTION (adversarial round 2: heading-NR machinery must not re-open fail-OPEN holes) ────"
# DEFECT 1 (was fail-OPEN): incidental body-prose "NOT REACHABLE" must NOT skip a table-REACHABLE absent proc.
# Line-scoped NR (table row or heading line) only — body prose does not flip reachability. Over-flag is SAFE.
CONTRACT_BODY_PROSE_NR='| Name | Reachable | Path |
| --- | --- | --- |
| usp_RealProc | REACHABLE | controller -> proc |

### `usp_RealProc`
The @LegacyFlag branch is NOT REACHABLE from the new entry point, but the proc itself is reached.'
run_check3 "$CONTRACT_BODY_PROSE_NR" 'public class S { void M() {} }'
{ [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qw 'usp_RealProc'; } \
  && ok "M15 incidental body-prose 'NOT REACHABLE' does NOT skip a table-REACHABLE absent proc -> FAIL (was fail-OPEN)" \
  || bad "M15 body-prose-NR: expected FAIL naming usp_RealProc, got RC=$RC ($(printf '%s' "$OUT" | grep -i 'CHECK 3' | head -1))"

# DEFECT 3 (was fail-OPEN): the NEXT proc's heading-line NR marker must NOT bleed back to skip the prior proc.
CONTRACT_BLEED='### `usp_Prev`
REACHABLE — controller -> repo -> usp_Prev
### `usp_Next` (NOT REACHABLE)
gated; never reached'
run_check3 "$CONTRACT_BLEED" 'public class S { void M() {} }'
{ [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qw 'usp_Prev'; } \
  && ok "M15 next-heading NR marker does NOT bleed back to skip prior absent REACHABLE proc -> FAIL (was fail-OPEN)" \
  || bad "M15 NR-bleed: expected FAIL naming usp_Prev, got RC=$RC ($(printf '%s' "$OUT" | grep -i 'CHECK 3' | head -1))"

# DEFECT 2 (was fail-CLOSED): prose `### ` headings (no backticks) must NOT be treated as procs.
CONTRACT_PROSE_HEADINGS='| Name | Reachable | Path |
| --- | --- | --- |
| usp_Real | REACHABLE | controller -> proc |

### Overview
### Summary
### Reachability analysis'
run_check3 "$CONTRACT_PROSE_HEADINGS" 'public class S { void M() { var a = "usp_Real"; } }'
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qi 'CHECK 3 PASS' && ! printf '%s' "$OUT" | grep -qiE "MISSING: '(Overview|Summary|Reachability)'"; } \
  && ok "M15 prose '### ' headings (no backticks) NOT treated as procs -> no false MISSING (was fail-CLOSED)" \
  || bad "M15 prose-headings: expected PASS+exit0 with no header-word MISSING, got RC=$RC ($(printf '%s' "$OUT" | grep -i 'MISSING\|CHECK 3' | head -2 | tr '\n' ' '))"

echo ""
echo "migrate-check3-shortproc tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Behavioral test for the --check-blob-syntax structural blind spot (M9).
#
# THE GAP (FRAMEWORK-SCRUTINY-FINDINGS M9): --check-blob-syntax relied solely on `git show HEAD:f | bash -n`.
# A single-statement-per-line "N|" corruption — `1|#!/usr/bin/env bash\n2|echo hi\n3|exit 0` — is VALID bash
# grammar (command N piped into a comment) → bash -n rc=0, so the gate was blind to it. The shipped c0e01a4
# corruption only tripped because those hooks had multi-line control flow; the gate rested on an unenforced
# invariant.
#
# THE FIX: alongside bash -n, two structural assertions on the committed blob — (1) a line-prefix scan that
# flags head-1 being "N|"-prefixed OR >=2 consecutive ^[0-9]+\| lines; (2) a shebang sanity check (head-1
# must be "#!..."). Any of the three failing -> the gate records the file as dead.
#
# NO-FALSE-POSITIVE: a clean hook -> exit 0; a single incidental "N|" heredoc/table line (below the
# 2-consecutive threshold) -> exit 0; the multi-line c0e01a4 shape still -> exit 1.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PBC="$ROOT/lib/pre-branch-cut-check.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

[ -f "$PBC" ] || { bad "missing $PBC"; echo ""; echo "blob-syntax-nprefix tests: ${PASS} passed, ${FAIL} failed"; exit 1; }

# build_repo <hook-content-printf-fmt> -> sets REPO; commits a hooks/<name> extensionless executable.
# We commit into hooks/ with an extensionless basename so the gate's location filter scans it.
make_repo() {
  local content="$1" name="${2:-myhook}"
  local d; d="$(mktemp -d)/r"; mkdir -p "$d/hooks"
  printf '%b' "$content" > "$d/hooks/$name"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm c1 ) >/dev/null 2>&1
  REPO="$d"
}
run_gate() { ( cd "$REPO" && bash "$PBC" --check-blob-syntax ) >/tmp/m9.out 2>&1; RC=$?; }

echo "════════ M9 — N|-prefixed single-statement blob must be caught (structural, not just bash -n) ════════"
# A minimal script where EVERY line is N|-prefixed and bash -n alone passes (valid grammar).
make_repo '1|#!/usr/bin/env bash\n2|echo hi\n3|exit 0\n' nprefix-min
run_gate
{ [ "$RC" -eq 1 ] && grep -qi 'BLOB-SYNTAX GATE' /tmp/m9.out; } \
  && ok "M9 minimal N|-prefixed blob (bash -n passes) -> exit 1 (structural scan caught it)" \
  || bad "M9 nprefix-min: expected exit 1, got $RC ($(grep -i 'N|\|shebang\|BLOB' /tmp/m9.out | head -1))"

echo "──── M9 mangled shebang ────"
make_repo '1|#!/usr/bin/env bash\necho ok\n' bad-shebang
run_gate
[ "$RC" -eq 1 ] && ok "M9 mangled shebang '1|#!/...' -> exit 1" \
               || bad "M9 bad-shebang: expected exit 1, got $RC"

echo "──── M9 regression: the multi-line c0e01a4 shape still blocks ────"
# A control-flow script with every line N|-prefixed -> bash -n ALSO fails; must stay exit 1.
make_repo '1|#!/usr/bin/env bash\n2|if [ -z "$x" ]; then\n3|  echo a\n4|fi\n' c0e01a4-shape
run_gate
[ "$RC" -eq 1 ] && ok "M9 multi-line c0e01a4 shape -> exit 1 (regression: stays blocked)" \
               || bad "M9 c0e01a4-shape: expected exit 1, got $RC"

echo "──── M9 NO-FALSE-POSITIVE: a clean hook -> exit 0 ────"
make_repo '#!/usr/bin/env bash\nset -euo pipefail\necho hello\nexit 0\n' clean-hook
run_gate
{ [ "$RC" -eq 0 ] && grep -qi 'all shipped executables pass' /tmp/m9.out; } \
  && ok "M9-NFP clean hook -> exit 0 (passes bash -n + structural checks)" \
  || bad "M9-NFP clean: expected exit 0, got $RC ($(head -1 /tmp/m9.out))"

echo "──── M9 NO-FALSE-POSITIVE: a single incidental N| line (below threshold) -> exit 0 ────"
# One heredoc body line legitimately looks like "3|two"; only ONE such line, head-1 is a real shebang.
make_repo '#!/usr/bin/env bash\ncat <<EOF\n3|two\nplain line\nEOF\nexit 0\n' incidental-nprefix
run_gate
{ [ "$RC" -eq 0 ]; } \
  && ok "M9-NFP single incidental 'N|' heredoc line (below 2-consecutive threshold) -> exit 0" \
  || bad "M9-NFP incidental: expected exit 0, got $RC ($(grep -i 'N|\|BLOB' /tmp/m9.out | head -1))"

echo ""
echo "blob-syntax-nprefix tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

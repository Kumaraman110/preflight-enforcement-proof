#!/usr/bin/env bash
# Anti-tautology test lint — flags assertions that test code against its own
# values (issue #7).
#
# Usage: bash lib/anti-tautology-lint.sh <target-dir-or-file> [--json]
# Exit codes: 0 = clean, 1 = findings (ADVISORY, non-blocking), 2 = usage error
#
# ── MECHANISM (honest label) ─────────────────────────────────────────────────
# HEURISTIC LEXICAL lint, ADVISORY ONLY — a single-pass awk scan of
# comment-stripped assertion lines in TEST files. NOT static analysis: no
# symbol table, no dataflow, no knowledge of which class is "under test".
#
# WHAT IT CATCHES — the symbol-reference subset (per issue #7's honest split):
# an assertion line where the SAME class-like identifier (PascalCase token
# followed by '.') appears in BOTH argument positions, e.g.
#   Assert.Equal(ResultMessages.W0008, ResultMessages.GetMessage("W0008"))
#   ResultMessages.GetMessage("E1001").Should().Be(ResultMessages.E1001)
# This is the live PR #95 exhibit: generated ResultMessagesTests asserting the
# buggy map against the map's own constants — passing while wrong.
#
# DOCUMENTED FALSE-NEGATIVE BOUNDS (mechanically undecidable here, stay
# prompt-level per issue #7 — the behavioral test PINS these as misses):
#   - copied-literals: a human pastes the same wrong literal on both sides
#   - cross-line arguments: Assert.Equal(\n  X.A,\n  X.F()) — no same-line view
#   - var-indirection: var expected = Sut.X; Assert.Equal(expected, Sut.F())
#   - aliasing/using-static: the class reached under another name
# KNOWN FALSE-POSITIVE CLASS: a shared CONSTANTS class legitimately referenced
# on both sides (e.g. comparing two different members both via TestData.*).
# Findings are review prompts, not verdicts — hence ADVISORY/surface-only;
# wiring into a blocking gate is a human promotion decision.
#
# TEST-FILE SCOPE (filename heuristic): *Test.cs / *Tests.cs / *_test.py /
# *.test.ts|js / *.spec.ts|js. A tautology in a non-test file is out of scope.

set -uo pipefail

TARGET="${1:-}"
FORMAT="${2:-text}"

if [ -z "$TARGET" ]; then
  echo "Usage: $0 <target-dir-or-file> [--json]" >&2
  exit 2
fi
if [ ! -e "$TARGET" ]; then
  echo "ERROR: target '$TARGET' does not exist" >&2
  exit 2
fi

# ── Collect TEST files only ───────────────────────────────────────────────────
FILES=()
if [ -f "$TARGET" ]; then
  FILES=("$TARGET")
else
  while IFS= read -r -d '' f; do
    FILES+=("$f")
  done < <(find "$TARGET" -type f \( \
      -name "*Test.cs" -o -name "*Tests.cs" \
      -o -name "*_test.py" -o -name "test_*.py" \
      -o -name "*.test.ts" -o -name "*.test.js" \
      -o -name "*.spec.ts" -o -name "*.spec.js" \
    \) -print0 2>/dev/null)
fi

FILE_COUNT=${#FILES[@]}

# ── Single-pass awk scan ──────────────────────────────────────────────────────
# Finding line format: file <TAB> line <TAB> TAUTOLOGICAL_ASSERTION <TAB> code
read -r -d '' AWK_PROG <<'AWK' || true
function emit(text) {
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", text)
  gsub(/\t/, " ", text)
  printf "%s\t%d\tTAUTOLOGICAL_ASSERTION\t%s\n", FILENAME, FNR, text
}
{
  code = $0
  sub(/\r$/, "", code)
  sub(/\/\/.*$/, "", code)     # strip // comments
  sub(/#.*$/, "", code)        # strip # comments (py)

  # Only assertion lines.
  if (code !~ /Assert\.|\.Should\(\)|assertEquals|assertEqual|expect\(/) next

  # Split the line into the two "sides" of the comparison:
  #  - xunit-style: Assert.Equal(EXPECTED, ACTUAL)  → split at the top-level comma
  #  - fluent:      ACTUAL.Should().Be(EXPECTED)    → split at .Should()
  lhs = ""; rhs = ""
  if (code ~ /\.Should\(\)/) {
    split(code, parts, /\.Should\(\)/)
    lhs = parts[1]; rhs = parts[2]
  } else {
    # take the argument list of the first assert call
    p = index(code, "(")
    if (p == 0) next
    args = substr(code, p + 1)
    # split at the first comma at paren-depth 0 (string-aware enough: skip
    # commas inside quotes)
    depth = 0; cut = 0; inq = 0
    for (i = 1; i <= length(args); i++) {
      c = substr(args, i, 1)
      if (c == "\"" ) inq = !inq
      if (inq) continue
      if (c == "(") depth++
      else if (c == ")") { if (depth == 0) break; depth-- }
      else if (c == "," && depth == 0) { cut = i; break }
    }
    if (cut == 0) next
    lhs = substr(args, 1, cut - 1)
    rhs = substr(args, cut + 1)
  }
  if (lhs == "" || rhs == "") next

  # Mask string literals on each side so identifiers inside quotes don't count.
  gsub(/"[^"]*"/, "\"\"", lhs)
  gsub(/"[^"]*"/, "\"\"", rhs)

  # Collect class-like tokens (PascalCase identifier followed by '.') per side;
  # flag when the SAME token appears on both. Assert/Should/common framework
  # tokens are excluded.
  delete L
  s = lhs
  while (match(s, /[A-Z][A-Za-z0-9_]*\./)) {
    tok = substr(s, RSTART, RLENGTH - 1)
    if (tok !~ /^(Assert|Should|Be|Xunit|FluentAssertions|String|System|Math|Convert|Guid|DateTime|TimeSpan|Task|Console)$/)
      L[tok] = 1
    s = substr(s, RSTART + RLENGTH)
  }
  s = rhs
  while (match(s, /[A-Z][A-Za-z0-9_]*\./)) {
    tok = substr(s, RSTART, RLENGTH - 1)
    if (tok !~ /^(Assert|Should|Be|Xunit|FluentAssertions|String|System|Math|Convert|Guid|DateTime|TimeSpan|Task|Console)$/) {
      if (tok in L) { emit(code); next }
    }
    s = substr(s, RSTART + RLENGTH)
  }
}
AWK

RAW=""
if [ "$FILE_COUNT" -gt 0 ]; then
  RAW="$(awk "$AWK_PROG" "${FILES[@]}")" || { echo "ERROR: scan failed" >&2; exit 2; }
fi

FINDINGS_COUNT=0
if [ -n "$RAW" ]; then
  FINDINGS_COUNT=$(printf '%s\n' "$RAW" | grep -c .) || FINDINGS_COUNT=0
fi

if [ "$FORMAT" = "--json" ]; then
  printf '{\n'
  printf '  "scanned_files": %d,\n' "$FILE_COUNT"
  printf '  "findings_count": %d,\n' "$FINDINGS_COUNT"
  printf '  "findings": [\n'
  i=0
  if [ -n "$RAW" ]; then
    while IFS=$'\t' read -r f l t m; do
      [ -z "$f" ] && continue
      i=$((i + 1))
      comma=","
      [ "$i" -eq "$FINDINGS_COUNT" ] && comma=""
      f_esc="${f//\\/\\\\}"; f_esc="${f_esc//\"/\\\"}"
      m_esc="${m//\\/\\\\}"; m_esc="${m_esc//\"/\\\"}"
      printf '    {"file": "%s", "line": %s, "type": "%s", "message": "%s"}%s\n' \
        "$f_esc" "$l" "$t" "$m_esc" "$comma"
    done <<< "$RAW"
  fi
  printf '  ]\n'
  printf '}\n'
else
  echo "Anti-tautology lint: scanned $FILE_COUNT test files, $FINDINGS_COUNT findings"
  if [ -n "$RAW" ]; then
    while IFS=$'\t' read -r f l t m; do
      [ -z "$f" ] && continue
      echo "  $f:$l:$t:\"$m\""
    done <<< "$RAW"
  fi
fi

[ "$FINDINGS_COUNT" -eq 0 ] && exit 0 || exit 1

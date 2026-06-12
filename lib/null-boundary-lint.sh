#!/usr/bin/env bash
# Null-boundary lint — flags fail-open patterns at external boundaries (issue #8).
#
# Usage: bash lib/null-boundary-lint.sh <target-dir-or-file> [--json]
# Exit codes: 0 = clean, 1 = findings (SURFACE-ONLY, non-blocking), 2 = usage/IO error
#
# ── MECHANISM (honest label) ─────────────────────────────────────────────────
# This is a HEURISTIC lexical lint: a single-pass awk state machine over
# comment-stripped source lines. It is NOT static analysis — no AST, no type
# information, no dataflow. (A Roslyn analyzer would be the true-static path,
# but it belongs in a consumer's .NET build; this framework's stack is
# bash/jq/python and must run with no compiler present.)
#
# Detection heuristics (each one labeled, each one bounded):
#   - Boundary scope  = the FILENAME contains Controller|Handler|Middleware|
#     Repository|Service|Endpoint|Filter|Attribute|Validator|Validation.
#     Heuristic: a boundary method in a differently-named file is MISSED.
#   - Entry-point scope = empty-guard checks fire only inside methods whose
#     declared visibility is public (or undetermined). Heuristic: a private
#     helper reached from a public wrapper is MISSED; an internal method with
#     the defect is deliberately skipped (counter-example fixture).
#   - Same-line suppression = a null-check anywhere on the SAME line suppresses
#     the empty-guard finding — including a null-check of a DIFFERENT variable
#     (known false-negative class). The W0008 token check is stricter: only a
#     null-check of the Token(Status|State) itself suppresses.
#   - Permissive-default window = `if (...!<flag>Configured/Initialized/Loaded/
#     Ready...)` followed within 3 lines by `return true` (or same-line), plus
#     the single-line `return !_<flag>` form. MISSES `?? true`,
#     `GetValueOrDefault(true)`, windows longer than 3 lines, inverted flags.
#
# Detects three shapes (the SessionToken PR #95 class — one instance per
# stochastic review round, three rounds; hence this deterministic check):
#   1. EMPTY_GUARD_WITHOUT_NULL_CHECK — boundary string guard tests == "" /
#      == string.Empty / .Length == 0 with NO null check (a JSON-omitted field
#      deserializes to null, not "", and FAILS OPEN past the guard)
#   2. PERMISSIVE_DEFAULT_UNCONFIGURED — return !_dbConfigured / admit-all when
#      a dependency is unset (fail-open auth when the cache/DB is not configured)
#   3. W0008_STYLE_GUARD — Token(Status|State) == "" where null slips through
#
# ── INTEGRATION (surface-only, by design) ────────────────────────────────────
# Runnable standalone (this script) and exercised by
# tests/behavioral/null-boundary-lint-test.sh (wired into run-all-tests.sh).
# Deliberately NOT wired into any blocking PreToolUse gate or the fix-and-close
# pipeline — exit 1 is a report, not a block. Promotion into the Stage-1 flow /
# a scan-profile §D8 signal is a human decision (see issue #8).
#
# History: replaces a prior bash implementation that was PRESENT-BUT-DEAD —
# its case-patterns required `==""` with no whitespace (real code reads
# `== ""`), its permissive check was line-local (the live shape spans two
# lines), and per-line subprocess forks made it ~145s for 4 files on
# Windows/MSYS. It returned 0 findings on the known-bad fixtures (behavioral
# test: 1/10 passing). It was never proven RED-first — exactly the
# behavioral-cert failure mode CLAUDE.md rule 4 exists to prevent.

set -euo pipefail

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

# ── Collect files ─────────────────────────────────────────────────────────────
FILES=()
if [ -f "$TARGET" ]; then
  FILES=("$TARGET")
else
  while IFS= read -r -d '' f; do
    FILES+=("$f")
  done < <(find "$TARGET" -type f \( \
      -name "*.cs" -o -name "*.java" -o -name "*.py" -o -name "*.js" \
      -o -name "*.ts" -o -name "*.go" -o -name "*.rs" \
    \) -print0 2>/dev/null)
fi

FILE_COUNT=${#FILES[@]}

# ── Single-pass awk scan (one process for the whole tree) ────────────────────
# Output: TAB-separated  file <TAB> line <TAB> type <TAB> code-text
read -r -d '' AWK_PROG <<'AWK' || true
function emit(type, text) {
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", text)
  gsub(/\t/, " ", text)
  printf "%s\t%d\t%s\t%s\n", FILENAME, FNR, type, text
}
FNR == 1 {
  n = split(FILENAME, parts, /[\/\\]/)
  base = parts[n]
  is_boundary = (base ~ /(Controller|Handler|Middleware|Repository|Service|Endpoint|Filter|Attribute|Validator|Validation)/)
  vis = ""      # visibility of the enclosing method ("" until first decl seen)
  pend = 0      # open lines remaining in a permissive-if window
}
{
  code = $0
  sub(/\r$/, "", code)
  sub(/\/\/.*$/, "", code)        # strip // comments (heuristic; ignores strings)

  if (!is_boundary) next

  # Track enclosing-method visibility (heuristic: decl = visibility keyword +
  # parens, not a type declaration).
  if (code ~ /^[[:space:]]*(public|private|protected|internal)[[:space:]]/ \
      && code ~ /\(/ \
      && code !~ /(^|[[:space:]])(class|interface|struct|record|enum)([[:space:]]|$)/) {
    if      (code ~ /^[[:space:]]*public/)   vis = "public"
    else if (code ~ /^[[:space:]]*internal/) vis = "internal"
    else if (code ~ /^[[:space:]]*protected/) vis = "protected"
    else                                      vis = "private"
  }

  has_empty = (code ~ /==[[:space:]]*""/ || code ~ /==[[:space:]]*''/ \
            || code ~ /==[[:space:]]*[Ss]tring\.Empty/ \
            || code ~ /\.Length[[:space:]]*==[[:space:]]*0/)
  has_null  = (code ~ /IsNullOrEmpty|IsNullOrWhiteSpace/ \
            || code ~ /[!=]=[[:space:]]*null/ || code ~ /null[[:space:]]*[!=]=/ \
            || code ~ /\?\?/ \
            || code ~ /is[[:space:]]+(not[[:space:]]+)?null/ \
            || code ~ /Objects\.nonNull|Optional\.ofNullable/)

  # 1. Empty-only guard on a boundary entry point, no null check on the line.
  if (has_empty && !has_null && vis != "private" && vis != "internal" && vis != "protected")
    emit("EMPTY_GUARD_WITHOUT_NULL_CHECK", code)

  # 3. W0008-style: Token(Status|State) == ""/string.Empty; only a null check
  #    of the TOKEN ITSELF suppresses (a null check of another variable on the
  #    same line — the live RequestValidation.cs:44 shape — must NOT suppress).
  if (code ~ /[Tt]oken(Status|State)[[:space:]]*==[[:space:]]*(""|[Ss]tring\.Empty)/) {
    tok_null = (code ~ /[Tt]oken(Status|State)[[:space:]]*[!=]=[[:space:]]*null/ \
             || code ~ /IsNullOrEmpty[[:space:]]*\([^)]*[Tt]oken(Status|State)/ \
             || code ~ /IsNullOrWhiteSpace[[:space:]]*\([^)]*[Tt]oken(Status|State)/)
    if (!tok_null) emit("W0008_STYLE_GUARD", code)
  }

  # 2a. Single-line permissive default: return !_dbConfigured / !initialized...
  if (code ~ /return[[:space:]]+![_A-Za-z0-9]*([Cc]onfigured|[Ii]nitialized|[Ll]oaded|[Rr]eady)/)
    emit("PERMISSIVE_DEFAULT_UNCONFIGURED", code)

  # 2b. Two-line shape: `if (!<flag>Configured...)` then `return true` within
  #     a 3-line window. `return false` (fail-closed) closes the window clean.
  if (pend > 0) {
    if (code ~ /return[[:space:]]+true/) { emit("PERMISSIVE_DEFAULT_UNCONFIGURED", code); pend = 0 }
    else if (code ~ /return[[:space:]]+false/) pend = 0
    else pend--
  }
  if (code ~ /if[[:space:]]*\([^)]*![_A-Za-z0-9]*([Cc]onfigured|[Ii]nitialized|[Ll]oaded|[Rr]eady)/) {
    if (code ~ /return[[:space:]]+true/) emit("PERMISSIVE_DEFAULT_UNCONFIGURED", code)
    else pend = 3
  }
}
AWK

RAW=""
if [ "$FILE_COUNT" -gt 0 ]; then
  RAW="$(awk "$AWK_PROG" "${FILES[@]}")" || { echo "ERROR: scan failed" >&2; exit 2; }
fi

# ── Output ────────────────────────────────────────────────────────────────────
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
  echo "Null-boundary lint: scanned $FILE_COUNT files, $FINDINGS_COUNT findings"
  if [ -n "$RAW" ]; then
    while IFS=$'\t' read -r f l t m; do
      [ -z "$f" ] && continue
      echo "  $f:$l:$t:\"$m\""
    done <<< "$RAW"
  fi
fi

[ "$FINDINGS_COUNT" -eq 0 ] && exit 0 || exit 1

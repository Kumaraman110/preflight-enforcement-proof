#!/usr/bin/env bash
# spec-integrity-check.sh — Mechanical anti-forgery check for behavior-spec.json
#
# Verifies that a behavior spec is CONSISTENT with its source code in both directions:
#   spec→source: every anchor claimed in the spec actually exists in the source
#   source→spec: every anchor emitted in the source is represented in the spec
#
# The second direction is the FORGE-CATCH: if an agent edits the spec to remove a
# behavior (to make parity pass), the code still contains the anchor. This script
# detects the inconsistency.
#
# Usage: spec-integrity-check.sh <behavior-spec.json> <source-directory>
#
# Exit codes:
#   0 = consistent (all anchors match in both directions)
#   1 = inconsistency found (details printed to stdout)
#   2 = usage error (missing args, file not found)
#
# Anchor types checked (mechanical only — no semantic judgment):
#   a. result_code: [EWS]\d{4} patterns
#   b. wire_contract: property names on model classes
#   c. proc names: stored procedure name literals
#   d. routes: endpoint route attributes
#
# HEURISTIC FOR "EMITTED" RESULT CODES:
#   A result code in source is considered "emitted" if it appears on a line that is NOT:
#     - A pure comment line (starts with // or * after whitespace)
#     - An XML doc comment (starts with ///)
#     - A log-only call (line contains .Log, _logger, LogDebug, LogInformation, etc.)
#   AND the line contains the code in a context suggesting assignment or definition:
#     - ResultCode = "X0000"
#     - case "X0000":
#     - => "X0000" (switch expression)
#     - new ... { ResultCode = "X0000" }
#     - .Contains("X0000")
#     - GetMessage("X0000") — defines the code in a helper
#
#   The heuristic errs toward inclusion for the forge-critical direction.

set -uo pipefail

SPEC="${1:-}"
SOURCE_DIR="${2:-}"

if [ -z "$SPEC" ] || [ -z "$SOURCE_DIR" ]; then
  echo "Usage: spec-integrity-check.sh <behavior-spec.json> <source-directory>" >&2
  exit 2
fi

if [ ! -f "$SPEC" ]; then
  echo "ERROR: Spec file not found: $SPEC" >&2
  exit 2
fi

if [ ! -d "$SOURCE_DIR" ]; then
  echo "ERROR: Source directory not found: $SOURCE_DIR" >&2
  exit 2
fi

# (M4) Compute the .cs-presence fact ONCE — the single source for "can we read source to verify against".
# The source-anchor extraction below is gated on this. PRE-FIX, each category inlined this `find` guard,
# so a SOURCE_DIR that exists but holds ZERO .cs files (wrong/mistyped-but-real path, partial/shallow
# checkout, non-.NET target) left every SOURCE_* empty -> BOTH directions skipped -> "PASSED" exit 0:
# "nothing to compare" read as "verified" (a silent fail-open of an anti-forgery check). With HAS_CS=false
# AND a spec that DECLARES an anchor of a type, we now emit a could-not-verify FAIL per category (below),
# so an unverifiable spec FAILS rather than passing green.
HAS_CS=false
if find "$SOURCE_DIR" -name '*.cs' -print -quit 2>/dev/null | grep -q .; then HAS_CS=true; fi

FAILURES=0
FAILURE_DETAILS=""

fail() {
  FAILURES=$((FAILURES + 1))
  FAILURE_DETAILS="${FAILURE_DETAILS}FAIL: $1
"
}

# ═══════════════════════════════════════════════════════════════════════════════
# (a) RESULT CODES
# ═══════════════════════════════════════════════════════════════════════════════

# Extract result codes from spec
SPEC_CODES=$(grep -oE '[EWS][0-9]{4}' "$SPEC" | sort -u || true)

# (M4) Could-not-verify: the spec DECLARES result codes but the source has no .cs to check them against.
if [ "$HAS_CS" = false ] && [ -n "$SPEC_CODES" ]; then
  fail "result_code could-not-verify: spec declares result codes but the source scan found ZERO .cs files under '$SOURCE_DIR' — cannot confirm consistency (treated as FAIL, not verified)"
fi

# Find emitted result codes in source
SOURCE_CODES=""
if [ "$HAS_CS" = true ]; then
  # Get all lines with result-code pattern in .cs files
  ALL_CODE_LINES=$(grep -rn --include="*.cs" -E '[EWS][0-9]{4}' "$SOURCE_DIR" 2>/dev/null || true)

  # Filter: keep lines that are NOT pure comments and NOT pure log calls
  # grep -rn output format is "filepath:linenum:content"
  # We strip to content and test, but pass the whole line for code extraction
  # Strategy: use awk to extract content portion and test it
  EMITTED_LINES=$(echo "$ALL_CODE_LINES" | awk -F: '{
    # Reconstruct content after file:linenum:
    content = ""
    for (i=3; i<=NF; i++) content = content (i>3 ? ":" : "") $i
    # Strip leading whitespace for pattern matching
    gsub(/^[[:space:]]+/, "", content)
    # Skip pure comment lines
    if (content ~ /^\/\//) next
    if (content ~ /^\/\*/) next
    if (content ~ /^\*/) next
    # Skip log-only lines
    if (content ~ /\.(Log|LogDebug|LogInformation|LogWarning|LogError)\(/) next
    # Pass through
    print $0
  }' || true)

  # Also include lines from result-message helpers (case/switch/GetMessage define codes)
  HELPER_LINES=$(echo "$ALL_CODE_LINES" | grep -E '(GetMessage|case "|=> ")' || true)

  COMBINED_LINES=$(printf '%s\n%s' "$EMITTED_LINES" "$HELPER_LINES" | sort -u)
  SOURCE_CODES=$(echo "$COMBINED_LINES" | grep -oE '[EWS][0-9]{4}' | sort -u || true)
fi

# Direction 1: spec→source
if [ -n "$SPEC_CODES" ]; then
  while IFS= read -r code; do
    [ -z "$code" ] && continue
    if [ -n "$SOURCE_CODES" ]; then
      if ! echo "$SOURCE_CODES" | grep -qx "$code"; then
        fail "result_code spec→source: '$code' claimed in spec but NOT found emitted in source"
      fi
    fi
  done <<< "$SPEC_CODES"
fi

# Direction 2: source→spec — THE FORGE-CATCH
# (H5) NO inner [ -n "$SPEC_CODES" ] guard: the catch must fire whenever the SOURCE emits codes, regardless
# of whether the SPEC declares any. An empty/empty-category spec is the MOST aggressive forge (drop the
# whole category to dodge parity) — pre-fix the inner guard SKIPPED the catch on exactly that input, so an
# empty SPEC_CODES passed GREEN. Now an empty SPEC_CODES means "EVERY source code is missing from spec" and
# each one fails (grep -qx against an empty list never matches), which is the correct fail-closed behavior.
if [ -n "$SOURCE_CODES" ]; then
  while IFS= read -r code; do
    [ -z "$code" ] && continue
    if ! echo "$SPEC_CODES" | grep -qx "$code"; then
      fail "result_code source→spec: '$code' emitted in source but MISSING from spec (possible forge)"
    fi
  done <<< "$SOURCE_CODES"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# (b) WIRE CONTRACT (property names)
# ═══════════════════════════════════════════════════════════════════════════════

# Extract wire field names from spec ("field": "Name" patterns)
SPEC_FIELDS=$(grep -oE '"field"[[:space:]]*:[[:space:]]*"[^"]+"' "$SPEC" 2>/dev/null | \
  grep -oE '"[A-Z][a-zA-Z]*"$' | tr -d '"' | sort -u || true)
# Fallback: also grab PascalCase keys from "fields" objects
SPEC_FIELDS_ALT=$(grep -oE '"[A-Z][a-zA-Z]+"[[:space:]]*:[[:space:]]*"(string|int|bool|List)' "$SPEC" 2>/dev/null | \
  grep -oE '^"[A-Z][a-zA-Z]+"' | tr -d '"' | sort -u || true)
SPEC_FIELDS=$(printf '%s\n%s' "$SPEC_FIELDS" "$SPEC_FIELDS_ALT" | sort -u | grep -v '^$' || true)

# (M4) Could-not-verify: the spec DECLARES wire fields but the source has no .cs to check them against.
if [ "$HAS_CS" = false ] && [ -n "$SPEC_FIELDS" ]; then
  fail "wire_contract could-not-verify: spec declares wire fields but the source scan found ZERO .cs files under '$SOURCE_DIR' — cannot confirm consistency (treated as FAIL, not verified)"
fi

# Find public properties on model/response/request classes
MODEL_FIELDS=""
if [ "$HAS_CS" = true ]; then
  MODEL_FILES=$(find "$SOURCE_DIR" \( -name '*Response*.cs' -o -name '*Request*.cs' -o -name '*Model*.cs' \) 2>/dev/null | grep -v '/obj/' | grep -v '/bin/' || true)
  if [ -n "$MODEL_FILES" ]; then
    # (M7) Drop TYPE-DECLARATION lines BEFORE harvesting a field name. The property regex
    # `public <type-token> <Name> {` also matches a K&R same-line-brace declaration like
    # `public class TokenResponse {` — taking the keyword `class` as the type-token and `TokenResponse`
    # as a phantom "field". With H5's now-active source→spec catch, that phantom false-FAILs an honest
    # spec (the class name is never a wire field, so it can't be in SPEC_FIELDS). The negative-match
    # removes any line whose type-position token is a declaration keyword (class/interface/struct/enum/
    # record, with optional modifiers). The trailing `\b` keeps a REAL field whose TYPE merely STARTS with
    # a keyword (`public ClassRoom Building {`, `public Record Recorder {`) — those survive and are still
    # checked. After M7, MODEL_FIELDS = exactly the real-property set, which is what H5 should police.
    # (rc.5 D5 fix) Iterate MODEL_FILES per-line with a QUOTED path, not `echo "$MODEL_FILES" | xargs grep`.
    # The old pipeline word-split any SOURCE_DIR path containing a SPACE or backslash (common on Windows, e.g.
    # `C:\Users\Name\My Project\…`), handing grep broken path fragments → grep found nothing → MODEL_FIELDS
    # empty → the Direction-2 source→spec forge-catch below silently never fired (a fail-open in the wire-
    # contract integrity check). `find` emits one path per line; reading each quoted path is space/backslash-
    # proof. (A path containing a literal newline is not a real .cs source layout; not a concern here.)
    MODEL_FIELDS=$(while IFS= read -r _mf; do
        [ -n "$_mf" ] && grep -hE 'public[[:space:]]+[A-Za-z<>?]+[[:space:]]+[A-Z][a-zA-Z]+[[:space:]]*\{' "$_mf" 2>/dev/null
      done <<< "$MODEL_FILES" | \
      grep -vE 'public[[:space:]]+(abstract[[:space:]]+|sealed[[:space:]]+|partial[[:space:]]+|static[[:space:]]+)*(class|interface|struct|enum|record)\b' | \
      sed -E 's/.*public[[:space:]]+[A-Za-z<>?]+[[:space:]]+([A-Z][a-zA-Z]+)[[:space:]]*\{.*/\1/' | \
      sort -u || true)
  fi
fi

# Direction 1: spec→source
if [ -n "$SPEC_FIELDS" ] && [ -n "$MODEL_FIELDS" ]; then
  while IFS= read -r field; do
    [ -z "$field" ] && continue
    if ! echo "$MODEL_FIELDS" | grep -qx "$field"; then
      fail "wire_contract spec→source: field '$field' claimed in spec but no matching property in source models"
    fi
  done <<< "$SPEC_FIELDS"
fi

# Direction 2: source→spec — THE FORGE-CATCH
# (H5) NO inner [ -n "$SPEC_FIELDS" ] guard — fire whenever SOURCE models expose properties (MODEL_FIELDS
# non-empty), regardless of whether the spec declares any. An empty SPEC_FIELDS means every source property
# is missing from spec (the dropped-category forge), which now correctly fails. (MODEL_FIELDS non-empty is
# the SOURCE-side iteration guard — kept; with no source properties there is nothing to forge-check.)
if [ -n "$MODEL_FIELDS" ]; then
  while IFS= read -r field; do
    [ -z "$field" ] && continue
    if ! echo "$SPEC_FIELDS" | grep -qx "$field"; then
      fail "wire_contract source→spec: property '$field' on model/response class but MISSING from spec (possible forge)"
    fi
  done <<< "$MODEL_FIELDS"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# (c) STORED PROCEDURE NAMES
# ═══════════════════════════════════════════════════════════════════════════════

# Extract proc names from spec
SPEC_PROCS=$(grep -oE '"(cpsl_|sp_|fn_)[a-zA-Z0-9_]+"' "$SPEC" 2>/dev/null | tr -d '"' | sort -u || true)

# (M4) Could-not-verify: the spec DECLARES proc names but the source has no .cs to check them against.
if [ "$HAS_CS" = false ] && [ -n "$SPEC_PROCS" ]; then
  fail "proc_name could-not-verify: spec declares proc names but the source scan found ZERO .cs files under '$SOURCE_DIR' — cannot confirm consistency (treated as FAIL, not verified)"
fi

# Find proc names in source
SOURCE_PROCS=""
if [ "$HAS_CS" = true ]; then
  SOURCE_PROCS=$(grep -rhE '"(cpsl_|sp_|fn_)[a-zA-Z0-9_]+"' "$SOURCE_DIR" --include="*.cs" 2>/dev/null | \
    grep -oE '(cpsl_|sp_|fn_)[a-zA-Z0-9_]+' | sort -u || true)
fi

# Direction 1: spec→source
if [ -n "$SPEC_PROCS" ] && [ -n "$SOURCE_PROCS" ]; then
  while IFS= read -r proc; do
    [ -z "$proc" ] && continue
    if ! echo "$SOURCE_PROCS" | grep -qix "$proc"; then
      fail "proc_name spec→source: '$proc' claimed in spec but NOT found in source"
    fi
  done <<< "$SPEC_PROCS"
fi

# Direction 2: source→spec — THE FORGE-CATCH
# (H5) NO inner [ -n "$SPEC_PROCS" ] guard — fire whenever SOURCE invokes procs, regardless of the spec.
# An empty SPEC_PROCS means every source proc is missing from spec (the dropped-category forge). (The
# SOURCE-side [ -n "$SOURCE_PROCS" ] guard is kept — with no source procs there is nothing to forge-check.)
if [ -n "$SOURCE_PROCS" ]; then
  while IFS= read -r proc; do
    [ -z "$proc" ] && continue
    if ! echo "$SPEC_PROCS" | grep -qix "$proc"; then
      fail "proc_name source→spec: '$proc' invoked in source but MISSING from spec (possible forge)"
    fi
  done <<< "$SOURCE_PROCS"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# (d) ENDPOINT ROUTES
# ═══════════════════════════════════════════════════════════════════════════════

# Extract routes from spec
SPEC_ROUTES=$(grep -oE '"path"[[:space:]]*:[[:space:]]*"[^"]+"' "$SPEC" 2>/dev/null | \
  grep -oE '"[a-z/][^"]*"$' | tr -d '"' | sort -u || true)

# (M4) Could-not-verify: the spec DECLARES routes but the source has no .cs to check them against.
if [ "$HAS_CS" = false ] && [ -n "$SPEC_ROUTES" ]; then
  fail "route could-not-verify: spec declares routes but the source scan found ZERO .cs files under '$SOURCE_DIR' — cannot confirm consistency (treated as FAIL, not verified)"
fi

# Find route segments from source attributes: [Route("x")], [HttpPost("x")], etc.
SOURCE_ROUTES=""
if [ "$HAS_CS" = true ]; then
  SOURCE_ROUTES=$(grep -rhE '\[(Route|HttpPost|HttpGet|HttpPut|HttpDelete|HttpPatch)\("[^"]+"\)' "$SOURCE_DIR" --include="*.cs" 2>/dev/null | \
    grep -oE '"[^"]+"' | tr -d '"' | sort -u || true)
fi

# Direction 1: spec→source (spec route segments must appear in source attributes)
if [ -n "$SPEC_ROUTES" ] && [ -n "$SOURCE_ROUTES" ]; then
  while IFS= read -r route; do
    [ -z "$route" ] && continue
    # Check if any source route segment is contained in this spec route
    FOUND=false
    while IFS= read -r src_seg; do
      [ -z "$src_seg" ] && continue
      if echo "$route" | grep -qF "$src_seg"; then
        FOUND=true
        break
      fi
    done <<< "$SOURCE_ROUTES"
    if [ "$FOUND" = false ]; then
      fail "route spec→source: '$route' claimed in spec but no matching route attribute in source"
    fi
  done <<< "$SPEC_ROUTES"
fi

# Direction 2: source→spec (source route segments must appear in some spec route)
# (H5) NO inner [ -n "$SPEC_ROUTES" ] guard — fire whenever SOURCE declares route attributes, regardless of
# the spec. An empty SPEC_ROUTES means no spec route can contain the segment, so FOUND stays false and the
# source route is flagged missing (the dropped-category forge). (SOURCE-side guard kept — no source routes,
# nothing to forge-check.)
if [ -n "$SOURCE_ROUTES" ]; then
  while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    FOUND=false
    while IFS= read -r spec_route; do
      [ -z "$spec_route" ] && continue
      if echo "$spec_route" | grep -qF "$seg"; then
        FOUND=true
        break
      fi
    done <<< "$SPEC_ROUTES"
    if [ "$FOUND" = false ]; then
      fail "route source→spec: route attribute '$seg' in source but MISSING from spec (possible forge)"
    fi
  done <<< "$SOURCE_ROUTES"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# VERDICT
# ═══════════════════════════════════════════════════════════════════════════════

if [ $FAILURES -gt 0 ]; then
  echo "SPEC INTEGRITY CHECK: FAILED ($FAILURES inconsistencies)"
  echo ""
  printf '%s' "$FAILURE_DETAILS"
  exit 1
else
  echo "SPEC INTEGRITY CHECK: PASSED (all mechanical anchors consistent)"
  exit 0
fi

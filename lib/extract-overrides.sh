#!/usr/bin/env bash
# Layer 3 — natural-language overrides from CLAUDE.md.
#
# Extracted mechanically by regex from a designated section. No LLM call.
# Future enhancement (step 2.5): heuristic + LLM fallback for ambiguous lines.
# Today: pure mechanical.
#
# Path-of-honesty: if the section is missing, no overrides are extracted;
# resolve-config falls through to derived state unchanged.
#
# Section format expected in CLAUDE.md:
#   ## Tool Overrides
#   testCommand: mvn verify
#   buildCommand: mvn package -DskipTests
#   packageManager: maven
#
# Lines within the section that match "^<fieldName>: <value>" are extracted.
# The section ends at the next "## " heading or EOF.
# Lines starting with # or <!-- are comments (skipped).
# Blank lines are skipped.
# Lines without a colon are malformed (warning emitted, skipped).
# Field names not in resolve-config.sh's registry are unrecognized (warning, skipped).
#
# Extraction limit: max 100 override lines processed. Beyond that, truncated
# with a warning. This bounds extraction time against adversarial inputs.
#
# Source this file; do not execute directly. Defines:
#   extract_overrides_from_claude_md [claude_md_path] [output_path]
#   overrides_are_fresh [overrides_path] [claude_md_path]

# ─── Dependencies ─────────────────────────────────────────────

_EXTRACT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source resolve-config for field registry access
if [ -z "${_RESOLVE_CONFIG_RESOLVABLE_FIELDS+x}" ]; then
  source "${_EXTRACT_SCRIPT_DIR}/resolve-config.sh"
fi

# ─── Constants ────────────────────────────────────────────────

_EXTRACT_SECTION_HEADING="## Tool Overrides"
_EXTRACT_MAX_LINES=100
_EXTRACT_DEFAULT_OUTPUT=".preflight/derived/overrides.json"

# ─── Helpers ──────────────────────────────────────────────────

_extract_sha256() {
  local file="$1"
  if command -v sha256sum &>/dev/null; then
    sha256sum "$file" 2>/dev/null | cut -d' ' -f1
  elif command -v shasum &>/dev/null; then
    shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1
  elif [ -n "$_RESOLVE_PYTHON_CMD" ]; then
    $_RESOLVE_PYTHON_CMD -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$file" 2>/dev/null
  else
    # Fallback: use file mtime as pseudo-hash (weak but functional)
    stat -c '%Y' "$file" 2>/dev/null || stat -f '%m' "$file" 2>/dev/null || echo "unknown"
  fi
}

_extract_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  echo "$s"
}

# ─── Public API ───────────────────────────────────────────────

# Extract overrides from CLAUDE.md's "## Tool Overrides" section.
# Writes JSON to output_path. Returns 0 on success, 1 on hard errors.
extract_overrides_from_claude_md() {
  local claude_md_path="${1:-./CLAUDE.md}"
  local output_path="${2:-$_EXTRACT_DEFAULT_OUTPUT}"

  if [ ! -f "$claude_md_path" ]; then
    echo "ERROR: CLAUDE.md not found at '$claude_md_path'" >&2
    return 1
  fi

  local head_sha=""
  head_sha=$(git rev-parse HEAD 2>/dev/null || echo "no-git")
  local claude_hash=""
  claude_hash=$(_extract_sha256 "$claude_md_path")
  local timestamp=""
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

  # Find the override section
  local in_section=false
  local line_count=0
  local overrides_json="{"
  local first_field=true

  while IFS= read -r line || [ -n "$line" ]; do
    # Detect section start
    if [ "$in_section" = false ]; then
      # Match section heading (case-sensitive, allow trailing whitespace)
      local trimmed="${line%%[[:space:]]}"
      if [[ "$line" =~ ^##[[:space:]]+Tool[[:space:]]+Overrides[[:space:]]*$ ]]; then
        in_section=true
      fi
      continue
    fi

    # In section: detect section end (next ## heading)
    if [[ "$line" =~ ^##[[:space:]] ]]; then
      break
    fi

    # Skip blank lines
    [ -z "${line// /}" ] && continue

    # Skip comment lines (# or <!-- -->)
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*\<\!-- ]] && continue

    # Enforce extraction limit
    line_count=$((line_count + 1))
    if [ "$line_count" -gt "$_EXTRACT_MAX_LINES" ]; then
      echo "WARNING: Override section exceeds $_EXTRACT_MAX_LINES lines; truncating." >&2
      break
    fi

    # Parse "fieldName: value" — require at least one colon
    if [[ ! "$line" =~ : ]]; then
      echo "WARNING: Malformed override line (no colon): '$line'" >&2
      continue
    fi

    # Split on first colon
    local field_name="${line%%:*}"
    local field_value="${line#*:}"

    # Trim whitespace from field name and value
    field_name="${field_name#"${field_name%%[![:space:]]*}"}"
    field_name="${field_name%"${field_name##*[![:space:]]}"}"
    field_value="${field_value#"${field_value%%[![:space:]]*}"}"
    field_value="${field_value%"${field_value##*[![:space:]]}"}"

    # Validate field name against registry
    if [ -z "$field_name" ]; then
      echo "WARNING: Malformed override line (empty field name): '$line'" >&2
      continue
    fi

    if ! is_field_resolvable "$field_name"; then
      echo "WARNING: Unregistered field '$field_name' in override section; skipping. Register it in lib/resolve-config.sh if intentional." >&2
      continue
    fi

    # Add to JSON
    local escaped_name escaped_value
    escaped_name=$(_extract_json_escape "$field_name")
    escaped_value=$(_extract_json_escape "$field_value")

    if [ "$first_field" = true ]; then
      first_field=false
    else
      overrides_json="$overrides_json,"
    fi
    overrides_json="$overrides_json \"$escaped_name\": \"$escaped_value\""

  done < "$claude_md_path"

  overrides_json="$overrides_json }"

  # Build full output JSON
  local escaped_head escaped_hash escaped_ts
  escaped_head=$(_extract_json_escape "$head_sha")
  escaped_hash=$(_extract_json_escape "$claude_hash")
  escaped_ts=$(_extract_json_escape "$timestamp")

  local output_json
  output_json=$(cat <<ENDJSON
{
  "extractedAtHEAD": "$escaped_head",
  "claudeMdHash": "$escaped_hash",
  "extractedAt": "$escaped_ts",
  "overrides": $overrides_json
}
ENDJSON
)

  # Write atomically
  mkdir -p "$(dirname "$output_path")"
  echo "$output_json" > "${output_path}.tmp" && mv "${output_path}.tmp" "$output_path"
  return 0
}

# Check if cached overrides are fresh.
# Returns 0 (fresh) if claudeMdHash matches current CLAUDE.md AND extractedAtHEAD matches current HEAD.
# Returns 1 (stale) otherwise.
overrides_are_fresh() {
  local overrides_path="${1:-$_EXTRACT_DEFAULT_OUTPUT}"
  local claude_md_path="${2:-./CLAUDE.md}"

  if [ ! -f "$overrides_path" ]; then
    return 1
  fi

  if [ ! -f "$claude_md_path" ]; then
    return 1
  fi

  local current_hash current_head cached_hash cached_head

  current_hash=$(_extract_sha256 "$claude_md_path")
  current_head=$(git rev-parse HEAD 2>/dev/null || echo "no-git")

  # Read cached values
  if command -v jq &>/dev/null; then
    cached_hash=$(jq -r '.claudeMdHash // ""' "$overrides_path" 2>/dev/null) || cached_hash=""
    cached_head=$(jq -r '.extractedAtHEAD // ""' "$overrides_path" 2>/dev/null) || cached_head=""
  elif [ -n "$_RESOLVE_PYTHON_CMD" ]; then
    cached_hash=$($_RESOLVE_PYTHON_CMD -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('claudeMdHash',''))" "$overrides_path" 2>/dev/null | tr -d '\r') || cached_hash=""
    cached_head=$($_RESOLVE_PYTHON_CMD -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('extractedAtHEAD',''))" "$overrides_path" 2>/dev/null | tr -d '\r') || cached_head=""
  else
    return 1
  fi

  if [ "$cached_hash" = "$current_hash" ] && [ "$cached_head" = "$current_head" ]; then
    return 0
  fi

  return 1
}

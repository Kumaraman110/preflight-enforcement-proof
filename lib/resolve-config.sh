#!/usr/bin/env bash
# Config resolution library — two-layer merge: explicit config + derived state.
#
# Built for future Decision C step 2/3 (Layer 3 overrides + skill wiring).
# No skill currently consumes this library. Adding a consumer is a separate
# deliberate decision.
#
# Precedence (locked):
#   1. Explicit config (.preflight/config.json) wins everything.
#   2. Derived state (.preflight/derived/state.json) fills gaps where config
#      is silent or missing.
#   3. [Future step 2: Layer 3 overrides slot BETWEEN config and derived.]
#
# Concurrency: not addressed. No consumer exists yet. When one is added,
# assess whether atomic reads or file-locking are needed.
#
# Source this file; do not execute directly. Defines:
#   resolve_field <name> [config_path] [derived_path]
#   resolve_field_with_source <name> [config_path] [derived_path]
#   is_field_resolvable <name>

# ─── Constants ────────────────────────────────────────────────

_RESOLVE_CONFIG_DEFAULT_CONFIG=".preflight/config.json"
_RESOLVE_CONFIG_DEFAULT_DERIVED=".preflight/derived/state.json"

# Fields that can be resolved from EITHER config or derived state.
# Config-only fields (rubric, capture, mode, branch, review, loop, migration)
# are NOT in this list and will warn if queried.
_RESOLVE_CONFIG_RESOLVABLE_FIELDS="stack buildCommand testCommand packageManager frameworkVersion sourceRoot projectFiles"

# ─── Internal helpers ─────────────────────────────────────────

# Detect a working Python interpreter (cached across calls)
if [ -z "${_RESOLVE_PYTHON_CMD+x}" ]; then
  _RESOLVE_PYTHON_CMD=""
  for _rc_py in python python3; do
    if command -v "$_rc_py" &>/dev/null; then
      if "$_rc_py" -c "pass" &>/dev/null 2>&1; then
        _RESOLVE_PYTHON_CMD="$_rc_py"
        break
      fi
    fi
  done
fi

# Extract a field value from a JSON file.
# For derived state: fields are objects with .value sub-key (except projectFiles which is an array).
# For config: fields may be top-level or nested (test.command → testCommand).
# Returns the raw string value, or empty if not found/null/empty.
_resolve_read_field() {
  local file="$1" field="$2" source_type="$3"

  if [ ! -f "$file" ]; then
    echo ""
    return
  fi

  if command -v jq &>/dev/null; then
    local result=""
    if [ "$source_type" = "derived" ]; then
      # Derived state: field is an object with .value, or an array (projectFiles)
      if [ "$field" = "projectFiles" ]; then
        result=$(jq -r 'if .projectFiles then (.projectFiles | if type == "array" then join("\n") else . end) else "" end' "$file" 2>/dev/null) || result=""
      else
        result=$(jq -r "if .[\"$field\"] then (if .[\"$field\"] | type == \"object\" then .[\"$field\"].value // \"\" else .[\"$field\"] // \"\" end) else \"\" end" "$file" 2>/dev/null) || result=""
      fi
    else
      # Config: check direct field, then known nested mappings
      case "$field" in
        testCommand)
          result=$(jq -r 'if .testCommand then .testCommand // "" elif .test and .test.command then .test.command // "" else "" end' "$file" 2>/dev/null) || result=""
          ;;
        buildCommand)
          result=$(jq -r 'if .buildCommand then .buildCommand // "" elif .build and .build.command then .build.command // "" else "" end' "$file" 2>/dev/null) || result=""
          ;;
        *)
          result=$(jq -r ".[\"$field\"] // \"\"" "$file" 2>/dev/null) || result=""
          ;;
      esac
    fi
    # Normalize: "null" string from jq → empty
    if [ "$result" = "null" ]; then
      echo ""
    else
      echo "$result"
    fi
  elif [ -n "$_RESOLVE_PYTHON_CMD" ]; then
    local result=""
    result=$($_RESOLVE_PYTHON_CMD -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except:
    print('')
    sys.exit(0)
field = sys.argv[2]
source_type = sys.argv[3]
if source_type == 'derived':
    if field == 'projectFiles':
        v = d.get('projectFiles', [])
        if isinstance(v, list):
            print('\n'.join(str(x) for x in v) if v else '')
        else:
            print(v if v else '')
    else:
        obj = d.get(field, {})
        if isinstance(obj, dict):
            v = obj.get('value', '')
            print(v if v is not None else '')
        else:
            print(obj if obj is not None else '')
else:
    # Config: direct field or nested mapping
    if field == 'testCommand':
        v = d.get('testCommand') or (d.get('test', {}) or {}).get('command')
    elif field == 'buildCommand':
        v = d.get('buildCommand') or (d.get('build', {}) or {}).get('command')
    else:
        v = d.get(field)
    if v is None:
        print('')
    elif isinstance(v, list):
        print('\n'.join(str(x) for x in v) if v else '')
    else:
        print(v)
" "$file" "$field" "$source_type" 2>/dev/null | tr -d '\r') || result=""
    echo "$result"
  else
    # No jq, no python — cannot parse JSON
    echo ""
  fi
}

# ─── Public API ───────────────────────────────────────────────

# Check if a field name is in the resolvable set.
# Returns 0 if resolvable, 1 if config-only (not subject to merge).
is_field_resolvable() {
  local field="$1"
  local f
  for f in $_RESOLVE_CONFIG_RESOLVABLE_FIELDS; do
    if [ "$f" = "$field" ]; then
      return 0
    fi
  done
  return 1
}

# Resolve a field value using two-layer precedence.
# Outputs the resolved value (or empty) to stdout.
# Emits a stderr warning if the field is not in the resolvable set.
resolve_field() {
  local field="$1"
  local config_path="${2:-$_RESOLVE_CONFIG_DEFAULT_CONFIG}"
  local derived_path="${3:-$_RESOLVE_CONFIG_DEFAULT_DERIVED}"

  if ! is_field_resolvable "$field"; then
    echo "WARNING: '$field' is not a resolvable field (config-only). Use config directly." >&2
    echo ""
    return
  fi

  # Layer 1: explicit config wins
  local config_val=""
  config_val=$(_resolve_read_field "$config_path" "$field" "config")
  if [ -n "$config_val" ]; then
    echo "$config_val"
    return
  fi

  # Layer 2: derived state fills gaps
  local derived_val=""
  derived_val=$(_resolve_read_field "$derived_path" "$field" "derived")
  if [ -n "$derived_val" ]; then
    echo "$derived_val"
    return
  fi

  # Unresolved
  echo ""
}

# Resolve a field with source attribution.
# Outputs "value|source" where source ∈ {explicit, derived, unresolved}.
resolve_field_with_source() {
  local field="$1"
  local config_path="${2:-$_RESOLVE_CONFIG_DEFAULT_CONFIG}"
  local derived_path="${3:-$_RESOLVE_CONFIG_DEFAULT_DERIVED}"

  if ! is_field_resolvable "$field"; then
    echo "WARNING: '$field' is not a resolvable field (config-only). Use config directly." >&2
    echo "|unresolved"
    return
  fi

  # Layer 1: explicit config wins
  local config_val=""
  config_val=$(_resolve_read_field "$config_path" "$field" "config")
  if [ -n "$config_val" ]; then
    echo "${config_val}|explicit"
    return
  fi

  # Layer 2: derived state fills gaps
  local derived_val=""
  derived_val=$(_resolve_read_field "$derived_path" "$field" "derived")
  if [ -n "$derived_val" ]; then
    echo "${derived_val}|derived"
    return
  fi

  # Unresolved
  echo "|unresolved"
}

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
#   resolve_field_type <name>

# ─── Constants ────────────────────────────────────────────────

_RESOLVE_CONFIG_DEFAULT_CONFIG=".preflight/config.json"
_RESOLVE_CONFIG_DEFAULT_DERIVED=".preflight/derived/state.json"

# Fields that can be resolved from EITHER config or derived state.
# Config-only fields (rubric, capture, mode, branch, review, loop, migration)
# are NOT in this list and will warn if queried.
_RESOLVE_CONFIG_RESOLVABLE_FIELDS="stack buildCommand testCommand packageManager frameworkVersion sourceRoot projectFiles"

# ─── Field type registry ─────────────────────────────────────
# Each resolvable field declares its type. The "is this layer unset for this
# field" predicate is type-aware: numeric 0, boolean false, and empty arrays
# are legitimate SET values for their respective types — not "unset."
#
# Types: string, number, boolean, array, object
# Add new entries when new resolvable fields are introduced.

_resolve_field_type() {
  case "$1" in
    stack|buildCommand|testCommand|packageManager|frameworkVersion|sourceRoot)
      echo "string" ;;
    projectFiles)
      echo "array" ;;
    *)
      echo "unknown" ;;
  esac
}

# ─── Unset sentinel ──────────────────────────────────────────
# This token disambiguates "field missing from JSON" from "field present with
# value null or empty." It is chosen to be impossible to collide with any real
# config value: it contains control characters and a UUID-like suffix that no
# human would write and no generator would produce.
_RESOLVE_UNSET_SENTINEL="__RESOLVE_UNSET_\x00_7f3a9c2e__"

# ─── Per-type "is unset" predicates ──────────────────────────
# Return 0 (true) if the value should be treated as "unset" for this type.
# Return 1 (false) if the value is a legitimate SET value.

_resolve_is_unset_string() {
  # Unset if: sentinel, JSON null, or empty string
  local v="$1"
  [ "$v" = "$_RESOLVE_UNSET_SENTINEL" ] && return 0
  [ "$v" = "null" ] && return 0
  [ -z "$v" ] && return 0
  return 1
}

_resolve_is_unset_number() {
  # Unset if: sentinel or JSON null. SET if: any number including 0.
  local v="$1"
  [ "$v" = "$_RESOLVE_UNSET_SENTINEL" ] && return 0
  [ "$v" = "null" ] && return 0
  [ -z "$v" ] && return 0
  return 1
}

_resolve_is_unset_boolean() {
  # Unset if: sentinel or JSON null. SET if: "true" or "false".
  local v="$1"
  [ "$v" = "$_RESOLVE_UNSET_SENTINEL" ] && return 0
  [ "$v" = "null" ] && return 0
  [ -z "$v" ] && return 0
  return 1
}

_resolve_is_unset_array() {
  # Unset if: sentinel or JSON null only. Empty string after join of [] is SET.
  # An empty array is an explicit "no items" — distinct from missing/null.
  local v="$1"
  [ "$v" = "$_RESOLVE_UNSET_SENTINEL" ] && return 0
  [ "$v" = "null" ] && return 0
  return 1
}

_resolve_is_unset_object() {
  # Unset if: sentinel or JSON null. SET if: any object including "{}".
  local v="$1"
  [ "$v" = "$_RESOLVE_UNSET_SENTINEL" ] && return 0
  [ "$v" = "null" ] && return 0
  [ -z "$v" ] && return 0
  return 1
}

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

# Extract a field value from a JSON file with type-aware extraction.
# Returns the raw value as a string, or the unset sentinel if field is missing/null.
# For derived state: fields are objects with .value sub-key (except projectFiles).
# For config: fields may be top-level or nested (test.command → testCommand).
_resolve_read_field() {
  local file="$1" field="$2" source_type="$3" field_type="$4"

  if [ ! -f "$file" ]; then
    echo "$_RESOLVE_UNSET_SENTINEL"
    return
  fi

  if command -v jq &>/dev/null; then
    local result=""
    if [ "$source_type" = "derived" ]; then
      if [ "$field" = "projectFiles" ] || [ "$field_type" = "array" ]; then
        # Array fields: return JSON array representation for type checking
        result=$(jq -r "if .[\"$field\"] == null then \"$_RESOLVE_UNSET_SENTINEL\" elif .[\"$field\"] | type == \"array\" then (.[\"$field\"] | join(\"\\n\")) else .[\"$field\"] // \"$_RESOLVE_UNSET_SENTINEL\" end" "$file" 2>/dev/null) || result="$_RESOLVE_UNSET_SENTINEL"
      else
        result=$(jq -r "if .[\"$field\"] == null then \"$_RESOLVE_UNSET_SENTINEL\" elif .[\"$field\"] | type == \"object\" then (.[\"$field\"].value // \"$_RESOLVE_UNSET_SENTINEL\" | if . == null then \"$_RESOLVE_UNSET_SENTINEL\" else tostring end) else (.[\"$field\"] | tostring) end" "$file" 2>/dev/null) || result="$_RESOLVE_UNSET_SENTINEL"
      fi
    else
      # Config: check direct field, then known nested mappings
      case "$field" in
        testCommand)
          result=$(jq -r "if .testCommand != null then (.testCommand | tostring) elif .test != null and .test.command != null then (.test.command | tostring) else \"$_RESOLVE_UNSET_SENTINEL\" end" "$file" 2>/dev/null) || result="$_RESOLVE_UNSET_SENTINEL"
          ;;
        buildCommand)
          result=$(jq -r "if .buildCommand != null then (.buildCommand | tostring) elif .build != null and .build.command != null then (.build.command | tostring) else \"$_RESOLVE_UNSET_SENTINEL\" end" "$file" 2>/dev/null) || result="$_RESOLVE_UNSET_SENTINEL"
          ;;
        *)
          result=$(jq -r "if .[\"$field\"] == null then \"$_RESOLVE_UNSET_SENTINEL\" else (.[\"$field\"] | if type == \"array\" then join(\"\\n\") else tostring end) end" "$file" 2>/dev/null) || result="$_RESOLVE_UNSET_SENTINEL"
          ;;
      esac
    fi
    echo "$result"
  elif [ -n "$_RESOLVE_PYTHON_CMD" ]; then
    local result=""
    result=$($_RESOLVE_PYTHON_CMD -c "
import json, sys

SENTINEL = sys.argv[4]
try:
    d = json.load(open(sys.argv[1]))
except:
    print(SENTINEL)
    sys.exit(0)

field = sys.argv[2]
source_type = sys.argv[3]

if source_type == 'derived':
    if field == 'projectFiles' or '$field_type' == 'array':
        v = d.get(field)
        if v is None:
            print(SENTINEL)
        elif isinstance(v, list):
            print('\n'.join(str(x) for x in v) if v else '')
        else:
            print(v)
    else:
        obj = d.get(field)
        if obj is None:
            print(SENTINEL)
        elif isinstance(obj, dict):
            v = obj.get('value')
            if v is None:
                print(SENTINEL)
            else:
                print(str(v))
        else:
            print(str(obj))
else:
    # Config: direct field or nested mapping
    if field == 'testCommand':
        v = d.get('testCommand')
        if v is None:
            v = (d.get('test') or {}).get('command')
    elif field == 'buildCommand':
        v = d.get('buildCommand')
        if v is None:
            v = (d.get('build') or {}).get('command')
    else:
        v = d.get(field)
    if v is None:
        print(SENTINEL)
    elif isinstance(v, list):
        print('\n'.join(str(x) for x in v))
    elif isinstance(v, bool):
        print(str(v).lower())
    else:
        print(str(v))
" "$file" "$field" "$source_type" "$_RESOLVE_UNSET_SENTINEL" 2>/dev/null | tr -d '\r') || result="$_RESOLVE_UNSET_SENTINEL"
    echo "$result"
  else
    # No jq, no python — cannot parse JSON
    echo "$_RESOLVE_UNSET_SENTINEL"
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

# Returns the registered type for a resolvable field.
# Echoes: string, number, boolean, array, object, or unknown.
resolve_field_type() {
  _resolve_field_type "$1"
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

  local field_type
  field_type=$(_resolve_field_type "$field")
  if [ "$field_type" = "unknown" ]; then
    echo "WARNING: field '$field' has no registered type. Register it in _resolve_field_type(). Defaulting to string." >&2
  fi

  # Layer 1: explicit config wins
  local config_val=""
  config_val=$(_resolve_read_field "$config_path" "$field" "config" "$field_type")
  if ! "_resolve_is_unset_${field_type}" "$config_val" 2>/dev/null; then
    echo "$config_val"
    return
  fi

  # Layer 2: derived state fills gaps
  local derived_val=""
  derived_val=$(_resolve_read_field "$derived_path" "$field" "derived" "$field_type")
  if ! "_resolve_is_unset_${field_type}" "$derived_val" 2>/dev/null; then
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

  local field_type
  field_type=$(_resolve_field_type "$field")
  if [ "$field_type" = "unknown" ]; then
    echo "WARNING: field '$field' has no registered type. Register it in _resolve_field_type(). Defaulting to string." >&2
  fi

  # Layer 1: explicit config wins
  local config_val=""
  config_val=$(_resolve_read_field "$config_path" "$field" "config" "$field_type")
  if ! "_resolve_is_unset_${field_type}" "$config_val" 2>/dev/null; then
    echo "${config_val}|explicit"
    return
  fi

  # Layer 2: derived state fills gaps
  local derived_val=""
  derived_val=$(_resolve_read_field "$derived_path" "$field" "derived" "$field_type")
  if ! "_resolve_is_unset_${field_type}" "$derived_val" 2>/dev/null; then
    echo "${derived_val}|derived"
    return
  fi

  # Unresolved
  echo "|unresolved"
}

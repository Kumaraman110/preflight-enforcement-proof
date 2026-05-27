#!/usr/bin/env bash
# Derived state reader — utility for reading values from the detector's output.
#
# Source this file and call read_derived() to get operational values.
#
# Usage:
#   source "$PLUGIN_ROOT/lib/derived-state-reader.sh"
#   TEST_CMD=$(read_derived "testCommand")
#   STACK=$(read_derived "stack")
#
# Returns the "value" field for the given key. Returns empty string
# if state file doesn't exist or field is not found.

DERIVED_STATE_PATH="${DERIVED_STATE_PATH:-.preflight/derived/state.json}"

read_derived() {
  local field="$1"
  local state_file="$DERIVED_STATE_PATH"

  if [ ! -f "$state_file" ]; then
    echo ""
    return 0
  fi

  local result=""

  # Try python first (most reliable JSON parsing)
  local py_cmd=""
  if command -v python3 &>/dev/null && python3 --version &>/dev/null; then
    py_cmd="python3"
  elif command -v python &>/dev/null && python --version &>/dev/null; then
    py_cmd="python"
  fi

  if [ -n "$py_cmd" ]; then
    result=$($py_cmd -c "
import sys, json
try:
    with open('$state_file') as f:
        d = json.load(f)
    v = d.get('$field', {})
    if isinstance(v, dict):
        val = v.get('value', '')
        print('' if val is None else val)
    elif isinstance(v, list):
        print(' '.join(v))
    else:
        print('' if v is None else v)
except:
    print('')
" 2>/dev/null || echo "")
  # Fallback: jq
  elif command -v jq &>/dev/null; then
    result=$(jq -r ".[\"$field\"].value // .[\"$field\"] // \"\"" "$state_file" 2>/dev/null || echo "")
    [ "$result" = "null" ] && result=""
  # Last resort: grep-based extraction (fragile but functional)
  else
    result=$(grep -oP "\"$field\"\\s*:\\s*\\{[^}]*\"value\"\\s*:\\s*\"\\K[^\"]*" "$state_file" 2>/dev/null || echo "")
  fi

  echo "$result"
}

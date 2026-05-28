#!/usr/bin/env bash
# Tests for lib/resolve-config.sh — two-layer config resolution.
# Validates: precedence (config > derived), source attribution,
# field-safety check, and robustness against malformed inputs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PLUGIN_ROOT/lib/resolve-config.sh"
FAILURES=0
PASSES=0

red() { printf "\033[31m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }

assert_eq() {
  local actual="$1" expected="$2" context="$3"
  if [ "$actual" = "$expected" ]; then
    green "PASS: $context"
    PASSES=$((PASSES + 1))
  else
    red "FAIL: $context — expected '$expected', got '$actual'"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_contains_stderr() {
  local stderr_output="$1" needle="$2" context="$3"
  if echo "$stderr_output" | grep -qi "$needle"; then
    PASSES=$((PASSES + 1))
  else
    red "FAIL: $context — stderr expected to contain '$needle'"
    FAILURES=$((FAILURES + 1))
  fi
}

# ─── Setup ────────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

source "$LIB"

setup_workspace() {
  rm -rf "$TMPDIR"/* "$TMPDIR"/.* 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════════
# TWO-LAYER PRECEDENCE TESTS (1-7)
# ════════════════════════════════════════════════════════════════

# Test 1: Config has testCommand, derived has testCommand → CONFIG wins
echo "Test 1: Config wins over derived"
setup_workspace
echo '{"testCommand":"dotnet test --config"}' > "$TMPDIR/config.json"
echo '{"testCommand":{"value":"dotnet test --derived","confidence":"high","evidence":"detected"}}' > "$TMPDIR/derived.json"

result=$(resolve_field "testCommand" "$TMPDIR/config.json" "$TMPDIR/derived.json")
assert_eq "$result" "dotnet test --config" "Config testCommand wins over derived"

# Test 2: Config silent, derived has value → DERIVED fills gap
echo "Test 2: Derived fills gap when config silent"
setup_workspace
echo '{"mode":"generic"}' > "$TMPDIR/config.json"
echo '{"testCommand":{"value":"npm test","confidence":"high","evidence":"package.json scripts"}}' > "$TMPDIR/derived.json"

result=$(resolve_field "testCommand" "$TMPDIR/config.json" "$TMPDIR/derived.json")
assert_eq "$result" "npm test" "Derived testCommand fills gap"

# Test 3: Both silent → empty
echo "Test 3: Both silent returns empty"
setup_workspace
echo '{"mode":"generic"}' > "$TMPDIR/config.json"
echo '{"testCommand":{"value":null,"confidence":"default","evidence":"none"}}' > "$TMPDIR/derived.json"

result=$(resolve_field "testCommand" "$TMPDIR/config.json" "$TMPDIR/derived.json")
assert_eq "$result" "" "Both silent returns empty"

# Test 4: Config has explicit null → treat as silent → DERIVED wins
echo "Test 4: Config null treated as silent, derived fills"
setup_workspace
echo '{"testCommand":null}' > "$TMPDIR/config.json"
echo '{"testCommand":{"value":"pytest","confidence":"high","evidence":"setup.py"}}' > "$TMPDIR/derived.json"

result=$(resolve_field "testCommand" "$TMPDIR/config.json" "$TMPDIR/derived.json")
assert_eq "$result" "pytest" "Config null → derived fills"

# Test 5: Config has empty string → treat as silent → DERIVED wins
echo "Test 5: Config empty string treated as silent"
setup_workspace
echo '{"testCommand":""}' > "$TMPDIR/config.json"
echo '{"testCommand":{"value":"go test ./...","confidence":"high","evidence":"go.mod"}}' > "$TMPDIR/derived.json"

result=$(resolve_field "testCommand" "$TMPDIR/config.json" "$TMPDIR/derived.json")
assert_eq "$result" "go test ./..." "Config empty string → derived fills"

# Test 6: Config has value, derived file missing → CONFIG
echo "Test 6: Config value survives missing derived"
setup_workspace
echo '{"stack":"dotnet"}' > "$TMPDIR/config.json"

result=$(resolve_field "stack" "$TMPDIR/config.json" "$TMPDIR/nonexistent.json")
assert_eq "$result" "dotnet" "Config value with missing derived file"

# Test 7: Both files missing → empty, no crash
echo "Test 7: Both files missing returns empty"
setup_workspace

result=$(resolve_field "stack" "$TMPDIR/no-config.json" "$TMPDIR/no-derived.json")
assert_eq "$result" "" "Both files missing → empty"

# ════════════════════════════════════════════════════════════════
# SOURCE ATTRIBUTION TESTS (8-10)
# ════════════════════════════════════════════════════════════════

# Test 8: Source = explicit when config has value
echo "Test 8: Source attribution — explicit"
setup_workspace
echo '{"stack":"java"}' > "$TMPDIR/config.json"
echo '{"stack":{"value":"dotnet","confidence":"high","evidence":".csproj"}}' > "$TMPDIR/derived.json"

result=$(resolve_field_with_source "stack" "$TMPDIR/config.json" "$TMPDIR/derived.json")
assert_eq "$result" "java|explicit" "Source is 'explicit' when config has value"

# Test 9: Source = derived when only derived has value
echo "Test 9: Source attribution — derived"
setup_workspace
echo '{"mode":"generic"}' > "$TMPDIR/config.json"
echo '{"stack":{"value":"python","confidence":"high","evidence":"pyproject.toml"}}' > "$TMPDIR/derived.json"

result=$(resolve_field_with_source "stack" "$TMPDIR/config.json" "$TMPDIR/derived.json")
assert_eq "$result" "python|derived" "Source is 'derived' when only derived has value"

# Test 10: Source = unresolved when neither has value
echo "Test 10: Source attribution — unresolved"
setup_workspace
echo '{"mode":"generic"}' > "$TMPDIR/config.json"
echo '{"stack":{"value":"","confidence":"default","evidence":"none"}}' > "$TMPDIR/derived.json"

result=$(resolve_field_with_source "stack" "$TMPDIR/config.json" "$TMPDIR/derived.json")
assert_eq "$result" "|unresolved" "Source is 'unresolved' when neither has value"

# ════════════════════════════════════════════════════════════════
# RESOLVABLE FIELD SAFETY (11-13)
# ════════════════════════════════════════════════════════════════

# Test 11: is_field_resolvable testCommand → 0
echo "Test 11: testCommand is resolvable"
if is_field_resolvable "testCommand"; then
  green "PASS: testCommand is resolvable"
  PASSES=$((PASSES + 1))
else
  red "FAIL: testCommand should be resolvable"
  FAILURES=$((FAILURES + 1))
fi

# Test 12: is_field_resolvable rubric → 1
echo "Test 12: rubric is NOT resolvable (config-only)"
if ! is_field_resolvable "rubric"; then
  green "PASS: rubric is not resolvable"
  PASSES=$((PASSES + 1))
else
  red "FAIL: rubric should NOT be resolvable"
  FAILURES=$((FAILURES + 1))
fi

# Test 13: resolve_field on non-resolvable emits warning, returns empty
echo "Test 13: Non-resolvable field emits warning"
setup_workspace
echo '{"rubric":"path/to/rubric.md"}' > "$TMPDIR/config.json"

# Capture stdout and stderr to separate files
resolve_field "rubric" "$TMPDIR/config.json" "$TMPDIR/derived.json" > "$TMPDIR/stdout.txt" 2> "$TMPDIR/stderr.txt"
result=$(cat "$TMPDIR/stdout.txt")
stderr_output=$(cat "$TMPDIR/stderr.txt")

if [ -z "$result" ] && echo "$stderr_output" | grep -q "WARNING"; then
  green "PASS: non-resolvable field returns empty + warns"
  PASSES=$((PASSES + 1))
else
  red "FAIL: expected empty result + WARNING on stderr (result='$result', stderr='$stderr_output')"
  FAILURES=$((FAILURES + 1))
fi

# ════════════════════════════════════════════════════════════════
# ROBUSTNESS TESTS (14-17)
# ════════════════════════════════════════════════════════════════

# Test 14: Malformed config JSON → don't crash, fall to derived
echo "Test 14: Malformed config falls through to derived"
setup_workspace
echo 'NOT VALID JSON {{{' > "$TMPDIR/config.json"
echo '{"testCommand":{"value":"cargo test","confidence":"high","evidence":"Cargo.toml"}}' > "$TMPDIR/derived.json"

result=$(resolve_field "testCommand" "$TMPDIR/config.json" "$TMPDIR/derived.json")
assert_eq "$result" "cargo test" "Malformed config → derived fills"

# Test 15: Malformed derived JSON → don't crash, return config or empty
echo "Test 15: Malformed derived JSON handled gracefully"
setup_workspace
echo '{"testCommand":"dotnet test"}' > "$TMPDIR/config.json"
echo 'BROKEN JSON %%%' > "$TMPDIR/derived.json"

result=$(resolve_field "testCommand" "$TMPDIR/config.json" "$TMPDIR/derived.json")
assert_eq "$result" "dotnet test" "Malformed derived → config still works"

# Test 16: Field name with hyphen (frameworkVersion is camelCase but test edge)
echo "Test 16: Field with standard naming works"
setup_workspace
echo '{}' > "$TMPDIR/config.json"
echo '{"frameworkVersion":{"value":"net10.0","confidence":"high","evidence":".csproj"}}' > "$TMPDIR/derived.json"

result=$(resolve_field "frameworkVersion" "$TMPDIR/config.json" "$TMPDIR/derived.json")
assert_eq "$result" "net10.0" "frameworkVersion resolved from derived"

# Test 17: Paths with spaces in config_path/derived_path
echo "Test 17: Paths with spaces work"
setup_workspace
mkdir -p "$TMPDIR/path with spaces"
echo '{"stack":"node"}' > "$TMPDIR/path with spaces/config.json"
echo '{"stack":{"value":"python","confidence":"high","evidence":"setup.py"}}' > "$TMPDIR/path with spaces/derived.json"

result=$(resolve_field "stack" "$TMPDIR/path with spaces/config.json" "$TMPDIR/path with spaces/derived.json")
assert_eq "$result" "node" "Paths with spaces work (config wins)"

# ════════════════════════════════════════════════════════════════
# FIX B: TYPE-AWARE SENTINEL TESTS (18-27)
# Forward-looking tests proving numeric 0, boolean false, and
# empty arrays survive as legitimate explicit values.
# ════════════════════════════════════════════════════════════════

# Register test-only field types for numeric/boolean/object tests
# (these don't exist in the production registry)
_resolve_field_type() {
  case "$1" in
    stack|buildCommand|testCommand|packageManager|frameworkVersion|sourceRoot)
      echo "string" ;;
    projectFiles)
      echo "array" ;;
    test_port)
      echo "number" ;;
    test_strict)
      echo "boolean" ;;
    test_meta)
      echo "object" ;;
    test_includes)
      echo "array" ;;
    *)
      echo "unknown" ;;
  esac
}

# Temporarily add test fields to resolvable set
_RESOLVE_CONFIG_RESOLVABLE_FIELDS="stack buildCommand testCommand packageManager frameworkVersion sourceRoot projectFiles test_port test_strict test_meta test_includes"

# Test 18: String "0" in config → returns "0" (not unset)
echo "Test 18: String '0' is a legitimate value (not unset)"
setup_workspace
echo '{"stack":"0"}' > "$TMPDIR/config.json"
echo '{"stack":{"value":"python","confidence":"high","evidence":"test"}}' > "$TMPDIR/derived.json"

result=$(resolve_field_with_source "stack" "$TMPDIR/config.json" "$TMPDIR/derived.json")
assert_eq "$result" "0|explicit" "String '0' survives as explicit"

# Test 19: Numeric 0 in config (number field) → returns "0", source=explicit
echo "Test 19: Numeric 0 is legitimate for number fields"
setup_workspace
echo '{"test_port":0}' > "$TMPDIR/config.json"
echo '{"test_port":{"value":"8080","confidence":"high","evidence":"test"}}' > "$TMPDIR/derived.json"

result=$(resolve_field_with_source "test_port" "$TMPDIR/config.json" "$TMPDIR/derived.json")
assert_eq "$result" "0|explicit" "Numeric 0 survives as explicit"

# Test 20: Boolean false in config (boolean field) → returns "false", source=explicit
echo "Test 20: Boolean false is legitimate for boolean fields"
setup_workspace
echo '{"test_strict":false}' > "$TMPDIR/config.json"
echo '{"test_strict":{"value":"true","confidence":"high","evidence":"test"}}' > "$TMPDIR/derived.json"

result=$(resolve_field_with_source "test_strict" "$TMPDIR/config.json" "$TMPDIR/derived.json")
assert_eq "$result" "false|explicit" "Boolean false survives as explicit"

# Test 21: Empty array [] in config (array field) → returns "", source=explicit
echo "Test 21: Empty array is legitimate for array fields"
setup_workspace
echo '{"test_includes":[]}' > "$TMPDIR/config.json"
echo '{"test_includes":["a.cs","b.cs"]}' > "$TMPDIR/derived.json"

result=$(resolve_field_with_source "test_includes" "$TMPDIR/config.json" "$TMPDIR/derived.json")
# Empty array join is empty string but it's still SET (not sentinel)
assert_eq "$result" "|explicit" "Empty array survives as explicit (empty join)"

# Test 22: JSON null in config → falls through to derived
echo "Test 22: JSON null falls through to derived (number field)"
setup_workspace
echo '{"test_port":null}' > "$TMPDIR/config.json"
echo '{"test_port":{"value":"3000","confidence":"high","evidence":"test"}}' > "$TMPDIR/derived.json"

result=$(resolve_field_with_source "test_port" "$TMPDIR/config.json" "$TMPDIR/derived.json")
assert_eq "$result" "3000|derived" "JSON null in number field → derived fills"

# Test 23: Missing key falls through to derived
echo "Test 23: Missing key falls through (boolean field)"
setup_workspace
echo '{"mode":"generic"}' > "$TMPDIR/config.json"
echo '{"test_strict":{"value":"true","confidence":"high","evidence":"test"}}' > "$TMPDIR/derived.json"

result=$(resolve_field_with_source "test_strict" "$TMPDIR/config.json" "$TMPDIR/derived.json")
assert_eq "$result" "true|derived" "Missing key in boolean field → derived fills"

# Test 24: resolve_field_type returns registered types
echo "Test 24: resolve_field_type returns correct types"
setup_workspace

t1=$(resolve_field_type "testCommand")
t2=$(resolve_field_type "projectFiles")
t3=$(resolve_field_type "test_port")
t4=$(resolve_field_type "nonexistent_field")

if [ "$t1" = "string" ] && [ "$t2" = "array" ] && [ "$t3" = "number" ] && [ "$t4" = "unknown" ]; then
  green "PASS: resolve_field_type returns correct types"
  PASSES=$((PASSES + 1))
else
  red "FAIL: resolve_field_type wrong (got: $t1, $t2, $t3, $t4)"
  FAILURES=$((FAILURES + 1))
fi

# Test 25: Unknown field type emits warning but still works
echo "Test 25: Unknown field type warns but resolves"
setup_workspace

# Temporarily add an unregistered field to resolvable set
_RESOLVE_CONFIG_RESOLVABLE_FIELDS="$_RESOLVE_CONFIG_RESOLVABLE_FIELDS unknown_field"

# Override type to return unknown for this field (it already does via default)
echo '{"unknown_field":"hello"}' > "$TMPDIR/config.json"
echo '{}' > "$TMPDIR/derived.json"

resolve_field "unknown_field" "$TMPDIR/config.json" "$TMPDIR/derived.json" > "$TMPDIR/stdout.txt" 2> "$TMPDIR/stderr.txt"
result=$(cat "$TMPDIR/stdout.txt")
stderr_output=$(cat "$TMPDIR/stderr.txt")

if [ "$result" = "hello" ] && echo "$stderr_output" | grep -q "no registered type"; then
  green "PASS: unknown field resolves with warning"
  PASSES=$((PASSES + 1))
else
  red "FAIL: expected value 'hello' + warning (result='$result', stderr='$stderr_output')"
  FAILURES=$((FAILURES + 1))
fi

# Test 26: projectFiles as array in derived → returns joined values
echo "Test 26: Array field (projectFiles) from derived"
setup_workspace
echo '{}' > "$TMPDIR/config.json"
echo '{"projectFiles":["src/A.cs","src/B.cs","src/C.cs"]}' > "$TMPDIR/derived.json"

result=$(resolve_field "projectFiles" "$TMPDIR/config.json" "$TMPDIR/derived.json")
expected="src/A.cs
src/B.cs
src/C.cs"
assert_eq "$result" "$expected" "projectFiles array from derived joins correctly"

# Test 27: String "false" in a string field is SET (not confused with boolean)
echo "Test 27: String 'false' is not confused with boolean false"
setup_workspace
echo '{"stack":"false"}' > "$TMPDIR/config.json"
echo '{"stack":{"value":"node","confidence":"high","evidence":"test"}}' > "$TMPDIR/derived.json"

result=$(resolve_field_with_source "stack" "$TMPDIR/config.json" "$TMPDIR/derived.json")
assert_eq "$result" "false|explicit" "String 'false' survives as explicit string"

# ─── Results ──────────────────────────────────────────────────

echo ""
echo "Resolve-config tests: $PASSES passed, $FAILURES failed"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
else
  exit 0
fi

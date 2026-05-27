#!/usr/bin/env bash
# Tests for the detector module (lib/detector.sh).
# Validates: dotnet detection, node detection, java detection, unknown detection, JSON structure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DETECTOR="$PLUGIN_ROOT/lib/detector.sh"
FAILURES=0
PASSES=0

# Find a working python (python3 may not exist on Windows Git Bash)
PYTHON=""
if command -v python3 &>/dev/null && python3 --version &>/dev/null; then
  PYTHON="python3"
elif command -v python &>/dev/null && python --version &>/dev/null; then
  PYTHON="python"
else
  red "FATAL: No working python interpreter found"
  exit 1
fi

red() { printf "\033[31m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }

assert_exit_code() {
  local expected="$1" actual="$2" context="$3"
  if [ "$actual" -eq "$expected" ]; then
    PASSES=$((PASSES + 1))
  else
    red "FAIL: $context — expected exit $expected, got $actual"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_json_field() {
  local file="$1" field="$2" expected="$3" context="$4"
  local actual pyfile
  pyfile=$(cygpath -m "$file" 2>/dev/null || echo "$file")
  actual=$($PYTHON -c "
import json
with open('$pyfile') as f:
    d = json.load(f)
v = d.get('$field', {})
if isinstance(v, dict):
    val = v.get('value', '')
    print('' if val is None else val)
elif isinstance(v, list):
    print(len(v))
else:
    print('' if v is None else v)
" 2>/dev/null || echo "PARSE_ERROR")
  if [ "$actual" = "$expected" ]; then
    PASSES=$((PASSES + 1))
  else
    red "FAIL: $context — field '$field' expected '$expected', got '$actual'"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_json_has_field() {
  local file="$1" field="$2" context="$3"
  local has_it pyfile
  pyfile=$(cygpath -m "$file" 2>/dev/null || echo "$file")
  has_it=$($PYTHON -c "
import json
with open('$pyfile') as f:
    d = json.load(f)
print('yes' if '$field' in d else 'no')
" 2>/dev/null || echo "no")
  if [ "$has_it" = "yes" ]; then
    PASSES=$((PASSES + 1))
  else
    red "FAIL: $context — field '$field' not found in JSON"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_json_confidence() {
  local file="$1" field="$2" expected="$3" context="$4"
  local actual pyfile
  pyfile=$(cygpath -m "$file" 2>/dev/null || echo "$file")
  actual=$($PYTHON -c "
import json
with open('$pyfile') as f:
    d = json.load(f)
v = d.get('$field', {})
print(v.get('confidence', '') if isinstance(v, dict) else '')
" 2>/dev/null || echo "PARSE_ERROR")
  if [ "$actual" = "$expected" ]; then
    PASSES=$((PASSES + 1))
  else
    red "FAIL: $context — confidence expected '$expected', got '$actual'"
    FAILURES=$((FAILURES + 1))
  fi
}

# ─── Setup temp workspace ─────────────────────────────────────

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# ─── Test 1: Dotnet detection ─────────────────────────────────

echo "Test 1: Dotnet stack detection"
WORKDIR="$TMPDIR/dotnet-project"
mkdir -p "$WORKDIR/src/MyService"
cat > "$WORKDIR/src/MyService/MyService.csproj" <<'XMLEOF'
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
</Project>
XMLEOF
mkdir -p "$WORKDIR/src/MyService.Tests"
cat > "$WORKDIR/src/MyService.Tests/MyService.Tests.csproj" <<'XMLEOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
</Project>
XMLEOF

OUTPUT_FILE="$WORKDIR/.preflight/derived/state.json"
(cd "$WORKDIR" && bash "$DETECTOR" "$OUTPUT_FILE")
EXIT_CODE=$?

assert_exit_code 0 $EXIT_CODE "Dotnet detection exits clean"
assert_json_field "$OUTPUT_FILE" "stack" "dotnet" "Detects dotnet stack"
assert_json_confidence "$OUTPUT_FILE" "stack" "high" "Dotnet stack confidence is high"
assert_json_field "$OUTPUT_FILE" "buildCommand" "dotnet build" "Dotnet build command"
assert_json_field "$OUTPUT_FILE" "testCommand" "dotnet test" "Dotnet test command"
assert_json_confidence "$OUTPUT_FILE" "testCommand" "high" "Test confidence high (test project found)"
assert_json_field "$OUTPUT_FILE" "frameworkVersion" "net10.0" "Framework version detected"
assert_json_field "$OUTPUT_FILE" "packageManager" "nuget" "Package manager is nuget"

# ─── Test 2: Node detection ──────────────────────────────────

echo "Test 2: Node stack detection"
WORKDIR="$TMPDIR/node-project"
mkdir -p "$WORKDIR/src"
cat > "$WORKDIR/package.json" <<'JSONEOF'
{
  "name": "my-app",
  "scripts": { "test": "jest", "build": "tsc" },
  "engines": { "node": ">=18.0.0" }
}
JSONEOF
echo "console.log('hi')" > "$WORKDIR/src/index.js"

OUTPUT_FILE="$WORKDIR/.preflight/derived/state.json"
(cd "$WORKDIR" && bash "$DETECTOR" "$OUTPUT_FILE")
EXIT_CODE=$?

assert_exit_code 0 $EXIT_CODE "Node detection exits clean"
assert_json_field "$OUTPUT_FILE" "stack" "node" "Detects node stack"
assert_json_confidence "$OUTPUT_FILE" "stack" "high" "Node stack confidence is high"
assert_json_field "$OUTPUT_FILE" "testCommand" "npm test" "Node test command"
assert_json_confidence "$OUTPUT_FILE" "testCommand" "high" "Node test confidence high (scripts.test found)"
assert_json_field "$OUTPUT_FILE" "packageManager" "npm" "Package manager is npm"

# ─── Test 3: Java detection ──────────────────────────────────

echo "Test 3: Java stack detection"
WORKDIR="$TMPDIR/java-project"
mkdir -p "$WORKDIR/src/main/java"
cat > "$WORKDIR/pom.xml" <<'XMLEOF'
<project>
  <properties>
    <java.version>17</java.version>
  </properties>
</project>
XMLEOF
echo "class App {}" > "$WORKDIR/src/main/java/App.java"

OUTPUT_FILE="$WORKDIR/.preflight/derived/state.json"
(cd "$WORKDIR" && bash "$DETECTOR" "$OUTPUT_FILE")
EXIT_CODE=$?

assert_exit_code 0 $EXIT_CODE "Java detection exits clean"
assert_json_field "$OUTPUT_FILE" "stack" "java" "Detects java stack"
assert_json_confidence "$OUTPUT_FILE" "stack" "high" "Java stack confidence is high"
assert_json_field "$OUTPUT_FILE" "buildCommand" "mvn package" "Java build command (maven)"
assert_json_field "$OUTPUT_FILE" "testCommand" "mvn test" "Java test command"
assert_json_field "$OUTPUT_FILE" "frameworkVersion" "17" "Java version detected"
assert_json_field "$OUTPUT_FILE" "packageManager" "maven" "Package manager is maven"

# ─── Test 4: Unknown detection (empty project) ───────────────

echo "Test 4: Unknown stack (no project files)"
WORKDIR="$TMPDIR/empty-project"
mkdir -p "$WORKDIR"
echo "just a readme" > "$WORKDIR/README.md"

OUTPUT_FILE="$WORKDIR/.preflight/derived/state.json"
(cd "$WORKDIR" && bash "$DETECTOR" "$OUTPUT_FILE")
EXIT_CODE=$?

assert_exit_code 0 $EXIT_CODE "Unknown detection exits clean"
assert_json_field "$OUTPUT_FILE" "stack" "unknown" "Detects unknown stack"
assert_json_confidence "$OUTPUT_FILE" "stack" "default" "Unknown stack confidence is default"

# ─── Test 5: JSON structure validation ────────────────────────

echo "Test 5: JSON structure has all required fields"
# Use the dotnet output from test 1
OUTPUT_FILE="$TMPDIR/dotnet-project/.preflight/derived/state.json"

assert_json_has_field "$OUTPUT_FILE" "generatedAt" "JSON has generatedAt"
assert_json_has_field "$OUTPUT_FILE" "generatedBy" "JSON has generatedBy"
assert_json_has_field "$OUTPUT_FILE" "stack" "JSON has stack"
assert_json_has_field "$OUTPUT_FILE" "buildCommand" "JSON has buildCommand"
assert_json_has_field "$OUTPUT_FILE" "testCommand" "JSON has testCommand"
assert_json_has_field "$OUTPUT_FILE" "packageManager" "JSON has packageManager"
assert_json_has_field "$OUTPUT_FILE" "sourceRoot" "JSON has sourceRoot"
assert_json_has_field "$OUTPUT_FILE" "frameworkVersion" "JSON has frameworkVersion"
assert_json_has_field "$OUTPUT_FILE" "projectFiles" "JSON has projectFiles"

# Verify generatedBy value
assert_json_field "$OUTPUT_FILE" "generatedBy" "preflight-detector-v1" "generatedBy is correct"

# ─── Results ──────────────────────────────────────────────────

echo ""
echo "Detector tests: $PASSES passed, $FAILURES failed"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
else
  exit 0
fi

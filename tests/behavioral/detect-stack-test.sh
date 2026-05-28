#!/usr/bin/env bash
# Tests for the shared stack detection module (lib/detect-stack.sh).
# Validates: all 7 stack outcomes (dotnet, java, python, node, go, rust, unknown).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DETECT_STACK="$PLUGIN_ROOT/lib/detect-stack.sh"
FAILURES=0
PASSES=0

red() { printf "\033[31m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }

assert_stack() {
  local expected="$1" context="$2"
  if [ "$STACK_VALUE" = "$expected" ]; then
    PASSES=$((PASSES + 1))
  else
    red "FAIL: $context — expected '$expected', got '$STACK_VALUE'"
    FAILURES=$((FAILURES + 1))
  fi
}

# ─── Setup ────────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# ─── Test 1: Dotnet ───────────────────────────────────────────

echo "Test 1: Dotnet detection"
WORKDIR="$TMPDIR/dotnet"
mkdir -p "$WORKDIR/src"
echo '<Project Sdk="Microsoft.NET.Sdk.Web"></Project>' > "$WORKDIR/src/App.csproj"

(cd "$WORKDIR" && source "$DETECT_STACK" && detect_stack && echo "$STACK_VALUE") > /dev/null
STACK_VALUE=$(cd "$WORKDIR" && source "$DETECT_STACK" && detect_stack && echo "$STACK_VALUE")
assert_stack "dotnet" "Detects dotnet from .csproj"

# ─── Test 2: Java ────────────────────────────────────────────

echo "Test 2: Java detection"
WORKDIR="$TMPDIR/java"
mkdir -p "$WORKDIR"
echo '<project></project>' > "$WORKDIR/pom.xml"

STACK_VALUE=$(cd "$WORKDIR" && source "$DETECT_STACK" && detect_stack && echo "$STACK_VALUE")
assert_stack "java" "Detects java from pom.xml"

# ─── Test 3: Python ──────────────────────────────────────────

echo "Test 3: Python detection"
WORKDIR="$TMPDIR/python"
mkdir -p "$WORKDIR"
printf '[project]\nname = "x"\n' > "$WORKDIR/pyproject.toml"

STACK_VALUE=$(cd "$WORKDIR" && source "$DETECT_STACK" && detect_stack && echo "$STACK_VALUE")
assert_stack "python" "Detects python from pyproject.toml"

# ─── Test 4: Node ────────────────────────────────────────────

echo "Test 4: Node detection"
WORKDIR="$TMPDIR/node"
mkdir -p "$WORKDIR"
echo '{"name":"x"}' > "$WORKDIR/package.json"

STACK_VALUE=$(cd "$WORKDIR" && source "$DETECT_STACK" && detect_stack && echo "$STACK_VALUE")
assert_stack "node" "Detects node from package.json"

# ─── Test 5: Go ──────────────────────────────────────────────

echo "Test 5: Go detection"
WORKDIR="$TMPDIR/go"
mkdir -p "$WORKDIR"
printf 'module example.com/x\n\ngo 1.22\n' > "$WORKDIR/go.mod"

STACK_VALUE=$(cd "$WORKDIR" && source "$DETECT_STACK" && detect_stack && echo "$STACK_VALUE")
assert_stack "go" "Detects go from go.mod"

# ─── Test 6: Rust ────────────────────────────────────────────

echo "Test 6: Rust detection"
WORKDIR="$TMPDIR/rust"
mkdir -p "$WORKDIR"
printf '[package]\nname = "x"\n' > "$WORKDIR/Cargo.toml"

STACK_VALUE=$(cd "$WORKDIR" && source "$DETECT_STACK" && detect_stack && echo "$STACK_VALUE")
assert_stack "rust" "Detects rust from Cargo.toml"

# ─── Test 7: Unknown ─────────────────────────────────────────

echo "Test 7: Unknown detection"
WORKDIR="$TMPDIR/unknown"
mkdir -p "$WORKDIR"
echo "readme" > "$WORKDIR/README.md"

STACK_VALUE=$(cd "$WORKDIR" && source "$DETECT_STACK" && detect_stack && echo "$STACK_VALUE")
assert_stack "unknown" "Returns unknown when no indicators"

# ─── Results ──────────────────────────────────────────────────

echo ""
echo "Detect-stack tests: $PASSES passed, $FAILURES failed"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
else
  exit 0
fi

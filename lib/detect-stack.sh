#!/usr/bin/env bash
# Shared stack-detection. Source this; do not execute. Defines detect_stack().
#
# After calling detect_stack(), these variables are set:
#   STACK_VALUE      — one of: dotnet, java, python, node, go, rust, unknown
#   STACK_CONFIDENCE — one of: high, default
#   STACK_EVIDENCE   — human-readable reason for the detection

_detect_stack_find_files() { find . -maxdepth 3 -name "$1" -print 2>/dev/null | sort | head -20; }

detect_stack() {
  local value="unknown" confidence="default" evidence="no project indicators found"
  if [ -n "$(_detect_stack_find_files '*.csproj')" ] || [ -n "$(_detect_stack_find_files '*.sln')" ]; then
    value="dotnet"; confidence="high"; evidence=".csproj or .sln files found"
  elif [ -f "pom.xml" ] || [ -n "$(_detect_stack_find_files 'build.gradle')" ]; then
    value="java"; confidence="high"; evidence="pom.xml or build.gradle found"
  elif [ -f "pyproject.toml" ] || [ -f "requirements.txt" ] || [ -f "setup.py" ]; then
    value="python"; confidence="high"; evidence="Python project file found"
  elif [ -f "package.json" ]; then
    value="node"; confidence="high"; evidence="package.json found"
  elif [ -f "go.mod" ]; then
    value="go"; confidence="high"; evidence="go.mod found"
  elif [ -f "Cargo.toml" ]; then
    value="rust"; confidence="high"; evidence="Cargo.toml found"
  fi
  STACK_VALUE="$value"; STACK_CONFIDENCE="$confidence"; STACK_EVIDENCE="$evidence"
}

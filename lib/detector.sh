#!/usr/bin/env bash
# Detector module — Layer 1 of the three-layer configuration system.
# Inspects the current repository and infers operational values with
# confidence levels. Outputs structured JSON to derived state file.
#
# Usage: bash lib/detector.sh [output-path]
# Exit 0 on success, exit 1 on critical failure.

set -euo pipefail

OUTPUT_PATH="${1:-.preflight/derived/state.json}"

json_escape() {
  local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"
}

find_files() { find . -maxdepth 3 -name "$1" -print 2>/dev/null | sort | head -20; }

# ─── Stack Detection ─────────────────────────────────────────────
detect_stack() {
  local value="unknown" confidence="default" evidence="no project indicators found"
  if [ -n "$(find_files '*.csproj')" ] || [ -n "$(find_files '*.sln')" ]; then
    value="dotnet"; confidence="high"; evidence=".csproj or .sln files found"
  elif [ -f "pom.xml" ] || [ -n "$(find_files 'build.gradle')" ]; then
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

# ─── Build Command Detection ─────────────────────────────────────
detect_build_command() {
  local value="null" confidence="default" evidence="no build system detected"
  case "$STACK_VALUE" in
    dotnet) value="dotnet build"; confidence="high"; evidence="SDK-style .csproj found" ;;
    java)
      if [ -f "pom.xml" ]; then value="mvn package"; confidence="high"; evidence="pom.xml found"
      elif [ -n "$(find_files 'build.gradle')" ]; then value="./gradlew build"; confidence="high"; evidence="build.gradle found"; fi ;;
    python) value="null"; confidence="medium"; evidence="no universal Python build command" ;;
    node) value="npm run build"; confidence="medium"; evidence="package.json found, build script assumed" ;;
    go) value="go build ./..."; confidence="high"; evidence="go.mod found" ;;
    rust) value="cargo build"; confidence="high"; evidence="Cargo.toml found" ;;
  esac
  BUILD_VALUE="$value"; BUILD_CONFIDENCE="$confidence"; BUILD_EVIDENCE="$evidence"
}

# ─── Test Command Detection ──────────────────────────────────────
detect_test_command() {
  local value="null" confidence="default" evidence="no test framework detected"
  case "$STACK_VALUE" in
    dotnet)
      if [ -n "$(find_files '*.Tests.csproj')" ] || [ -n "$(find_files '*Test*.csproj')" ]; then
        value="dotnet test"; confidence="high"; evidence="test project (.Tests.csproj) found"
      else
        value="dotnet test"; confidence="medium"; evidence=".csproj found but no .Tests project"
      fi ;;
    java)
      if [ -f "pom.xml" ]; then value="mvn test"; confidence="high"; evidence="pom.xml found"
      elif [ -n "$(find_files 'build.gradle')" ]; then value="./gradlew test"; confidence="high"; evidence="build.gradle found"; fi ;;
    python) value="pytest"; confidence="medium"; evidence="Python stack, pytest assumed" ;;
    node)
      if [ -f "package.json" ] && grep -q '"test"' package.json 2>/dev/null; then
        value="npm test"; confidence="high"; evidence="scripts.test defined in package.json"
      else
        value="npm test"; confidence="low"; evidence="package.json found but no test script confirmed"
      fi ;;
    go) value="go test ./..."; confidence="high"; evidence="go.mod found" ;;
    rust) value="cargo test"; confidence="high"; evidence="Cargo.toml found" ;;
  esac
  TEST_VALUE="$value"; TEST_CONFIDENCE="$confidence"; TEST_EVIDENCE="$evidence"
}

# ─── Package Manager Detection ───────────────────────────────────
detect_package_manager() {
  local value="unknown" confidence="default" evidence="no package manager detected"
  case "$STACK_VALUE" in
    dotnet) value="nuget"; confidence="high"; evidence=".csproj PackageReference elements" ;;
    java)
      if [ -f "pom.xml" ]; then value="maven"; confidence="high"; evidence="pom.xml found"
      else value="gradle"; confidence="high"; evidence="build.gradle found"; fi ;;
    python)
      if [ -f "pyproject.toml" ]; then value="pip"; confidence="medium"; evidence="pyproject.toml found"
      elif [ -f "requirements.txt" ]; then value="pip"; confidence="high"; evidence="requirements.txt found"; fi ;;
    node)
      if [ -f "yarn.lock" ]; then value="yarn"; confidence="high"; evidence="yarn.lock found"
      elif [ -f "pnpm-lock.yaml" ]; then value="pnpm"; confidence="high"; evidence="pnpm-lock.yaml found"
      else value="npm"; confidence="high"; evidence="package.json found"; fi ;;
    go) value="go-modules"; confidence="high"; evidence="go.mod found" ;;
    rust) value="cargo"; confidence="high"; evidence="Cargo.toml found" ;;
  esac
  PKG_VALUE="$value"; PKG_CONFIDENCE="$confidence"; PKG_EVIDENCE="$evidence"
}

# ─── Framework Version Detection ─────────────────────────────────
detect_framework_version() {
  local value="unknown" confidence="default" evidence="could not determine version"
  case "$STACK_VALUE" in
    dotnet)
      local csproj; csproj=$(find_files '*.csproj' | head -1)
      if [ -n "$csproj" ]; then
        local fw; fw=$(grep -o '<TargetFramework>[^<]*' "$csproj" 2>/dev/null | sed 's/<TargetFramework>//' || true)
        [ -n "$fw" ] && { value="$fw"; confidence="high"; evidence="TargetFramework in $csproj"; }
      fi ;;
    java)
      if [ -f "pom.xml" ]; then
        local jver; jver=$(grep -o '<java.version>[^<]*' pom.xml 2>/dev/null | sed 's/<java.version>//' || true)
        [ -z "$jver" ] && jver=$(grep -o '<maven.compiler.source>[^<]*' pom.xml 2>/dev/null | sed 's/<maven.compiler.source>//' || true)
        [ -n "$jver" ] && { value="$jver"; confidence="high"; evidence="java.version in pom.xml"; }
      fi ;;
    python)
      if [ -f "pyproject.toml" ]; then
        local pyver; pyver=$(sed -n 's/.*requires-python\s*=\s*"\([^"]*\)".*/\1/p' pyproject.toml 2>/dev/null || true)
        [ -z "$pyver" ] && pyver=$(sed -n 's/.*python_requires\s*=\s*"\([^"]*\)".*/\1/p' pyproject.toml 2>/dev/null || true)
        [ -n "$pyver" ] && { value="$pyver"; confidence="medium"; evidence="requires-python in pyproject.toml"; }
      fi ;;
    node)
      if [ -f "package.json" ]; then
        local nver; nver=$(grep -o '"node"[[:space:]]*:[[:space:]]*"[^"]*' package.json 2>/dev/null | sed 's/.*"//' || true)
        [ -n "$nver" ] && { value="$nver"; confidence="medium"; evidence="engines.node in package.json"; }
      fi ;;
    go)
      if [ -f "go.mod" ]; then
        local gover; gover=$(sed -n 's/^go[[:space:]]\+\([0-9.]\+\).*/\1/p' go.mod 2>/dev/null || true)
        [ -n "$gover" ] && { value="$gover"; confidence="high"; evidence="go directive in go.mod"; }
      fi ;;
    rust)
      if [ -f "Cargo.toml" ]; then
        local edition; edition=$(sed -n 's/.*edition[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' Cargo.toml 2>/dev/null || true)
        [ -n "$edition" ] && { value="$edition"; confidence="high"; evidence="edition in Cargo.toml"; }
      fi ;;
  esac
  FW_VALUE="$value"; FW_CONFIDENCE="$confidence"; FW_EVIDENCE="$evidence"
}

# ─── Source Root Detection ────────────────────────────────────────
detect_source_root() {
  local value="." confidence="low" evidence="defaulting to repository root"
  for dir in src lib app source; do
    if [ -d "$dir" ]; then
      local count; count=$(find "$dir" -maxdepth 2 -type f \( -name "*.cs" -o -name "*.java" -o -name "*.py" -o -name "*.ts" -o -name "*.js" -o -name "*.go" -o -name "*.rs" \) 2>/dev/null | head -5 | wc -l)
      if [ "$count" -gt 0 ]; then
        value="$dir"; confidence="medium"; evidence="$dir/ directory contains source files"; break
      fi
    fi
  done
  SRC_VALUE="$value"; SRC_CONFIDENCE="$confidence"; SRC_EVIDENCE="$evidence"
}

# ─── Project Files Detection ─────────────────────────────────────
detect_project_files() {
  local files=""
  case "$STACK_VALUE" in
    dotnet) files=$(find_files '*.csproj') ;;
    java)   files=$(find_files 'pom.xml'); files="$files"$'\n'$(find_files 'build.gradle') ;;
    python) files=$(find_files 'pyproject.toml'); files="$files"$'\n'$(find_files 'setup.py') ;;
    node)   files=$(find_files 'package.json') ;;
    go)     files=$(find_files 'go.mod') ;;
    rust)   files=$(find_files 'Cargo.toml') ;;
    *)      files="" ;;
  esac
  PROJECT_FILES=$(echo "$files" | sed '/^$/d' | sed 's|^\./||' | head -20)
}

# ─── Generate JSON Output ────────────────────────────────────────
generate_json() {
  local timestamp; timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

  # Build project files JSON array
  local pf_json="[]"
  if [ -n "$PROJECT_FILES" ]; then
    pf_json="["; local first=true
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      if [ "$first" = true ]; then first=false; else pf_json="$pf_json, "; fi
      pf_json="$pf_json\"$(json_escape "$f")\""
    done <<< "$PROJECT_FILES"
    pf_json="$pf_json]"
  fi

  local build_val test_val
  if [ "$BUILD_VALUE" = "null" ]; then build_val="null"; else build_val="\"$(json_escape "$BUILD_VALUE")\""; fi
  if [ "$TEST_VALUE" = "null" ]; then test_val="null"; else test_val="\"$(json_escape "$TEST_VALUE")\""; fi

  cat <<ENDJSON
{
  "generatedAt": "$timestamp",
  "generatedBy": "preflight-detector-v1",
  "stack": { "value": "$(json_escape "$STACK_VALUE")", "confidence": "$STACK_CONFIDENCE", "evidence": "$(json_escape "$STACK_EVIDENCE")" },
  "buildCommand": { "value": $build_val, "confidence": "$BUILD_CONFIDENCE", "evidence": "$(json_escape "$BUILD_EVIDENCE")" },
  "testCommand": { "value": $test_val, "confidence": "$TEST_CONFIDENCE", "evidence": "$(json_escape "$TEST_EVIDENCE")" },
  "packageManager": { "value": "$(json_escape "$PKG_VALUE")", "confidence": "$PKG_CONFIDENCE", "evidence": "$(json_escape "$PKG_EVIDENCE")" },
  "sourceRoot": { "value": "$(json_escape "$SRC_VALUE")", "confidence": "$SRC_CONFIDENCE", "evidence": "$(json_escape "$SRC_EVIDENCE")" },
  "frameworkVersion": { "value": "$(json_escape "$FW_VALUE")", "confidence": "$FW_CONFIDENCE", "evidence": "$(json_escape "$FW_EVIDENCE")" },
  "projectFiles": $pf_json
}
ENDJSON
}

# ─── Main ─────────────────────────────────────────────────────────
detect_stack
detect_build_command
detect_test_command
detect_package_manager
detect_framework_version
detect_source_root
detect_project_files

mkdir -p "$(dirname "$OUTPUT_PATH")"
generate_json > "$OUTPUT_PATH.tmp" && mv "$OUTPUT_PATH.tmp" "$OUTPUT_PATH"
exit 0

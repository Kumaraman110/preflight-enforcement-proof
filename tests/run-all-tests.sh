#!/usr/bin/env bash
# Test runner for preflight review system validation.
#
# Tests the reviewer ITSELF, not the service code. This ensures:
# - Rubric changes don't break detection of known-bad patterns
# - Operative rules fire/don't-fire correctly
# - Coupling analysis produces correct groupings
# - Rubric cross-check catches contradicting suggestions
#
# Usage: bash tests/run-all-tests.sh [--suite stage1|coupling|crosscheck|operative|behavioral]
#
# Exit 0 = all assertions pass
# Exit 1 = at least one assertion failed (details printed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FAILURES=0
PASSES=0
SUITE="${1:-all}"

red() { printf "\033[31m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }
yellow() { printf "\033[33m%s\033[0m\n" "$1"; }

assert_contains() {
  local haystack="$1" needle="$2" context="$3"
  if echo "$haystack" | grep -qi "$needle"; then
    PASSES=$((PASSES + 1))
  else
    red "FAIL: $context — expected to contain '$needle'"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" context="$3"
  if ! echo "$haystack" | grep -qi "$needle"; then
    PASSES=$((PASSES + 1))
  else
    red "FAIL: $context — expected NOT to contain '$needle'"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_json_field() {
  local json="$1" field="$2" expected="$3" context="$4"
  local actual
  actual=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field',''))" 2>/dev/null || echo "PARSE_ERROR")
  if [ "$actual" = "$expected" ]; then
    PASSES=$((PASSES + 1))
  else
    red "FAIL: $context — $field expected '$expected', got '$actual'"
    FAILURES=$((FAILURES + 1))
  fi
}

# ═══════════════════════════════════════════════════════════════
# SUITE: Stage 1 fixture detection
# Validates that the rubric contains detection patterns for each
# fixture's anti-patterns. This is a static check — it verifies
# the rubric has the signals, not that the LLM will find them.
# ═══════════════════════════════════════════════════════════════

run_stage1_tests() {
  echo ""
  echo "══════════════════════════════════════════"
  echo " Stage 1: Rubric coverage of fixtures"
  echo "══════════════════════════════════════════"
  echo ""

  local rubric="$PLUGIN_ROOT/examples/rubrics/rubric-migration-dotnet.md"

  if [ ! -f "$rubric" ]; then
    red "SKIP: rubric-migration.md not found at $rubric"
    return
  fi

  local rubric_content
  rubric_content=$(cat "$rubric")

  # known-bad-logging.cs expects §M9.1 and §M9.2 to exist
  assert_contains "$rubric_content" "M9.1\|Unsanitized" "Rubric has §M9.1 (unsanitized logging)"
  assert_contains "$rubric_content" "sanitiz" "Rubric mentions sanitization in logging section"

  # known-bad-token-cache.cs expects §M4.3 to exist
  assert_contains "$rubric_content" "M4.3\|thundering herd" "Rubric has §M4.3 (token cache)"
  assert_contains "$rubric_content" "GetOrCreateAsync\|thundering herd\|single-flight" "Rubric mentions GetOrCreateAsync or thundering herd"

  # known-bad-config.cs expects §M3.1 and §M2.2
  assert_contains "$rubric_content" "§M3.1\|M3\.1" "Rubric has §M3.1 (ConfigurationManager)"
  assert_contains "$rubric_content" "ConfigurationManager" "Rubric mentions ConfigurationManager"
  assert_contains "$rubric_content" "§M2.2\|M2\.2" "Rubric has §M2.2 (Service Locator)"
  assert_contains "$rubric_content" "Service Locator\|GetRequiredService" "Rubric mentions Service Locator pattern"

  # known-bad-http.cs expects §M4.1 and §M4.2
  assert_contains "$rubric_content" "§M4.1\|M4\.1" "Rubric has §M4.1 (WebClient)"
  assert_contains "$rubric_content" "WebClient" "Rubric mentions WebClient"
  assert_contains "$rubric_content" "§M4.2\|M4\.2" "Rubric has §M4.2 (System.Web)"
  assert_contains "$rubric_content" "HttpContext.Current\|System\.Web" "Rubric mentions HttpContext.Current or System.Web"
}

# ═══════════════════════════════════════════════════════════════
# SUITE: Promotion criteria wiring (post-federation contract)
# Validates that the federated capture/rubric contract is
# correctly wired: code-reviewer reads only the rubric,
# external-review-handler owns promotion criteria and lifecycle.
# ═══════════════════════════════════════════════════════════════

run_operative_rule_tests() {
  echo ""
  echo "══════════════════════════════════════════"
  echo " Promotion Criteria: Post-federation contract"
  echo "══════════════════════════════════════════"
  echo ""

  local reviewer="$PLUGIN_ROOT/agents/code-reviewer.md"

  if [ ! -f "$reviewer" ]; then
    red "SKIP: code-reviewer.md not found"
    return
  fi

  local reviewer_content
  reviewer_content=$(cat "$reviewer")

  # Post-federation: code-reviewer reads ONLY the rubric
  assert_contains "$reviewer_content" "do NOT read capture files" "Reviewer explicitly excludes capture files"
  assert_not_contains "$reviewer_content" "operative rules from capture" "Reviewer has no capture-as-operative language"
  assert_contains "$reviewer_content" "rubric and the diff. Nothing else" "Reviewer reads only rubric and diff"

  # Copilot-loop owns promotion criteria and lifecycle tracking
  local copilot_loop="$PLUGIN_ROOT/agents/external-review-handler.md"
  if [ -f "$copilot_loop" ]; then
    local loop_content
    loop_content=$(cat "$copilot_loop")
    assert_contains "$loop_content" "Survived.*0\|\\*\\*Survived:\\*\\* 0" "Copilot-loop initializes Survived at 0"
    assert_contains "$loop_content" "Incrementing" "Copilot-loop documents how to increment Survived"
    assert_contains "$loop_content" "\\*\\*FirstSeen:\\*\\*" "Copilot-loop templates have FirstSeen field"
    assert_contains "$loop_content" "\\*\\*Cycles:\\*\\*" "Copilot-loop templates have Cycles field"
    assert_contains "$loop_content" "Promotion Criteria" "Copilot-loop documents promotion criteria"
  fi

  # Rubric-edit process documents four-state lifecycle
  local rubric_edit="$PLUGIN_ROOT/docs/rubric-edit-process.md"
  if [ -f "$rubric_edit" ]; then
    local edit_content
    edit_content=$(cat "$rubric_edit")
    assert_contains "$edit_content" "Active" "Rubric-edit process documents Active state"
    assert_contains "$edit_content" "Promoted" "Rubric-edit process documents Promoted state"
    assert_contains "$edit_content" "Consumed" "Rubric-edit process documents Consumed state"
    assert_contains "$edit_content" "Deferred" "Rubric-edit process documents Deferred state"
    assert_contains "$edit_content" "Cycles.*2\|Cycles ≥ 2" "Rubric-edit process specifies TTL N=2"
  fi
}

# ═══════════════════════════════════════════════════════════════
# SUITE: Coupling analysis validation
# Validates that coupling signals are correctly identified in
# fixture code.
# ═══════════════════════════════════════════════════════════════

run_coupling_tests() {
  echo ""
  echo "══════════════════════════════════════════"
  echo " Coupling: Signal detection"
  echo "══════════════════════════════════════════"
  echo ""

  # DI-coupled pair should share an interface reference
  local token_file="$SCRIPT_DIR/coupling/fixtures/di-coupled-pair/TokenProvider.cs"
  local client_file="$SCRIPT_DIR/coupling/fixtures/di-coupled-pair/AccountClient.cs"

  if [ -f "$token_file" ] && [ -f "$client_file" ]; then
    # TokenProvider implements ITokenProvider
    assert_contains "$(cat "$token_file")" "ITokenProvider" "TokenProvider implements ITokenProvider"

    # AccountClient depends on ITokenProvider
    assert_contains "$(cat "$client_file")" "ITokenProvider" "AccountClient references ITokenProvider"

    # AccountClient calls method on the injected dependency
    assert_contains "$(cat "$client_file")" "_tokenProvider" "AccountClient uses _tokenProvider field"

    # These share a type reference — coupling signal
    local shared_type="ITokenProvider"
    local in_token in_client
    in_token=$(grep -c "$shared_type" "$token_file" || echo 0)
    in_client=$(grep -c "$shared_type" "$client_file" || echo 0)

    if [ "$in_token" -gt 0 ] && [ "$in_client" -gt 0 ]; then
      green "PASS: DI coupling detected — shared type $shared_type in both files"
      PASSES=$((PASSES + 1))
    else
      red "FAIL: DI coupling NOT detected between TokenProvider and AccountClient"
      FAILURES=$((FAILURES + 1))
    fi
  else
    yellow "SKIP: di-coupled-pair fixtures not found"
  fi

  # Independent pair should share NO type references
  local dockerfile="$SCRIPT_DIR/coupling/fixtures/independent-pair/Dockerfile"
  local launch_file="$SCRIPT_DIR/coupling/fixtures/independent-pair/launchSettings.json"

  if [ -f "$dockerfile" ] && [ -f "$launch_file" ]; then
    # Dockerfile and launchSettings share no C# types, no imports, no call chains
    # The validator's step 1 (shared imports) should find nothing
    local docker_content launch_content
    docker_content=$(cat "$dockerfile")
    launch_content=$(cat "$launch_file")

    # No using statements in either (one is Docker, one is JSON)
    assert_not_contains "$docker_content" "^using " "Dockerfile has no C# imports"
    assert_not_contains "$launch_content" "^using " "launchSettings has no C# imports"

    green "PASS: Independent pair confirmed — no structural coupling signals"
    PASSES=$((PASSES + 1))
  else
    yellow "SKIP: independent-pair fixtures not found"
  fi
}

# ═══════════════════════════════════════════════════════════════
# SUITE: Rubric cross-check
# Validates that the CONTRADICTS_RUBRIC classification exists
# and the cross-check step is documented in external-review-handler.
# ═══════════════════════════════════════════════════════════════

run_crosscheck_tests() {
  echo ""
  echo "══════════════════════════════════════════"
  echo " Rubric Cross-check: Anti-oscillation"
  echo "══════════════════════════════════════════"
  echo ""

  local copilot_loop="$PLUGIN_ROOT/agents/external-review-handler.md"

  if [ ! -f "$copilot_loop" ]; then
    red "SKIP: external-review-handler.md not found"
    return
  fi

  local loop_content
  loop_content=$(cat "$copilot_loop")

  # Step 7.5 exists
  assert_contains "$loop_content" "Step 7.5\|Rubric cross-check" "Cross-check step exists in external-review-handler"

  # CONTRADICTS_RUBRIC classification exists
  assert_contains "$loop_content" "CONTRADICTS_RUBRIC" "CONTRADICTS_RUBRIC classification documented"

  # Cross-check happens BEFORE classification (step 8)
  # Verify ordering: 7.5 before 8
  local step75_line step8_line
  step75_line=$(grep -n "Step 7.5\|Rubric cross-check" "$copilot_loop" | head -1 | cut -d: -f1)
  step8_line=$(grep -n "Step 8.*Classify" "$copilot_loop" | head -1 | cut -d: -f1)

  if [ -n "$step75_line" ] && [ -n "$step8_line" ] && [ "$step75_line" -lt "$step8_line" ]; then
    green "PASS: Cross-check (line $step75_line) runs before classification (line $step8_line)"
    PASSES=$((PASSES + 1))
  else
    red "FAIL: Cross-check must run BEFORE classification step"
    FAILURES=$((FAILURES + 1))
  fi

  # Rubric BAD pattern matching is documented
  assert_contains "$loop_content" "BAD.*pattern\|anti-pattern" "Cross-check matches against rubric BAD patterns"

  # false-positives.md is the destination for contradictions
  assert_contains "$loop_content" "false-positives" "Contradictions written to false-positives.md"

  # Fix-and-close handles the new stability category
  local fac="$PLUGIN_ROOT/skills/fix-and-close/SKILL.md"
  if [ -f "$fac" ]; then
    local fac_content
    fac_content=$(cat "$fac")
    assert_contains "$fac_content" "CONTRADICTS_RUBRIC" "fix-and-close handles CONTRADICTS_RUBRIC"
    assert_contains "$fac_content" "rubric wins" "fix-and-close defaults to rubric winning"
  fi
}

# ═══════════════════════════════════════════════════════════════
# SUITE: Behavioral (hook unit tests)
# Validates hook scripts in isolation using temp workspaces.
# ═══════════════════════════════════════════════════════════════

run_behavioral_tests() {
  echo ""
  echo "══════════════════════════════════════════"
  echo " Behavioral: Hook unit tests"
  echo "══════════════════════════════════════════"
  echo ""

  local test_script="$SCRIPT_DIR/behavioral/drift-detector-test.sh"
  if [ -f "$test_script" ]; then
    if bash "$test_script"; then
      PASSES=$((PASSES + 5))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: Drift detector behavioral tests failed"
    fi
  else
    yellow "SKIP: drift-detector-test.sh not found"
  fi

  local detector_test="$SCRIPT_DIR/behavioral/detector-test.sh"
  if [ -f "$detector_test" ]; then
    if bash "$detector_test"; then
      PASSES=$((PASSES + 10))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: Detector module behavioral tests failed"
    fi
  else
    yellow "SKIP: detector-test.sh not found"
  fi

  local detect_stack_test="$SCRIPT_DIR/behavioral/detect-stack-test.sh"
  if [ -f "$detect_stack_test" ]; then
    if bash "$detect_stack_test"; then
      PASSES=$((PASSES + 7))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: Detect-stack shared module tests failed"
    fi
  else
    yellow "SKIP: detect-stack-test.sh not found"
  fi

  local write_gate_test="$SCRIPT_DIR/behavioral/bootstrap-write-gate-test.sh"
  if [ -f "$write_gate_test" ]; then
    if bash "$write_gate_test"; then
      PASSES=$((PASSES + 7))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: Bootstrap write-gate tests failed"
    fi
  else
    yellow "SKIP: bootstrap-write-gate-test.sh not found"
  fi

  local rubric_gate_test="$SCRIPT_DIR/behavioral/rubric-validity-gate-test.sh"
  if [ -f "$rubric_gate_test" ]; then
    if bash "$rubric_gate_test"; then
      PASSES=$((PASSES + 10))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: Rubric validity gate tests failed"
    fi
  else
    yellow "SKIP: rubric-validity-gate-test.sh not found"
  fi
}

# ═══════════════════════════════════════════════════════════════
# SUITE: Scan profile format and pattern tests
# Validates that the scan profile format spec, example profile,
# and minimal scan patterns all work correctly.
# ═══════════════════════════════════════════════════════════════

run_scan_profile_tests() {
  echo ""
  echo "══════════════════════════════════════════"
  echo " Scan Profiles: Format and pattern tests"
  echo "══════════════════════════════════════════"
  echo ""

  local test_script="$SCRIPT_DIR/scan-profiles/run-tests.sh"
  if [ -f "$test_script" ]; then
    local result
    if result=$(bash "$test_script" 2>&1); then
      local sub_passes
      sub_passes=$(echo "$result" | grep "Scan profile tests:" | awk '{print $4}')
      PASSES=$((PASSES + ${sub_passes:-0}))
    else
      local sub_passes sub_failures
      sub_passes=$(echo "$result" | grep "Scan profile tests:" | awk '{print $4}')
      sub_failures=$(echo "$result" | grep "Scan profile tests:" | awk '{print $6}')
      PASSES=$((PASSES + ${sub_passes:-0}))
      FAILURES=$((FAILURES + ${sub_failures:-1}))
      red "FAIL: scan-profiles suite had failures"
      echo "$result" | grep "^FAIL:" || true
    fi
  else
    yellow "SKIP: scan-profiles/run-tests.sh not found"
  fi
}

# ═══════════════════════════════════════════════════════════════
# SUITE: Dependency-map-validator hook tests
# Validates: hybrid HEAD-stamp validation logic for map freshness.
# ═══════════════════════════════════════════════════════════════

run_dependency_map_validator_tests() {
  echo ""
  echo "══════════════════════════════════════════"
  echo " Dependency Map Validator: Hook tests"
  echo "══════════════════════════════════════════"
  echo ""

  local test_script="$SCRIPT_DIR/dependency-map-validator/run-tests.sh"
  if [ -f "$test_script" ]; then
    local result
    if result=$(bash "$test_script" 2>&1); then
      local sub_passes
      sub_passes=$(echo "$result" | grep "Dependency-map-validator tests:" | awk '{print $3}')
      PASSES=$((PASSES + ${sub_passes:-0}))
    else
      local sub_passes sub_failures
      sub_passes=$(echo "$result" | grep "Dependency-map-validator tests:" | awk '{print $3}')
      sub_failures=$(echo "$result" | grep "Dependency-map-validator tests:" | awk '{print $5}')
      PASSES=$((PASSES + ${sub_passes:-0}))
      FAILURES=$((FAILURES + ${sub_failures:-1}))
      red "FAIL: dependency-map-validator suite had failures"
      echo "$result" | grep "^FAIL:" || true
    fi
  else
    yellow "SKIP: dependency-map-validator/run-tests.sh not found"
  fi
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════

echo "╔══════════════════════════════════════════╗"
echo "║  preflight Review System Test Suite     ║"
echo "╚══════════════════════════════════════════╝"

case "$SUITE" in
  all)
    run_stage1_tests
    run_operative_rule_tests
    run_coupling_tests
    run_crosscheck_tests
    run_behavioral_tests
    run_scan_profile_tests
    run_dependency_map_validator_tests
    ;;
  stage1) run_stage1_tests ;;
  operative) run_operative_rule_tests ;;
  coupling) run_coupling_tests ;;
  crosscheck) run_crosscheck_tests ;;
  behavioral) run_behavioral_tests ;;
  scan-profiles) run_scan_profile_tests ;;
  dependency-map-validator) run_dependency_map_validator_tests ;;
  *)
    red "Unknown suite: $SUITE"
    echo "Usage: $0 [all|stage1|operative|coupling|crosscheck|behavioral|scan-profiles|dependency-map-validator]"
    exit 1
    ;;
esac

echo ""
echo "══════════════════════════════════════════"
echo " Results: $PASSES passed, $FAILURES failed"
echo "══════════════════════════════════════════"

if [ "$FAILURES" -gt 0 ]; then
  red "FAILED: $FAILURES assertion(s) failed"
  exit 1
else
  green "ALL TESTS PASSED ($PASSES assertions)"
  exit 0
fi

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

  local resolve_config_test="$SCRIPT_DIR/behavioral/resolve-config-test.sh"
  if [ -f "$resolve_config_test" ]; then
    if bash "$resolve_config_test"; then
      PASSES=$((PASSES + 34))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: Resolve-config tests failed"
    fi
  else
    yellow "SKIP: resolve-config-test.sh not found"
  fi

  local extract_overrides_test="$SCRIPT_DIR/behavioral/extract-overrides-test.sh"
  if [ -f "$extract_overrides_test" ]; then
    if bash "$extract_overrides_test"; then
      PASSES=$((PASSES + 10))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: Extract-overrides tests failed"
    fi
  else
    yellow "SKIP: extract-overrides-test.sh not found"
  fi

  local tdd_resolution_test="$SCRIPT_DIR/behavioral/tdd-skill-resolution-test.sh"
  if [ -f "$tdd_resolution_test" ]; then
    if bash "$tdd_resolution_test"; then
      PASSES=$((PASSES + 7))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: TDD-skill resolution tests failed"
    fi
  else
    yellow "SKIP: tdd-skill-resolution-test.sh not found"
  fi

  local review_thread_test="$SCRIPT_DIR/behavioral/review-thread-resolution-test.sh"
  if [ -f "$review_thread_test" ]; then
    if bash "$review_thread_test"; then
      PASSES=$((PASSES + 11))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: Review-thread-resolution tests failed"
    fi
  else
    yellow "SKIP: review-thread-resolution-test.sh not found"
  fi

  local prune_confinement_test="$SCRIPT_DIR/behavioral/install-prune-confinement-test.sh"
  if [ -f "$prune_confinement_test" ]; then
    if bash "$prune_confinement_test"; then
      PASSES=$((PASSES + 14))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: install-prune path-traversal confinement tests failed"
    fi
  else
    yellow "SKIP: install-prune-confinement-test.sh not found"
  fi

  local remote_guard_test="$SCRIPT_DIR/behavioral/pre-push-remote-guard-test.sh"
  if [ -f "$remote_guard_test" ]; then
    if bash "$remote_guard_test"; then
      PASSES=$((PASSES + 8))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: pre-push remote/repo guard tests failed (A1 forbidden-destination)"
    fi
  else
    yellow "SKIP: pre-push-remote-guard-test.sh not found"
  fi

  local cpsl_incident_test="$SCRIPT_DIR/behavioral/pre-push-installed-cpsl-incident-test.sh"
  if [ -f "$cpsl_incident_test" ]; then
    if bash "$cpsl_incident_test"; then
      PASSES=$((PASSES + 12))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: pre-push installed-CPSL-incident tests failed (the inverted-clone repository-target incident, against the INSTALLED artifact: safe-PR allow / forbidden-PR block / implicit-origin-PR block / poc-push passes / origin-push block / alias→CPSL-slug block / direct-CPSL-URL block / no dangerous steering / fresh-install verifies clean / tampered install detected as DRIFT / reinstall restores byte-identical hook / restored hook still blocks the forbidden push). Destination IDENTITY (resolved slug) governs, never the remote-name alias."
    fi
  else
    yellow "SKIP: pre-push-installed-cpsl-incident-test.sh not found"
  fi

  local install_cwd_test="$SCRIPT_DIR/behavioral/install-cwd-independence-test.sh"
  if [ -f "$install_cwd_test" ]; then
    if bash "$install_cwd_test"; then
      PASSES=$((PASSES + 3))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: installer cwd-independence tests failed (A4 CODE_FORGE_DIR)"
    fi
  else
    yellow "SKIP: install-cwd-independence-test.sh not found"
  fi

  local copilot_path_test="$SCRIPT_DIR/behavioral/copilot-reviewer-path-test.sh"
  if [ -f "$copilot_path_test" ]; then
    if bash "$copilot_path_test"; then
      PASSES=$((PASSES + 1))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: copilot reviewer-path test failed (A2 prescriptive --add-reviewer)"
    fi
  else
    yellow "SKIP: copilot-reviewer-path-test.sh not found"
  fi

  local ci_liveness_test="$SCRIPT_DIR/behavioral/ci-gate-liveness-template-test.sh"
  if [ -f "$ci_liveness_test" ]; then
    if bash "$ci_liveness_test"; then
      PASSES=$((PASSES + 5))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: CI gate-liveness template tests failed (A5 dead-gate exit-capture)"
    fi
  else
    yellow "SKIP: ci-gate-liveness-template-test.sh not found"
  fi

  local null_lint_test="$SCRIPT_DIR/behavioral/null-boundary-lint-test.sh"
  if [ -f "$null_lint_test" ]; then
    if bash "$null_lint_test"; then
      PASSES=$((PASSES + 11))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: null-boundary lint tests failed (issue #8 fail-open class)"
    fi
  else
    yellow "SKIP: null-boundary-lint-test.sh not found"
  fi

  local overlay_test="$SCRIPT_DIR/behavioral/config-local-overlay-test.sh"
  if [ -f "$overlay_test" ]; then
    if bash "$overlay_test"; then
      PASSES=$((PASSES + 10))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: config.local.json overlay tests failed (issue #6 per-clone topology)"
    fi
  else
    yellow "SKIP: config-local-overlay-test.sh not found"
  fi

  local convergence_test="$SCRIPT_DIR/behavioral/convergence-semantics-test.sh"
  if [ -f "$convergence_test" ]; then
    if bash "$convergence_test"; then
      PASSES=$((PASSES + 7))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: convergence-semantics tests failed (issue #8 CONVERGED != clean)"
    fi
  else
    yellow "SKIP: convergence-semantics-test.sh not found"
  fi

  local taut_lint_test="$SCRIPT_DIR/behavioral/anti-tautology-lint-test.sh"
  if [ -f "$taut_lint_test" ]; then
    if bash "$taut_lint_test"; then
      PASSES=$((PASSES + 7))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: anti-tautology lint tests failed (issue #7 self-asserting tests)"
    fi
  else
    yellow "SKIP: anti-tautology-lint-test.sh not found"
  fi

  local evidence_scope_test="$SCRIPT_DIR/behavioral/evidence-gate-scoping-test.sh"
  if [ -f "$evidence_scope_test" ]; then
    if bash "$evidence_scope_test"; then
      PASSES=$((PASSES + 5))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: evidence-gate scoping tests failed (NEW-3 session-root anchoring)"
    fi
  else
    yellow "SKIP: evidence-gate-scoping-test.sh not found"
  fi

  local selfcheck_test="$SCRIPT_DIR/behavioral/selfcheck-liveness-test.sh"
  if [ -f "$selfcheck_test" ]; then
    if bash "$selfcheck_test"; then
      PASSES=$((PASSES + 4))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: gate-liveness selfcheck tests failed (issue #10 present-but-dead gates)"
    fi
  else
    yellow "SKIP: selfcheck-liveness-test.sh not found"
  fi

  local wire_format_test="$SCRIPT_DIR/behavioral/wire-format-parity-test.sh"
  if [ -f "$wire_format_test" ]; then
    if bash "$wire_format_test"; then
      PASSES=$((PASSES + 13))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: wire-format parity tests failed (issue #5 WIRE-A serialized-name dimension)"
    fi
  else
    yellow "SKIP: wire-format-parity-test.sh not found"
  fi

  local tripwire_test="$SCRIPT_DIR/behavioral/sentinel-tripwire-test.sh"
  if [ -f "$tripwire_test" ]; then
    if bash "$tripwire_test"; then
      PASSES=$((PASSES + 10))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: sentinel-tripwire tests failed (gap #5 self-approval hardening; incl. the line-244 \$[ arithmetic-misparse that silently broke the variable-expansion obfuscation branch)"
    fi
  else
    yellow "SKIP: sentinel-tripwire-test.sh not found"
  fi

  local registration_test="$SCRIPT_DIR/behavioral/registration-check-test.sh"
  if [ -f "$registration_test" ]; then
    if bash "$registration_test"; then
      PASSES=$((PASSES + 8))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: registration-check tests failed (issue #10 file-level registration liveness)"
    fi
  else
    yellow "SKIP: registration-check-test.sh not found"
  fi

  local verify_floor_test="$SCRIPT_DIR/behavioral/verify-manifest-floor-test.sh"
  if [ -f "$verify_floor_test" ]; then
    if bash "$verify_floor_test"; then
      PASSES=$((PASSES + 14))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: verify-manifest-floor tests failed (M11: a degenerate manifest — empty/null/absent/non-object artifacts, or zero files — must FAIL, not 'Integrity: PASS'; H7: a skill must be CONTENT-checked by tree-SHA so a tampered/added/removed/deleted SKILL.md is DRIFT, not a silent OK/WARN; JOINT GUARD: an untampered real install must still PASS)"
    fi
  else
    yellow "SKIP: verify-manifest-floor-test.sh not found"
  fi

  local coverage_default_test="$SCRIPT_DIR/behavioral/coverage-default-consistency-test.sh"
  if [ -f "$coverage_default_test" ]; then
    if bash "$coverage_default_test"; then
      PASSES=$((PASSES + 11))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: coverage-default consistency tests failed (gap #29 80-vs-85 reconciliation)"
    fi
  else
    yellow "SKIP: coverage-default-consistency-test.sh not found"
  fi

  local wire_golden_test="$SCRIPT_DIR/behavioral/wire-golden-test.sh"
  if [ -f "$wire_golden_test" ]; then
    if bash "$wire_golden_test"; then
      PASSES=$((PASSES + 6))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: wire-golden tests failed (issue #5 WIRE-B byte-level wire parity)"
    fi
  else
    yellow "SKIP: wire-golden-test.sh not found"
  fi

  local branch_cut_test="$SCRIPT_DIR/behavioral/pre-branch-cut-test.sh"
  if [ -f "$branch_cut_test" ]; then
    if bash "$branch_cut_test"; then
      PASSES=$((PASSES + 8))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: pre-branch-cut cleanliness tests failed (G4 branch-crossover drift)"
    fi
  else
    yellow "SKIP: pre-branch-cut-test.sh not found"
  fi

  local adjudication_shape_test="$SCRIPT_DIR/behavioral/adjudication-shape-test.sh"
  if [ -f "$adjudication_shape_test" ]; then
    if bash "$adjudication_shape_test"; then
      PASSES=$((PASSES + 7))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: adjudication-shape tests failed (L2 fail-closed on unexpected top-level shape)"
    fi
  else
    yellow "SKIP: adjudication-shape-test.sh not found"
  fi

  local coupled_failclosed_test="$SCRIPT_DIR/behavioral/coupled-gate-failclosed-test.sh"
  if [ -f "$coupled_failclosed_test" ]; then
    if bash "$coupled_failclosed_test"; then
      PASSES=$((PASSES + 8))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: coupled-gate fail-closed tests failed (L1 unreadable groups file)"
    fi
  else
    yellow "SKIP: coupled-gate-failclosed-test.sh not found"
  fi

  local migrate_check3_test="$SCRIPT_DIR/behavioral/migrate-check3-shortproc-test.sh"
  if [ -f "$migrate_check3_test" ]; then
    if bash "$migrate_check3_test"; then
      PASSES=$((PASSES + 12))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: migrate-check3-shortproc tests failed (M15: Check-3 must FAIL on a genuinely-absent REACHABLE proc — short 'usp' [the <5 length skip dropped it] OR a heading-only '### \`<proc>\`' proc absent from the summary table [dual-format bypass] — via column-1 + heading-form extraction with the <5 gate deleted; without false-MISSING on header/marker/call-chain words, and still skipping NOT-REACHABLE procs [table- and heading-form] length-independently)"
    fi
  else
    yellow "SKIP: migrate-check3-shortproc-test.sh not found"
  fi

  local wire_golden_delim_test="$SCRIPT_DIR/behavioral/wire-golden-delimiter-safe-test.sh"
  if [ -f "$wire_golden_delim_test" ]; then
    if bash "$wire_golden_delim_test"; then
      PASSES=$((PASSES + 6))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: wire-golden-delimiter-safe tests failed (M10: a '|' in a sample/golden value must NOT yield an assertion-less exit-0 'green' test — the substitution must be an index()-based literal splice [not sed s|…| nor awk gsub, which corrupts &/backslash], with a PIPESTATUS backstop; real clean fixtures must stay byte-identical with one string.Equals per case)"
    fi
  else
    yellow "SKIP: wire-golden-delimiter-safe-test.sh not found"
  fi

  local parity_behaviors_guard_test="$SCRIPT_DIR/behavioral/parity-behaviors-key-guard-test.sh"
  if [ -f "$parity_behaviors_guard_test" ]; then
    if bash "$parity_behaviors_guard_test"; then
      PASSES=$((PASSES + 9))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: parity-behaviors-key-guard tests failed (M6: a missing/renamed/typo'd or non-list top-level \"behaviors\" key must be could-not-run exit 3 [symmetric on baseline+current] — never a silent .get default that masks a dropped behavior as CLEAN exit 0 or a phantom exit 2; a genuine zero-behavior {\"behaviors\":[]} still passes the guard and keeps its 0/2 verdict)"
    fi
  else
    yellow "SKIP: parity-behaviors-key-guard-test.sh not found"
  fi

  local adjudication_citation_test="$SCRIPT_DIR/behavioral/adjudication-citation-regex-test.sh"
  if [ -f "$adjudication_citation_test" ]; then
    if bash "$adjudication_citation_test"; then
      PASSES=$((PASSES + 19))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: adjudication-citation-regex tests failed (M2: the citedEvidence regex must BLOCK prose word:digit tokens [ratio/version/timestamp — was a false-green allow] by anchoring the file:line branch to a real source-extension allow-list, AND must ALLOW genuine letter-prefixed rule ids §G2.1/§M4.3/§D1/§M3 [was wrongly rejected by §[0-9]+] while keeping genuine file:line citations and digit §-ids accepted)"
    fi
  else
    yellow "SKIP: adjudication-citation-regex-test.sh not found"
  fi

  local depmap_empty_test="$SCRIPT_DIR/behavioral/depmap-empty-mapfiles-test.sh"
  if [ -f "$depmap_empty_test" ]; then
    if bash "$depmap_empty_test"; then
      PASSES=$((PASSES + 5))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: depmap-empty-mapfiles tests failed (M3: empty/missing mapFiles must be STALE exit 1 and NOT re-stamped — never a FRESH exit 0 that launders a non-validatable sidecar; a correct list still validates normally)"
    fi
  else
    yellow "SKIP: depmap-empty-mapfiles-test.sh not found"
  fi

  local rubric_added_failclosed_test="$SCRIPT_DIR/behavioral/rubric-source-added-failclosed-test.sh"
  if [ -f "$rubric_added_failclosed_test" ]; then
    if bash "$rubric_added_failclosed_test"; then
      PASSES=$((PASSES + 4))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: rubric-source-added-failclosed tests failed (M5: --added mode must check git's real exit status BEFORE the grep — a git failure [bad base-ref, non-git dir, shallow/detached] is could-not-run exit 2, NEVER a swallowed empty-diff CLEAN exit 0; a legitimately-empty diff stays CLEAN exit 0)"
    fi
  else
    yellow "SKIP: rubric-source-added-failclosed-test.sh not found"
  fi

  local detector_write_test="$SCRIPT_DIR/behavioral/detector-write-failclosed-test.sh"
  if [ -f "$detector_write_test" ]; then
    if bash "$detector_write_test"; then
      PASSES=$((PASSES + 5))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: detector-write-failclosed tests failed (M8: a failed state-file write [redirect/mv error, un-creatable parent, .tmp occupied] must exit 1 with a diagnostic and leave no stale file as 'current' — never the unconditional exit 0 that retained a stale state.json; a normal write still exits 0 with valid JSON)"
    fi
  else
    yellow "SKIP: detector-write-failclosed-test.sh not found"
  fi

  local blob_syntax_nprefix_test="$SCRIPT_DIR/behavioral/blob-syntax-nprefix-test.sh"
  if [ -f "$blob_syntax_nprefix_test" ]; then
    if bash "$blob_syntax_nprefix_test"; then
      PASSES=$((PASSES + 5))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: blob-syntax-nprefix tests failed (M9: --check-blob-syntax must catch an 'N|' line-prefix corruption that is valid bash grammar [single-statement-per-line passes bash -n] via a structural scan [head-1 N|-prefixed OR >=2 consecutive ^[0-9]+| lines] + a shebang sanity check — while a clean hook, a single incidental N| heredoc line, and the multi-line c0e01a4 shape behave correctly)"
    fi
  else
    yellow "SKIP: blob-syntax-nprefix-test.sh not found"
  fi

  local selftest_missing_gate_test="$SCRIPT_DIR/behavioral/selftest-missing-gate-test.sh"
  if [ -f "$selftest_missing_gate_test" ]; then
    if bash "$selftest_missing_gate_test"; then
      PASSES=$((PASSES + 4))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: selftest-missing-gate tests failed (M12: preflight-selftest must report a MISSING mandatory gate as DEAD exit 1 [not SKIP+green], and a coverage assertion must catch any PreToolUse gate registered in hooks.json but not self-tested [incl. the prior behavioral-contract-gate omission] — while the genuinely-optional dependency-map-validator stays a legitimate SKIP when absent)"
    fi
  else
    yellow "SKIP: selftest-missing-gate-test.sh not found"
  fi

  local coupled_pathform_test="$SCRIPT_DIR/behavioral/coupled-edit-pathform-test.sh"
  if [ -f "$coupled_pathform_test" ]; then
    if bash "$coupled_pathform_test"; then
      PASSES=$((PASSES + 20))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: coupled-edit-pathform tests failed (H3+H4: membership must match an ABSOLUTE/./-prefixed file_path by canonical /-anchored-suffix — not fail open — without false-blocking a shared-basename file; and a group counts unacknowledged unless acknowledged==true [missing/null/string/0 all BLOCK]; writer normalizes missing acknowledged->false; jq and python backends must agree)"
    fi
  else
    yellow "SKIP: coupled-edit-pathform-test.sh not found"
  fi

  local coupled_matcher_test="$SCRIPT_DIR/behavioral/coupled-edit-matcher-test.sh"
  if [ -f "$coupled_matcher_test" ]; then
    if bash "$coupled_matcher_test"; then
      PASSES=$((PASSES + 9))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: coupled-edit-matcher tests failed (M13: coupled-edit-gate must be registered under the Write AND Edit|MultiEdit matchers so a whole-file Write/MultiEdit to a coupled file is gated, not just Edit; a Write to a coupled file in an unacked group must BLOCK, and an unrelated/acknowledged Write must ALLOW; the Bash-seam residual must be honesty-labeled in fix-and-close SKILL.md)"
    fi
  else
    yellow "SKIP: coupled-edit-matcher-test.sh not found"
  fi

  local agent_scorer_test="$SCRIPT_DIR/behavioral/agent-scorer-test.sh"
  if [ -f "$agent_scorer_test" ]; then
    if bash "$agent_scorer_test"; then
      PASSES=$((PASSES + 14))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: agent-scorer tests failed (independent judgment scorer; RED->GREEN overclaim + no-gate-feed)"
    fi
  else
    yellow "SKIP: agent-scorer-test.sh not found"
  fi

  local decision_emission_test="$SCRIPT_DIR/behavioral/decision-emission-test.sh"
  if [ -f "$decision_emission_test" ]; then
    if bash "$decision_emission_test"; then
      PASSES=$((PASSES + 8))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: decision-emission tests failed (record-claim faithful recorder; verbatim + no-self-assess + end-to-end)"
    fi
  else
    yellow "SKIP: decision-emission-test.sh not found"
  fi

  local rubric_overlay_test="$SCRIPT_DIR/behavioral/rubric-overlay-check-test.sh"
  if [ -f "$rubric_overlay_test" ]; then
    if bash "$rubric_overlay_test"; then
      PASSES=$((PASSES + 8))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: rubric-overlay-check tests failed (Model B governance POC; overlay must not weaken the base)"
    fi
  else
    yellow "SKIP: rubric-overlay-check-test.sh not found"
  fi

  local bc_gate_test="$SCRIPT_DIR/behavioral/behavioral-contract-gate-test.sh"
  if [ -f "$bc_gate_test" ]; then
    if bash "$bc_gate_test"; then
      PASSES=$((PASSES + 11))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: behavioral-contract-gate tests failed (staged fail-closed mechanism; bypass must BLOCK, spec-output not accepted as contract)"
    fi
  else
    yellow "SKIP: behavioral-contract-gate-test.sh not found"
  fi

  local rubric_resolve_test="$SCRIPT_DIR/behavioral/rubric-resolve-test.sh"
  if [ -f "$rubric_resolve_test" ]; then
    if bash "$rubric_resolve_test"; then
      PASSES=$((PASSES + 8))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: rubric-resolve tests failed (Model B merge engine; weakening overlay must ABORT the merge, not silently drop)"
    fi
  else
    yellow "SKIP: rubric-resolve-test.sh not found"
  fi

  local rubric_source_test="$SCRIPT_DIR/behavioral/rubric-source-check-test.sh"
  if [ -f "$rubric_source_test" ]; then
    if bash "$rubric_source_test"; then
      PASSES=$((PASSES + 9))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: rubric-source-check tests failed (enforced provenance; a rule with no Source line must fail — mechanism not convention)"
    fi
  else
    yellow "SKIP: rubric-source-check-test.sh not found"
  fi

  local codeowners_test="$SCRIPT_DIR/behavioral/base-owners-codeowners-test.sh"
  if [ -f "$codeowners_test" ]; then
    if bash "$codeowners_test"; then
      PASSES=$((PASSES + 5))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: base-owners-codeowners tests failed (base rubric owner-governed; stub state must be honestly surfaced, not silently fail-open)"
    fi
  else
    yellow "SKIP: base-owners-codeowners-test.sh not found"
  fi

  local rubric_ci_test="$SCRIPT_DIR/behavioral/rubric-governance-ci-test.sh"
  if [ -f "$rubric_ci_test" ]; then
    if bash "$rubric_ci_test"; then
      PASSES=$((PASSES + 6))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: rubric-governance-ci tests failed (advisory-first CI step; must wire both checks, stay advisory, be dead-gate-safe)"
    fi
  else
    yellow "SKIP: rubric-governance-ci-test.sh not found"
  fi

  local spec_div_test="$SCRIPT_DIR/behavioral/spec-divergence-poc-test.sh"
  if [ -f "$spec_div_test" ]; then
    if bash "$spec_div_test"; then
      PASSES=$((PASSES + 8))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: spec-divergence-poc tests failed (POC#1 token-Jaccard scorer math; identical->0, maxdiff->1, deterministic, computed-not-self-assessed)"
    fi
  else
    yellow "SKIP: spec-divergence-poc-test.sh not found"
  fi

  local spec_integ_cluster_test="$SCRIPT_DIR/behavioral/spec-integrity-cluster-test.sh"
  if [ -f "$spec_integ_cluster_test" ]; then
    if bash "$spec_integ_cluster_test"; then
      PASSES=$((PASSES + 14))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: spec-integrity-cluster tests failed (M4: a zero-.cs source + a spec declaring an anchor must FAIL could-not-verify, not PASS; H5: an empty/empty-category spec must NOT skip the source->spec forge-catch; M7: a K&R 'public class Foo {' line must NOT yield a phantom field; THE 3-WAY GUARD: a REAL omitted property STILL FAILs after all three — M7's narrowing must not blunt H5's catch)"
    fi
  else
    yellow "SKIP: spec-integrity-cluster-test.sh not found"
  fi

  local spec_div_sem_test="$SCRIPT_DIR/behavioral/spec-divergence-semantic-poc-test.sh"
  if [ -f "$spec_div_sem_test" ]; then
    if bash "$spec_div_sem_test"; then
      PASSES=$((PASSES + 8))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: spec-divergence-semantic-poc tests failed (POC#2 semantic aggregator; agree->0, fork->1, p1-inversion-fixed, vague>specified separation)"
    fi
  else
    yellow "SKIP: spec-divergence-semantic-poc-test.sh not found"
  fi

  local spec_div_eng_test="$SCRIPT_DIR/behavioral/spec-divergence-engine-test.sh"
  if [ -f "$spec_div_eng_test" ]; then
    if bash "$spec_div_eng_test"; then
      PASSES=$((PASSES + 11))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: spec-divergence-engine tests failed (productionized engine; blind-judge-brief, semantic score, ELICIT/PROCEED decision, targeted questions, elicited artifact, advisory threshold)"
    fi
  else
    yellow "SKIP: spec-divergence-engine-test.sh not found"
  fi

  local spec_div_wire_test="$SCRIPT_DIR/behavioral/spec-divergence-wiring-test.sh"
  if [ -f "$spec_div_wire_test" ]; then
    if bash "$spec_div_wire_test"; then
      PASSES=$((PASSES + 10))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: spec-divergence-wiring tests failed (Phase 0 wired into scaffold+migrate at fresh-ambiguity entry points, advisory, not on internal dispatches)"
    fi
  else
    yellow "SKIP: spec-divergence-wiring-test.sh not found"
  fi

  local spec_div_pref_test="$SCRIPT_DIR/behavioral/spec-divergence-prefilter-test.sh"
  if [ -f "$spec_div_pref_test" ]; then
    if bash "$spec_div_pref_test"; then
      PASSES=$((PASSES + 7))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: spec-divergence-prefilter tests failed (cheap mechanical pre-check; obviously-detailed->SKIP, vague/padded/borderline/short/empty->RUN-CHECK, conservative; drama can't manufacture a SKIP)"
    fi
  else
    yellow "SKIP: spec-divergence-prefilter-test.sh not found"
  fi

  local cov_gap_test="$SCRIPT_DIR/behavioral/coverage-gap-detection-test.sh"
  if [ -f "$cov_gap_test" ]; then
    if bash "$cov_gap_test"; then
      PASSES=$((PASSES + 13))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: coverage-gap-detection tests failed (L1 source-agnostic capture: any source reaches capture; L2 mechanical gap classification: BLIND-SPOT/UNCOVERED-CLASS/NEW-COVERAGE; INTEGRITY: classification is computed from artifacts, immune to the working agent's self-assessment — claims can't suppress or manufacture a gap)"
    fi
  else
    yellow "SKIP: coverage-gap-detection-test.sh not found"
  fi

  local cov_gap_signal_test="$SCRIPT_DIR/behavioral/coverage-gap-signal-body-test.sh"
  if [ -f "$cov_gap_signal_test" ]; then
    if bash "$cov_gap_signal_test"; then
      PASSES=$((PASSES + 3))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: coverage-gap-signal-body tests failed (G3: a detection-signal keyword matched in a rule BODY must classify BLIND-SPOT attributed to the containing rule, not be silently dropped to UNCOVERED-CLASS — a covered miss must not be mislabeled an uncovered class; an absent token must still be UNCOVERED-CLASS, no manufactured coverage)"
    fi
  else
    yellow "SKIP: coverage-gap-signal-body-test.sh not found"
  fi

  local cap_write_test="$SCRIPT_DIR/behavioral/capture-finding-write-failclosed-test.sh"
  if [ -f "$cap_write_test" ]; then
    if bash "$cap_write_test"; then
      PASSES=$((PASSES + 4))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: capture-finding-write-failclosed tests failed (G4: a FAILED capture write must FAIL CLOSED — error + non-zero exit, no 'captured:' success — never a silent loss; a lost capture is an invisible accountability gap. Normal writable capture and the usage-error path must be unchanged)"
    fi
  else
    yellow "SKIP: capture-finding-write-failclosed-test.sh not found"
  fi

  local sot_test="$SCRIPT_DIR/behavioral/source-of-truth-check-test.sh"
  if [ -f "$sot_test" ]; then
    if bash "$sot_test"; then
      PASSES=$((PASSES + 12))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: source-of-truth-check tests failed (the third gap-detector: a missing/empty/unreadable required source -> ESCALATE not guess; present -> PROCEED; INTEGRITY: presence is computed from the filesystem, immune to the agent's self-assessment — a claim of sufficiency can't override a mechanical absence, and drama can't manufacture a false escalation)"
    fi
  else
    yellow "SKIP: source-of-truth-check-test.sh not found"
  fi

  local sot_jq_test="$SCRIPT_DIR/behavioral/source-of-truth-jq-absent-test.sh"
  if [ -f "$sot_jq_test" ]; then
    if bash "$sot_jq_test"; then
      PASSES=$((PASSES + 3))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: source-of-truth-jq-absent tests failed (G5: when --json is supplied but jq is absent, the gate must FAIL CLOSED — ESCALATE, not silently drop the json-declared sources and PROCEED on a --require subset; the jq-present path must be unchanged)"
    fi
  else
    yellow "SKIP: source-of-truth-jq-absent-test.sh not found"
  fi

  local parity_exit_test="$SCRIPT_DIR/behavioral/parity-check-exit-codes-test.sh"
  if [ -f "$parity_exit_test" ]; then
    if bash "$parity_exit_test"; then
      PASSES=$((PASSES + 9))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: parity-check-exit-codes tests failed (flagship-gate false-green; malformed spec MUST be 3=check-error, never 1=advisory)"
    fi
  else
    yellow "SKIP: parity-check-exit-codes-test.sh not found"
  fi

  local bare_push_test="$SCRIPT_DIR/behavioral/pre-push-bare-remote-test.sh"
  if [ -f "$bare_push_test" ]; then
    if bash "$bare_push_test"; then
      PASSES=$((PASSES + 10))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: pre-push-bare-remote tests failed (three-tier push policy: AUTO=allow / CONFIRM=ask / BLOCK=exit2; reversible pushes proceed, consequential ones confirm, force-to-protected & forbidden blocked)"
    fi
  else
    yellow "SKIP: pre-push-bare-remote-test.sh not found"
  fi

  local wedge_failclosed_test="$SCRIPT_DIR/behavioral/pre-push-wedge-failclosed-test.sh"
  if [ -f "$wedge_failclosed_test" ]; then
    if bash "$wedge_failclosed_test"; then
      PASSES=$((PASSES + 6))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: pre-push-wedge-failclosed tests failed (a wedged/slow push-safety hook must BLOCK (exit 2), never fall through to a non-blocking 124/137 that lets the push proceed ungated)"
    fi
  else
    yellow "SKIP: pre-push-wedge-failclosed-test.sh not found"
  fi

  # ── P0 router/engine split — timeout-budget invariant (the lost-invariant fail-OPEN RED guard) ──
  local rtr_budget_test="$SCRIPT_DIR/behavioral/router-timeout-budget-test.sh"
  if [ -f "$rtr_budget_test" ]; then
    if bash "$rtr_budget_test"; then
      PASSES=$((PASSES + 4))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: router-timeout-budget tests failed (the router's candidate deadline must be DERIVED from the hooks.json platform timeout so its fail-closed exit 2 always fires BEFORE the platform SIGKILL — a 137 is non-blocking = fail-OPEN)"
    fi
  else
    yellow "SKIP: router-timeout-budget-test.sh not found"
  fi

  # ── P0 router/engine split — fast-path latency SLO (zero external spawns on the ordinary path) ──
  local rtr_fastpath_test="$SCRIPT_DIR/behavioral/router-fastpath-latency-test.sh"
  if [ -f "$rtr_fastpath_test" ]; then
    if bash "$rtr_fastpath_test"; then
      PASSES=$((PASSES + 5))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: router-fastpath-latency tests failed (the ordinary Bash fast path must spawn ZERO external processes and never invoke the engine — the structural fix for the every-Bash-denial incident)"
    fi
  else
    yellow "SKIP: router-fastpath-latency-test.sh not found"
  fi

  # ── P0 Part B — branch-stable runtime: install/migrate/rollback/uninstall/hazard-detect lifecycle ──
  # Runs the runtime installer + verify hazard checks against throwaway consumers; involves the real engine
  # on a couple of router probes, so it is moderately slow on a scan-on-exec host but bounded.
  local branch_stable_test="$SCRIPT_DIR/behavioral/branch-stable-runtime-test.sh"
  if [ -f "$branch_stable_test" ]; then
    if bash "$branch_stable_test"; then
      PASSES=$((PASSES + 12))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: branch-stable-runtime tests failed (the Bash gate must register ONLY in the untracked local layer pinned to a SHA-runtime; ownership-aware migration must preserve non-Bash + foreign hooks and ABORT on ambiguity; duplicate/legacy registrations must FAIL verify)"
    fi
  else
    yellow "SKIP: branch-stable-runtime-test.sh not found"
  fi

  # ── P0 router/engine split — spawn-delay deterministic regression harness (the incident recreation) ──
  # NOTE: this harness injects a +1s/spawn tax and runs the REAL engine on candidate pushes, so on a
  # slow-spawn host it can take several minutes. It is registered but gated behind PREFLIGHT_RUN_SPAWN_DELAY
  # so the default suite run stays fast; CI / a deliberate slow-host run sets the flag to include it.
  local spawn_delay_test="$SCRIPT_DIR/behavioral/spawn-delay-harness-test.sh"
  if [ -f "$spawn_delay_test" ]; then
    if [ "${PREFLIGHT_RUN_SPAWN_DELAY:-0}" = "1" ]; then
      if bash "$spawn_delay_test"; then
        PASSES=$((PASSES + 15))
      else
        FAILURES=$((FAILURES + 1))
        red "FAIL: spawn-delay-harness tests failed (ordinary Bash must stay fast+allowed under an artificial per-spawn tax; candidate timeouts must be scoped; the every-Bash-denial incident must not recur)"
      fi
    else
      yellow "SKIP: spawn-delay-harness-test.sh (set PREFLIGHT_RUN_SPAWN_DELAY=1 to run; it is slow — injects a +1s/spawn tax through the real engine)"
    fi
  else
    yellow "SKIP: spawn-delay-harness-test.sh not found"
  fi

  local evidence_rc_test="$SCRIPT_DIR/behavioral/pre-push-evidence-rc-failclosed-test.sh"
  if [ -f "$evidence_rc_test" ]; then
    if bash "$evidence_rc_test"; then
      PASSES=$((PASSES + 4))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: pre-push-evidence-rc-failclosed tests failed (G6: an evidence-gate exit that is neither 0 nor 2 — e.g. 127 missing sibling, 1 set-e abort — is NON-blocking under PreToolUse; it must be normalized to a hard BLOCK (exit 2), never passed through; exit 0 and exit 2 paths unchanged)"
    fi
  else
    yellow "SKIP: pre-push-evidence-rc-failclosed-test.sh not found"
  fi

  local parser_bypass_test="$SCRIPT_DIR/behavioral/pre-push-parser-bypass-test.sh"
  if [ -f "$parser_bypass_test" ]; then
    if bash "$parser_bypass_test"; then
      PASSES=$((PASSES + 26))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: pre-push-parser-bypass tests failed (H1+H2: the structural push parser must detect+gate every invocation form — git -C/-c/--git-dir push, command/\\\\/env-prefix/abs-path git push, (git push)/{ git push;}, the '+'-refspec force [H1] — and FAIL CLOSED to CONFIRM on unparseable indirection (eval/bash -c/xargs); benign 'push'-containing commands and a normal safe push must NOT be over-gated)"
    fi
  else
    yellow "SKIP: pre-push-parser-bypass-test.sh not found"
  fi

  # ── live Gate-4 incident — shell line-continuation parser fail-open (security-significant) ──
  local continuation_test="$SCRIPT_DIR/behavioral/pre-push-continuation-failopen-test.sh"
  if [ -f "$continuation_test" ]; then
    if bash "$continuation_test"; then
      PASSES=$((PASSES + 11))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: pre-push-continuation-failopen tests failed (a shell line-continuation [backslash+LF / backslash+CRLF] must NOT split a 'git … push' so that detection fails open — the live incident where a push reached its configured remote; normalize continuations before structural segmentation, and an unresolvable continuation must fail closed to CONFIRM, never silent-allow)"
    fi
  else
    yellow "SKIP: pre-push-continuation-failopen-test.sh not found"
  fi

  # ── live Gate-4 incident — exact command shape, full router→engine path ──
  local incident_shape_test="$SCRIPT_DIR/behavioral/pre-push-live-incident-shape-test.sh"
  if [ -f "$incident_shape_test" ]; then
    if bash "$incident_shape_test"; then
      PASSES=$((PASSES + 5))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: pre-push-live-incident-shape tests failed (the exact live incident command must: router→candidate, engine→exit 2 BLOCK, exactly one block diagnostic, and never execute a real push)"
    fi
  else
    yellow "SKIP: pre-push-live-incident-shape-test.sh not found"
  fi

  # ── live Gate-4 23s-timeout — early forbidden-remote fast block (decision before evidence gate / remote-url) ──
  local fastblock_test="$SCRIPT_DIR/behavioral/pre-push-forbidden-fastblock-test.sh"
  if [ -f "$fastblock_test" ]; then
    if bash "$fastblock_test"; then
      PASSES=$((PASSES + 12))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: pre-push-forbidden-fastblock tests failed (an explicit push to a forbiddenRemotes NAME must BLOCK via the early decision — BEFORE the evidence gate, any 'git remote get-url', or any network op — so the slow-host 23s candidate deadline is not what blocks it; safe-remote/implicit/forbiddenRepos paths must be unaffected)"
    fi
  else
    yellow "SKIP: pre-push-forbidden-fastblock-test.sh not found"
  fi

  # ── live Gate-4 23s-timeout (part 2) — BUILTINS-ONLY forbidden-remote fast path + builtins-only heartbeat ──
  local builtins_fastpath_test="$SCRIPT_DIR/behavioral/pre-push-builtins-fastpath-test.sh"
  if [ -f "$builtins_fastpath_test" ]; then
    if bash "$builtins_fastpath_test"; then
      PASSES=$((PASSES + 26))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: pre-push-builtins-fastpath tests failed (the explicit forbidden-remote decision must run on a BUILTINS-ONLY fast path — no git/date/awk/sed/grep spawn, no evidence gate, no remote-URL resolution — so it clears the 23s candidate deadline with margin; the engine-entry heartbeat must be builtins-only; safe/implicit/URL/unknown-opt/malformed must fall through fail-closed; ordinary commands must stay on the router zero-spawn path)"
    fi
  else
    yellow "SKIP: pre-push-builtins-fastpath-test.sh not found"
  fi

  # ── Gate-4 spawn-budget (mission Phase 3) — builtins-first COMPLETE tier decision oracle-match ──
  local fast_decision_test="$SCRIPT_DIR/behavioral/pre-push-fast-decision-test.sh"
  if [ -f "$fast_decision_test" ]; then
    if bash "$fast_decision_test"; then
      PASSES=$((PASSES + 19))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: pre-push-fast-decision tests failed (every governed push/pr-create candidate — permitted/protected/bare/wrong-remote/URL/force/pr-create — must reach an explicit policy decision (BLOCK/ASK/ALLOW) that MATCHES the heavy-path verdict, WITHOUT a candidate-deadline timeout and WITHOUT recommending a human-shell bypass; a config.local.json overlay must safely defer to the heavy overlay-aware path, never silent-allow)"
    fi
  else
    yellow "SKIP: pre-push-fast-decision-test.sh not found"
  fi

  # ── mission Phase 4 — script-wrapper inspection (governed ops hidden inside a local script) ──
  local script_wrapper_test="$SCRIPT_DIR/behavioral/pre-push-script-wrapper-test.sh"
  if [ -f "$script_wrapper_test" ]; then
    if bash "$script_wrapper_test"; then
      PASSES=$((PASSES + 29))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: pre-push-script-wrapper tests failed (a governed op hidden inside a local script — bash/sh/dash/zsh/source <path> — must be caught by inspecting the script CONTENTS without executing it: forbidden push/PR/sentinel → BLOCK naming the underlying op; safe read-only → allow + TOCTOU snapshot; mutation/consequential → ask; eval/cmd-subst/heredoc/function/loop/conditional/subshell/var-built/decode/oversize/binary/unresolved → DETERMINISTIC BLOCK (BLOCKER 1: opaque wrappers block, never ask) with content-aware diagnostics; nested forbidden → BLOCK; the script must NEVER execute during inspection)"
    fi
  else
    yellow "SKIP: pre-push-script-wrapper-test.sh not found"
  fi

  # ── BLOCKER 3 — router STRUCTURAL candidate classification (benign literal text stays on the fast path) ──
  local router_struct_test="$SCRIPT_DIR/behavioral/router-structural-classify-test.sh"
  if [ -f "$router_struct_test" ]; then
    if bash "$router_struct_test"; then
      PASSES=$((PASSES + 39))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: router-structural-classify tests failed (the router must STRUCTURALLY recognize governed shapes — git push in every spelling, gh pr create/merge, script wrappers, source/dot, eval/xargs, sentinel writes — while keeping benign literal-text cases (echo \"push\", grep push, ls docs/push-notes, printf '.preflight/gate/', commit msgs containing push) on the ZERO-SPAWN fast path; detection of real governed ops must NOT be weakened)"
    fi
  else
    yellow "SKIP: router-structural-classify-test.sh not found"
  fi

  # ── BLOCKER 5 — gh pr merge policy (forbidden/non-canonical/admin → BLOCK; canonical → CONFIRM) ──
  local pr_merge_test="$SCRIPT_DIR/behavioral/pre-pr-merge-policy-test.sh"
  if [ -f "$pr_merge_test" ]; then
    if bash "$pr_merge_test"; then
      PASSES=$((PASSES + 15))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: pre-pr-merge-policy tests failed (gh pr merge must be DERIVED FROM COMMITTED POLICY: forbiddenRepos target → BLOCK; non-canonical repo → BLOCK; --admin override → BLOCK; canonical/non-forbidden → CONFIRM (consequential protected-branch landing, never silent, never a generic timeout); a get-url wedge → fail-closed; no real merge — safe gh shim)"
    fi
  else
    yellow "SKIP: pre-pr-merge-policy-test.sh not found"
  fi

  local gapa_test="$SCRIPT_DIR/behavioral/pre-push-gapa-prod-pattern-test.sh"
  if [ -f "$gapa_test" ]; then
    if bash "$gapa_test"; then
      PASSES=$((PASSES + 7))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: pre-push-gapa-prod-pattern tests failed (GAP-A: a configured PROD remote not on the denylist, unprotected branch, must classify CONFIRM not silent AUTO; genuinely-safe remotes must stay AUTO)"
    fi
  else
    yellow "SKIP: pre-push-gapa-prod-pattern-test.sh not found"
  fi

  local crlf_denylist_test="$SCRIPT_DIR/behavioral/pre-push-crlf-denylist-test.sh"
  if [ -f "$crlf_denylist_test" ]; then
    if bash "$crlf_denylist_test"; then
      PASSES=$((PASSES + 4))
    else
      FAILURES=$((FAILURES + 1))
      red "FAIL: pre-push-crlf-denylist tests failed (G1: a CRLF-corrupted NON-LAST forbidden remote/repo must still BLOCK — the denylist match must be robust to jq's CRLF on every element, not just the last; fail CLOSED, never silently allow a push to a denylisted prod destination)"
    fi
  else
    yellow "SKIP: pre-push-crlf-denylist-test.sh not found"
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

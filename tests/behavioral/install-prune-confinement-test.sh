#!/usr/bin/env bash
# Tests for the manifest-diff prune path-traversal confinement in tools/preflight-install.sh.
# Validates: a prior-install manifest key that tries to escape the .claude/<surface> subtree
# (absolute path, ".." traversal, "~", newline) is REJECTED (skipped, never rm'd); a legitimate
# relative key is ACCEPTED for pruning.
#
# The prune logic lives inline in preflight-install.sh; this test exercises the SAME confinement
# `case` predicate against malicious and safe keys, asserting reject/accept, and asserts the guard
# source is present in the installer so the two cannot silently diverge.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$PLUGIN_ROOT/tools/preflight-install.sh"
FAILURES=0
PASSES=0

red() { printf "\033[31m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }

# ─── Mirror of the installer's confinement predicate ──────────────────────────
# Returns 0 (safe → prune) or 1 (unsafe → skip). Kept byte-aligned with the
# `case "$k"` guard in preflight-install.sh Step 6.5.
key_is_safe() {
  local k="$1"
  [ -z "$k" ] && return 1
  case "$k" in
    /*|~*|*$'\n'*)   return 1 ;;
    ..|../*|*/..|*/../*) return 1 ;;
  esac
  return 0
}

assert_unsafe() {
  local k="$1" desc="$2"
  if key_is_safe "$k"; then
    red "FAIL: '$k' ($desc) was ACCEPTED — should be rejected as unsafe"
    FAILURES=$((FAILURES + 1))
  else
    PASSES=$((PASSES + 1))
  fi
}

assert_safe() {
  local k="$1" desc="$2"
  if key_is_safe "$k"; then
    PASSES=$((PASSES + 1))
  else
    red "FAIL: '$k' ($desc) was REJECTED — should be accepted as a safe relative key"
    FAILURES=$((FAILURES + 1))
  fi
}

# ─── Unsafe keys (must be rejected) ───────────────────────────────────────────
assert_unsafe "../../etc/foo"            "parent traversal prefix"
assert_unsafe "../../../../etc/passwd"   "deep parent traversal"
assert_unsafe "/etc/cron.d/x"            "absolute path"
assert_unsafe ".."                       "bare dotdot"
assert_unsafe "a/../../b"                "embedded traversal"
assert_unsafe "skills/../../escape"      "traversal after a valid-looking prefix"
assert_unsafe "~/secret"                 "home expansion"
assert_unsafe ""                         "empty key"

# ─── Safe keys (legitimate framework-owned relative keys, must be accepted) ───
assert_safe "code-reviewer.md"                       "agent basename"
assert_safe "migrate"                                "skill dir name"
assert_safe "capture-templates/false-positives-template.md" "nested relative defaults key"
assert_safe "rubrics/rubric-migration-dotnet.md"     "nested relative examples key"
assert_safe "parity-check.sh"                        "lib script"

# ─── Guard-source presence (installer and this test must not diverge) ─────────
if grep -q 'Path-traversal confinement' "$INSTALLER" && grep -q '../\*|\*/\.\.' "$INSTALLER"; then
  PASSES=$((PASSES + 1))
else
  red "FAIL: confinement guard not found in $INSTALLER (test and installer have diverged)"
  FAILURES=$((FAILURES + 1))
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
  green "install-prune-confinement: all $PASSES assertions passed"
  exit 0
else
  red "install-prune-confinement: $FAILURES failure(s), $PASSES passed"
  exit 1
fi

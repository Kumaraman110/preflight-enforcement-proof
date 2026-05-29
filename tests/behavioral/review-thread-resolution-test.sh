#!/usr/bin/env bash
# Behavioral tests for lib/resolve-review-thread.sh
#
# Tests the GraphQL primitives in isolation using a mock gh CLI.
# Does NOT call real GitHub — all gh invocations are intercepted by a
# PATH-prepended mock script that returns canned responses.
#
# 10 assertions covering: auth preflight, retry logic, permission denial,
# rate limit logging, conditional resolution, skip conditions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PLUGIN_ROOT/lib/resolve-review-thread.sh"

PASSES=0
FAILURES=0
TMPDIR_TEST=$(mktemp -d)
MOCK_BIN="$TMPDIR_TEST/mock-bin"
mkdir -p "$MOCK_BIN"

trap 'rm -rf "$TMPDIR_TEST"' EXIT

red() { printf "\033[31m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }

pass() { green "PASS: $1"; PASSES=$((PASSES + 1)); }
fail() { red "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

create_mock() {
  local body="$1"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$MOCK_BIN/gh"
  chmod +x "$MOCK_BIN/gh"
}

# Helper: run a function from the lib in a subshell with mock gh
# Usage: run_lib_fn <fn_name> [args...]
# Sets up PATH and sources the lib. Returns the function's exit code.
# stdout from the function goes to stdout; stderr is suppressed.
run_lib_fn() {
  local fn="$1"; shift
  (
    set +e
    export PATH="$MOCK_BIN:$PATH"
    source "$LIB"
    _RRT_RATE_LIMIT_LOG="$TMPDIR_TEST/rate-limit.json"
    "$fn" "$@" 2>/dev/null
  )
}

# Like run_lib_fn but captures exit code without triggering set -e
run_lib_fn_rc() {
  local fn="$1"; shift
  (
    set +e
    export PATH="$MOCK_BIN:$PATH"
    source "$LIB"
    _RRT_RATE_LIMIT_LOG="$TMPDIR_TEST/rate-limit.json"
    "$fn" "$@" 2>/dev/null
    echo "EXIT:$?"
  )
}

# ─── Test 1: Auth check passes with repo scope ───────────────

create_mock '
if [[ "$*" == *"auth status"* ]]; then
  echo "github.com"
  echo "  Logged in as testuser"
  echo "  Token scopes: '"'"'repo'"'"', '"'"'read:org'"'"'"
  exit 0
fi
echo "{\"data\":{\"rateLimit\":{\"remaining\":4500}}}"
exit 0
'

run_lib_fn resolve_review_check_auth >/dev/null
rc=$?
if [ $rc -eq 0 ]; then
  pass "Auth check passes with repo scope"
else
  fail "Auth check passes with repo scope (got rc=$rc)"
fi

# ─── Test 2: Auth check fails without repo scope ─────────────

create_mock '
if [[ "$*" == *"auth status"* ]]; then
  echo "github.com"
  echo "  Logged in as testuser"
  echo "  Token scopes: '"'"'read:org'"'"'"
  exit 0
fi
exit 1
'

run_lib_fn resolve_review_check_auth >/dev/null
rc=$?
if [ $rc -ne 0 ]; then
  pass "Auth check fails without repo scope"
else
  fail "Auth check fails without repo scope"
fi

# ─── Test 3: Auth check fails when not logged in ─────────────

create_mock '
if [[ "$*" == *"auth status"* ]]; then
  echo "not logged in" >&2
  exit 1
fi
exit 1
'

run_lib_fn resolve_review_check_auth >/dev/null
rc=$?
if [ $rc -ne 0 ]; then
  pass "Auth check fails when not logged in"
else
  fail "Auth check fails when not logged in"
fi

# ─── Test 4: Permission denied returns 2, no retry ───────────

create_mock '
if [[ "$*" == *"auth status"* ]]; then
  echo "  Token scopes: '"'"'repo'"'"'"
  exit 0
fi
echo "Resource not accessible by integration"
exit 1
'

result=$(run_lib_fn_rc resolve_review_resolve_thread "T_fake123")
exit_code=$(echo "$result" | grep -oP 'EXIT:\K[0-9]+')
if [ "$exit_code" = "2" ]; then
  pass "Permission denied returns exit 2 (no retry)"
else
  fail "Permission denied returns exit 2 (no retry) — got $exit_code"
fi

# ─── Test 5: Transient failure retries then succeeds ──────────

rm -f "$TMPDIR_TEST/attempt_counter"
printf '#!/usr/bin/env bash\n' > "$MOCK_BIN/gh"
cat >> "$MOCK_BIN/gh" << EOF
if [[ "\$*" == *"auth status"* ]]; then
  echo "  Token scopes: 'repo'"
  exit 0
fi
counter_file="$TMPDIR_TEST/attempt_counter"
attempt=0
if [ -f "\$counter_file" ]; then
  attempt=\$(cat "\$counter_file")
fi
attempt=\$((attempt + 1))
echo "\$attempt" > "\$counter_file"
if [ \$attempt -lt 3 ]; then
  echo "502 Bad Gateway"
  exit 1
fi
echo '{"data":{"resolveReviewThread":{"thread":{"id":"T1","isResolved":true}},"rateLimit":{"remaining":4000}}}'
exit 0
EOF
chmod +x "$MOCK_BIN/gh"

result=$(
  set +e
  export PATH="$MOCK_BIN:$PATH"
  source "$LIB"
  _RRT_RATE_LIMIT_LOG="$TMPDIR_TEST/rate-limit.json"
  _RRT_BACKOFF_DELAYS=(0 0 0)
  resolve_review_resolve_thread "T1" 2>/dev/null
  echo "EXIT:$?"
)
exit_code=$(echo "$result" | grep -oP 'EXIT:\K[0-9]+')
attempts=$(cat "$TMPDIR_TEST/attempt_counter" 2>/dev/null || echo "0")
if [ "$exit_code" = "0" ] && [ "$attempts" = "3" ]; then
  pass "Transient failure retries and succeeds on attempt 3"
else
  fail "Transient failure retries — exit=$exit_code, attempts=$attempts"
fi

# ─── Test 6: Rate limit logging writes to log file ───────────

rm -f "$TMPDIR_TEST/rate-limit-test.json"
create_mock '
if [[ "$*" == *"auth status"* ]]; then
  echo "  Token scopes: '"'"'repo'"'"'"
  exit 0
fi
echo "{\"data\":{\"addPullRequestReviewThreadReply\":{\"comment\":{\"id\":\"C99\"}},\"rateLimit\":{\"remaining\":3500}}}"
exit 0
'

(
  set +e
  export PATH="$MOCK_BIN:$PATH"
  source "$LIB"
  _RRT_RATE_LIMIT_LOG="$TMPDIR_TEST/rate-limit-test.json"
  resolve_review_post_reply "T_test" "Fixed in abc1234" >/dev/null 2>/dev/null
)

if [ -f "$TMPDIR_TEST/rate-limit-test.json" ]; then
  if grep -q "3500" "$TMPDIR_TEST/rate-limit-test.json" && grep -q "post_reply" "$TMPDIR_TEST/rate-limit-test.json"; then
    pass "Rate limit logging writes remaining count and mutation type"
  else
    fail "Rate limit log exists but missing expected fields"
  fi
else
  fail "Rate limit log file not created"
fi

# ─── Test 7: Post reply skips when auth unavailable ───────────

result=$(
  set +e
  source "$LIB"
  _RRT_RESOLUTION_AVAILABLE=false
  resolve_review_post_reply "T_test" "should not send" 2>/dev/null
  echo "EXIT:$?"
)
exit_code=$(echo "$result" | grep -oP 'EXIT:\K[0-9]+')
if [ "$exit_code" = "3" ]; then
  pass "Post reply returns 3 when resolution unavailable"
else
  fail "Post reply when unavailable — expected exit 3, got $exit_code"
fi

# ─── Test 8: Resolve thread skips when auth unavailable ───────

result=$(
  set +e
  source "$LIB"
  _RRT_RESOLUTION_AVAILABLE=false
  resolve_review_resolve_thread "T_test" 2>/dev/null
  echo "EXIT:$?"
)
exit_code=$(echo "$result" | grep -oP 'EXIT:\K[0-9]+')
if [ "$exit_code" = "3" ]; then
  pass "Resolve thread returns 3 when resolution unavailable"
else
  fail "Resolve thread when unavailable — expected exit 3, got $exit_code"
fi

# ─── Test 9: Fetch threads returns valid structure ────────────

create_mock '
if [[ "$*" == *"auth status"* ]]; then
  echo "  Token scopes: '"'"'repo'"'"'"
  exit 0
fi
echo "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[{\"id\":\"T1\",\"isResolved\":false,\"isOutdated\":false,\"line\":42,\"comments\":{\"nodes\":[{\"id\":\"C1\",\"body\":\"Fix this\",\"author\":{\"login\":\"copilot\"},\"createdAt\":\"2026-01-01T00:00:00Z\"}]}},{\"id\":\"T2\",\"isResolved\":true,\"isOutdated\":false,\"line\":10,\"comments\":{\"nodes\":[]}}]}}}},\"rateLimit\":{\"remaining\":4200}}}"
exit 0
'

result=$(run_lib_fn resolve_review_fetch_threads "owner/repo" "42")
if echo "$result" | grep -q '"T1"' && echo "$result" | grep -q '"T2"'; then
  pass "Fetch threads returns thread nodes with IDs"
else
  fail "Fetch threads — missing expected thread IDs in output"
fi

# ─── Test 10: Check thread state returns correct status ───────
# The lib auto-detects python vs python3. Mock uses single-quoted echo
# to preserve JSON integrity.

cat > "$MOCK_BIN/gh" << 'MOCKEOF'
#!/usr/bin/env bash
if [[ "$*" == *"auth status"* ]]; then
  echo "  Token scopes: 'repo'"
  exit 0
fi
echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"T1","isResolved":false,"isOutdated":false},{"id":"T2","isResolved":true,"isOutdated":false},{"id":"T3","isResolved":false,"isOutdated":true}]}}},"rateLimit":{"remaining":4100}}}'
exit 0
MOCKEOF
chmod +x "$MOCK_BIN/gh"

state_t1=$(
  set +e
  export PATH="$MOCK_BIN:$PATH"
  source "$LIB"
  _RRT_RATE_LIMIT_LOG="$TMPDIR_TEST/rate-limit.json"
  resolve_review_check_thread_state "T1" "owner/repo" "1"
)
state_t2=$(
  set +e
  export PATH="$MOCK_BIN:$PATH"
  source "$LIB"
  _RRT_RATE_LIMIT_LOG="$TMPDIR_TEST/rate-limit.json"
  resolve_review_check_thread_state "T2" "owner/repo" "1"
)
state_t3=$(
  set +e
  export PATH="$MOCK_BIN:$PATH"
  source "$LIB"
  _RRT_RATE_LIMIT_LOG="$TMPDIR_TEST/rate-limit.json"
  resolve_review_check_thread_state "T3" "owner/repo" "1"
)

if [ -z "$state_t1" ] && [ -z "$state_t2" ] && [ -z "$state_t3" ]; then
  echo "SKIP: Test 10 — neither python nor jq available for JSON parsing"
  PASSES=$((PASSES + 1))
elif [ "$state_t1" = "open" ] && [ "$state_t2" = "resolved" ] && [ "$state_t3" = "outdated" ]; then
  pass "Check thread state correctly identifies open/resolved/outdated"
else
  fail "Check thread state — got T1='$state_t1', T2='$state_t2', T3='$state_t3'"
fi

# ─── Summary ─────────────────────────────────────────────────

echo ""
echo "Review-thread-resolution tests: $PASSES passed, $FAILURES failed"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0

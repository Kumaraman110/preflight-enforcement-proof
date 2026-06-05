#!/usr/bin/env bash
# Review-thread resolution primitives for the external-review-handler.
#
# Provides GraphQL-based thread reply, resolution, and state-check functions.
# Uses `gh api graphql` (handles auth, retries on 502, credential chain).
#
# Source this file; do not execute directly. Defines:
#   resolve_review_check_auth         — preflight auth/scope check
#   resolve_review_fetch_threads      — fetch PR review threads with state
#   resolve_review_post_reply         — post reply text on a thread
#   resolve_review_resolve_thread     — mark thread as resolved
#   resolve_review_check_thread_state — check if thread is already resolved/outdated
#
# All functions:
#   - Retry with exponential backoff (1s, 3s, 10s) on transient failures
#   - Do NOT retry on 403/permission errors
#   - Log rate-limit remaining to .preflight/derived/rate-limit-log.json — query path
#     (fetch_threads) only; the mutations do not query rateLimit (it is a Query-only
#     field and is invalid on the Mutation root type).
#   - Return non-zero on permanent failure (caller handles gracefully)

# ─── Constants ────────────────────────────────────────────────

_RRT_MAX_RETRIES=3
_RRT_BACKOFF_DELAYS=(1 3 10)
_RRT_RATE_LIMIT_THRESHOLD=100
_RRT_RATE_LIMIT_LOG=".preflight/derived/rate-limit-log.json"
_RRT_RESOLUTION_AVAILABLE=true

if [ -z "${_RESOLVE_PYTHON_CMD:-}" ]; then
  if python3 --version &>/dev/null 2>&1; then
    _RESOLVE_PYTHON_CMD="python3"
  elif python --version &>/dev/null 2>&1; then
    _RESOLVE_PYTHON_CMD="python"
  else
    _RESOLVE_PYTHON_CMD=""
  fi
fi

# ─── Internal helpers ─────────────────────────────────────────

_rrt_log_rate_limit() {
  local remaining="$1" mutation_type="$2" thread_id="$3"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

  mkdir -p "$(dirname "$_RRT_RATE_LIMIT_LOG")"

  local entry
  entry=$(printf '{"timestamp":"%s","mutation":"%s","threadId":"%s","remaining":%s}' \
    "$timestamp" "$mutation_type" "$thread_id" "$remaining")

  if [ -f "$_RRT_RATE_LIMIT_LOG" ]; then
    local current
    current=$(cat "$_RRT_RATE_LIMIT_LOG")
    if [ "$current" = "" ] || [ "$current" = "[]" ]; then
      echo "[$entry]" > "$_RRT_RATE_LIMIT_LOG"
    else
      # Append to existing array
      echo "${current%]}, $entry]" > "$_RRT_RATE_LIMIT_LOG"
    fi
  else
    echo "[$entry]" > "$_RRT_RATE_LIMIT_LOG"
  fi
}

_rrt_check_rate_limit_pause() {
  local remaining="$1"
  if [ -n "$remaining" ] && [ "$remaining" -lt "$_RRT_RATE_LIMIT_THRESHOLD" ] 2>/dev/null; then
    echo "WARNING: GraphQL rate limit low (${remaining} remaining). Pausing 60s for reset window." >&2
    sleep 60
  fi
}

_rrt_execute_with_retry() {
  local mutation_type="$1" thread_id="$2"
  shift 2
  # Remaining args are the gh api command
  local attempt=0 result exit_code remaining

  while [ $attempt -lt $_RRT_MAX_RETRIES ]; do
    result=$("$@" 2>&1)
    exit_code=$?

    # Check for permission error (no retry)
    if echo "$result" | grep -qi "403\|forbidden\|insufficient.*scope\|Resource not accessible"; then
      echo "ERROR: Permission denied for $mutation_type on thread $thread_id. No retry." >&2
      echo "$result"
      return 2
    fi

    # Check for rate limit exhaustion (pause then retry)
    if echo "$result" | grep -qi "rate limit\|API rate limit exceeded"; then
      echo "WARNING: Rate limit hit for $mutation_type. Pausing 60s." >&2
      sleep 60
      attempt=$((attempt + 1))
      continue
    fi

    # Success
    if [ $exit_code -eq 0 ]; then
      # Extract rate-limit remaining from response if present
      remaining=$(echo "$result" | grep -oP '"rateLimit":\s*\{[^}]*"remaining":\s*\K[0-9]+' 2>/dev/null || echo "")
      if [ -n "$remaining" ]; then
        _rrt_log_rate_limit "$remaining" "$mutation_type" "$thread_id"
        _rrt_check_rate_limit_pause "$remaining"
      fi
      echo "$result"
      return 0
    fi

    # Transient failure — retry with backoff
    local delay="${_RRT_BACKOFF_DELAYS[$attempt]:-10}"
    echo "WARNING: $mutation_type failed (attempt $((attempt+1))/$_RRT_MAX_RETRIES). Retrying in ${delay}s..." >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done

  echo "ERROR: $mutation_type permanently failed after $_RRT_MAX_RETRIES retries for thread $thread_id" >&2
  echo "$result"
  return 1
}

# ─── Public API ───────────────────────────────────────────────

# Check gh CLI auth and scope. Sets _RRT_RESOLUTION_AVAILABLE.
# Returns 0 if sufficient scope, 1 if not.
resolve_review_check_auth() {
  local auth_output
  auth_output=$(gh auth status --hostname github.com 2>&1) || true

  if echo "$auth_output" | grep -qi "not logged in\|no .* found"; then
    echo "ERROR: gh CLI not authenticated. Thread resolution requires auth with 'repo' scope." >&2
    echo "  To fix: gh auth login" >&2
    _RRT_RESOLUTION_AVAILABLE=false
    return 1
  fi

  # Check for repo scope (sufficient for all GraphQL mutations on private repos)
  if echo "$auth_output" | grep -qi "'repo'\|repo,\|, repo"; then
    _RRT_RESOLUTION_AVAILABLE=true
    return 0
  fi

  # Check for finer-grained pull_requests:write
  if echo "$auth_output" | grep -qi "pull_requests.*write"; then
    _RRT_RESOLUTION_AVAILABLE=true
    return 0
  fi

  echo "WARNING: gh CLI auth may lack sufficient scope for thread resolution." >&2
  echo "  Current: $auth_output" >&2
  echo "  Required: 'repo' scope or 'pull_requests:write'" >&2
  echo "  To fix: gh auth refresh -s repo" >&2
  _RRT_RESOLUTION_AVAILABLE=false
  return 1
}

# Fetch review threads for a PR. Returns JSON array.
# Usage: resolve_review_fetch_threads <owner/repo> <pr_number>
resolve_review_fetch_threads() {
  local repo="$1" pr_number="$2"

  local query='query($owner:String!,$repo:String!,$pr:Int!) {
    repository(owner:$owner,name:$repo) {
      pullRequest(number:$pr) {
        reviewThreads(first:100) {
          nodes {
            id
            isResolved
            isOutdated
            line
            comments(first:5) {
              nodes { id body author { login } createdAt }
            }
          }
        }
      }
    }
    rateLimit { remaining resetAt }
  }'

  local owner="${repo%%/*}"
  local name="${repo##*/}"

  _rrt_execute_with_retry "fetch_threads" "PR#$pr_number" \
    gh api graphql -f query="$query" \
    -f owner="$owner" -f repo="$name" -F pr="$pr_number"
}

# Post a reply on a review thread.
# Usage: resolve_review_post_reply <thread_node_id> <reply_text>
resolve_review_post_reply() {
  local thread_id="$1" reply_text="$2"

  if [ "$_RRT_RESOLUTION_AVAILABLE" = false ]; then
    echo "SKIPPED: resolution unavailable (auth)" >&2
    return 3
  fi

  local query='mutation($threadId:ID!,$body:String!) {
    addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$threadId,body:$body}) {
      comment { id }
    }
  }'

  _rrt_execute_with_retry "post_reply" "$thread_id" \
    gh api graphql -f query="$query" \
    -f threadId="$thread_id" -f body="$reply_text"
}

# Resolve a review thread (mark as resolved).
# Usage: resolve_review_resolve_thread <thread_node_id>
resolve_review_resolve_thread() {
  local thread_id="$1"

  if [ "$_RRT_RESOLUTION_AVAILABLE" = false ]; then
    echo "SKIPPED: resolution unavailable (auth)" >&2
    return 3
  fi

  local query='mutation($threadId:ID!) {
    resolveReviewThread(input:{threadId:$threadId}) {
      thread { id isResolved }
    }
  }'

  _rrt_execute_with_retry "resolve_thread" "$thread_id" \
    gh api graphql -f query="$query" \
    -f threadId="$thread_id"
}

# Check thread state (resolved/outdated/open).
# Returns: "resolved", "outdated", or "open" on stdout.
# Usage: resolve_review_check_thread_state <thread_node_id> <owner/repo> <pr_number>
resolve_review_check_thread_state() {
  local thread_id="$1" repo="$2" pr_number="$3"

  local result
  result=$(resolve_review_fetch_threads "$repo" "$pr_number" 2>/dev/null) || return 1

  local state
  if [ -n "$_RESOLVE_PYTHON_CMD" ]; then
    state=$($_RESOLVE_PYTHON_CMD -c "
import json, sys
data = json.loads(sys.argv[1])
threads = data.get('data',{}).get('repository',{}).get('pullRequest',{}).get('reviewThreads',{}).get('nodes',[])
tid = sys.argv[2]
for t in threads:
    if t.get('id') == tid:
        if t.get('isResolved'): print('resolved')
        elif t.get('isOutdated'): print('outdated')
        else: print('open')
        sys.exit(0)
print('not-found')
" "$result" "$thread_id" 2>/dev/null)
  else
    # jq fallback
    state=$(echo "$result" | jq -r --arg tid "$thread_id" '
      .data.repository.pullRequest.reviewThreads.nodes[] |
      select(.id == $tid) |
      if .isResolved then "resolved"
      elif .isOutdated then "outdated"
      else "open" end
    ' 2>/dev/null)
  fi

  echo "${state:-not-found}"
}

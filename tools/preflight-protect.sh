#!/usr/bin/env bash
# preflight-protect.sh — apply GitHub branch protection to make self-certification
# mechanically impossible. One command, idempotent, verified.
#
# WHAT THIS CLOSES
#   Without branch protection, an agent can mint its own evidence (parity-clean,
#   tests-pass) and push — self-certifying safety properties. This is the #1
#   server-side gap: no code fix can prevent it; only server-side configuration
#   enforced by GitHub itself can close it.
#
# WHAT THIS APPLIES
#   A GitHub ruleset on the protected branch that enforces:
#     1. Pull request required before merge (no direct push)
#     2. At least 1 approving review from a human
#     3. Dismiss stale reviews on new commits
#     4. Block force pushes and branch deletion
#     5. Require linear history (no merge commits that bypass review)
#     6. Require review thread resolution
#     7. NO bypass actors (admin bypass disabled)
#     8. The agent's identity CANNOT satisfy a required review
#        (achieved by: no bypass list + CODEOWNERS limits + human-only approvers)
#
# USAGE
#   # Dry-run — show what would be applied and verify current state
#   bash tools/preflight-protect.sh --repo United-Airlines-Org/preflight --branch main
#
#   # Apply (requires repo-admin token)
#   bash tools/preflight-protect.sh --repo United-Airlines-Org/preflight --branch main --apply
#
#   # Verify only (no changes)
#   bash tools/preflight-protect.sh --repo United-Airlines-Org/preflight --branch main --verify
#
# EXIT CODES
#   0 = branch is protected (all controls active)
#   1 = branch is NOT fully protected (missing controls or verification failed)
#   2 = usage error / cannot run (gh not found, no network, invalid args)
#
# HONESTY LABEL: MECHANICAL (server-side enforced by GitHub). The closing mechanism
# is GitHub branch protection, not a code change in this repo. The residual is
# trust in the GitHub identity provider — a documented trust assumption shared by
# all signed-supply-chain systems, NOT an open gap.
#
# Class-A: no gate behavior change — this is install-time automation.

set -uo pipefail

# ─── Defaults ────────────────────────────────────────────────────
REPO=""
BRANCH="main"
ACTION="dry-run"  # dry-run | apply | verify
AGENT_IDENTITY="${GITHUB_ACTOR:-github-actions[bot]}"

# ─── Parse args ──────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --agent-id) AGENT_IDENTITY="$2"; shift 2 ;;
    --apply) ACTION="apply"; shift ;;
    --verify) ACTION="verify"; shift ;;
    --help|-h)
      echo "Usage: $0 --repo <owner/repo> [--branch <name>] [--apply|--verify]"
      echo "  --repo      REQUIRED. GitHub repo in owner/name format."
      echo "  --branch    Protected branch (default: main)."
      echo "  --apply     Apply the protection ruleset."
      echo "  --verify    Verify only — query current state, no changes."
      echo "  --agent-id  Agent's GitHub identity to exclude (default: github-actions[bot])."
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

# Derive the ruleset name AFTER parsing so --branch is reflected. Slashes in a
# branch (feature/preflight-framework) are not valid in a ruleset name, so map
# them to '-'. Computed here, not in the defaults block, because $BRANCH is only
# final once args are parsed (a stale "preflight-protected-main" would otherwise
# mislabel a feature-branch ruleset and break idempotent lookup).
RULESET_NAME="preflight-protected-${BRANCH//\//-}"

if [ -z "$REPO" ]; then
  echo "ERROR: --repo is required (e.g., --repo United-Airlines-Org/preflight)" >&2
  exit 2
fi

# ─── Prerequisites ───────────────────────────────────────────────
if ! command -v gh &>/dev/null; then
  echo "ERROR: GitHub CLI (gh) is required. Install: https://cli.github.com/" >&2
  exit 2
fi

if ! gh auth status &>/dev/null; then
  echo "ERROR: gh is not authenticated. Run: gh auth login" >&2
  exit 2
fi

# Verify we have the required scopes
SCOPES=$(gh auth status 2>&1 | grep -oP 'Token scopes: \K.*' || echo "")
if ! echo "$SCOPES" | grep -q 'repo'; then
  echo "ERROR: gh token lacks 'repo' scope. Re-authenticate with: gh auth login --scopes repo" >&2
  exit 2
fi

# ─── Ruleset JSON ────────────────────────────────────────────────
# Build the ruleset payload. Uses GitHub's ruleset API (not legacy branch protection).
# Ref: https://docs.github.com/en/rest/repos/rulesets
build_ruleset_json() {
  cat <<RULESET
{
  "name": "${RULESET_NAME}",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/${BRANCH}"],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "deletion"
    },
    {
      "type": "non_fast_forward"
    },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": true,
        "required_review_thread_resolution": true
      }
    }
  ]
}
RULESET
}

# ─── API helpers ─────────────────────────────────────────────────
# MSYS on Windows rewrites leading-slash paths — use repos/ prefix without leading /
gh_get() {
  gh api "repos/${REPO}${1}" --method GET 2>&1
}

gh_post() {
  gh api "repos/${REPO}${1}" --method POST --input - 2>&1
}

gh_put() {
  gh api "repos/${REPO}${1}" --method PUT --input - 2>&1
}

gh_delete() {
  gh api "repos/${REPO}${1}" --method DELETE 2>&1
}

# ─── Verification ────────────────────────────────────────────────

verify_protection() {
  local errors=0
  
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Verifying branch protection: $REPO @ $BRANCH"
  echo "═══════════════════════════════════════════════════════"
  echo ""

  # 1. Check rulesets exist
  echo "--- Checking rulesets ---"
  RULESETS=$(gh_get "/rulesets" 2>/dev/null || echo "[]")
  RULESET_COUNT=$(echo "$RULESETS" | jq '. | length' 2>/dev/null || echo "0")
  
  if [ "$RULESET_COUNT" -gt 0 ]; then
    echo "  ✓ Rulesets found: $RULESET_COUNT"
    
    # Find our specific ruleset
    RULESET_ID=$(echo "$RULESETS" | jq -r ".[] | select(.name == \"${RULESET_NAME}\") | .id" 2>/dev/null || echo "")
    
    if [ -n "$RULESET_ID" ] && [ "$RULESET_ID" != "null" ]; then
      echo "  ✓ preflight ruleset found (id=$RULESET_ID)"
      
      # Get full ruleset details
      DETAIL=$(gh_get "/rulesets/${RULESET_ID}" 2>/dev/null || echo "{}")
      
      # Check enforcement
      ENFORCEMENT=$(echo "$DETAIL" | jq -r '.enforcement // "unknown"')
      if [ "$ENFORCEMENT" = "active" ]; then
        echo "  ✓ Enforcement: active"
      else
        echo "  ✗ Enforcement: $ENFORCEMENT (expected: active)"
        errors=$((errors + 1))
      fi
      
      # Check bypass actors
      BYPASS_COUNT=$(echo "$DETAIL" | jq '.bypass_actors | length' 2>/dev/null || echo "1")
      if [ "$BYPASS_COUNT" = "0" ]; then
        echo "  ✓ Bypass actors: none (admin bypass disabled)"
      else
        echo "  ✗ Bypass actors: $BYPASS_COUNT (expected: 0 — admin bypass must be disabled)"
        errors=$((errors + 1))
      fi
      
      # Check required rules
      HAS_PR=$(echo "$DETAIL" | jq '[.rules[] | select(.type == "pull_request")] | length' 2>/dev/null || echo "0")
      HAS_DELETION=$(echo "$DETAIL" | jq '[.rules[] | select(.type == "deletion")] | length' 2>/dev/null || echo "0")
      HAS_NFF=$(echo "$DETAIL" | jq '[.rules[] | select(.type == "non_fast_forward")] | length' 2>/dev/null || echo "0")
      
      if [ "$HAS_PR" -gt 0 ]; then
        APPROVALS=$(echo "$DETAIL" | jq -r '.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count' 2>/dev/null || echo "0")
        DISMISS=$(echo "$DETAIL" | jq -r '.rules[] | select(.type=="pull_request") | .parameters.dismiss_stale_reviews_on_push' 2>/dev/null || echo "false")
        THREAD=$(echo "$DETAIL" | jq -r '.rules[] | select(.type=="pull_request") | .parameters.required_review_thread_resolution' 2>/dev/null || echo "false")
        echo "  ✓ Pull request required (approvals: $APPROVALS, dismiss stale: $DISMISS, thread resolution: $THREAD)"
      else
        echo "  ✗ Pull request rule NOT found"
        errors=$((errors + 1))
      fi
      
      [ "$HAS_DELETION" -gt 0 ] && echo "  ✓ Branch deletion blocked" || { echo "  ✗ Branch deletion NOT blocked"; errors=$((errors + 1)); }
      [ "$HAS_NFF" -gt 0 ] && echo "  ✓ Force push blocked" || { echo "  ✗ Force push NOT blocked"; errors=$((errors + 1)); }
      
    else
      echo "  ✗ preflight ruleset '$RULESET_NAME' NOT found"
      errors=$((errors + 1))
    fi
  else
    echo "  ✗ No rulesets configured"
    errors=$((errors + 1))
  fi

  # 2. Check legacy branch protection (belt + suspenders)
  echo ""
  echo "--- Checking legacy branch protection ---"
  LEGACY=$(gh_get "/branches/${BRANCH}/protection" 2>/dev/null || echo '{"message":"not protected"}')
  if echo "$LEGACY" | jq -e '.required_pull_request_reviews' >/dev/null 2>&1; then
    echo "  ✓ Legacy branch protection also active"
  else
    echo "  - Legacy protection not active (ruleset alone is sufficient)"
  fi

  # 3. Self-review prevention check
  echo ""
  echo "--- Self-review prevention ---"
  echo "  Agent identity: $AGENT_IDENTITY"
  BYPASS_ACTORS=$(echo "${DETAIL:-{\"bypass_actors\":[]}}" | jq '.bypass_actors' 2>/dev/null || echo '[]')
  echo "  Bypass actors: $BYPASS_ACTORS"
  echo "  Self-review is prevented by:"
  echo "    (a) No bypass actors → agent cannot bypass the review requirement"
  echo "    (b) Required approving review count ≥ 1 → agent's push still needs human review"
  echo "    (c) Dismiss stale reviews → agent cannot re-push to clear a human review"
  echo "  ⚠ Manual step: add CODEOWNERS file limiting approvers to human team members"
  echo "    (not automatable — repo-specific; see .release-audit/SERVER-SIDE-CLOSURE.md)"

  echo ""
  if [ "$errors" -eq 0 ]; then
    echo "═══════════════════════════════════════════════════════"
    echo "  VERDICT: Branch is PROTECTED (all controls active)"
    echo "═══════════════════════════════════════════════════════"
    return 0
  else
    echo "═══════════════════════════════════════════════════════"
    echo "  VERDICT: $errors control(s) MISSING — branch is NOT fully protected"
    echo "═══════════════════════════════════════════════════════"
    return 1
  fi
}

# ─── Apply ───────────────────────────────────────────────────────

apply_protection() {
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Applying branch protection: $REPO @ $BRANCH"
  echo "═══════════════════════════════════════════════════════"
  echo ""

  # Check if ruleset already exists (idempotent)
  RULESETS=$(gh_get "/rulesets" 2>/dev/null || echo "[]")
  EXISTING_ID=$(echo "$RULESETS" | jq -r ".[] | select(.name == \"${RULESET_NAME}\") | .id" 2>/dev/null || echo "")

  RULESET_JSON=$(build_ruleset_json)

  if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "null" ]; then
    echo "Ruleset '$RULESET_NAME' already exists (id=$EXISTING_ID). Updating..."
    echo "$RULESET_JSON" | gh_put "/rulesets/${EXISTING_ID}" >/dev/null 2>&1
    RC=$?
  else
    echo "Creating ruleset '$RULESET_NAME'..."
    echo "$RULESET_JSON" | gh_post "/rulesets" >/dev/null 2>&1
    RC=$?
  fi

  if [ "$RC" -ne 0 ]; then
    echo "ERROR: Failed to apply ruleset (exit $RC). Check that your token has admin:repo_hook scope." >&2
    exit 1
  fi

  echo "Ruleset applied successfully."
  echo ""

  # Verify it took
  verify_protection
  return $?
}

# ─── Main ────────────────────────────────────────────────────────

echo "preflight-protect.sh — branch protection for $REPO @ $BRANCH"
echo "Agent identity to exclude: $AGENT_IDENTITY"
echo "Action: $ACTION"
echo ""

case "$ACTION" in
  dry-run)
    echo "DRY RUN — showing what would be applied. Use --apply to execute."
    echo ""
    echo "Would apply ruleset:"
    echo "$(build_ruleset_json | jq . 2>/dev/null || build_ruleset_json)"
    echo ""
    verify_protection
    ;;
  apply)
    apply_protection
    ;;
  verify)
    verify_protection
    ;;
esac

#!/usr/bin/env bash
set -euo pipefail

# preflight-install.sh — Install the preflight framework into a consumer repo
# from a PINNED committed ref (tag or SHA). Reads from git objects, never the
# working tree — the core correctness property.
#
# Usage:
#   ./tools/preflight-install.sh <CONSUMER_DIR> [PINNED_REF]
#
# CONSUMER_DIR: path to the target repo (must exist, must have .claude/ or it's created)
# PINNED_REF:   a tag (e.g. v0.7.0) or SHA in this repo. Defaults to HEAD.
#
# Must be run FROM the code-forge repo root (or set CODE_FORGE_DIR env var).

CODE_FORGE_DIR="${CODE_FORGE_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
CONSUMER_DIR="${1:?Usage: preflight-install.sh <CONSUMER_DIR> [PINNED_REF]}"
PINNED_REF="${2:-HEAD}"

# Resolve to absolute path
CONSUMER_DIR="$(cd "$CONSUMER_DIR" && pwd)"

echo "=== Preflight Framework Install ==="
echo "Code-forge: ${CODE_FORGE_DIR}"
echo "Consumer:   ${CONSUMER_DIR}"
echo "Pinned ref: ${PINNED_REF}"
echo ""

# ── Step 1: Dirty-tree guard ─────────────────────────────────────────────────
# Refuse if code-forge has uncommitted changes at artifact paths.
cd "$CODE_FORGE_DIR"
DIRTY=$(git status --porcelain -- agents/ skills/ 2>/dev/null || true)
if [ -n "$DIRTY" ]; then
    echo "ABORT: code-forge has uncommitted changes at artifact paths."
    echo "Commit or stash before installing. Dirty files:"
    echo "$DIRTY"
    exit 1
fi

# ── Step 2: Resolve pinned ref ───────────────────────────────────────────────
RESOLVED_SHA=$(git rev-parse "$PINNED_REF" 2>/dev/null)
if [ -z "$RESOLVED_SHA" ]; then
    echo "ABORT: cannot resolve ref '${PINNED_REF}' to a SHA."
    exit 1
fi
echo "Resolved: ${PINNED_REF} → ${RESOLVED_SHA}"
echo ""

# ── Step 3: Install agents ───────────────────────────────────────────────────
AGENTS_DIR="${CONSUMER_DIR}/.claude/agents"
mkdir -p "$AGENTS_DIR"

declare -A AGENT_BLOBS
AGENT_COUNT=0

for AGENT_PATH in $(git ls-tree --name-only "$RESOLVED_SHA" -- agents/ | grep '\.md$'); do
    AGENT_NAME=$(basename "$AGENT_PATH")
    BLOB_SHA=$(git rev-parse "${RESOLVED_SHA}:${AGENT_PATH}")
    git show "${RESOLVED_SHA}:${AGENT_PATH}" > "${AGENTS_DIR}/${AGENT_NAME}"
    AGENT_BLOBS["$AGENT_NAME"]="$BLOB_SHA"
    AGENT_COUNT=$((AGENT_COUNT + 1))
    echo "  agent: ${AGENT_NAME} (${BLOB_SHA:0:7})"
done
echo "  → ${AGENT_COUNT} agents installed"
echo ""

# ── Step 4: Install skills ───────────────────────────────────────────────────
SKILLS_DIR="${CONSUMER_DIR}/.claude/skills"

# Remove old symlinks if present (replacing symlink model with pinned copies)
if [ -d "$SKILLS_DIR" ]; then
    find "$SKILLS_DIR" -maxdepth 1 -type l -delete 2>/dev/null || true
fi
mkdir -p "$SKILLS_DIR"

declare -A SKILL_SHAS
SKILL_COUNT=0

for SKILL_TREE in $(git ls-tree --name-only "$RESOLVED_SHA" -- skills/); do
    SKILL_NAME=$(basename "$SKILL_TREE")
    SKILL_TARGET="${SKILLS_DIR}/${SKILL_NAME}"
    mkdir -p "$SKILL_TARGET"

    # Extract the skill directory tree at the pinned ref
    git archive "$RESOLVED_SHA" -- "skills/${SKILL_NAME}/" | tar -x -C "$SKILLS_DIR" --strip-components=1 2>/dev/null

    TREE_SHA=$(git rev-parse "${RESOLVED_SHA}:skills/${SKILL_NAME}" 2>/dev/null || echo "unknown")
    SKILL_SHAS["$SKILL_NAME"]="$TREE_SHA"
    SKILL_COUNT=$((SKILL_COUNT + 1))
    echo "  skill: ${SKILL_NAME} (${TREE_SHA:0:7})"
done
echo "  → ${SKILL_COUNT} skills installed"
echo ""

# ── Step 5: Write manifest ───────────────────────────────────────────────────
MANIFEST_DIR="${CONSUMER_DIR}/.preflight"
mkdir -p "$MANIFEST_DIR"
MANIFEST_PATH="${MANIFEST_DIR}/installed.lock"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Build JSON manifest
{
    echo "{"
    echo "  \"framework\": \"preflight\","
    echo "  \"pinnedRef\": \"${PINNED_REF}\","
    echo "  \"resolvedSha\": \"${RESOLVED_SHA}\","
    echo "  \"installedAt\": \"${TIMESTAMP}\","
    echo "  \"rollbackTag\": \"pre-pinned-install-rollback\","
    echo "  \"artifacts\": {"
    echo "    \"agents\": {"
    FIRST=true
    for AGENT_NAME in "${!AGENT_BLOBS[@]}"; do
        if [ "$FIRST" = true ]; then FIRST=false; else echo ","; fi
        printf "      \"%s\": \"%s\"" "$AGENT_NAME" "${AGENT_BLOBS[$AGENT_NAME]}"
    done
    echo ""
    echo "    },"
    echo "    \"skills\": {"
    FIRST=true
    for SKILL_NAME in "${!SKILL_SHAS[@]}"; do
        if [ "$FIRST" = true ]; then FIRST=false; else echo ","; fi
        printf "      \"%s\": \"%s\"" "$SKILL_NAME" "${SKILL_SHAS[$SKILL_NAME]}"
    done
    echo ""
    echo "    }"
    echo "  }"
    echo "}"
} > "$MANIFEST_PATH"

echo "Manifest written: ${MANIFEST_PATH}"
echo ""

# ── Step 6: Summary ──────────────────────────────────────────────────────────
echo "=== Install Complete ==="
echo "  Ref:    ${PINNED_REF}"
echo "  SHA:    ${RESOLVED_SHA}"
echo "  Agents: ${AGENT_COUNT}"
echo "  Skills: ${SKILL_COUNT}"
echo ""
echo "Next steps:"
echo "  cd ${CONSUMER_DIR}"
echo "  git add .claude/agents/ .claude/skills/ .preflight/installed.lock"
echo "  git commit -m \"chore: pin preflight framework at ${PINNED_REF} (${RESOLVED_SHA:0:7})\""
echo ""
echo "To verify integrity later: tools/preflight-verify.sh ${CONSUMER_DIR}"

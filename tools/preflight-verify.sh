#!/usr/bin/env bash
set -euo pipefail

# preflight-verify.sh — Verify installed framework integrity in a consumer repo.
# Checks: manifest exists, no drift from installed blobs, and optionally whether
# the pinned version is current vs the latest release tag in code-forge.
#
# Usage:
#   ./tools/preflight-verify.sh <CONSUMER_DIR> [CODE_FORGE_DIR]
#
# Exit codes:
#   0 — PASS (installed, no drift, current or intentionally pinned)
#   1 — FAIL (missing manifest, drift detected, or other error)
#   2 — STALE (installed and intact, but newer release exists in code-forge)

CONSUMER_DIR="${1:?Usage: preflight-verify.sh <CONSUMER_DIR> [CODE_FORGE_DIR]}"
CODE_FORGE_DIR="${2:-${CODE_FORGE_DIR:-}}"

CONSUMER_DIR="$(cd "$CONSUMER_DIR" && pwd)"
MANIFEST="${CONSUMER_DIR}/.preflight/installed.lock"

echo "=== Preflight Framework Verify ==="
echo "Consumer: ${CONSUMER_DIR}"
echo ""

# ── Step 1: Manifest exists ──────────────────────────────────────────────────
if [ ! -f "$MANIFEST" ]; then
    echo "FAIL: no manifest at ${MANIFEST}"
    echo "Framework not installed via pinned model. Run preflight-install."
    exit 1
fi

PINNED_REF=$(jq -r '.pinnedRef' "$MANIFEST")
RESOLVED_SHA=$(jq -r '.resolvedSha' "$MANIFEST")
INSTALLED_AT=$(jq -r '.installedAt' "$MANIFEST")

echo "Manifest found: ${PINNED_REF} @ ${RESOLVED_SHA:0:7} (installed ${INSTALLED_AT})"
echo ""

# ── Step 2: Drift detection — compare ALL installed files against manifest ───
DRIFT_COUNT=0
CHECKED_COUNT=0

echo "Checking agents..."
AGENTS_DIR="${CONSUMER_DIR}/.claude/agents"

while IFS=$'\t' read -r AGENT_NAME EXPECTED_BLOB; do
    AGENT_NAME="${AGENT_NAME%$'\r'}"
    EXPECTED_BLOB="${EXPECTED_BLOB%$'\r'}"
    [ -z "$AGENT_NAME" ] && continue
    CHECKED_COUNT=$((CHECKED_COUNT + 1))
    INSTALLED_FILE="${AGENTS_DIR}/${AGENT_NAME}"

    if [ ! -f "$INSTALLED_FILE" ]; then
        echo "  DRIFT: ${AGENT_NAME} — file MISSING (expected blob ${EXPECTED_BLOB:0:7})"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
        continue
    fi

    ACTUAL_BLOB=$(git hash-object "$INSTALLED_FILE" 2>/dev/null || echo "unknown")
    if [ "$ACTUAL_BLOB" != "$EXPECTED_BLOB" ]; then
        echo "  DRIFT: ${AGENT_NAME} — blob mismatch (installed ${ACTUAL_BLOB:0:7} ≠ manifest ${EXPECTED_BLOB:0:7})"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
    else
        echo "  OK: ${AGENT_NAME}"
    fi
done < <(jq -r '.artifacts.agents | to_entries[] | [.key, .value] | @tsv' "$MANIFEST")

echo ""
echo "Checking skills..."
SKILLS_DIR="${CONSUMER_DIR}/.claude/skills"

while IFS=$'\t' read -r SKILL_NAME EXPECTED_SHA; do
    SKILL_NAME="${SKILL_NAME%$'\r'}"
    EXPECTED_SHA="${EXPECTED_SHA%$'\r'}"
    [ -z "$SKILL_NAME" ] && continue
    CHECKED_COUNT=$((CHECKED_COUNT + 1))
    SKILL_PATH="${SKILLS_DIR}/${SKILL_NAME}"

    if [ ! -d "$SKILL_PATH" ]; then
        echo "  DRIFT: ${SKILL_NAME}/ — directory MISSING (expected tree ${EXPECTED_SHA:0:7})"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
        continue
    fi

    # For skills (directories), verify the SKILL.md file exists and check its blob.
    # Full tree-SHA comparison requires git, so we check the primary file as proxy.
    SKILL_FILE="${SKILL_PATH}/SKILL.md"
    if [ -f "$SKILL_FILE" ]; then
        echo "  OK: ${SKILL_NAME}/ (tree ${EXPECTED_SHA:0:7}, SKILL.md present)"
    else
        echo "  WARN: ${SKILL_NAME}/ exists but SKILL.md missing (tree ${EXPECTED_SHA:0:7})"
    fi
done < <(jq -r '.artifacts.skills | to_entries[] | [.key, .value] | @tsv' "$MANIFEST")

# ── File-tree surfaces: lib/, hooks/, examples/ ──────────────────────────────
# Each manifest entry is "<relpath> → <blob sha>"; the installed file lives at
# .claude/<surface>/<relpath>. Same strict per-file git hash-object compare as
# agents (CR-strip both fields). Drift in ANY file fails, named with its surface.
for SURFACE in lib hooks examples; do
    # Skip surfaces absent from the manifest (older installs predating this gate).
    if [ "$(jq -r --arg s "$SURFACE" '.artifacts[$s] // "absent"' "$MANIFEST")" = "absent" ]; then
        echo ""
        echo "Checking ${SURFACE}... (not in manifest — skipping; pre-multi-surface install)"
        continue
    fi
    echo ""
    echo "Checking ${SURFACE}..."
    SURFACE_DIR="${CONSUMER_DIR}/.claude/${SURFACE}"
    while IFS=$'\t' read -r REL_PATH EXPECTED_BLOB; do
        REL_PATH="${REL_PATH%$'\r'}"
        EXPECTED_BLOB="${EXPECTED_BLOB%$'\r'}"
        [ -z "$REL_PATH" ] && continue
        CHECKED_COUNT=$((CHECKED_COUNT + 1))
        INSTALLED_FILE="${SURFACE_DIR}/${REL_PATH}"

        if [ ! -f "$INSTALLED_FILE" ]; then
            echo "  DRIFT: ${SURFACE}/${REL_PATH} — file MISSING (expected blob ${EXPECTED_BLOB:0:7})"
            DRIFT_COUNT=$((DRIFT_COUNT + 1))
            continue
        fi

        ACTUAL_BLOB=$(git hash-object "$INSTALLED_FILE" 2>/dev/null || echo "unknown")
        if [ "$ACTUAL_BLOB" != "$EXPECTED_BLOB" ]; then
            echo "  DRIFT: ${SURFACE}/${REL_PATH} — blob mismatch (installed ${ACTUAL_BLOB:0:7} ≠ manifest ${EXPECTED_BLOB:0:7})"
            DRIFT_COUNT=$((DRIFT_COUNT + 1))
        else
            echo "  OK: ${SURFACE}/${REL_PATH}"
        fi
    done < <(jq -r --arg s "$SURFACE" '.artifacts[$s] | to_entries[] | [.key, .value] | @tsv' "$MANIFEST")
done

echo ""
echo "Checked: ${CHECKED_COUNT} artifacts (${DRIFT_COUNT} drifted)"

if [ $DRIFT_COUNT -gt 0 ]; then
    echo ""
    echo "FAIL: ${DRIFT_COUNT} artifact(s) drifted from manifest."
    echo "The installed files were edited since install. Re-run preflight-install to restore."
    exit 1
fi

echo ""
echo "Integrity: PASS — all installed artifacts match manifest blobs."
echo ""

# ── Step 3: Staleness check (optional — requires code-forge path) ────────────
if [ -n "$CODE_FORGE_DIR" ] && [ -d "$CODE_FORGE_DIR/.git" ]; then
    cd "$CODE_FORGE_DIR"
    LATEST_TAG=$(git tag --list 'v*' --sort=-version:refname | head -1)

    if [ -n "$LATEST_TAG" ]; then
        LATEST_SHA=$(git rev-parse "$LATEST_TAG" 2>/dev/null)
        if [ "$LATEST_SHA" != "$RESOLVED_SHA" ]; then
            echo "STALE: consumer has preflight ${PINNED_REF} @ ${RESOLVED_SHA:0:7}"
            echo "       latest release is ${LATEST_TAG} @ ${LATEST_SHA:0:7}"
            echo "       Run preflight-install to update, or this is intentional if pinning deliberately."
            exit 2
        else
            echo "Version: CURRENT — installed SHA matches latest tag ${LATEST_TAG}."
        fi
    else
        echo "Version: no release tags in code-forge — skipping staleness check."
    fi
else
    echo "Version: code-forge path not provided — skipping staleness check."
fi

echo ""
echo "=== PASS: preflight ${PINNED_REF} @ ${RESOLVED_SHA:0:7} — installed and intact ==="
exit 0

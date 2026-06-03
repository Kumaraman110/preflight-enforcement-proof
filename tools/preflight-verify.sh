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

PINNED_REF=$(grep -o '"pinnedRef": *"[^"]*"' "$MANIFEST" | cut -d'"' -f4)
RESOLVED_SHA=$(grep -o '"resolvedSha": *"[^"]*"' "$MANIFEST" | cut -d'"' -f4)
INSTALLED_AT=$(grep -o '"installedAt": *"[^"]*"' "$MANIFEST" | cut -d'"' -f4)

echo "Manifest found: ${PINNED_REF} @ ${RESOLVED_SHA:0:7} (installed ${INSTALLED_AT})"
echo ""

# ── Step 2: Drift detection — compare installed files against manifest blobs ─
DRIFT_COUNT=0

echo "Checking agents..."
AGENTS_DIR="${CONSUMER_DIR}/.claude/agents"
# Extract agent entries from manifest (simple grep-based JSON parsing)
while IFS= read -r LINE; do
    AGENT_NAME=$(echo "$LINE" | grep -o '"[^"]*":' | head -1 | tr -d '":')
    EXPECTED_BLOB=$(echo "$LINE" | grep -o ': *"[^"]*"' | head -1 | cut -d'"' -f2)

    if [ -z "$AGENT_NAME" ] || [ -z "$EXPECTED_BLOB" ]; then continue; fi

    INSTALLED_FILE="${AGENTS_DIR}/${AGENT_NAME}"
    if [ ! -f "$INSTALLED_FILE" ]; then
        echo "  DRIFT: ${AGENT_NAME} — file MISSING (expected blob ${EXPECTED_BLOB:0:7})"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
        continue
    fi

    ACTUAL_BLOB=$(git hash-object "$INSTALLED_FILE" 2>/dev/null || echo "unknown")
    if [ "$ACTUAL_BLOB" != "$EXPECTED_BLOB" ]; then
        echo "  DRIFT: ${AGENT_NAME} — blob mismatch (expected ${EXPECTED_BLOB:0:7}, got ${ACTUAL_BLOB:0:7})"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
    else
        echo "  OK: ${AGENT_NAME}"
    fi
done < <(grep -A1 '"agents"' "$MANIFEST" | grep -v '"agents"' | grep '".*": *"' | sed 's/[,{}]//g' || true)

# More robust: parse all agent lines between "agents": { and the closing }
AGENTS_SECTION=$(sed -n '/"agents":/,/}/p' "$MANIFEST" | grep -v '"agents"' | grep -v '^[[:space:]]*[{}]' | sed 's/[,]$//')
while IFS= read -r LINE; do
    [ -z "$LINE" ] && continue
    AGENT_NAME=$(echo "$LINE" | sed 's/.*"\([^"]*\)".*/\1/' | head -1)
    EXPECTED_BLOB=$(echo "$LINE" | sed 's/.*: *"\([^"]*\)".*/\1/')

    [ -z "$AGENT_NAME" ] || [ -z "$EXPECTED_BLOB" ] && continue
    [ "$AGENT_NAME" = "$EXPECTED_BLOB" ] && continue

    INSTALLED_FILE="${AGENTS_DIR}/${AGENT_NAME}"
    if [ ! -f "$INSTALLED_FILE" ]; then
        echo "  DRIFT: ${AGENT_NAME} — file MISSING"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
        continue
    fi

    ACTUAL_BLOB=$(git -C "$CONSUMER_DIR" hash-object "$INSTALLED_FILE" 2>/dev/null || git hash-object "$INSTALLED_FILE" 2>/dev/null || echo "unknown")
    if [ "$ACTUAL_BLOB" != "$EXPECTED_BLOB" ]; then
        echo "  DRIFT: ${AGENT_NAME} — blob mismatch (installed ${ACTUAL_BLOB:0:7} ≠ manifest ${EXPECTED_BLOB:0:7})"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
    fi
done <<< "$AGENTS_SECTION"

echo ""

if [ $DRIFT_COUNT -gt 0 ]; then
    echo "FAIL: ${DRIFT_COUNT} artifact(s) drifted from manifest."
    echo "The installed files were edited since install. Re-run preflight-install to restore."
    exit 1
fi

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

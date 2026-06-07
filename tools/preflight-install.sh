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
#
# Installs ALL framework surfaces into the consumer's .claude/ (the unified root —
# skills/agents are platform-locked there; hooks/lib/examples join them so the
# Layer-2 resolution idiom ${CLAUDE_PROJECT_DIR:-…}/.claude finds them as siblings):
#   .claude/agents/   .claude/skills/   .claude/lib/   .claude/hooks/   .claude/examples/
# Plus a structured jq-merge of the hooks registration block into .claude/settings.json
# (preserving every pre-existing key), and a manifest covering every surface.
# .preflight/ holds runtime state only (manifest, cache, captures).

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

# Scratch space for per-surface artifact tables (name<TAB>blobsha), assembled into
# the manifest via jq at the end. Cleaned up on exit.
TSV_DIR="$(mktemp -d)"
trap 'rm -rf "$TSV_DIR"' EXIT

# ── Step 1: Dirty-tree guard ─────────────────────────────────────────────────
# Refuse if code-forge has uncommitted changes at any copied artifact path.
cd "$CODE_FORGE_DIR"
DIRTY=$(git status --porcelain -- agents/ skills/ lib/ hooks/ examples/ defaults/ docs/ 2>/dev/null || true)
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

# ── Helper: convert a name<TAB>sha table to a JSON object {name: sha, …} ──────
tsv_to_json() {
    # $1 = path to a TSV file (may be missing/empty → {})
    if [ -s "$1" ]; then
        jq -R -s 'split("\n") | map(select(length>0) | split("\t")) | map({(.[0]): .[1]}) | add // {}' "$1"
    else
        echo "{}"
    fi
}

# ── Helper: install a file-tree surface (lib/ hooks/ examples/) from the ref ──
# Copies every blob under <surface>/ at the pinned ref into the consumer's
# .claude/<surface>/, preserving relative subpaths, and records each file's blob
# SHA keyed by its path RELATIVE to the surface dir (e.g. "rubrics/foo.md").
install_file_surface() {
    local surface="$1"
    local exclude="${2:-}"   # optional: relpath (relative to surface) to NOT copy as a file
    local tsv="${TSV_DIR}/${surface}.tsv"
    : > "$tsv"
    local count=0
    local line meta path mode relpath dest actual_blob
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # git ls-tree -r output: "<mode> <type> <sha>\t<path>"
        meta="${line%%$'\t'*}"
        path="${line#*$'\t'}"
        mode="${meta%% *}"
        relpath="${path#"${surface}"/}"          # strip "lib/" → "detect-stack.sh"
        # Skip an explicitly-excluded file (e.g. defaults/hooks-settings-template.json,
        # whose content already reaches the consumer via the Step 6 settings.json merge —
        # copying it as a file would be misleading).
        if [ -n "$exclude" ] && [ "$relpath" = "$exclude" ]; then
            echo "  ${surface}: skip ${relpath} (excluded — consumed via settings.json merge, not copied as a file)"
            continue
        fi
        dest="${CONSUMER_DIR}/.claude/${path}"    # → .claude/lib/detect-stack.sh
        mkdir -p "$(dirname "$dest")"
        git show "${RESOLVED_SHA}:${path}" > "$dest"
        # Preserve an executable bit if the committed mode carried one.
        if [ "$mode" = "100755" ]; then chmod +x "$dest"; fi
        actual_blob=$(git hash-object "$dest")
        printf '%s\t%s\n' "$relpath" "$actual_blob" >> "$tsv"
        count=$((count + 1))
        echo "  ${surface}: ${relpath} (${actual_blob:0:7})"
    done < <(git ls-tree -r "$RESOLVED_SHA" -- "${surface}/")
    echo "  → ${count} ${surface} files installed"
    echo ""
}

# ── Step 3: Install agents ───────────────────────────────────────────────────
AGENTS_DIR="${CONSUMER_DIR}/.claude/agents"
mkdir -p "$AGENTS_DIR"
: > "${TSV_DIR}/agents.tsv"
AGENT_COUNT=0
for AGENT_PATH in $(git ls-tree --name-only "$RESOLVED_SHA" -- agents/ | grep '\.md$'); do
    AGENT_NAME=$(basename "$AGENT_PATH")
    git show "${RESOLVED_SHA}:${AGENT_PATH}" > "${AGENTS_DIR}/${AGENT_NAME}"
    BLOB_SHA=$(git hash-object "${AGENTS_DIR}/${AGENT_NAME}")
    printf '%s\t%s\n' "$AGENT_NAME" "$BLOB_SHA" >> "${TSV_DIR}/agents.tsv"
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
: > "${TSV_DIR}/skills.tsv"
SKILL_COUNT=0
for SKILL_TREE in $(git ls-tree --name-only "$RESOLVED_SHA" -- skills/); do
    SKILL_NAME=$(basename "$SKILL_TREE")
    SKILL_TARGET="${SKILLS_DIR}/${SKILL_NAME}"
    mkdir -p "$SKILL_TARGET"
    # Extract the skill directory tree at the pinned ref
    git archive "$RESOLVED_SHA" -- "skills/${SKILL_NAME}/" | tar -x -C "$SKILLS_DIR" --strip-components=1 2>/dev/null
    TREE_SHA=$(git rev-parse "${RESOLVED_SHA}:skills/${SKILL_NAME}" 2>/dev/null || echo "unknown")
    printf '%s\t%s\n' "$SKILL_NAME" "$TREE_SHA" >> "${TSV_DIR}/skills.tsv"
    SKILL_COUNT=$((SKILL_COUNT + 1))
    echo "  skill: ${SKILL_NAME} (${TREE_SHA:0:7})"
done
echo "  → ${SKILL_COUNT} skills installed"
echo ""

# ── Step 5: Install lib/, hooks/, examples/, docs/, defaults/ (file-tree surfaces) ─────────────
install_file_surface "lib"
install_file_surface "hooks"
install_file_surface "examples"
install_file_surface "docs"
# defaults/: ship the files the consumer uses AS files (config-template + capture-templates),
# but NOT hooks-settings-template.json — its content reaches the consumer via the Step 6
# settings.json merge, so copying it as a file would be misleading/redundant.
install_file_surface "defaults" "hooks-settings-template.json"

# Hook scripts are invoked by Claude Code (run-hook.cmd) and by skills (bash <script>).
# Ensure they are executable on POSIX consumers — chmod does NOT change the content
# blob, so manifest integrity (git hash-object) is unaffected.
chmod +x "${CONSUMER_DIR}/.claude/hooks/"* 2>/dev/null || true

# ── Step 6: Merge the hooks registration block into .claude/settings.json ─────
# Structured jq merge — add/replace ONLY the .hooks key; every other key is preserved.
# The hooks block is read from the PINNED REF (never the working tree), consistent
# with the rest of the install.
echo "Merging hooks block into .claude/settings.json…"
SETTINGS="${CONSUMER_DIR}/.claude/settings.json"
HOOKS_BLOCK=$(git show "${RESOLVED_SHA}:defaults/hooks-settings-template.json" | jq '.hooks')

if [ -z "$HOOKS_BLOCK" ] || [ "$HOOKS_BLOCK" = "null" ]; then
    echo "ABORT: hooks template at ${RESOLVED_SHA}:defaults/hooks-settings-template.json has no .hooks block."
    exit 1
fi

if [ -f "$SETTINGS" ]; then
    if ! jq empty "$SETTINGS" 2>/dev/null; then
        echo "ABORT: existing ${SETTINGS} is not valid JSON — refusing to merge."
        exit 1
    fi
    # Snapshot every NON-.hooks key (content-normalized) before the merge.
    BEFORE_NONHOOKS=$(jq -S 'del(.hooks)' "$SETTINGS")
    # Merge: set ONLY .hooks.
    MERGED=$(jq --argjson hooks "$HOOKS_BLOCK" '.hooks = $hooks' "$SETTINGS")
    # POST-MERGE VERIFICATION: every non-.hooks key must be byte-identical (normalized).
    AFTER_NONHOOKS=$(printf '%s' "$MERGED" | jq -S 'del(.hooks)')
    if [ "$BEFORE_NONHOOKS" != "$AFTER_NONHOOKS" ]; then
        echo "ABORT: merge would alter keys other than .hooks — settings.json left UNCHANGED."
        echo "--- non-.hooks keys BEFORE ---"; echo "$BEFORE_NONHOOKS"
        echo "--- non-.hooks keys AFTER ----"; echo "$AFTER_NONHOOKS"
        exit 1
    fi
    printf '%s\n' "$MERGED" > "$SETTINGS"
    echo "  merged .hooks into existing settings.json (all other keys preserved, verified)"
else
    mkdir -p "$(dirname "$SETTINGS")"
    jq -n --argjson hooks "$HOOKS_BLOCK" '{hooks: $hooks}' > "$SETTINGS"
    echo "  created settings.json with hooks block (no pre-existing settings)"
fi
echo ""

# ── Step 7: Write manifest ───────────────────────────────────────────────────
# Manifest shape: artifacts.{agents,skills,lib,hooks,examples}, each an object of
# {name → sha}. agents = per-file blob SHA; skills = per-skill tree SHA; lib/hooks/
# examples = per-file blob SHA keyed by path relative to the surface dir.
MANIFEST_DIR="${CONSUMER_DIR}/.preflight"
mkdir -p "$MANIFEST_DIR"
MANIFEST_PATH="${MANIFEST_DIR}/installed.lock"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

AGENTS_JSON=$(tsv_to_json "${TSV_DIR}/agents.tsv")
SKILLS_JSON=$(tsv_to_json "${TSV_DIR}/skills.tsv")
LIB_JSON=$(tsv_to_json "${TSV_DIR}/lib.tsv")
HOOKS_JSON=$(tsv_to_json "${TSV_DIR}/hooks.tsv")
EXAMPLES_JSON=$(tsv_to_json "${TSV_DIR}/examples.tsv")
DOCS_JSON=$(tsv_to_json "${TSV_DIR}/docs.tsv")
DEFAULTS_JSON=$(tsv_to_json "${TSV_DIR}/defaults.tsv")

jq -n \
    --arg framework "preflight" \
    --arg pinnedRef "$PINNED_REF" \
    --arg resolvedSha "$RESOLVED_SHA" \
    --arg installedAt "$TIMESTAMP" \
    --arg rollbackTag "pre-pinned-install-rollback" \
    --argjson agents "$AGENTS_JSON" \
    --argjson skills "$SKILLS_JSON" \
    --argjson lib "$LIB_JSON" \
    --argjson hooks "$HOOKS_JSON" \
    --argjson examples "$EXAMPLES_JSON" \
    --argjson docs "$DOCS_JSON" \
    --argjson defaults "$DEFAULTS_JSON" \
    '{
        framework: $framework,
        pinnedRef: $pinnedRef,
        resolvedSha: $resolvedSha,
        installedAt: $installedAt,
        rollbackTag: $rollbackTag,
        artifacts: {
            agents: $agents,
            skills: $skills,
            lib: $lib,
            hooks: $hooks,
            examples: $examples,
            docs: $docs,
            defaults: $defaults
        }
    }' > "$MANIFEST_PATH"

echo "Manifest written: ${MANIFEST_PATH}"
echo "  (artifacts: agents=$(echo "$AGENTS_JSON" | jq 'length'), skills=$(echo "$SKILLS_JSON" | jq 'length'), lib=$(echo "$LIB_JSON" | jq 'length'), hooks=$(echo "$HOOKS_JSON" | jq 'length'), examples=$(echo "$EXAMPLES_JSON" | jq 'length'), docs=$(echo "$DOCS_JSON" | jq 'length'), defaults=$(echo "$DEFAULTS_JSON" | jq 'length'))"
echo ""

# ── Step 8: Summary ──────────────────────────────────────────────────────────
echo "=== Install Complete ==="
echo "  Ref:      ${PINNED_REF}"
echo "  SHA:      ${RESOLVED_SHA}"
echo "  Agents:   ${AGENT_COUNT}"
echo "  Skills:   ${SKILL_COUNT}"
echo "  lib/hooks/examples/docs/defaults + hooks block merged into settings.json"
echo ""
echo "Next steps:"
echo "  cd ${CONSUMER_DIR}"
echo "  git add .claude/ .preflight/installed.lock"
echo "  git commit -m \"chore: pin preflight framework at ${PINNED_REF} (${RESOLVED_SHA:0:7})\""
echo ""
echo "To verify integrity later: tools/preflight-verify.sh ${CONSUMER_DIR}"

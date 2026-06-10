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

# CODE_FORGE_DIR resolution (A4 fix): default to the code-forge repo derived from THIS
# script's own location (tools/preflight-install.sh → repo root is the parent dir), NOT
# from `git rev-parse` in the caller's cwd. The old default ran `git rev-parse
# --show-toplevel` in cwd; with `set -e` (above) a non-git cwd made that substitution
# exit 128 and the whole installer died — even when given absolute path args. The env
# override still wins (CODE_FORGE_DIR=… bash …). We then VALIDATE the resolved dir is a
# git worktree (the install reads git objects via the pinned ref), failing with a CLEAR
# message rather than an opaque exit 128 deeper in.
if [ -z "${CODE_FORGE_DIR:-}" ]; then
    _PF_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CODE_FORGE_DIR="$(cd "${_PF_SCRIPT_DIR}/.." && pwd)"   # tools/ → repo root
fi
if ! git -C "$CODE_FORGE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "ABORT: CODE_FORGE_DIR ('${CODE_FORGE_DIR}') is not a git repository."
    echo "  The installer reads framework artifacts from git objects at a pinned ref, so it"
    echo "  must point at the code-forge git worktree. Either run this script from within the"
    echo "  code-forge checkout, or set CODE_FORGE_DIR=/path/to/code-forge explicitly."
    exit 1
fi

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
# Use --verify --quiet so an UNKNOWN ref yields an EMPTY result + non-zero (caught by the
# -z check below), instead of (a) echoing the bad ref to stdout — plain `git rev-parse
# <bad>` prints its argument, which would slip past `[ -z ]` as a bogus non-empty SHA — and
# (b) aborting the script at exit 128 under `set -e` BEFORE this friendly ABORT can run
# (that handler was dead). `|| true` keeps the assignment from tripping errexit.
RESOLVED_SHA=$(git -C "$CODE_FORGE_DIR" rev-parse --verify --quiet "$PINNED_REF" 2>/dev/null || true)
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
        # Skip an explicitly-excluded file (optional 2nd arg) — for a surface file whose
        # content reaches the consumer by another path and would be misleading to copy.
        # (Currently no surface passes an exclude; the mechanism is retained for reuse.)
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
# defaults/: ship config-template + capture-templates. (There is no hooks-settings-template
# anymore — hook registration has a SINGLE source of truth: hooks/hooks.json, read directly by
# Step 6. This eliminates the dual-source drift that silently dropped adjudication-output-gate.)
install_file_surface "defaults"

# Hook scripts are invoked by Claude Code (run-hook.cmd) and by skills (bash <script>).
# Ensure they are executable on POSIX consumers — chmod does NOT change the content
# blob, so manifest integrity (git hash-object) is unaffected.
chmod +x "${CONSUMER_DIR}/.claude/hooks/"* 2>/dev/null || true

# ── Step 6: Merge the hooks registration block into .claude/settings.json ─────
# Structured jq merge — add/replace ONLY the .hooks key; every other key is preserved.
# SINGLE SOURCE OF TRUTH: the .hooks block is read directly from hooks/hooks.json (the same
# file shipped to .claude/hooks/ and the file engineers edit when adding a hook). There is no
# separate settings-template to keep in sync — eliminating the dual-source drift that silently
# dropped adjudication-output-gate from the merged settings.json (the v0.7.4 RED-1 dead-gate).
# Read from the PINNED REF (never the working tree), consistent with the rest of the install.
echo "Merging hooks block into .claude/settings.json…"
SETTINGS="${CONSUMER_DIR}/.claude/settings.json"
HOOKS_BLOCK=$(git show "${RESOLVED_SHA}:hooks/hooks.json" | jq '.hooks')

if [ -z "$HOOKS_BLOCK" ] || [ "$HOOKS_BLOCK" = "null" ]; then
    echo "ABORT: hooks/hooks.json at ${RESOLVED_SHA} has no .hooks block."
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

# ── Step 6.5: Manifest-diff prune (close the copy-only-never-prune gap) ───────
# Before overwriting the manifest, remove consumer artifacts that a PRIOR install
# placed but the pinned ref NO LONGER ships — e.g. a renamed/removed agent like the
# `copilot-review-loop` zombie (renamed to external-review-handler; the old file
# lingered in consumers and stayed an invocable subagent_type). Same dead-artifact
# CLASS as the RED-1 dead gate: the surface was additive-only, so stale files
# accumulated invisibly (preflight-verify is manifest-blind to EXTRA files).
#
# SURGICAL + SAFE: prunes EXACTLY (old manifest keys) − (new manifest keys) per
# surface. A consumer's own hand-authored file is NEVER touched — it was never in
# preflight's manifest, so it is never in the "old keys" set. Only the seven
# framework-owned .claude/ surfaces are in scope; .preflight/ runtime state is never
# pruned. If there is no prior manifest (first install), nothing is pruned.
PRUNED_COUNT=0
if [ -f "$MANIFEST_PATH" ] && command -v jq &>/dev/null; then
    OLD_MANIFEST="$(cat "$MANIFEST_PATH")"
    prune_surface() {
        # NOTE: split declarations — a single `local a=$1 b="${a}.x"` does NOT see `a` in
        # `b`'s RHS in some bash builds (all RHS expand before any binds), which silently made
        # tsv resolve to "${TSV_DIR}/.tsv" → no file → nothing pruned (caught in sandbox).
        local surface="$1" kind="$2"
        local tsv="${TSV_DIR}/${surface}.tsv"
        local k target
        # Set-difference (removed = old manifest keys − newly-installed keys) computed with a
        # single CRLF-proof awk pass. tr -d '\r' on BOTH inputs is load-bearing: jq output and
        # TSV lines can carry CRLF on Windows consumers; a stray "\r" makes naive comparison see
        # "name\r" != "name" and prune LIVE artifacts while keeping zombies (both inversions were
        # caught in sandbox). awk (not `comm`) avoids `comm`'s strict byte+collation fragility.
        # Process-substitution feeds the while-loop (NOT a pipe) so PRUNED_COUNT survives.
        while IFS= read -r k; do
            k="${k%$'\r'}"          # belt-and-suspenders: strip any residual CR on the read key
            [ -z "$k" ] && continue
            # ── Path-traversal confinement (security) ──────────────────────────────
            # `k` originates from a PRIOR install's manifest, which a corrupt or
            # hostile manifest could populate with an escaping path (e.g.
            # "../../../../etc/passwd" or "/etc/cron.d/x"). The key is interpolated
            # into an rm -rf/-f target, so confine it to the surface subtree: reject
            # absolute paths, any "../" / "/.." / bare ".." segment, "~", and NUL.
            # Pruning only ever targets framework-owned relative keys under
            # .claude/<surface>/; anything that could escape that subtree is skipped
            # (not pruned) and reported, never deleted.
            case "$k" in
                /*|~*|*$'\n'*)
                    echo "  WARN prune ${surface}: skipping unsafe key (absolute/escaping): ${k}" >&2
                    continue ;;
                ..|../*|*/..|*/../*)
                    echo "  WARN prune ${surface}: skipping unsafe key (path traversal): ${k}" >&2
                    continue ;;
            esac
            if [ "$kind" = "skill" ]; then
                target="${CONSUMER_DIR}/.claude/skills/${k}"
                if [ -d "$target" ]; then
                    echo "  prune skill: ${k}/ (prior install; not in ${PINNED_REF})"
                    rm -rf "$target"
                    PRUNED_COUNT=$((PRUNED_COUNT + 1))
                fi
            else
                # file surface — agents key=basename; lib/hooks/examples/docs/defaults key=relpath
                target="${CONSUMER_DIR}/.claude/${surface}/${k}"
                if [ -f "$target" ]; then
                    echo "  prune ${surface}: ${k} (prior install; not in ${PINNED_REF})"
                    rm -f "$target"
                    PRUNED_COUNT=$((PRUNED_COUNT + 1))
                fi
            fi
        done < <(
            # Tag each line with its source file (n=new, o=old) instead of relying on NR==FNR —
            # NR==FNR mis-assigns when the FIRST file is EMPTY (a surface that ships zero files),
            # the classic awk empty-first-file bug. Tag-by-prefix is immune. removed = old − new.
            { cut -f1 "$tsv" 2>/dev/null | tr -d '\r' | sort -u | sed 's/^/n /'
              printf '%s' "$OLD_MANIFEST" | jq -r ".artifacts.${surface} // {} | keys[]" 2>/dev/null | tr -d '\r' | sort -u | sed 's/^/o /'
            } | awk '{ if($1=="n"){new[$2]=1} else {old[$2]=1} } END{ for(k in old) if(!(k in new)) print k }'
        )
    }
    prune_surface agents   file
    prune_surface skills   skill
    prune_surface lib      file
    prune_surface hooks    file
    prune_surface examples file
    prune_surface docs     file
    prune_surface defaults file
    # Remove now-empty subdirs left behind by file-surface prunes (never the surface root).
    for s in agents lib hooks examples docs defaults; do
        find "${CONSUMER_DIR}/.claude/${s}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    done
    if [ "$PRUNED_COUNT" -gt 0 ]; then
        echo "  → pruned ${PRUNED_COUNT} stale artifact(s) no longer shipped at ${PINNED_REF}"
    fi
    echo ""
fi

# ── Step 6.6: Place .preflight/.gitignore so runtime state can't be committed (GAP-5c) ──
# Without this, a consumer has NO ignore for .preflight/ runtime state, so a broad `git add`
# sweeps gate evidence / derived caches / metrics / checkpoint into a commit. The template
# ships in defaults/ (already installed to .claude/defaults/preflight-gitignore above).
# - Absent  → create from template.
# - Present → APPEND only the required lines that are missing (don't clobber a consumer's
#   customized ignore; a prior hand-made file was observed missing 'derived/' and 'metrics.json').
GITIGNORE_TEMPLATE="${CONSUMER_DIR}/.claude/defaults/preflight-gitignore"
CONSUMER_GITIGNORE="${MANIFEST_DIR}/.gitignore"
REQUIRED_IGNORES="cache/ derived/ gate/ metrics.json migrate-checkpoint.json"
if [ -f "$GITIGNORE_TEMPLATE" ]; then
    if [ ! -f "$CONSUMER_GITIGNORE" ]; then
        cp "$GITIGNORE_TEMPLATE" "$CONSUMER_GITIGNORE"
        echo "Created .preflight/.gitignore from template (runtime state will not be committed)."
    else
        ADDED=""
        for pat in $REQUIRED_IGNORES; do
            # match the bare pattern as a whole line (ignoring CR), so we don't double-add
            if ! grep -qE "^${pat//./\\.}[[:space:]]*$" <(tr -d '\r' < "$CONSUMER_GITIGNORE"); then
                printf '%s\n' "$pat" >> "$CONSUMER_GITIGNORE"
                ADDED="${ADDED} ${pat}"
            fi
        done
        if [ -n "$ADDED" ]; then
            echo "Updated .preflight/.gitignore — added missing runtime-state ignores:${ADDED}"
        else
            echo ".preflight/.gitignore already covers all required runtime-state paths."
        fi
    fi
    echo ""
fi

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

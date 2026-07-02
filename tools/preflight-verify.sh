#!/usr/bin/env bash
set -euo pipefail

# preflight-verify.sh — Verify installed framework integrity in a consumer repo.
# Checks: manifest exists, no drift from installed blobs, and (optionally, given a code-forge path) the
# ANCESTRY-AWARE release relation of the installed SHA to the latest release tag.
#
# Usage:
#   ./tools/preflight-verify.sh <CONSUMER_DIR> [CODE_FORGE_DIR]
#
# The verifier reports FOUR clearly-separated dimensions:
#   Integrity            — do installed artifacts match the manifest blobs?
#   Installation identity— pinned ref / resolved SHA / runtime registration / hazard state.
#   Release relation     — ancestry of the installed SHA vs the latest release tag.
#   Final classification — the single status below.
#
# Release-relation classifications (Step 3) and exit codes:
#   CURRENT_RELEASE       (exit 0)  — installed SHA == latest release tag commit.
#   PINNED_AHEAD          (exit 0)  — installed SHA is a DESCENDANT of the latest tag (deliberately pinned,
#                                     intact, newer than the latest tagged release). NOT stale.
#   STALE                 (exit 2)  — installed SHA is an ANCESTOR of the latest tag (a newer release exists).
#   DIVERGED_OR_UNKNOWN   (exit 3)  — installed SHA and latest tag are unrelated, ancestry can't be
#                                     established, or required source objects are unavailable (advisory,
#                                     distinct from integrity drift).
#
# Integrity / identity exit codes (take precedence — never hidden behind release status):
#   0 — PASS (installed, no drift; release relation is CURRENT_RELEASE or PINNED_AHEAD or skipped)
#   1 — FAIL/INTEGRITY_FAILURE (missing manifest, artifact drift, runtime/manifest mismatch, registration
#       hazard, or other integrity error)
#   2 — STALE (integrity OK, but the installed SHA is behind the latest release tag)
#   3 — DIVERGED_OR_UNKNOWN (integrity OK, but the release relation could not be established)

CONSUMER_DIR="${1:?Usage: preflight-verify.sh <CONSUMER_DIR> [CODE_FORGE_DIR]}"
CODE_FORGE_DIR="${2:-${CODE_FORGE_DIR:-}}"

CONSUMER_DIR="$(cd "$CONSUMER_DIR" && pwd)"
MANIFEST="${CONSUMER_DIR}/.preflight/installed.lock"

# (H7) Recompute the git TREE sha of an installed skill directory, to compare against the manifest's stored
# tree sha (the installer records skills.<name> = `git rev-parse <ref>:skills/<name>`, a TREE object sha;
# see preflight-install.sh). PRE-FIX, verify only tested `[ -f SKILL.md ]` and printed OK — the tree sha was
# never compared, so a TAMPERED SKILL.md, an added/removed sibling, or a hollowed skill all passed
# "Integrity: PASS", and a deleted SKILL.md was a non-DRIFT WARN. Skills are the framework's ONLY invocable
# surface, so that was a silent false-green on the highest-value surface.
#
# Mechanism: copy the installed skill dir into an ISOLATED throwaway git repo (NO dependency on the consumer
# being a git repo, NO dependency on the framework's GIT_DIR), `git add` + `write-tree`, and read the
# subtree sha. core.autocrlf=input normalizes CRLF->LF so the recomputed sha matches the committed-object
# tree sha the manifest stores (the installer's `git rev-parse <ref>:skills/<name>` reads LF committed
# objects; an install that wrote CRLF on disk would otherwise mismatch). Echoes the tree sha, or "unknown"
# on any failure (caller treats unknown as DRIFT — fail-closed). git is already a hard dep of verify
# (git hash-object on every other surface).
recompute_skill_tree() {  # $1 = installed skill dir ; echoes the tree sha or "unknown". Always returns 0.
    local d="$1" iso t st
    [ -d "$d" ] || { echo "unknown"; return 0; }
    iso="$(mktemp -d 2>/dev/null)" || { echo "unknown"; return 0; }
    mkdir -p "$iso/s" 2>/dev/null || { echo "unknown"; rm -rf "$iso" 2>/dev/null; return 0; }
    cp -r "$d"/. "$iso/s/" 2>/dev/null || { echo "unknown"; rm -rf "$iso" 2>/dev/null; return 0; }
    st="$( cd "$iso" \
        && git init -q 2>/dev/null \
        && git config core.autocrlf input 2>/dev/null \
        && git add s 2>/dev/null \
        && t="$(git write-tree 2>/dev/null)" \
        && git rev-parse "${t}:s" 2>/dev/null )"
    rm -rf "$iso" 2>/dev/null || true
    [ -n "$st" ] && echo "$st" || echo "unknown"
    return 0
}

# ── STAGE 2C.1 (Phase 2): BRANCH-STABLE RUNTIME-INSTALL VERIFICATION ────────────────────────────────────────
# Full integrity verification for the runtime-install model (tools/preflight-runtime-install.sh), which has NO
# .preflight/installed.lock. Validates the ACTIVE generation against its own immutable RUNTIME_MANIFEST.json
# (source blob shas) + the registration + rollback metadata. PASSES a valid runtime install (exit 0), FAILS a
# broken one (exit 1); the release relation (when a code-forge path is given) can still yield 2/3, exactly like
# the artifact path. The absence of installed.lock is NEVER treated as a PASS — a missing/invalid runtime here
# FAILS loudly. $1 = consumer dir ; $2 = absolute git common dir ; $3 = code-forge dir (may be empty).
verify_runtime_install() {
    local cons="$1" common="$2" forge="$3"
    local RT_ROOT="$common/preflight/runtime"
    local ACTIVE_MARK="$RT_ROOT/ACTIVE" PREVIOUS_MARK="$RT_ROOT/PREVIOUS"
    local FAIL=0
    local RE='run-hook\.cmd.*(pre-push-gate-check|pre-bash-risk-router)'
    echo "=== Preflight Framework Verify (branch-stable RUNTIME-INSTALL model) ==="
    echo "Consumer:   ${cons}"
    echo "Runtime store: ${RT_ROOT}"
    echo ""

    # (1) ACTIVE exists and is a well-formed 40-hex sha.
    if [ ! -f "$ACTIVE_MARK" ]; then echo "FAIL: no ACTIVE marker at $ACTIVE_MARK."; return 1; fi
    local ACTIVE_SHA; ACTIVE_SHA="$(tr -d ' \r\n' < "$ACTIVE_MARK")"
    case "$ACTIVE_SHA" in
        *[!0-9a-f]*|"") echo "FAIL: ACTIVE marker is not a valid sha ('${ACTIVE_SHA}')."; return 1 ;;
    esac
    [ "${#ACTIVE_SHA}" -eq 40 ] || { echo "FAIL: ACTIVE sha is not 40 hex chars ('${ACTIVE_SHA}')."; return 1; }
    local RT_DIR="$RT_ROOT/$ACTIVE_SHA"
    echo "ACTIVE runtime: ${ACTIVE_SHA:0:12} → $RT_DIR"
    [ -d "$RT_DIR" ] || { echo "FAIL: ACTIVE runtime dir is missing ($RT_DIR)."; return 1; }

    # (2) The immutable RUNTIME_MANIFEST.json exists, is valid JSON, and its resolvedSha matches ACTIVE.
    local MAN="$RT_DIR/RUNTIME_MANIFEST.json"
    if [ ! -f "$MAN" ] || ! jq empty "$MAN" 2>/dev/null; then
        echo "FAIL: ACTIVE runtime has no valid RUNTIME_MANIFEST.json ($MAN) — cannot attest integrity."
        echo "  Re-run tools/preflight-runtime-install.sh (this generation predates the runtime manifest or is corrupt)."
        return 1
    fi
    local MAN_SHA; MAN_SHA="$(jq -r '.resolvedSha // ""' "$MAN")"
    if [ "$MAN_SHA" != "$ACTIVE_SHA" ]; then
        echo "FAIL: RUNTIME_MANIFEST.resolvedSha (${MAN_SHA:0:12}) != ACTIVE (${ACTIVE_SHA:0:12}) — metadata mismatch."; FAIL=1
    fi
    # RUNTIME_SHA provenance file must also agree (belt-and-braces; catches a hand-edited marker).
    local PROV; PROV="$( [ -f "$RT_DIR/RUNTIME_SHA" ] && tr -d ' \r\n' < "$RT_DIR/RUNTIME_SHA" || echo '' )"
    [ "$PROV" = "$ACTIVE_SHA" ] || { echo "FAIL: RUNTIME_SHA provenance ('${PROV:0:12}') != ACTIVE (${ACTIVE_SHA:0:12})."; FAIL=1; }

    # (3) Every artifact in the manifest closure exists AND its on-disk git blob sha matches the manifest.
    # This is the core integrity oracle: a tampered/replaced runtime file changes its blob sha → DRIFT → FAIL.
    echo "Checking runtime closure integrity (manifest blob-sha match)…"
    local checked=0 drift=0 kind rel dir
    for kind in hooks libs; do
        [ "$kind" = hooks ] && dir="$RT_DIR/hooks" || dir="$RT_DIR/lib"
        while IFS=$'\t' read -r rel expected; do
            rel="${rel%$'\r'}"; expected="${expected%$'\r'}"
            [ -z "$rel" ] && continue
            checked=$((checked+1))
            local f="$dir/$rel"
            if [ ! -f "$f" ]; then
                echo "  DRIFT: ${kind}/${rel} — MISSING (expected blob ${expected:0:7})"; drift=$((drift+1)); continue
            fi
            local actual; actual="$(git hash-object "$f" 2>/dev/null || echo unknown)"
            if [ "$actual" != "$expected" ]; then
                echo "  DRIFT: ${kind}/${rel} — blob ${actual:0:7} != manifest ${expected:0:7}"; drift=$((drift+1))
            else
                echo "  OK: ${kind}/${rel}"
            fi
        done < <(jq -r --arg k "$kind" '.closure[$k] | to_entries[] | [.key, .value] | @tsv' "$MAN")
    done
    [ "$checked" -eq 0 ] && { echo "FAIL: runtime manifest closure is empty — nothing verified."; FAIL=1; }
    [ "$drift" -gt 0 ] && { echo "FAIL: ${drift} runtime artifact(s) drifted from the manifest."; FAIL=1; }

    # (4) The AUTHORITATIVE parser closure MUST be present (Stage-2B: the engine fails closed without it,
    # blocking every push). Assert both files explicitly, independent of the manifest loop.
    for req in "lib/shell-structure.sh" "lib/shell-structure-lexer.awk"; do
        [ -f "$RT_DIR/$req" ] || { echo "FAIL: required authoritative-parser file missing from runtime ($req)."; FAIL=1; }
    done
    # The engine + router + evidence gate must exist too (the Bash candidate path).
    for req in "hooks/pre-bash-risk-router" "hooks/pre-push-gate-engine" "hooks/pre-push-gate" "hooks/run-hook.cmd"; do
        [ -f "$RT_DIR/$req" ] || { echo "FAIL: required runtime hook missing ($req)."; FAIL=1; }
    done

    # (5) PREVIOUS, when present, must resolve to a materialized generation (rollback must be possible).
    if [ -f "$PREVIOUS_MARK" ]; then
        local PREV_SHA; PREV_SHA="$(tr -d ' \r\n' < "$PREVIOUS_MARK")"
        if [ -n "$PREV_SHA" ]; then
            case "$PREV_SHA" in *[!0-9a-f]*) echo "FAIL: PREVIOUS marker is not a valid sha ('${PREV_SHA}')."; FAIL=1 ;; esac
            if [ ! -d "$RT_ROOT/$PREV_SHA" ]; then
                echo "FAIL: PREVIOUS runtime ${PREV_SHA:0:12} is recorded but its generation dir is missing — rollback impossible."; FAIL=1
            else
                echo "  OK: PREVIOUS rollback target ${PREV_SHA:0:12} is materialized."
            fi
        fi
    fi

    # (6) Registration: settings.local.json must carry a preflight Bash gate pointing at the ACTIVE runtime,
    # and there must be NO duplicate (tracked settings.json must NOT also register a preflight Bash gate).
    local TRACKED="$cons/.claude/settings.json" LOCAL="$cons/.claude/settings.local.json"
    local tracked_bash=0 local_bash=0
    if [ -f "$LOCAL" ] && jq empty "$LOCAL" 2>/dev/null; then
        local_bash="$(jq -r --arg re "$RE" '[ (.hooks.PreToolUse // [])[] | select(.matcher=="Bash") | (.hooks // [])[] | select((.command // "") | test($re)) ] | length' "$LOCAL" 2>/dev/null || echo 0)"
    fi
    if [ -f "$TRACKED" ] && jq empty "$TRACKED" 2>/dev/null; then
        tracked_bash="$(jq -r --arg re "$RE" '[ (.hooks.PreToolUse // [])[] | select(.matcher=="Bash") | (.hooks // [])[] | select((.command // "") | test($re)) ] | length' "$TRACKED" 2>/dev/null || echo 0)"
    fi
    if [ "$local_bash" -lt 1 ]; then
        echo "FAIL: no preflight Bash PreToolUse registration in settings.local.json — the runtime gate is not active."; FAIL=1
    fi
    if [ "$tracked_bash" -ge 1 ]; then
        echo "FAIL: DUPLICATE registration — tracked settings.json ALSO registers a preflight Bash gate (branch-swappable). Re-run the runtime installer to scrub the tracked layer."; FAIL=1
    fi
    # The local command must point at the ACTIVE sha dir (a stale pin is a hazard).
    if [ "$local_bash" -ge 1 ]; then
        local LOCAL_CMD; LOCAL_CMD="$(jq -r --arg re "$RE" 'first((.hooks.PreToolUse // [])[] | select(.matcher=="Bash") | (.hooks // [])[] | select((.command // "") | test($re)) | .command) // ""' "$LOCAL" 2>/dev/null || echo '')"
        if printf '%s' "$LOCAL_CMD" | grep -qF "$ACTIVE_SHA"; then
            echo "  OK: settings.local.json Bash gate points at ACTIVE runtime ${ACTIVE_SHA:0:12}; tracked layer is clean."
        else
            echo "FAIL: settings.local.json Bash gate does NOT point at ACTIVE ${ACTIVE_SHA:0:12} (stale/unpinned registration)."; FAIL=1
        fi
    fi

    echo ""
    if [ "$FAIL" -ne 0 ]; then
        echo "=== FAIL (INTEGRITY_FAILURE): branch-stable runtime @ ${ACTIVE_SHA:0:12} — one or more runtime"
        echo "    integrity/registration checks failed (see above). ==="
        return 1
    fi
    echo "Runtime integrity: PASS — ACTIVE ${ACTIVE_SHA:0:12} closure matches its immutable manifest; registration clean."
    echo ""

    # (7) Release relation (optional; requires a code-forge path) — identical ancestry classification as the
    # artifact path, keyed on ACTIVE_SHA. Never overrides the integrity FAIL above (we already returned on it).
    if [ -n "$forge" ] && [ -d "$forge/.git" ]; then
        local LT; LT="$(git -C "$forge" tag --list 'v*' --sort=-version:refname 2>/dev/null | head -1)"
        if [ -z "$LT" ]; then
            echo "=== ADVISORY (DIVERGED_OR_UNKNOWN): runtime @ ${ACTIVE_SHA:0:12} intact; no release tags to relate. ==="
            return 3
        fi
        local LC IC; LC="$(git -C "$forge" rev-parse --verify --quiet "${LT}^{commit}" 2>/dev/null || echo '')"
        IC="$(git -C "$forge" rev-parse --verify --quiet "${ACTIVE_SHA}^{commit}" 2>/dev/null || echo '')"
        if [ -z "$LC" ] || [ -z "$IC" ]; then
            echo "=== ADVISORY (DIVERGED_OR_UNKNOWN): runtime @ ${ACTIVE_SHA:0:12} intact; ancestry vs ${LT} undeterminable. ==="
            return 3
        elif [ "$LC" = "$IC" ]; then
            echo "=== PASS (CURRENT_RELEASE): branch-stable runtime @ ${ACTIVE_SHA:0:12} == latest tag ${LT}. ==="; return 0
        elif git -C "$forge" merge-base --is-ancestor "$LC" "$IC" 2>/dev/null; then
            echo "=== PASS (PINNED_AHEAD): branch-stable runtime @ ${ACTIVE_SHA:0:12} intact, newer than ${LT}. ==="; return 0
        elif git -C "$forge" merge-base --is-ancestor "$IC" "$LC" 2>/dev/null; then
            echo "=== STALE: branch-stable runtime @ ${ACTIVE_SHA:0:12} is behind the latest release ${LT}. ==="; return 2
        else
            echo "=== ADVISORY (DIVERGED_OR_UNKNOWN): runtime @ ${ACTIVE_SHA:0:12} and ${LT} on unrelated histories. ==="; return 3
        fi
    fi
    echo "=== PASS: branch-stable runtime @ ${ACTIVE_SHA:0:12} — installed and intact (release relation not evaluated; no code-forge path). ==="
    return 0
}

echo "=== Preflight Framework Verify ==="
echo "Consumer: ${CONSUMER_DIR}"
echo ""

# ── Step 0 (STAGE 2C.1): resolve the git common dir (worktree-safe) — used by BOTH the runtime-install
# verification mode below AND the Step-2.5 hazard check. Absolutize a relative ".git". Empty on failure. ─────
resolve_common_dir() {  # $1 = consumer dir ; echoes absolute git-common-dir or empty
    local cons="$1" top common
    top="$(git -C "$cons" rev-parse --show-toplevel 2>/dev/null)" || return 0
    common="$(git -C "$top" rev-parse --git-common-dir 2>/dev/null)" || return 0
    case "$common" in /*|[A-Za-z]:*) : ;; *) common="$top/$common" ;; esac
    ( cd "$common" 2>/dev/null && pwd ) || return 0
}

# ── Step 1: Installed via the ARTIFACT model (manifest) OR the BRANCH-STABLE RUNTIME model? ──────────────
# The framework ships two install models:
#   • ARTIFACT install (tools/preflight-install.sh): writes .preflight/installed.lock + copies surfaces into
#     .claude/. Verified by the manifest-drift path below (Steps 1b–3).
#   • BRANCH-STABLE RUNTIME install (tools/preflight-runtime-install.sh): materializes an immutable runtime
#     under <git-common-dir>/preflight/runtime/<sha>/ (engine+router+gates+libs + RUNTIME_MANIFEST.json) and
#     registers the Bash gate in .claude/settings.local.json. There is NO .preflight/installed.lock.
# STAGE 2C.1 DEFECT FIXED: previously an ABSENT installed.lock => "FAIL: not installed" EVEN WHEN a valid
# runtime install was present — the verifier had NO runtime-install mode, so it could neither PASS a good
# runtime install nor properly FAIL a broken one; it just rejected the whole model. Now: if the artifact
# manifest is absent, DETECT a runtime install (an ACTIVE marker under the common dir) and hand off to the
# dedicated runtime verifier (verify_runtime_install), which PASSES a valid runtime install and FAILS a
# broken one on its own merits. The absence of installed.lock is NEVER by itself a PASS.
if [ ! -f "$MANIFEST" ]; then
    _COMMON="$(resolve_common_dir "$CONSUMER_DIR")"
    _ACTIVE_MARK="${_COMMON:+$_COMMON/preflight/runtime/ACTIVE}"
    if [ -n "$_COMMON" ] && [ -f "$_ACTIVE_MARK" ]; then
        # A branch-stable runtime install is present → verify it fully (own PASS/FAIL, own exit).
        verify_runtime_install "$CONSUMER_DIR" "$_COMMON" "$CODE_FORGE_DIR"
        exit $?
    fi
    echo "FAIL: no artifact manifest at ${MANIFEST} AND no branch-stable runtime install"
    echo "  (no ACTIVE marker under the git common dir). Framework not installed by either model."
    echo "  Run tools/preflight-install.sh (artifact model) or tools/preflight-runtime-install.sh (runtime model)."
    exit 1
fi

PINNED_REF=$(jq -r '.pinnedRef' "$MANIFEST")
RESOLVED_SHA=$(jq -r '.resolvedSha' "$MANIFEST")
INSTALLED_AT=$(jq -r '.installedAt' "$MANIFEST")

echo "Manifest found: ${PINNED_REF} @ ${RESOLVED_SHA:0:7} (installed ${INSTALLED_AT})"
echo ""

# ── Step 1b: Manifest-shape + mandatory-surface FLOOR (M11) ──────────────────
# PRE-FIX, drift detection was a loop over manifest keys with NO lower-bound assertion: an all-empty
# artifacts.*={} (truncated manifest) drove CHECKED_COUNT=0, DRIFT_COUNT=0 -> "Integrity: PASS" exit 0 with
# ZERO framework files on disk; artifacts.agents=null made the per-surface jq `to_entries[]` error inside a
# process substitution (set -e cannot abort a procsub) so the loop iterated nothing -> same PASS; and an
# absent / non-object artifacts key passed too. "Nothing was checked" was indistinguishable from
# "everything matched" — a silent false-green of the integrity oracle. This floor runs FIRST (a cheap "is
# the manifest even shaped like a real install?"), so a degenerate manifest FAILs before any drift loop —
# and it guarantees the skills loop (H7's content-check) is fed a non-empty object, so H7 needn't defend
# against a null/empty feeder.
#   - .artifacts must be an object (catches absent -> "null", and non-object "oops"/array/number).
#   - {agents, skills} are MANDATORY anchors: the only two surfaces with no sanctioned `// "absent"` legacy
#     path AND guaranteed >=1 entry in every real install (5 agents, 11 skills). Each must be a NON-EMPTY
#     object. Anchoring the floor here closes the degenerate-manifest class without misclassifying a
#     legitimate pre-multi-surface manifest (which still has agents+skills populated; only the OPTIONAL
#     lib/hooks/examples/docs/defaults may be absent). COUPLING NOTE: if the framework ever legitimately
#     ships zero agents or zero skills, this mandatory set must be updated in lockstep with
#     tools/preflight-install.sh's manifest shape.
ARTIFACTS_TYPE=$(jq -r '.artifacts | type' "$MANIFEST" 2>/dev/null || echo "null")
if [ "$ARTIFACTS_TYPE" != "object" ]; then
    echo "FAIL: manifest .artifacts is missing or not an object (got '${ARTIFACTS_TYPE}') — truncated/corrupt manifest."
    echo "A real install always carries an artifacts object; refusing to attest integrity on it."
    exit 1
fi
for MAND in agents skills; do
    MAND_TYPE=$(jq -r --arg s "$MAND" '.artifacts[$s] | type' "$MANIFEST" 2>/dev/null || echo "null")
    MAND_LEN=$(jq -r --arg s "$MAND" '(.artifacts[$s] | objects | length) // -1' "$MANIFEST" 2>/dev/null || echo "-1")
    if [ "$MAND_TYPE" != "object" ] || [ "$MAND_LEN" -lt 1 ] 2>/dev/null; then
        echo "FAIL: manifest .artifacts.${MAND} is null/empty/missing (type='${MAND_TYPE}', entries=${MAND_LEN})."
        echo "A valid install always ships >=1 ${MAND}; this manifest is truncated/corrupt — refusing to attest."
        exit 1
    fi
done

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

    # (H7) CONTENT-check: recompute the installed skill's git TREE sha and compare to the manifest's stored
    # tree sha. This replaces the old `[ -f SKILL.md ]` proxy (which never compared content, so a tampered
    # SKILL.md, an added/removed sibling, or a deleted SKILL.md all passed). ANY mismatch — tamper, added
    # file, removed file (incl. a missing SKILL.md) — changes the tree sha => DRIFT (exit-1 class), not a
    # WARN. An "unknown" recompute (git failure) is treated as DRIFT too (fail-closed). A missing SKILL.md is
    # now DRIFT via the tree-sha mismatch, not a non-blocking WARN.
    ACTUAL_TREE="$(recompute_skill_tree "$SKILL_PATH")"
    if [ "$ACTUAL_TREE" = "unknown" ]; then
        echo "  DRIFT: ${SKILL_NAME}/ — could not recompute the installed subtree sha (git error) — failing closed (expected tree ${EXPECTED_SHA:0:7})"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
    elif [ "$ACTUAL_TREE" != "$EXPECTED_SHA" ]; then
        echo "  DRIFT: ${SKILL_NAME}/ — subtree mismatch (installed ${ACTUAL_TREE:0:7} ≠ manifest ${EXPECTED_SHA:0:7}); tampered/added/removed file in the skill dir"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
    else
        echo "  OK: ${SKILL_NAME}/ (subtree ${EXPECTED_SHA:0:7} matches)"
    fi
done < <(jq -r '.artifacts.skills | to_entries[] | [.key, .value] | @tsv' "$MANIFEST")

# ── File-tree surfaces: lib/, hooks/, examples/ ──────────────────────────────
# Each manifest entry is "<relpath> → <blob sha>"; the installed file lives at
# .claude/<surface>/<relpath>. Same strict per-file git hash-object compare as
# agents (CR-strip both fields). Drift in ANY file fails, named with its surface.
for SURFACE in lib hooks examples docs defaults; do
    # (M11 seam 3) Type-classify the OPTIONAL surfaces — distinguish three states instead of the old
    # `// "absent"` which mapped a NULL (corrupt) surface to "absent" and silently skipped it (a fail-open):
    #   absent  (key not present)  -> skip  (sanctioned legacy/pre-multi-surface install)
    #   object  (a real surface)   -> iterate + hash-compare each file
    #   else    (null / string / array / number — corrupt) -> FAIL loudly, never skip.
    SURFACE_STATE=$(jq -r --arg s "$SURFACE" 'if (.artifacts | has($s) | not) then "absent" elif (.artifacts[$s] | type) == "object" then "ok" else "bad" end' "$MANIFEST" 2>/dev/null || echo "bad")
    if [ "$SURFACE_STATE" = "absent" ]; then
        echo ""
        echo "Checking ${SURFACE}... (not in manifest — skipping; pre-multi-surface install)"
        continue
    elif [ "$SURFACE_STATE" = "bad" ]; then
        echo ""
        echo "FAIL: manifest .artifacts.${SURFACE} is present but null/non-object (corrupt manifest) — refusing to skip."
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
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

# (M11 seam 2) CHECKED_COUNT backstop: if literally zero artifacts were examined, nothing was verified —
# "Integrity: PASS" would be a false attestation. The mandatory-surface floor above already guarantees
# >=1 agent + >=1 skill, so this is unreachable for a conforming manifest; it is defense-in-depth against
# a future surface-set change that might slip past the named floor. Never PASS on zero work.
if [ "$CHECKED_COUNT" -eq 0 ]; then
    echo ""
    echo "FAIL: drift check examined 0 artifacts — the manifest is empty/unreadable, nothing was actually verified."
    echo "Refusing to attest integrity. Re-run preflight-install to produce a valid manifest."
    exit 1
fi

if [ $DRIFT_COUNT -gt 0 ]; then
    echo ""
    echo "FAIL: ${DRIFT_COUNT} artifact(s) drifted from manifest."
    echo "The installed files were edited since install. Re-run preflight-install to restore."
    exit 1
fi

echo ""
echo "Integrity: PASS — all installed artifacts match manifest blobs."
echo ""

# ── Step 2.5: Branch-stable runtime hazard detection (P0 Part B / defect #3) ─────────────────────────────
# Distinguish three states without red-lining the supported legacy baseline:
#   • DUPLICATE (tracked AND local Preflight Bash hook both present) → genuine residual branch-swap hazard,
#     never healthy → RUNTIME_HAZARD=1 → verify FAILs. A half-migrated consumer is not "intact".
#   • LOCAL-ONLY but the pinned runtime is missing / not the ACTIVE sha → broken migration → FAIL.
#   • TRACKED-ONLY, no local pin → the LEGACY BASELINE (how preflight-install.sh still ships the gate) →
#     ADVISORY NOTE only, NOT a failure (flagging every pre-migration consumer FAIL would be over-broad).
#   • LOCAL-ONLY pinned to the ACTIVE runtime → the migrated branch-stable model → ✓ healthy.
RUNTIME_HAZARD=0
PFG_BASH_OWN_RE='run-hook\.cmd.*(pre-push-gate-check|pre-bash-risk-router)'
TRACKED="${CONSUMER_DIR}/.claude/settings.json"
LOCAL="${CONSUMER_DIR}/.claude/settings.local.json"

# does a settings file carry a Preflight-owned Bash PreToolUse hook?  echoes count
_pfg_bash_count() {  # $1 = settings path
  [ -f "$1" ] || { echo 0; return 0; }
  jq empty "$1" 2>/dev/null || { echo 0; return 0; }
  jq -r --arg re "$PFG_BASH_OWN_RE" '[ (.hooks.PreToolUse // [])[] | select(.matcher=="Bash") | (.hooks // [])[] | select((.command // "") | test($re)) ] | length' "$1" 2>/dev/null || echo 0
}
# does the tracked command point INTO branch-controlled .claude/hooks (the legacy in-tree runtime)?
_pfg_tracked_points_in_tree() {
  [ -f "$TRACKED" ] || return 1
  jq -r '[ (.hooks.PreToolUse // [])[] | select(.matcher=="Bash") | (.hooks // [])[] | .command // "" ] | .[]' "$TRACKED" 2>/dev/null \
    | grep -qE '\.claude/hooks/run-hook\.cmd|/\.claude/hooks/'
}

echo "Checking branch-stable runtime (defect #3)…"
TRACKED_BASH="$(_pfg_bash_count "$TRACKED")"
LOCAL_BASH="$(_pfg_bash_count "$LOCAL")"

if [ "$TRACKED_BASH" -ge 1 ] && [ "$LOCAL_BASH" -ge 1 ]; then
    echo "  HAZARD: DUPLICATE Preflight Bash PreToolUse registration — present in BOTH the tracked"
    echo "    .claude/settings.json AND the local .claude/settings.local.json. Because Claude Code runs hooks"
    echo "    ADDITIVELY, both fire, and the tracked one is branch-swappable. Run tools/preflight-runtime-install.sh"
    echo "    to migrate (it removes the Preflight-owned tracked Bash entry). NOT healthy."
    RUNTIME_HAZARD=1
elif [ "$TRACKED_BASH" -ge 1 ]; then
    # Tracked-only, NO local pin = the LEGACY BASELINE install (the pre-branch-stable model, which is how
    # preflight-install.sh still ships the Bash gate). This is NOT a verify FAILURE — it is the supported
    # legacy posture, advisory only. It becomes a true hazard ONLY when a local pin ALSO exists (the
    # DUPLICATE case above, which DOES fail). Flagging every legacy install as FAIL would wrongly red-line
    # every existing consumer that has not opted into the branch-stable runtime. Advisory NOTE, no FAIL.
    if _pfg_tracked_points_in_tree; then
        echo "  NOTE (legacy baseline): the tracked .claude/settings.json registers the Preflight Bash hook in"
        echo "    branch-controlled .claude/hooks/ (the pre-branch-stable model). A git checkout could swap this"
        echo "    live runtime. OPTIONAL hardening: tools/preflight-runtime-install.sh moves it to a SHA-pinned,"
        echo "    branch-stable local-layer runtime (defect #3). Not a failure — this is the supported baseline."
    else
        echo "  NOTE (legacy baseline): the tracked .claude/settings.json registers the Preflight Bash hook."
        echo "    OPTIONAL hardening: migrate to the branch-stable local-layer runtime with"
        echo "    tools/preflight-runtime-install.sh. Not a failure — this is the supported baseline."
    fi
    # RUNTIME_HAZARD stays 0 — legacy baseline is advisory, not a verify failure.
elif [ "$LOCAL_BASH" -ge 1 ]; then
    # Local-only registration — the migrated, branch-stable model. Validate the pinned runtime it points at.
    COMMON_DIR=""
    _top="$(git -C "$CONSUMER_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$_top" ]; then
        _c="$(git -C "$_top" rev-parse --git-common-dir 2>/dev/null || true)"
        case "$_c" in /*|[A-Za-z]:*) : ;; *) [ -n "$_c" ] && _c="$_top/$_c" ;; esac
        COMMON_DIR="$( [ -n "$_c" ] && cd "$_c" 2>/dev/null && pwd || true )"
    fi
    ACTIVE_SHA="$( [ -n "$COMMON_DIR" ] && [ -f "$COMMON_DIR/preflight/runtime/ACTIVE" ] && cat "$COMMON_DIR/preflight/runtime/ACTIVE" || echo '' )"
    LOCAL_CMD="$(jq -r --arg re "$PFG_BASH_OWN_RE" 'first((.hooks.PreToolUse // [])[] | select(.matcher=="Bash") | (.hooks // [])[] | select((.command // "") | test($re)) | .command) // ""' "$LOCAL" 2>/dev/null || echo '')"
    if [ -z "$ACTIVE_SHA" ] || [ ! -d "$COMMON_DIR/preflight/runtime/$ACTIVE_SHA" ]; then
        echo "  HAZARD: the local-layer Bash gate points at a pinned runtime, but the ACTIVE runtime is unset or"
        echo "    its dir is missing ($COMMON_DIR/preflight/runtime/$ACTIVE_SHA). Reinstall the runtime."
        RUNTIME_HAZARD=1
    elif ! printf '%s' "$LOCAL_CMD" | grep -qF "$ACTIVE_SHA"; then
        echo "  HAZARD: the local-layer Bash command does not point at the ACTIVE runtime SHA ($ACTIVE_SHA) —"
        echo "    a stale/unpinned local registration. Reinstall the runtime."
        RUNTIME_HAZARD=1
    elif [ "$ACTIVE_SHA" != "$RESOLVED_SHA" ]; then
        echo "  NOTE: active runtime SHA ${ACTIVE_SHA:0:7} differs from the installed manifest SHA ${RESOLVED_SHA:0:7}"
        echo "    (runtime/manifest skew). Not a hazard by itself, but reconcile by reinstalling deliberately."
    else
        echo "  ✓ Branch-stable: Preflight Bash gate is local-only, pinned to ACTIVE runtime ${ACTIVE_SHA:0:7}"
        echo "    (= manifest SHA); no tracked branch-swappable registration."
    fi
else
    echo "  NOTE: no Preflight Bash PreToolUse registration found in either tracked or local settings"
    echo "    (no Bash gate active in this consumer, or a non-standard install)."
fi
echo ""

# ── Step 3: Release relation — ANCESTRY-AWARE (optional; requires code-forge path) ───────────────────────
# THE DEFECT THIS REPLACES: the old check did a bare SHA inequality `latest-tag-SHA != installed-SHA -> STALE
# (exit 2)`. That mislabels an exact, deliberately-pinned candidate that is NEWER than the latest tag (a
# descendant) as STALE — exactly the pilot's case (latest tag v0.9.0; installed 4d45e46 is a descendant).
# We now classify by COMMIT ANCESTRY between the installed SHA and the latest tag's COMMIT:
#   ==              -> CURRENT_RELEASE   (exit 0)
#   installed is descendant of tag  -> PINNED_AHEAD (exit 0): intact + newer than the latest tagged release
#   installed is ancestor   of tag  -> STALE        (exit 2): a newer release exists
#   unrelated / unresolvable        -> DIVERGED_OR_UNKNOWN (exit 3): advisory, distinct from integrity drift
# This NEVER overrides an integrity/hazard FAIL (those exit 1 below, and take precedence). RELEASE_EXIT holds
# the release-relation exit; we apply it only AFTER the hazard gate, so an integrity failure is never hidden
# behind a release status.
RELEASE_STATUS="SKIPPED"
RELEASE_EXIT=0
echo "Release relation (ancestry-aware):"
if [ -n "$CODE_FORGE_DIR" ] && [ -d "$CODE_FORGE_DIR/.git" ]; then
    LATEST_TAG=$(git -C "$CODE_FORGE_DIR" tag --list 'v*' --sort=-version:refname 2>/dev/null | head -1)
    if [ -z "$LATEST_TAG" ]; then
        RELEASE_STATUS="DIVERGED_OR_UNKNOWN"
        RELEASE_EXIT=3
        echo "  DIVERGED_OR_UNKNOWN: no release tags (v*) in code-forge — cannot establish a release relation."
    else
        # Resolve the COMMIT each ref points at (a tag may be annotated -> ^{commit} dereferences it).
        LATEST_COMMIT=$(git -C "$CODE_FORGE_DIR" rev-parse --verify --quiet "${LATEST_TAG}^{commit}" 2>/dev/null || echo "")
        INSTALLED_COMMIT=$(git -C "$CODE_FORGE_DIR" rev-parse --verify --quiet "${RESOLVED_SHA}^{commit}" 2>/dev/null || echo "")
        if [ -z "$LATEST_COMMIT" ] || [ -z "$INSTALLED_COMMIT" ]; then
            # One of the objects is absent locally (e.g. shallow clone, or the pinned SHA was never fetched).
            RELEASE_STATUS="DIVERGED_OR_UNKNOWN"
            RELEASE_EXIT=3
            echo "  DIVERGED_OR_UNKNOWN: cannot resolve commit objects for ${LATEST_TAG} and/or installed ${RESOLVED_SHA:0:7}"
            echo "    in code-forge (shallow clone or missing objects) — ancestry undeterminable."
        elif [ "$LATEST_COMMIT" = "$INSTALLED_COMMIT" ]; then
            RELEASE_STATUS="CURRENT_RELEASE"
            RELEASE_EXIT=0
            echo "  CURRENT_RELEASE: installed SHA ${RESOLVED_SHA:0:7} == latest release tag ${LATEST_TAG} (${LATEST_COMMIT:0:7})."
        elif git -C "$CODE_FORGE_DIR" merge-base --is-ancestor "$LATEST_COMMIT" "$INSTALLED_COMMIT" 2>/dev/null; then
            # latest tag is an ANCESTOR of installed -> installed is a DESCENDANT -> pinned ahead.
            RELEASE_STATUS="PINNED_AHEAD"
            RELEASE_EXIT=0
            echo "  PINNED_AHEAD: installed SHA ${RESOLVED_SHA:0:7} is INTACT and NEWER than the latest tagged"
            echo "    release ${LATEST_TAG} (${LATEST_COMMIT:0:7}) — a deliberately-pinned descendant. Not stale."
        elif git -C "$CODE_FORGE_DIR" merge-base --is-ancestor "$INSTALLED_COMMIT" "$LATEST_COMMIT" 2>/dev/null; then
            # installed is an ANCESTOR of the latest tag -> a newer release exists -> STALE.
            RELEASE_STATUS="STALE"
            RELEASE_EXIT=2
            echo "  STALE: installed SHA ${RESOLVED_SHA:0:7} is an ANCESTOR of the latest release ${LATEST_TAG}"
            echo "    (${LATEST_COMMIT:0:7}) — a newer release exists. Run preflight-install to update."
        else
            # Neither is an ancestor of the other -> divergent branches.
            RELEASE_STATUS="DIVERGED_OR_UNKNOWN"
            RELEASE_EXIT=3
            echo "  DIVERGED_OR_UNKNOWN: installed SHA ${RESOLVED_SHA:0:7} and latest tag ${LATEST_TAG}"
            echo "    (${LATEST_COMMIT:0:7}) are on UNRELATED histories (no ancestry either direction)."
        fi
    fi
else
    echo "  SKIPPED: code-forge path not provided — release relation not evaluated (integrity/identity only)."
fi
echo ""

# ── Final classification — integrity/hazard (exit 1) takes precedence over release relation ──────────────
if [ "${RUNTIME_HAZARD:-0}" -ne 0 ]; then
    echo "=== FAIL (INTEGRITY_FAILURE): preflight ${PINNED_REF} @ ${RESOLVED_SHA:0:7} — artifacts intact, but a"
    echo "    branch-stable-runtime HAZARD (legacy/duplicate Bash registration or missing pinned runtime) makes"
    echo "    defect #3 NOT closed for this consumer. Migrate with tools/preflight-runtime-install.sh, re-verify. ==="
    exit 1
fi

case "$RELEASE_STATUS" in
  CURRENT_RELEASE)
    echo "=== PASS (CURRENT_RELEASE): preflight ${PINNED_REF} @ ${RESOLVED_SHA:0:7} — installed, intact, current. ==="
    exit 0 ;;
  PINNED_AHEAD)
    echo "=== PASS (PINNED_AHEAD): preflight ${PINNED_REF} @ ${RESOLVED_SHA:0:7} — installed, intact, deliberately"
    echo "    pinned NEWER than the latest tagged release. ==="
    exit 0 ;;
  STALE)
    echo "=== STALE: preflight ${PINNED_REF} @ ${RESOLVED_SHA:0:7} — installed and intact, but behind the latest"
    echo "    release tag. ==="
    exit 2 ;;
  DIVERGED_OR_UNKNOWN)
    echo "=== ADVISORY (DIVERGED_OR_UNKNOWN): preflight ${PINNED_REF} @ ${RESOLVED_SHA:0:7} — installed and"
    echo "    intact; release relation undeterminable (see above). This is NOT integrity drift. ==="
    exit 3 ;;
  SKIPPED|*)
    echo "=== PASS: preflight ${PINNED_REF} @ ${RESOLVED_SHA:0:7} — installed and intact (release relation not"
    echo "    evaluated; no code-forge path). ==="
    exit 0 ;;
esac

#!/usr/bin/env bash
set -euo pipefail

# preflight-runtime-install.sh — install the BRANCH-STABLE enforcement runtime (preflight P0 Part B).
#
# THE PROBLEM THIS SOLVES. preflight's hooks normally live under `.claude/hooks/`, which is git-tracked.
# Claude Code resolves & spawns the PreToolUse hook command PER tool call and (per its docs) picks up
# settings/hook changes via a file watcher with NO snapshot-at-startup and NO review-before-effect. So a
# `git checkout` of another branch can swap the LIVE safety-hook executable mid-session — the running
# control plane is branch-controlled. This installer moves the ACTIVE runtime OUTSIDE branch control.
#
# THE MODEL.
#   • Runtime home: `<git-common-dir>/preflight/runtime/<resolved-sha>/` — the git common dir holds repo
#     METADATA, not tracked working-tree content, so NO branch checkout can rewrite or delete it. It is
#     shared across all linked worktrees of the repo (resolved via `git rev-parse --git-common-dir`).
#   • Each install materializes a NEW, immutable, SHA-named runtime dir (atomic: staged then renamed).
#     Previous SHA dirs are LEFT IN PLACE → a failed upgrade or an explicit rollback can point back at one.
#   • The PreToolUse Bash hook is registered ONLY in `.claude/settings.local.json` (untracked, machine-local,
#     gitignored) with an ABSOLUTE path baked to the chosen SHA dir's run-hook.cmd. settings.local.json is
#     the auditable "current" pointer — switching runtime = rewriting this file (atomic temp+rename).
#   • An `<runtime>/ACTIVE` marker records the live SHA for session-start to report and verify to check.
#
# WHY settings.local.json AND a project-layer scrub (the load-bearing finding). Claude Code hooks are
# ADDITIVE across settings layers (DOCUMENTED): a local-layer hook runs ALONGSIDE a project-layer hook, it
# does NOT replace it. So if `.claude/settings.json` (tracked) still registers the Bash gate into
# `.claude/hooks/`, BOTH fire and the branch-swappable one is still live. A truly branch-stable runtime
# therefore requires the tracked project layer to carry NO PreToolUse Bash registration; this tool refuses
# to certify branch-stability while one is present (and preflight-verify enforces the same). See
# docs/branch-stable-runtime.md for the full model + honest limits (the platform-delivery half is inferred).
#
# Usage:
#   tools/preflight-runtime-install.sh <CONSUMER_DIR> [PINNED_REF]    # install/upgrade (PINNED_REF default HEAD)
#   tools/preflight-runtime-install.sh --rollback <CONSUMER_DIR>      # point settings.local.json at the prior SHA
#   tools/preflight-runtime-install.sh --uninstall <CONSUMER_DIR>     # remove the local-layer gate registration
#   tools/preflight-runtime-install.sh --list <CONSUMER_DIR>          # list materialized runtimes + the ACTIVE sha
#
# Reads framework files from THIS code-forge repo's git OBJECTS at the pinned ref (never the working tree),
# consistent with preflight-install.sh. CODE_FORGE_DIR env overrides the source repo.

# ── Resolve the code-forge source repo (this script's repo root) ──────────────────────────────────────────
if [ -z "${CODE_FORGE_DIR:-}" ]; then
  _RI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CODE_FORGE_DIR="$(cd "${_RI_SCRIPT_DIR}/.." && pwd)"
fi
git -C "$CODE_FORGE_DIR" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "ABORT: CODE_FORGE_DIR ('${CODE_FORGE_DIR}') is not a git repo. Run from the code-forge checkout or set CODE_FORGE_DIR."
  exit 1
}

# ── The minimal RUNTIME CLOSURE for the Bash gate (what must ship outside branch control) ─────────────────
# The Bash PreToolUse path needs exactly: the entry shim, the router, the engine it invokes, the evidence
# gate the engine invokes, and the libs the engine sources/uses. NOTHING else (skills/agents/other gates are
# not on the Bash candidate path). Keeping this set minimal keeps the immutable runtime small + reviewable.
# STAGE 2B: the engine now makes the shared shell-structure IR AUTHORITATIVE for git-push identification, so
# it depends on lib/shell-structure.sh (the wrapper) AND lib/shell-structure-lexer.awk (the POSIX-awk lexer
# it `-f`'s). BOTH must ship in the runtime — otherwise the installed engine reports "IR library not found"
# and fails CLOSED, blocking EVERY candidate push (a total-block regression on the consumer). This closure
# set is the SINGLE SOURCE for the runtime deps; keep it in lockstep with what the engine sources/reads.
RUNTIME_HOOKS="run-hook.cmd pre-bash-risk-router pre-push-gate-engine pre-push-gate session-start"
RUNTIME_LIBS="config-overlay.sh heartbeat.sh shell-structure.sh shell-structure-lexer.awk"

# ── git-common-dir resolution — worktree-safe + absolutized (the research caveat) ─────────────────────────
# `git rev-parse --git-common-dir` may return a RELATIVE path (often literally ".git") from the main
# worktree, and from a LINKED worktree it still resolves to the SHARED common dir. Always run from the
# worktree top and canonicalize to absolute, or a relative ".git" from a linked-worktree CWD misresolves.
resolve_common_dir() {  # $1 = consumer dir ; echoes absolute git-common-dir, or empty on failure
  local cons="$1" top common
  top="$(git -C "$cons" rev-parse --show-toplevel 2>/dev/null)" || return 0
  common="$(git -C "$top" rev-parse --git-common-dir 2>/dev/null)" || return 0
  # absolutize relative to the worktree top
  case "$common" in
    /*|[A-Za-z]:*) : ;;                  # already absolute (POSIX or Windows drive)
    *) common="$top/$common" ;;
  esac
  ( cd "$common" 2>/dev/null && pwd ) || return 0
}

# Stable OWNERSHIP marker for the Preflight Bash registration — command identity, never position. Used by
# both the local-layer merge (preserve a user's own local Bash hook) and the tracked-layer migration. Defined
# here (before the first consumer) so every function that references it sees it.
PFG_BASH_OWN_RE='run-hook\.cmd.*(pre-push-gate-check|pre-bash-risk-router)'

# ── settings.local.json hooks block: register the Bash gate at an ABSOLUTE pinned-runtime path ────────────
# Shell form (no `args`) is MANDATORY: run-hook.cmd is a .cmd shim and Windows cannot spawn a .cmd in exec
# form (DOCUMENTED). The absolute path is baked because ${CLAUDE_PROJECT_DIR} resolves to the WORKTREE root,
# not the common dir. Forward slashes are safest on Git-Bash. Keep the SAME timeout as hooks.json (35000).
emit_local_settings_merge() {  # $1 = existing settings.local.json (may be missing) ; $2 = abs run-hook.cmd path
  local existing="$1" runhook="$2" block
  block="$(jq -n --arg cmd "\"${runhook}\" pre-bash-risk-router \"\$TOOL_INPUT\"" '
    { PreToolUse: [ { matcher: "Bash", hooks: [ { type:"command", command:$cmd, timeout:35000, async:false } ] } ] }')"
  if [ -f "$existing" ] && jq empty "$existing" 2>/dev/null; then
    # Preserve every other key/layer AND any of the USER's OWN local hooks — including a foreign local Bash
    # hook. We must NOT strip all Bash matcher entries (that would delete a user's personal linter hook).
    # Idempotency rule: drop ONLY the PREFLIGHT-OWNED Bash entry (command matches PFG_BASH_OWN_RE), then
    # append our fresh one. A Bash matcher entry whose hooks are NOT preflight-owned is preserved verbatim.
    jq --argjson blk "$block" --arg re "$PFG_BASH_OWN_RE" '
      .hooks = (.hooks // {})
      | .hooks.PreToolUse = (
          ((.hooks.PreToolUse // [])
            | map(select(
                (.matcher == "Bash" and ([ (.hooks // [])[] | select((.command // "") | test($re)) ] | length) >= 1) | not
              )))
          + $blk.PreToolUse )
    ' "$existing"
  else
    jq -n --argjson blk "$block" '{ hooks: $blk }'
  fi
}

# ── project-layer scrub check (additive-hooks finding) ────────────────────────────────────────────────────
project_layer_has_bash_pretooluse() {  # $1 = consumer dir ; returns 0 (true) if tracked settings register a Bash PreToolUse hook
  local s="$1/.claude/settings.json"
  [ -f "$s" ] || return 1
  jq empty "$s" 2>/dev/null || return 1
  local n
  n="$(jq -r '[(.hooks.PreToolUse // [])[] | select(.matcher=="Bash")] | length' "$s" 2>/dev/null || echo 0)"
  [ "${n:-0}" -ge 1 ]
}

# ── OWNERSHIP-AWARE tracked-layer migration ───────────────────────────────────────────────────────────────
# Identify the PREFLIGHT-OWNED Bash PreToolUse registration by COMMAND IDENTITY (stable ownership marker),
# NEVER by position. Ownership signature: a PreToolUse entry with matcher=="Bash" whose hooks[].command
# references run-hook.cmd AND a preflight Bash-gate name (pre-push-gate-check OR pre-bash-risk-router). We
# remove ONLY that exact entry. We DO NOT touch: user-defined Bash hooks, third-party hooks (command without
# the preflight signature), Write/Edit gates, Agent|Task gates, or any non-Bash entry. If a Bash matcher
# block is AMBIGUOUS — it mixes a preflight-owned hook AND a non-preflight hook in the SAME matcher entry, or
# multiple distinct Bash matcher entries exist — we ABORT and report rather than risk deleting something
# unowned. jq is a hard dep here (the installer already requires it). PFG_BASH_OWN_RE is defined near the
# top (before emit_local_settings_merge, which also uses it for idempotent local-layer replacement).

# echoes one of: none | owned | foreign | ambiguous   (classification of the tracked Bash PreToolUse block)
classify_tracked_bash() {  # $1 = settings.json path
  local s="$1"
  [ -f "$s" ] || { echo none; return 0; }
  jq empty "$s" 2>/dev/null || { echo ambiguous; return 0; }   # unparseable tracked settings → don't guess
  jq -r --arg re "$PFG_BASH_OWN_RE" '
    [ (.hooks.PreToolUse // [])[] | select(.matcher=="Bash") ] as $bash
    | if ($bash | length) == 0 then "none"
      # more than one Bash matcher entry → ambiguous (which is ours? do not guess)
      elif ($bash | length) > 1 then "ambiguous"
      else
        ( $bash[0].hooks // [] ) as $hk
        | ( [ $hk[] | select((.command // "") | test($re)) ] | length ) as $own
        | ( [ $hk[] | select((.command // "") | test($re) | not) ] | length ) as $other
        | if ($own >= 1 and $other == 0) then "owned"          # the whole Bash entry is preflight-owned → safe to drop
          elif ($own >= 1 and $other >= 1) then "ambiguous"    # mixed entry → would delete an unowned hook → ABORT
          else "foreign" end                                   # a Bash hook, but not ours → leave it
      end' "$s" 2>/dev/null || echo ambiguous
}

# ── Subcommand dispatch ───────────────────────────────────────────────────────────────────────────────────
MODE="install"
case "${1:-}" in
  --rollback)            MODE="rollback";  shift ;;
  --uninstall)           MODE="uninstall"; shift ;;
  --list)                MODE="list";      shift ;;
  --scan-local-branches) MODE="scan";      shift ;;
esac
CONSUMER_DIR="${1:?Usage: preflight-runtime-install.sh [--rollback|--uninstall|--list|--scan-local-branches] <CONSUMER_DIR> [PINNED_REF]}"
PINNED_REF="${2:-HEAD}"
CONSUMER_DIR="$(cd "$CONSUMER_DIR" && pwd)"

# ── --scan-local-branches: READ-ONLY local-branch inventory (does NOT check out any branch) ──────────────
# Reports, per local branch, whether its TRACKED .claude/settings.json carries the legacy Preflight Bash
# registration (the branch-swap hazard) — read via `git show <branch>:path`, never a checkout. Never rewrites
# history; never claims a hazard branch is safe.
if [ "$MODE" = "scan" ]; then
  echo "=== preflight legacy-registration scan (read-only; no checkout) — $CONSUMER_DIR ==="
  printf '%-40s %-10s %-22s %s\n' "BRANCH" "settings?" "preflight-bash?" "RECOMMENDATION"
  _PFG_BASH_OWN_RE='run-hook\.cmd.*(pre-push-gate-check|pre-bash-risk-router)'
  while IFS= read -r br; do
    [ -n "$br" ] || continue
    if git -C "$CONSUMER_DIR" cat-file -e "$br:.claude/settings.json" 2>/dev/null; then
      _content="$(git -C "$CONSUMER_DIR" show "$br:.claude/settings.json" 2>/dev/null || true)"
      _n="$(printf '%s' "$_content" | jq -r --arg re "$_PFG_BASH_OWN_RE" '[ (.hooks.PreToolUse // [])[] | select(.matcher=="Bash") | (.hooks // [])[] | select((.command // "") | test($re)) ] | length' 2>/dev/null || echo "?")"
      if [ "$_n" = "?" ]; then
        printf '%-40s %-10s %-22s %s\n' "$br" "yes" "unparseable" "inspect settings.json by hand"
      elif [ "${_n:-0}" -ge 1 ]; then
        printf '%-40s %-10s %-22s %s\n' "$br" "yes" "LEGACY (tracked)" "MIGRATE before use (runtime-install)"
      else
        printf '%-40s %-10s %-22s %s\n' "$br" "yes" "none (migrated/clean)" "ok — no tracked preflight Bash hook"
      fi
    else
      printf '%-40s %-10s %-22s %s\n' "$br" "no" "n/a" "no tracked settings.json on this branch"
    fi
  done < <(git -C "$CONSUMER_DIR" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)
  echo ""
  echo "Branches marked LEGACY carry the old TRACKED Preflight Bash registration: a checkout makes that"
  echo "branch-controlled hook run alongside the pinned runtime (residual branch-swap hazard). This scan does"
  echo "NOT rewrite history and does NOT claim hazard branches are safe — migrate or remediate each before use."
  exit 0
fi

COMMON_DIR="$(resolve_common_dir "$CONSUMER_DIR")"
[ -n "$COMMON_DIR" ] || { echo "ABORT: consumer '$CONSUMER_DIR' is not inside a git worktree (cannot resolve a branch-stable common dir)."; exit 1; }
RUNTIME_ROOT="$COMMON_DIR/preflight/runtime"
ACTIVE_MARKER="$RUNTIME_ROOT/ACTIVE"
PREVIOUS_MARKER="$RUNTIME_ROOT/PREVIOUS"
LOCAL_SETTINGS="$CONSUMER_DIR/.claude/settings.local.json"

case "$MODE" in
  list)
    echo "=== preflight runtimes under $RUNTIME_ROOT ==="
    [ -d "$RUNTIME_ROOT" ] || { echo "(none materialized)"; exit 0; }
    for d in "$RUNTIME_ROOT"/*/; do [ -d "$d" ] && echo "  runtime: $(basename "$d")"; done
    echo "  ACTIVE:   $( [ -f "$ACTIVE_MARKER" ] && cat "$ACTIVE_MARKER" || echo '(unset)')"
    echo "  PREVIOUS: $( [ -f "$PREVIOUS_MARKER" ] && cat "$PREVIOUS_MARKER" || echo '(unset)')"
    exit 0 ;;

  uninstall)
    # Remove ONLY the local-layer Bash PreToolUse registration; leave materialized runtimes on disk (a
    # later --rollback/install can reuse them) and never touch the tracked project layer.
    if [ -f "$LOCAL_SETTINGS" ] && jq empty "$LOCAL_SETTINGS" 2>/dev/null; then
      tmp="$(mktemp)"
      jq '(.hooks.PreToolUse) |= ((. // []) | map(select(.matcher != "Bash")))' "$LOCAL_SETTINGS" > "$tmp"
      mv "$tmp" "$LOCAL_SETTINGS"
      echo "Uninstalled: removed the Bash PreToolUse registration from $LOCAL_SETTINGS (runtimes left on disk; project layer untouched)."
    else
      echo "Nothing to uninstall: $LOCAL_SETTINGS absent or not valid JSON."
    fi
    exit 0 ;;

  rollback)
    [ -f "$PREVIOUS_MARKER" ] || { echo "ABORT: no PREVIOUS runtime recorded ($PREVIOUS_MARKER) — nothing to roll back to."; exit 1; }
    PREV_SHA="$(cat "$PREVIOUS_MARKER")"
    PREV_DIR="$RUNTIME_ROOT/$PREV_SHA"
    [ -d "$PREV_DIR" ] || { echo "ABORT: PREVIOUS runtime $PREV_SHA is recorded but its dir is missing ($PREV_DIR) — cannot roll back."; exit 1; }
    RUNHOOK="$PREV_DIR/hooks/run-hook.cmd"
    [ -f "$RUNHOOK" ] || { echo "ABORT: PREVIOUS runtime $PREV_SHA is incomplete (no run-hook.cmd) — refusing to point at a broken runtime."; exit 1; }
    mkdir -p "$(dirname "$LOCAL_SETTINGS")"
    tmp="$(mktemp)"; emit_local_settings_merge "$LOCAL_SETTINGS" "$RUNHOOK" > "$tmp" && mv "$tmp" "$LOCAL_SETTINGS"
    # swap ACTIVE<->PREVIOUS
    CUR="$( [ -f "$ACTIVE_MARKER" ] && cat "$ACTIVE_MARKER" || echo '' )"
    printf '%s' "$PREV_SHA" > "$ACTIVE_MARKER"
    [ -n "$CUR" ] && printf '%s' "$CUR" > "$PREVIOUS_MARKER"
    echo "Rolled back: ACTIVE runtime is now $PREV_SHA (settings.local.json re-pointed). Prior ACTIVE ($CUR) is now PREVIOUS."
    exit 0 ;;
esac

# ── install / upgrade ─────────────────────────────────────────────────────────────────────────────────────
RESOLVED_SHA="$(git -C "$CODE_FORGE_DIR" rev-parse --verify --quiet "$PINNED_REF" 2>/dev/null || true)"
[ -n "$RESOLVED_SHA" ] || { echo "ABORT: cannot resolve ref '${PINNED_REF}' in $CODE_FORGE_DIR."; exit 1; }

echo "=== Preflight Branch-Stable Runtime Install ==="
echo "Code-forge:   $CODE_FORGE_DIR"
echo "Consumer:     $CONSUMER_DIR"
echo "Common dir:   $COMMON_DIR   (branch-stable; survives git checkout)"
echo "Pinned ref:   $PINNED_REF → $RESOLVED_SHA"
echo ""

TARGET_DIR="$RUNTIME_ROOT/$RESOLVED_SHA"
STAGING="$RUNTIME_ROOT/.staging.$$.$RESOLVED_SHA"
mkdir -p "$RUNTIME_ROOT"
rm -rf "$STAGING" 2>/dev/null || true
mkdir -p "$STAGING/hooks" "$STAGING/lib"

# Materialize the runtime closure from the pinned ref's git objects (never the working tree).
for h in $RUNTIME_HOOKS; do
  git -C "$CODE_FORGE_DIR" show "${RESOLVED_SHA}:hooks/${h}" > "$STAGING/hooks/${h}" 2>/dev/null \
    || { echo "ABORT: hooks/${h} not present at ${RESOLVED_SHA} — staging discarded, ACTIVE runtime untouched."; rm -rf "$STAGING"; exit 1; }
  chmod +x "$STAGING/hooks/${h}" 2>/dev/null || true
done
for l in $RUNTIME_LIBS; do
  git -C "$CODE_FORGE_DIR" show "${RESOLVED_SHA}:lib/${l}" > "$STAGING/lib/${l}" 2>/dev/null \
    || { echo "ABORT: lib/${l} not present at ${RESOLVED_SHA} — staging discarded, ACTIVE runtime untouched."; rm -rf "$STAGING"; exit 1; }
done
# Record provenance inside the runtime (for verify + audit).
printf '%s\n' "$RESOLVED_SHA" > "$STAGING/RUNTIME_SHA"

# ATOMIC promote: rename staging → SHA dir. If a dir for this SHA already exists (re-install), replace it
# atomically by renaming the old one aside first, then removing it AFTER the new one is in place.
if [ -d "$TARGET_DIR" ]; then
  OLD_ASIDE="$RUNTIME_ROOT/.replacing.$$.$RESOLVED_SHA"
  mv "$TARGET_DIR" "$OLD_ASIDE"
  if mv "$STAGING" "$TARGET_DIR"; then rm -rf "$OLD_ASIDE" 2>/dev/null || true
  else mv "$OLD_ASIDE" "$TARGET_DIR"; echo "ABORT: promote failed — restored the prior $RESOLVED_SHA runtime."; rm -rf "$STAGING"; exit 1; fi
else
  mv "$STAGING" "$TARGET_DIR"
fi
echo "Materialized immutable runtime: $TARGET_DIR"

RUNHOOK="$TARGET_DIR/hooks/run-hook.cmd"

# Re-point settings.local.json atomically (this is the "current" switch). Only AFTER the new runtime dir is
# fully in place — so if anything above failed, the OLD settings.local.json still points at the OLD (intact)
# runtime: previous-runtime-usable / rollback-on-failed-upgrade by construction.
PRIOR_ACTIVE="$( [ -f "$ACTIVE_MARKER" ] && cat "$ACTIVE_MARKER" || echo '' )"
mkdir -p "$(dirname "$LOCAL_SETTINGS")"
tmp="$(mktemp)"; emit_local_settings_merge "$LOCAL_SETTINGS" "$RUNHOOK" > "$tmp"
jq empty "$tmp" 2>/dev/null || { echo "ABORT: generated settings.local.json is invalid — leaving the existing one (and prior runtime) intact."; rm -f "$tmp"; exit 1; }
mv "$tmp" "$LOCAL_SETTINGS"
# advance ACTIVE / PREVIOUS markers
[ -n "$PRIOR_ACTIVE" ] && [ "$PRIOR_ACTIVE" != "$RESOLVED_SHA" ] && printf '%s' "$PRIOR_ACTIVE" > "$PREVIOUS_MARKER"
printf '%s' "$RESOLVED_SHA" > "$ACTIVE_MARKER"
echo "Registered the Bash PreToolUse gate in $LOCAL_SETTINGS → $RUNHOOK"

# Ensure settings.local.json is gitignored (it is machine-local; Claude Code auto-ignores when IT creates the
# file, but we created it, so we add the rule ourselves — the research caveat).
GI="$CONSUMER_DIR/.gitignore"
if ! { [ -f "$GI" ] && grep -qE '^\.claude/settings\.local\.json[[:space:]]*$' <(tr -d '\r' < "$GI"); }; then
  printf '%s\n' '.claude/settings.local.json' >> "$GI"
  echo "Added .claude/settings.local.json to $GI (machine-local; never commit)."
fi

# ── OWNERSHIP-AWARE tracked-layer migration (authorized scoped contract change) ──────────────────────────
# Remove ONLY the Preflight-owned Bash PreToolUse registration from the TRACKED .claude/settings.json, so it
# no longer runs ALONGSIDE (hooks are additive) the pinned local-layer gate and can no longer be swapped by a
# git checkout. Identification is by command identity (PFG_BASH_OWN_RE), never position. On ambiguity we
# ABORT the migration (the local-layer pin is already in place and active) and report the entry — we never
# risk deleting an unowned hook. All non-Bash Preflight hooks + user/third-party hooks are untouched.
echo ""
TRACKED_SETTINGS="$CONSUMER_DIR/.claude/settings.json"
_bash_class="$(classify_tracked_bash "$TRACKED_SETTINGS")"
case "$_bash_class" in
  none)
    echo "✓ Branch-stable: tracked .claude/settings.json registers no Bash PreToolUse hook; the only Bash gate"
    echo "  is the local-layer pin at $RUNHOOK (outside branch control)." ;;
  owned)
    # surgical removal: drop the Bash matcher entry whose hooks are entirely preflight-owned. Atomic temp+rename.
    _mig_tmp="$(mktemp)"
    if jq --arg re "$PFG_BASH_OWN_RE" '
        .hooks.PreToolUse |= ( (. // []) | map(
          select( (.matcher == "Bash" and ([ (.hooks // [])[] | select((.command // "") | test($re)) ] | length) >= 1) | not )
        ))' "$TRACKED_SETTINGS" > "$_mig_tmp" && jq empty "$_mig_tmp" 2>/dev/null; then
      mv "$_mig_tmp" "$TRACKED_SETTINGS"
      echo "✓ Migrated: removed the Preflight-owned Bash PreToolUse registration from the TRACKED"
      echo "  .claude/settings.json (identified by command identity, not position). The only Bash gate is now"
      echo "  the local-layer pin → $RUNHOOK. All non-Bash hooks and any non-Preflight settings are preserved."
    else
      rm -f "$_mig_tmp"
      echo "⚠ MIGRATION SKIPPED: could not produce valid settings.json removing the tracked Bash entry — left"
      echo "  the tracked layer UNCHANGED. The local-layer pin is active, but the tracked Bash hook still runs"
      echo "  alongside it (residual branch-swap hazard). Investigate $TRACKED_SETTINGS."
    fi ;;
  foreign)
    echo "✓ Branch-stable (Preflight side): the tracked .claude/settings.json has a Bash PreToolUse hook that is"
    echo "  NOT Preflight-owned (no run-hook.cmd preflight-gate signature) — left UNTOUCHED. The Preflight Bash"
    echo "  gate is the local-layer pin at $RUNHOOK." ;;
  ambiguous)
    echo "⚠ MIGRATION ABORTED (ambiguous ownership): the tracked .claude/settings.json has a Bash PreToolUse"
    echo "  block that mixes a Preflight-owned hook with a non-Preflight hook in the same entry, OR multiple"
    echo "  distinct Bash matcher entries, OR is unparseable. Refusing to delete anything by position. The"
    echo "  local-layer pin is in place and active, but the tracked Bash registration was NOT removed (residual"
    echo "  branch-swap hazard until you resolve it by hand). Entry left intact for review: $TRACKED_SETTINGS" ;;
esac

echo ""
echo "=== Runtime install complete ==="
echo "  ACTIVE runtime SHA: $RESOLVED_SHA"
[ -n "$PRIOR_ACTIVE" ] && [ "$PRIOR_ACTIVE" != "$RESOLVED_SHA" ] && echo "  PREVIOUS (rollback target): $PRIOR_ACTIVE"
echo ""
echo "Honest limits (see docs/branch-stable-runtime.md):"
echo "  • Per-clone: settings.local.json is machine-local; every clone/worktree must run this installer."
echo "  • Platform delivery (Claude Code actually invoking the pinned hook) is INFERRED from documented"
echo "    additive-hook + file-watcher behavior — confirm behaviorally in a live session before certifying."
echo "  • Agent-side / fail-open / user-editable / enterprise-managed-override ceiling — not server enforcement."

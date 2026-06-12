#!/usr/bin/env bash
# Per-clone config overlay resolver — .preflight/config.local.json (issue #6).
#
# Usage (standalone):  bash lib/config-overlay.sh <dotted.key> [config] [local]
#   echoes the resolved value (empty if unset anywhere); warnings on stderr.
# Usage (sourced):     source lib/config-overlay.sh; overlay_resolve <key> ...
#
# WHY THIS EXISTS: on an inverted clone (SessionToken live run, PR #95) the
# committed config said branch.remote=origin while origin was the LEGACY PROD
# repo and the real target was a different remote ('poc'). The committed value
# is shared truth; the clone's topology is per-machine truth. This overlay lets
# a clone declare its own topology WITHOUT committing a clone-specific value
# (which would pollute shared history and trip bootstrap-write-gate).
#
# MERGE SEMANTICS: per-key. For an ALLOWLISTED key, config.local.json (if
# present and set) wins over config.json. For any other key, config.json ALWAYS
# wins and a local attempt is IGNORED WITH A WARNING on stderr.
#
# ── THE ALLOWLIST (load-bearing — read before editing) ────────────────────────
# ALLOW (clone topology / non-gate facts only):
#   branch.remote  branch.base  branch.migrationPrefix
#   migration.legacyRepoPath  migration.servicesRoot  migration.referenceService
# DENY (everything else, EXPLICITLY including):
#   branch.forbiddenRemotes / branch.forbiddenRepos  — the guard's denylist;
#     a clone-local file must never be able to un-forbid the legacy repo
#   test.coverageBaseline / test.command              — gate thresholds
#   loop.*  review.*  rubric  mode  capture.*         — review policy
# RATIONALE: a clone-local file is invisible in code review. It may differ on
# WHERE this clone pushes / WHERE legacy source lives — never on HOW strictly
# the work is reviewed or WHAT destinations are forbidden. Local must not
# weaken gates. (CLAUDE.md rule 8: no engineering-to-pass.)
#
# ── ENFORCEMENT HONESTY LABEL ─────────────────────────────────────────────────
# The allowlist is enforced MECHANICALLY at THIS seam: every consumer that
# resolves config through this lib (hooks/pre-push-gate-check does) gets the
# filtered merge — a denied local key cannot reach those consumers. It is
# PROSE-LEVEL for any skill that still reads config.json directly with its own
# jq (they never see local keys at all — fail-safe direction: a denied local
# key is ignored, never honored). There is NO PreToolUse gate blocking someone
# from WRITING a denied key into config.local.json — the key is simply ignored
# at read time, with a warning. See issue #6 §4.

_OVERLAY_ALLOWLIST="branch.remote branch.base branch.migrationPrefix migration.legacyRepoPath migration.servicesRoot migration.referenceService"

overlay_key_allowed() {
  local key="$1" k
  for k in $_OVERLAY_ALLOWLIST; do
    [ "$k" = "$key" ] && return 0
  done
  return 1
}

# _overlay_read <file> <dotted.key> → echoes value or "" (jq → node → empty).
# Scalars only (the allowlist is all scalars; arrays/objects are not overlayable).
_overlay_read() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  if command -v jq &>/dev/null; then
    jq -r ".${key} // empty | if type==\"object\" or type==\"array\" then \"\" else tostring end" "$file" 2>/dev/null || true
  elif command -v node &>/dev/null; then
    node -e "
try {
  const c = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  const v = '$key'.split('.').reduce((o, p) => (o == null ? undefined : o[p]), c);
  if (v != null && typeof v !== 'object') process.stdout.write(String(v));
} catch (e) {}" "$file" 2>/dev/null || true
  fi
}

# overlay_resolve <dotted.key> [config_path] [local_path]
# Echoes the resolved value. Warns (stderr) when a local value was ignored.
overlay_resolve() {
  local key="$1"
  local top config local_cfg
  top="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  config="${2:-$top/.preflight/config.json}"
  local_cfg="${3:-$(dirname "$config")/config.local.json}"

  local committed local_val
  committed="$(_overlay_read "$config" "$key")"
  local_val="$(_overlay_read "$local_cfg" "$key")"

  if [ -n "$local_val" ]; then
    if overlay_key_allowed "$key"; then
      printf '%s\n' "$local_val"
      return 0
    fi
    echo "WARNING: config.local.json sets '$key' — not an allowlisted per-clone topology key; IGNORED (gates/thresholds/forbidden-lists cannot be changed locally). Committed value wins." >&2
  fi
  printf '%s\n' "$committed"
}

# Standalone invocation: bash lib/config-overlay.sh <key> [config] [local]
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ -z "${1:-}" ]; then
    echo "Usage: $0 <dotted.key> [config_path] [local_path]" >&2
    exit 2
  fi
  overlay_resolve "$@"
fi

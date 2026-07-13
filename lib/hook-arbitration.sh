#!/usr/bin/env bash
# hook-arbitration.sh — the SINGLE deterministic hook-ownership rule (v0.10.0 hook arbitration).
#
# THE RULE (one place; both the user-level router AND `doctor --project` derive their answer here — no
# second source of truth to drift):
#
#   Given an OPTED-IN repository root, decide who owns the PreToolUse Bash decision for this repo so the
#   SAME hook event is adjudicated by EXACTLY ONE authoritative runtime:
#
#     PROJECT  — the repo carries a VALID, ACTIVE project-level Preflight Bash registration: a settings
#                file (settings.json / settings.local.json) that registers a PreToolUse Bash hook whose
#                command targets a project-local runtime, AND the referenced project hook file physically
#                exists and is non-empty. The user-level router MUST yield (exit 0, write nothing) and let
#                the project-pinned runtime own the decision.
#     USER     — the repo opted in (has an opt-in config) but carries NO valid, distinct project-level
#                registration. The user-level runtime governs it.
#     AMBIGUOUS— a project registration is PRESENT but not trustworthy: its settings file is malformed/
#                unparseable, OR the registration references a project router whose hook FILE is missing/
#                empty (a STALE project install). The SAFE direction is to NOT defer to an unverifiable or
#                broken project runtime — the user runtime owns the decision (fail-closed-safe: a stale
#                project hook must never cause the user gate to stand down and let a governed push through)
#                — and `doctor` reports the ambiguity with remediation.
#
#   DUPLICATE-RUNTIME DETECTION (the "same physical runtime never runs twice" invariant): a project
#   settings file that registers the USER dispatcher/runtime (…/preflight/dispatcher.cmd or
#   …/preflight/runtime/<sha>/…) is NOT a distinct project owner — it re-invokes the SAME user runtime a
#   second time within one hook event. It never makes the repo PROJECT-owned; ownership stays USER and
#   PFA_DUP_RISK=yes so `doctor` can surface the misconfiguration and its remediation. (The router writes
#   nothing during passive routing, so a duplicate invocation of the user runtime is idempotent — the risk
#   is wasted latency, not a double side-effect — but it is reported so it can be removed.)
#
#   A CONFIG FILE ALONE IS NEVER SUFFICIENT to make a repo PROJECT-owned: ownership requires an actual
#   ACTIVE registration in a settings file, not merely the presence of .preflight/config.json.
#
# Contract for callers:
#   pfa_classify_owner "<repo-root>" ["<user-dispatcher-path>"]
#     -> sets, in the caller's shell (this file is SOURCED, never exec'd):
#        PFA_OWNER      : PROJECT | USER | AMBIGUOUS      (NONE is the router's pre-arbitration opt-in miss)
#        PFA_REASON     : one-line human-readable justification
#        PFA_PROJECT_CMDS : newline-joined project Bash hook command(s) found (may be empty)
#        PFA_DUP_RISK   : yes | no   (a duplicate/twice-registered physical runtime was detected)
#        PFA_STALE      : yes | no   (a project registration references a missing/empty project hook file)
#     -> returns 0 always (the classification itself never fails; unknowns resolve to the SAFE side).
#
# This library is builtins-first and jq-optional. It writes NOTHING anywhere. It is part of RUNTIME_LIBS
# so it ships into user installs alongside the router.

# A command string that points at the USER-LEVEL runtime (the stable user dispatcher OR a path under the
# user's ~/.claude/preflight/ tree). CRITICAL disambiguation vs the PROJECT branch-stable runtime: both a
# user install (~/.claude/preflight/runtime/<sha>/) and a project branch-stable install
# (<repo>/.git/preflight/runtime/<sha>/) contain "preflight/runtime/" — so that segment ALONE is NOT a
# user signal. The user runtime is identified ONLY by the stable dispatcher name (projects register
# run-hook.cmd, never dispatcher.cmd), the ".claude/preflight/" home segment, or the explicit dispatcher
# path the caller passes. A ".git/preflight/runtime/…" command is a PROJECT owner, never the user runtime.
_pfa_is_user_runtime_cmd() {  # $1 = command string ; $2 = optional explicit user-dispatcher path
  case "$1" in
    *preflight/dispatcher.cmd*|*'preflight\dispatcher.cmd'*) return 0 ;;
    *.claude/preflight/*|*'.claude\preflight\'*)             return 0 ;;
  esac
  # Also match an explicit user-dispatcher path passed by the caller (handles a relocated PREFLIGHT_CLAUDE_HOME
  # whose home segment is not literally ".claude"). Ignore an empty path so "" never matches everything.
  if [ -n "${2:-}" ]; then
    case "$1" in *"$2"*) return 0 ;; esac
  fi
  return 1
}

# Does a command string reference a PROJECT-level Preflight router token?
_pfa_is_project_router_cmd() {  # $1 = command string ; 0 = names a project router entrypoint
  case "$1" in
    *pre-bash-risk-router*|*pre-push-gate-check*|*pre-push-gate-engine*|*run-hook*) return 0 ;;
  esac
  return 1
}

# Is there a physical, non-empty project hook file backing a project registration under this root?
# (A registration with no runtime file behind it is STALE, not a valid owner.)
_pfa_project_hook_present() {  # $1 = repo root ; 0 = a real project hook file exists non-empty
  local root="$1" h
  for h in "$root/.claude/hooks/pre-bash-risk-router" "$root/.claude/hooks/run-hook.cmd" \
           "$root/.claude/hooks/pre-push-gate-check" "$root/.claude/hooks/pre-push-gate-engine"; do
    [ -s "$h" ] && return 0
  done
  return 1
}

# Extract every PreToolUse Bash hook command from a settings file into the GLOBAL _PFA_CMDS (one command
# per line), and set the GLOBAL _PFA_PARSE=ok|malformed|absent|raw. Sets globals (NOT stdout) so the caller
# does not lose the parse state to a command-substitution subshell. (malformed = present but not valid JSON;
# raw = no jq available, _PFA_CMDS holds the raw file content for a conservative SHAPE match.)
_pfa_settings_bash_cmds() {  # $1 = settings file path
  local s="$1"
  _PFA_PARSE=absent; _PFA_CMDS=""
  [ -f "$s" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    if jq empty "$s" >/dev/null 2>&1; then
      _PFA_PARSE=ok
      _PFA_CMDS="$(jq -r '(.hooks.PreToolUse // [])[] | select(.matcher=="Bash") | (.hooks // [])[] | (.command // "")' "$s" 2>/dev/null)"
    else
      _PFA_PARSE=malformed
    fi
    return 0
  fi
  # No jq: cannot structurally parse. Hold the raw content for a SHAPE match (still requires the command
  # token, never an incidental substring).
  _PFA_PARSE=raw
  _PFA_CMDS="$(cat "$s" 2>/dev/null)"
  return 0
}

# THE classifier. See the header contract.
pfa_classify_owner() {  # $1 = repo root ; $2 = optional user-dispatcher path
  local root="$1" udisp="${2:-}"
  PFA_OWNER="USER"; PFA_REASON=""; PFA_PROJECT_CMDS=""; PFA_DUP_RISK="no"; PFA_STALE="no"

  local s parse_any="absent" saw_malformed="no"
  local n_project_distinct=0 n_user_dup=0
  local hookfile_present="no"
  _pfa_project_hook_present "$root" && hookfile_present="yes"

  local _PFA_PARSE="" _PFA_CMDS=""
  for s in "$root/.claude/settings.json" "$root/.claude/settings.local.json"; do
    [ -f "$s" ] || continue
    _pfa_settings_bash_cmds "$s"
    local cmds="$_PFA_CMDS"
    case "$_PFA_PARSE" in
      malformed) saw_malformed="yes"; parse_any="present"; continue ;;
      absent)    continue ;;
      ok)        parse_any="present" ;;
      raw)       parse_any="present" ;;
    esac

    if [ "$_PFA_PARSE" = "raw" ]; then
      # No-jq SHAPE fallback: require the registration SHAPE (a "command" key AND a project router token,
      # NOT an incidental substring in a note field). Mirrors the historical hardened fallback.
      case "$cmds" in
        *'"command"'*pre-bash-risk-router*|*'"command"'*pre-push-gate-check*|*'"command"'*run-hook*)
          PFA_PROJECT_CMDS="${PFA_PROJECT_CMDS}[raw-shape-match in $(basename "$s")]"$'\n'
          # In raw mode we cannot dedup user-vs-project reliably; treat a project-router shape match as a
          # project registration ONLY if a project hook file is actually present (stale check still applies).
          if [ "$hookfile_present" = "yes" ]; then n_project_distinct=$((n_project_distinct+1)); fi
          ;;
      esac
      continue
    fi

    # Parsed (jq) path: classify each command precisely.
    local c
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      if _pfa_is_user_runtime_cmd "$c" "$udisp"; then
        n_user_dup=$((n_user_dup+1))
        PFA_PROJECT_CMDS="${PFA_PROJECT_CMDS}${c}"$'\n'
      elif _pfa_is_project_router_cmd "$c"; then
        n_project_distinct=$((n_project_distinct+1))
        PFA_PROJECT_CMDS="${PFA_PROJECT_CMDS}${c}"$'\n'
      fi
    done <<EOF
$cmds
EOF
  done

  # ── Decide ────────────────────────────────────────────────────────────────────────────────────────────
  # Malformed settings that we could not parse, with no confirmable valid project registration → AMBIGUOUS,
  # and the SAFE side is USER-owns (never defer to an unverifiable project runtime).
  if [ "$saw_malformed" = "yes" ] && [ "$n_project_distinct" -eq 0 ]; then
    PFA_OWNER="AMBIGUOUS"
    PFA_REASON="a project settings file is present but is not valid JSON; cannot confirm a project registration — user runtime owns the decision (safe). Fix or remove the malformed settings file."
    [ "$n_user_dup" -gt 0 ] && PFA_DUP_RISK="yes"
    return 0
  fi

  if [ "$n_project_distinct" -gt 0 ]; then
    if [ "$hookfile_present" = "yes" ]; then
      PFA_OWNER="PROJECT"
      PFA_REASON="a valid project-level Preflight Bash registration with a present runtime file owns this repo; the user router yields (writes nothing)."
      [ "$n_project_distinct" -gt 1 ] && PFA_DUP_RISK="yes"
      [ "$n_user_dup" -gt 0 ] && PFA_DUP_RISK="yes"
      return 0
    fi
    # Registration names a project router but NO project hook file is present → STALE project install.
    PFA_OWNER="AMBIGUOUS"; PFA_STALE="yes"
    PFA_REASON="a project settings file registers a project Preflight hook, but the referenced project hook file is missing/empty (stale install) — user runtime owns the decision (safe). Reinstall the project runtime or remove the stale registration."
    [ "$n_user_dup" -gt 0 ] && PFA_DUP_RISK="yes"
    return 0
  fi

  # No distinct project registration. If the project references the USER runtime, ownership is USER but a
  # duplicate physical runtime is registered → flag it.
  if [ "$n_user_dup" -gt 0 ]; then
    PFA_OWNER="USER"; PFA_DUP_RISK="yes"
    PFA_REASON="project settings register the USER runtime (dispatcher/runtime path) — the same physical runtime would run twice per event; user runtime owns it once. Remove the user-runtime reference from project settings (the user-level install already covers this repo)."
    return 0
  fi

  # Opted in, no project registration of any kind → user runtime owns (config-alone is not project ownership).
  PFA_OWNER="USER"
  PFA_REASON="repo opted in (config present) with no project-level Preflight registration — user runtime owns the decision."
  return 0
}

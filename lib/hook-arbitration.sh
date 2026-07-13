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

# Resolve the FILE a registered project-hook command actually invokes, and report whether it exists
# non-empty. This is the CORRECT staleness check: a branch-stable project install registers an ABSOLUTE
# path to <repo>/.git/preflight/runtime/<sha>/hooks/run-hook.cmd (with .claude/hooks/ deliberately EMPTY),
# so guessing .claude/hooks/<name> is wrong. We validate the ACTUAL registered target instead.
# Handles: a leading interpreter (bash/sh/env), a quoted or bare first token, ${CLAUDE_PROJECT_DIR} /
# $CLAUDE_PROJECT_DIR expansion, and relative-to-root resolution.
_pfa_registered_target_exists() {  # $1 = command string ; $2 = repo root ; 0 = target file exists non-empty
  local c="$1" root="$2" t rest
  # strip leading whitespace
  c="${c#"${c%%[![:space:]]*}"}"
  # skip a leading interpreter token (bash / sh / env) so we validate the SCRIPT, not the shell
  case "$c" in
    bash\ *|sh\ *|env\ *) c="${c#* }"; c="${c#"${c%%[![:space:]]*}"}" ;;
  esac
  # first token = the script/shim path, honoring surrounding quotes (path may contain spaces)
  case "$c" in
    \"*) t="${c#\"}"; t="${t%%\"*}" ;;
    \'*) t="${c#\'}"; t="${t%%\'*}" ;;
    *)   t="${c%%[[:space:]]*}" ;;
  esac
  # expand ${CLAUDE_PROJECT_DIR} / $CLAUDE_PROJECT_DIR (Claude Code injects the repo root here)
  t="${t//\$\{CLAUDE_PROJECT_DIR\}/$root}"
  t="${t//\$CLAUDE_PROJECT_DIR/$root}"
  # resolve relative to the repo root if not absolute (drive-letter or leading-slash = absolute)
  case "$t" in /*|[A-Za-z]:*|\\\\*) : ;; *) [ -n "$t" ] && t="$root/$t" ;; esac
  [ -n "$t" ] && [ -s "$t" ]
}

# Extract every PreToolUse Bash hook command from a settings file into the GLOBAL _PFA_CMDS (one command
# per line), and set the GLOBAL _PFA_PARSE=ok|malformed|absent|noparser. Sets globals (NOT stdout) so the
# caller does not lose the parse state to a command-substitution subshell. Parser preference: jq → python
# (a documented framework dependency) → noparser. MATCHER-AWARE in BOTH parser paths: only commands under a
# PreToolUse entry whose matcher is exactly "Bash" are returned — a Write/Edit/Agent gate is never mistaken
# for a Bash owner (that was the no-jq raw-fallback silent-allow bug). With NO parser at all we cannot make
# a matcher-aware decision, so we report noparser and the caller resolves to the SAFE side (user owns).
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
  local py=""
  command -v python3 >/dev/null 2>&1 && py=python3 || { command -v python >/dev/null 2>&1 && py=python; }
  if [ -n "$py" ]; then
    _PFA_CMDS="$("$py" - "$s" <<'PY' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding="utf-8"))
except Exception:
    print("__PFA_MALFORMED__"); sys.exit(0)
pre=(d.get("hooks",{}) or {}).get("PreToolUse",[]) or []
for e in pre:
    if isinstance(e,dict) and e.get("matcher")=="Bash":
        for h in (e.get("hooks",[]) or []):
            if isinstance(h,dict):
                c=h.get("command","")
                if c: print(c)
PY
)"
    if [ "$_PFA_CMDS" = "__PFA_MALFORMED__" ]; then _PFA_PARSE=malformed; _PFA_CMDS="";
    else _PFA_PARSE=ok; fi
    return 0
  fi
  # No jq AND no python: cannot make a matcher-aware decision. Fail to the SAFE side (caller → user owns).
  _PFA_PARSE=noparser
  _PFA_CMDS=""
  return 0
}

# THE classifier. See the header contract.
pfa_classify_owner() {  # $1 = repo root ; $2 = optional user-dispatcher path
  local root="$1" udisp="${2:-}"
  PFA_OWNER="USER"; PFA_REASON=""; PFA_PROJECT_CMDS=""; PFA_DUP_RISK="no"; PFA_STALE="no"

  local s saw_malformed="no" saw_noparser="no"
  local n_project_live=0 n_project_stale=0 n_user_dup=0

  local _PFA_PARSE="" _PFA_CMDS=""
  for s in "$root/.claude/settings.json" "$root/.claude/settings.local.json"; do
    [ -f "$s" ] || continue
    _pfa_settings_bash_cmds "$s"
    case "$_PFA_PARSE" in
      malformed) saw_malformed="yes"; continue ;;
      noparser)  saw_noparser="yes"; continue ;;
      absent)    continue ;;
      ok)        : ;;
    esac

    # Matcher-aware (Bash-only) commands. Classify each: USER-runtime dup, or PROJECT router. A PROJECT
    # router registration is LIVE only if its ACTUAL registered target file exists non-empty; otherwise it
    # is STALE. This validates the real command target (e.g. an absolute .git/preflight/runtime/<sha>/hooks/
    # run-hook.cmd from a branch-stable install), not a guessed .claude/hooks/ path.
    local c
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      if _pfa_is_user_runtime_cmd "$c" "$udisp"; then
        n_user_dup=$((n_user_dup+1))
        PFA_PROJECT_CMDS="${PFA_PROJECT_CMDS}${c}"$'\n'
      elif _pfa_is_project_router_cmd "$c"; then
        if _pfa_registered_target_exists "$c" "$root"; then
          n_project_live=$((n_project_live+1))
        else
          n_project_stale=$((n_project_stale+1))
        fi
        PFA_PROJECT_CMDS="${PFA_PROJECT_CMDS}${c}"$'\n'
      fi
    done <<EOF
$_PFA_CMDS
EOF
  done

  # ── Decide ────────────────────────────────────────────────────────────────────────────────────────────
  # A LIVE project registration (target file exists) wins → PROJECT; the user router yields.
  if [ "$n_project_live" -gt 0 ]; then
    PFA_OWNER="PROJECT"
    PFA_REASON="a valid project-level Preflight Bash registration whose runtime file exists owns this repo; the user router yields (writes nothing)."
    { [ "$n_project_live" -gt 1 ] || [ "$n_project_stale" -gt 0 ] || [ "$n_user_dup" -gt 0 ]; } && PFA_DUP_RISK="yes"
    return 0
  fi

  # A project router is registered but its target file is missing/empty → STALE project install → AMBIGUOUS,
  # user runtime owns SAFELY (never stand down for a broken project install).
  if [ "$n_project_stale" -gt 0 ]; then
    PFA_OWNER="AMBIGUOUS"; PFA_STALE="yes"
    PFA_REASON="a project settings file registers a project Preflight hook, but the referenced runtime file is missing/empty (stale install) — user runtime owns the decision (safe). Reinstall the project runtime or remove the stale registration."
    [ "$n_user_dup" -gt 0 ] && PFA_DUP_RISK="yes"
    return 0
  fi

  # Malformed settings we could not parse, with no confirmable live project registration → AMBIGUOUS (user
  # owns safely; never defer to an unverifiable project runtime).
  if [ "$saw_malformed" = "yes" ]; then
    PFA_OWNER="AMBIGUOUS"
    PFA_REASON="a project settings file is present but is not valid JSON; cannot confirm a project registration — user runtime owns the decision (safe). Fix or remove the malformed settings file."
    [ "$n_user_dup" -gt 0 ] && PFA_DUP_RISK="yes"
    return 0
  fi

  # No parser available (no jq AND no python) → cannot make a matcher-aware ownership decision → AMBIGUOUS,
  # user owns SAFELY. (install/verify already require a parser; this only affects passive routing on a host
  # that somehow lacks both, and it fails to the safe side — the user gate runs, never stands down.)
  if [ "$saw_noparser" = "yes" ]; then
    PFA_OWNER="AMBIGUOUS"
    PFA_REASON="no JSON parser (jq/python) available to read project settings matcher-aware — user runtime owns the decision (safe). Install jq or python for project-ownership detection."
    return 0
  fi

  # No distinct project registration. A project entry that only re-invokes the USER runtime is a duplicate.
  if [ "$n_user_dup" -gt 0 ]; then
    PFA_OWNER="USER"; PFA_DUP_RISK="yes"
    PFA_REASON="project settings register the USER runtime (dispatcher/user-home path) — the same physical runtime would run twice per event; user runtime owns it once. Remove the user-runtime reference from project settings (the user-level install already covers this repo)."
    return 0
  fi

  # Opted in, no project registration of any kind → user runtime owns (config-alone is not project ownership).
  PFA_OWNER="USER"
  PFA_REASON="repo opted in (config present) with no project-level Preflight registration — user runtime owns the decision."
  return 0
}

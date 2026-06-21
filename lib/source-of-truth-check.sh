#!/usr/bin/env bash
# source-of-truth-check.sh — the THIRD gap-detector (missing-ground-truth gap).
#
# THE FAMILY (same accountability principle, three kinds of gap — don't let the agent comfortably guess
# what it doesn't know):
#   1. lib/spec-divergence.sh     — PROMPT gap     (the request is under-specified -> elicit).
#   2. lib/coverage-gap-detect.sh — DETECTION gap  (a defect escaped my gates -> capture the blind spot).
#   3. lib/source-of-truth-check.sh (this file) — GROUND-TRUTH gap (I lack a source I need -> ESCALATE).
#
# THE PRINCIPLE: when an agent needs a source of truth it does not have — the referenced legacy file does
# not exist, the configured path is empty/unreadable, a required artifact/spec/baseline is absent — it must
# DETECT that gap and ESCALATE TO THE HUMAN for the input, NOT guess/confabulate a plausible value. An agent
# that confabulates a source of truth (e.g. produces an empty-but-plausible behavior baseline because the
# source dir was wrong/empty) is the comfortable-path / competent-rationalizer failure the framework exists
# to prevent.
#
# THE LOAD-BEARING INTEGRITY CONSTRAINT (mirrors coverage-gap-detect.sh's I1-I4):
#   "Do I have sufficient source of truth to proceed?" is COMPUTED/MECHANICAL, NEVER the working agent's
#   self-assessment. If the agent self-judges "I have enough," it WILL under-escalate (asking is friction).
#   So this tool computes presence+readability from the FILESYSTEM. Any agent-opinion field in the input
#   (claimedSufficient / agentSaysProceed / iHaveEnough / claimedMissing / agentDrama) is IGNORED BY
#   CONSTRUCTION — the verdict is a pure function of (does each required source EXIST and is it READABLE and
#   NON-EMPTY?). The integrity test proves: an agent CLAIMING "I have enough, proceed" when a required
#   source is mechanically ABSENT is still ESCALATED; an agent CLAIMING "huge missing source!" when the
#   source is actually PRESENT does NOT manufacture a false escalation.
#
# WHAT "HAVE A SOURCE" MEANS MECHANICALLY (per required source):
#   - file:  the path EXISTS, is a regular file, is READABLE, and is NON-EMPTY (a present-but-empty
#            configured legacy source is treated as MISSING — an empty source is not a source of truth).
#   - dir:   the path EXISTS, is a directory, is READABLE, and is NON-EMPTY (contains >=1 entry).
#   - any:   EXISTS + READABLE (file or dir), emptiness not checked (use when emptiness is legitimately ok).
#   A placeholder value (e.g. "<set-this-to-...>", "TODO", "CHANGEME") is treated as UNCONFIGURED -> MISSING
#   (the operator never filled it in — guessing past it is the failure).
#
# Usage:
#   bash lib/source-of-truth-check.sh \
#     --require <kind>:<label>:<path>   (repeatable; kind = file|dir|any) \
#     [--agent "<agent name, for the escalation message>"] \
#     [--json <descriptor.json>]        (alternative to flags; see below) \
#     [--override-token <file>]         (a HUMAN-written override sentinel that, if present+readable,
#                                         downgrades a MISSING to a human-acknowledged PROCEED — the ONLY
#                                         way past a mechanical absence, and it is human-minted, not agent.)
#
#   --json descriptor: { "agent": "...", "required": [ {"kind":"file","label":"legacy baseline","path":"..."},
#                                                       {"kind":"dir","label":"legacy source","path":"..."} ] }
#     Agent-opinion keys in the JSON (claimedSufficient, iHaveEnough, claimedMissing, agentDrama, …) are
#     NEVER read — the verdict is computed from the `required` paths only.
#
# Output: line 1 = verdict (PROCEED | ESCALATE); then per-source status; on ESCALATE, the human-facing
#   block naming EXACTLY what is missing and what input is needed.
# Exit: 0 = PROCEED (all required sources present+readable), 3 = ESCALATE (>=1 missing — a distinct,
#   greppable "stop and ask the human" code, NOT 1/2), 2 = usage error. FAIL-SAFE: a malformed/empty
#   requirement set, or any internal error resolving a path, escalates (never silently PROCEEDs).

set -uo pipefail

AGENT=""; JSON=""; OVERRIDE_TOKEN=""
REQ_KINDS=(); REQ_LABELS=(); REQ_PATHS=()

_add_req() {  # $1 = "kind:label:path" (label may contain spaces; split on first two colons)
  local spec="$1" kind label path
  kind="${spec%%:*}"; spec="${spec#*:}"
  label="${spec%%:*}"; path="${spec#*:}"
  if [ -z "$kind" ] || [ -z "$path" ] || [ "$kind" = "$1" ]; then
    echo "source-of-truth-check: malformed --require '$1' (need kind:label:path)" >&2; exit 2
  fi
  REQ_KINDS+=("$kind"); REQ_LABELS+=("${label:-source}"); REQ_PATHS+=("$path")
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --require)        _add_req "${2:-}"; shift 2 || shift ;;
    --agent)          AGENT="${2:-}"; shift 2 || shift ;;
    --json)           JSON="${2:-}"; shift 2 || shift ;;
    --override-token) OVERRIDE_TOKEN="${2:-}"; shift 2 || shift ;;
    *) echo "source-of-truth-check: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

# JSON descriptor: read ONLY the factual fields (agent + required[].{kind,label,path}). Agent-opinion keys
# are deliberately NOT read — presence/sufficiency is computed from the filesystem, not from what the agent
# claims about whether it has enough.
if [ -n "$JSON" ]; then
  [ -f "$JSON" ] || { echo "source-of-truth-check: --json file not found: $JSON" >&2; exit 2; }
  if command -v jq >/dev/null 2>&1; then
    [ -n "$AGENT" ] || AGENT="$(jq -r '.agent // empty' "$JSON" 2>/dev/null || true)"
    # Append each required entry. (kind defaults to file; label to "source".) Strip a trailing CR from
    # every field: jq's @tsv emits CRLF line endings on some platforms (Git-Bash/Windows), and a path
    # carrying a trailing \r fails every filesystem test ("file.json\r" does not exist) — which would make
    # a PRESENT source look MISSING. Tolerated mechanically here so the verdict reflects the real filesystem.
    while IFS=$'\t' read -r k l p; do
      k="${k%$'\r'}"; l="${l%$'\r'}"; p="${p%$'\r'}"
      [ -z "$p" ] && continue
      REQ_KINDS+=("${k:-file}"); REQ_LABELS+=("${l:-source}"); REQ_PATHS+=("$p")
    done < <(jq -r '.required[]? | [(.kind // "file"), (.label // "source"), (.path // "")] | @tsv' "$JSON" 2>/dev/null || true)
  fi
fi

# A required-source set is mandatory. An EMPTY requirement set is itself a fail-safe ESCALATE: a caller that
# declared no sources to check has not established it has the ground truth — do not silently PROCEED.
if [ "${#REQ_PATHS[@]}" -eq 0 ]; then
  echo "ESCALATE"
  echo "  no required sources were declared to check — cannot confirm sufficient ground truth. Declare the"
  echo "  required sources (--require kind:label:path) or escalate to a human. (Fail-safe: empty set escalates.)"
  exit 3
fi

# Is a value an unconfigured placeholder? (operator never filled it in)
_is_placeholder() {
  case "$1" in
    *"<set-this"*|*"<SET-THIS"*|*"<your-"*|*"<YOUR-"*|"<"*">"|*"CHANGEME"*|*"changeme"*|"TODO"|"todo"|""|"null"|"undefined") return 0 ;;
  esac
  return 1
}

# Check ONE required source mechanically. Echoes a status line; returns 0 if present, 1 if missing.
_check_one() {  # $1=kind $2=label $3=path
  local kind="$1" label="$2" path="$3"
  if _is_placeholder "$path"; then
    echo "  MISSING  [$label] path is an unconfigured placeholder ('$path') — the operator never set it."
    return 1
  fi
  if [ ! -e "$path" ]; then
    echo "  MISSING  [$label] does not exist on disk: $path"
    return 1
  fi
  if [ ! -r "$path" ]; then
    echo "  MISSING  [$label] exists but is NOT readable (permissions): $path"
    return 1
  fi
  case "$kind" in
    file)
      if [ ! -f "$path" ]; then echo "  MISSING  [$label] expected a file but it is not a regular file: $path"; return 1; fi
      if [ ! -s "$path" ]; then echo "  MISSING  [$label] file exists but is EMPTY (an empty source is not a source of truth): $path"; return 1; fi
      echo "  present  [$label] file ok: $path"; return 0 ;;
    dir)
      if [ ! -d "$path" ]; then echo "  MISSING  [$label] expected a directory but it is not a directory: $path"; return 1; fi
      # Non-empty = at least one entry (ignore . and ..). Unreadable-listing => treat as missing (fail-safe).
      if ! find "$path" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
        echo "  MISSING  [$label] directory exists but is EMPTY (no files to read as source): $path"; return 1
      fi
      echo "  present  [$label] dir ok (non-empty): $path"; return 0 ;;
    any)
      echo "  present  [$label] exists+readable: $path"; return 0 ;;
    *)
      echo "  MISSING  [$label] unknown kind '$kind' (use file|dir|any) — cannot verify, failing safe: $path"; return 1 ;;
  esac
}

MISSING_COUNT=0
STATUS_LINES=""
i=0
while [ "$i" -lt "${#REQ_PATHS[@]}" ]; do
  line="$(_check_one "${REQ_KINDS[$i]}" "${REQ_LABELS[$i]}" "${REQ_PATHS[$i]}")" || MISSING_COUNT=$((MISSING_COUNT + 1))
  STATUS_LINES="${STATUS_LINES}${line}"$'\n'
  i=$((i + 1))
done

if [ "$MISSING_COUNT" -eq 0 ]; then
  echo "PROCEED"
  printf '%s' "$STATUS_LINES"
  echo "  all ${#REQ_PATHS[@]} required source(s) exist and are readable — sufficient ground truth to proceed."
  exit 0
fi

# >=1 missing. Before escalating, honor a HUMAN-minted override token (the ONLY way past a mechanical
# absence — and it is human-written, never agent-minted). The override is itself a real, readable file:
# its presence is the human saying "I acknowledge the missing source; proceed anyway."
if [ -n "$OVERRIDE_TOKEN" ] && [ -f "$OVERRIDE_TOKEN" ] && [ -r "$OVERRIDE_TOKEN" ] && [ -s "$OVERRIDE_TOKEN" ]; then
  echo "PROCEED"
  printf '%s' "$STATUS_LINES"
  echo "  ${MISSING_COUNT} source(s) MISSING, but a human override token is present ($OVERRIDE_TOKEN) — proceeding"
  echo "  on explicit human acknowledgement. (The agent did not mint this; a human wrote the override file.)"
  exit 0
fi

# ESCALATE: surface EXACTLY what is missing and what input is needed. The agent does NOT proceed on a guess.
echo "ESCALATE"
printf '%s' "$STATUS_LINES"
echo ""
echo "  >>> STOP — escalate to a human. ${MISSING_COUNT} required source(s) of truth are MISSING/unreadable${AGENT:+ (agent: $AGENT)}."
echo "  Do NOT proceed on a guessed or confabulated value for an absent source — surface to the human:"
echo "    1. WHICH sources are missing (the MISSING lines above), and"
echo "    2. WHAT input is needed (the correct path, the missing artifact, or access to it)."
echo "  Proceed ONLY after the human provides the source, or explicitly overrides via a human-written"
echo "  override token (--override-token <file>). A missing source is a COMPUTED FACT, not a judgment the"
echo "  agent makes — the agent's belief that it 'has enough' does not clear this."
exit 3

#!/usr/bin/env bash
# coverage-gap-detect.sh — LAYER 2: MECHANICAL coverage-gap self-detection.
#
# THE PREMISE (see .release-audit/COVERAGE-GAP-DESIGN.md): when a defect is found POST-MERGE / in deploy
# (it got PAST the gates), a good engineer asks "how did this get past my detection, and what do I change
# so this CLASS of miss can't recur?" This encodes that meta-instinct: it determines whether the defect
# entered through a COVERAGE GAP, and classifies the gap so it can be captured and closed.
#
# THE LOAD-BEARING INTEGRITY CONSTRAINT (the whole point — do NOT weaken it):
#   The "was this a coverage gap, and which gate should have caught it" determination is COMPUTED from
#   artifacts — it is NEVER the working agent's self-assessment. A working agent that decides its own
#   coverage gaps produces the competent-rationalizer failure in two INVISIBLE directions: rationalize a
#   real gap away ("unforeseeable"), or manufacture gaps everywhere (every bug -> "coverage failure",
#   drowning the signal). Both look identical to a correct judgment. So this tool computes the answer
#   from (defect-category, rubric-rule-list, gate-evidence) as a PURE FUNCTION. Any agent-opinion field
#   in the input (claimedNotMyFault / claimedHugeGap / shouldHaveCaught / agentExcuse / agentDrama) is
#   IGNORED BY CONSTRUCTION — the classifier never reads it. The integrity test proves this: the SAME
#   defect with OPPOSITE agent claims yields the SAME classification.
#
# THE THREE MECHANICAL CLASSIFICATIONS:
#   BLIND-SPOT      — a rubric rule's category/CWE/detection-signal MATCHES this defect, AND the
#                     corresponding gate PASSED/was-clean at the defect's HEAD. Provable: the rule existed,
#                     the defect is of that kind, yet it got through. -> capture to calibration-log
#                     (in-rubric-but-missed) + the meta-finding "gate has a blind spot for <rule>".
#   UNCOVERED-CLASS — NO rubric rule matches this defect's category/CWE/signal. Provable absence of
#                     coverage. -> capture to checklist-additions (new-category) + meta "no rule covers
#                     <category>".
#   NEW-COVERAGE    — no rule matches AND the defect is flagged structurally-uncoverable by the existing
#                     gate set (--uncoverable, e.g. a runtime-only class with no static signal). Captured
#                     as new coverage, explicitly NOT a blind spot (the agent cannot inflate this into a
#                     missed-gate; the mechanism decides). In this build NEW-COVERAGE requires the explicit
#                     --uncoverable signal; without it, no-match defaults to UNCOVERED-CLASS (the
#                     conservative direction: an unmatched defect is treated as a coverage GAP to close,
#                     not excused as inherently-uncoverable).
#
# Inputs (a defect descriptor — flags OR a JSON file via --json):
#   --category "<defect category>"   (required) e.g. "Log injection (CWE-117)", "SSRF", "Missing input validation"
#   --cwe "<CWE-nnn>"                 (optional) strengthens the match
#   --signal "<keywords>"            (optional) free-text detection-signal keywords to match against rules
#   --rubric <rubric.md> [...]        (required, repeatable) the active rubric file(s)
#   --gate-evidence <dir>             (optional) .preflight/gate dir; if a matching gate's evidence shows
#                                      CLEAN/PASS at HEAD, the matched-rule case is a provable BLIND-SPOT.
#                                      Absent => still BLIND-SPOT on a rule match (the rule existed and the
#                                      defect escaped; gate-evidence only strengthens "the gate affirmatively passed").
#   --uncoverable                     mark the defect as structurally uncoverable by static gates => NEW-COVERAGE
#                                      (only meaningful when no rule matches).
#   --json <file>                     read the descriptor from JSON instead of flags (keys: category, cwe,
#                                      signal, uncoverable). Agent-opinion keys in the JSON are IGNORED.
#
# Output: line 1 = the classification (BLIND-SPOT | UNCOVERED-CLASS | NEW-COVERAGE); then the basis +
#   a ready-to-use capture suggestion (--bucket / --meta for lib/capture-finding.sh). With --emit-capture
#   and --capture-source <label>, it ALSO calls capture-finding.sh to record the entry (Layer 1).
# Exit: 0 = classified · 2 = usage error. NEVER exits non-zero "because it found a gap" (finding a gap is
#   the tool WORKING). NEVER feeds a gate (inherited boundary from agent-scorer): observes + captures only.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATEGORY=""; CWE=""; SIGNAL=""; UNCOVERABLE=0; GATE_DIR=""; JSON=""
EMIT_CAPTURE=0; CAPTURE_SOURCE=""; RUBRICS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --category)       CATEGORY="${2:-}"; shift 2 || shift ;;
    --cwe)            CWE="${2:-}"; shift 2 || shift ;;
    --signal)         SIGNAL="${2:-}"; shift 2 || shift ;;
    --uncoverable)    UNCOVERABLE=1; shift ;;
    --gate-evidence)  GATE_DIR="${2:-}"; shift 2 || shift ;;
    --rubric)         RUBRICS+=("${2:-}"); shift 2 || shift ;;
    --json)           JSON="${2:-}"; shift 2 || shift ;;
    --emit-capture)   EMIT_CAPTURE=1; shift ;;
    --capture-source) CAPTURE_SOURCE="${2:-}"; shift 2 || shift ;;
    *) echo "coverage-gap-detect: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

# If a JSON descriptor was given, read ONLY the factual fields. Agent-opinion keys are deliberately NOT
# read — the classification must not depend on what the working agent claims about its own culpability.
if [ -n "$JSON" ]; then
  [ -f "$JSON" ] || { echo "coverage-gap-detect: --json file not found: $JSON" >&2; exit 2; }
  if command -v jq >/dev/null 2>&1; then
    [ -n "$CATEGORY" ] || CATEGORY="$(jq -r '.category // empty' "$JSON" 2>/dev/null || true)"
    [ -n "$CWE" ]      || CWE="$(jq -r '.cwe // empty' "$JSON" 2>/dev/null || true)"
    [ -n "$SIGNAL" ]   || SIGNAL="$(jq -r '.signal // empty' "$JSON" 2>/dev/null || true)"
    # --uncoverable from JSON is a FACTUAL gate-capability flag (is there any static signal for this class),
    # not an agent opinion about fault. Read it.
    if [ "$UNCOVERABLE" = 0 ]; then
      [ "$(jq -r '.uncoverable // false' "$JSON" 2>/dev/null || echo false)" = "true" ] && UNCOVERABLE=1
    fi
    # INTEGRITY: keys like claimedNotMyFault / claimedHugeGap / shouldHaveCaught / agentExcuse are NEVER
    # read here. The classifier is a pure function of (category, cwe, signal, rubric, gate-evidence).
  fi
fi

[ -n "$CATEGORY" ] || { echo "coverage-gap-detect: --category (or .category in --json) is required" >&2; exit 2; }
[ "${#RUBRICS[@]}" -gt 0 ] || { echo "coverage-gap-detect: at least one --rubric <file> is required" >&2; exit 2; }

# ── MECHANICAL MATCH: does any rubric rule cover this defect's category/CWE/signal? ──
# A rubric rule is a "### §<id> <title>" header block. We match on, in priority order:
#   (1) CWE id appearing in any rule line  (strongest, exact id)
#   (2) the defect category's salient tokens appearing in a rule TITLE  (### §… line)
#   (3) the defect signal keywords appearing in a rule block
# We collect the FIRST matching rule's §id for the meta-finding. Pure text matching — no agent opinion.
_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Salient tokens from the category: drop punctuation + a small stopword set, keep words >= 3 chars.
_tokens() {
  _lower "$1" | tr -cs 'a-z0-9' '\n' \
    | grep -vE '^(the|and|for|with|missing|risk|in|on|of|a|an|to|cwe|via|use|using)$' \
    | awk 'length>=3'
}

MATCHED_RULE=""
MATCH_BASIS=""

# Build a combined haystack of all rubric rule headers + (for signal/CWE) full content, per file.
for rb in "${RUBRICS[@]}"; do
  [ -f "$rb" ] || continue

  # (1) CWE exact-id match (only if a CWE was supplied).
  if [ -z "$MATCHED_RULE" ] && [ -n "$CWE" ]; then
    cwe_norm="$(_lower "$CWE" | tr -d ' ')"   # e.g. cwe-117
    # find the rule header (### §...) whose block (header line itself, where CWE refs live) contains the CWE id
    line="$(grep -niE "^### §" "$rb" 2>/dev/null | while IFS=: read -r ln _; do
              hdr="$(sed -n "${ln}p" "$rb")"
              if printf '%s' "$(_lower "$hdr" | tr -d ' ')" | grep -qF "$cwe_norm"; then printf '%s' "$hdr"; break; fi
            done)"
    if [ -n "$line" ]; then
      MATCHED_RULE="$(printf '%s' "$line" | grep -oE '§[A-Za-z0-9.]+' | head -1)"
      MATCH_BASIS="CWE ${CWE} matched rule ${MATCHED_RULE} (${line#### })"
    fi
  fi

  # (2) category-token match against rule TITLES. Require a token to appear in a rule header.
  if [ -z "$MATCHED_RULE" ]; then
    while IFS= read -r tok; do
      [ -z "$tok" ] && continue
      hdr="$(grep -iE "^### §" "$rb" 2>/dev/null | grep -iE "(^|[^a-z])${tok}([^a-z]|\$)" | head -1 || true)"
      if [ -n "$hdr" ]; then
        MATCHED_RULE="$(printf '%s' "$hdr" | grep -oE '§[A-Za-z0-9.]+' | head -1)"
        MATCH_BASIS="category token '${tok}' matched rule ${MATCHED_RULE} (${hdr#### })"
        break
      fi
    done < <(_tokens "$CATEGORY")
  fi

  # (3) signal-keyword match against the whole rubric (any rule block) — weakest, only if signal given.
  if [ -z "$MATCHED_RULE" ] && [ -n "$SIGNAL" ]; then
    while IFS= read -r tok; do
      [ -z "$tok" ] && continue
      if grep -qiE "(^|[^a-z])${tok}([^a-z]|\$)" "$rb" 2>/dev/null; then
        # find the nearest preceding rule header for attribution (best-effort): first header containing the token
        hdr="$(grep -iE "^### §" "$rb" 2>/dev/null | grep -iE "(^|[^a-z])${tok}([^a-z]|\$)" | head -1 || true)"
        if [ -n "$hdr" ]; then
          MATCHED_RULE="$(printf '%s' "$hdr" | grep -oE '§[A-Za-z0-9.]+' | head -1)"
          MATCH_BASIS="signal keyword '${tok}' matched rule ${MATCHED_RULE} (${hdr#### })"
          break
        fi
      fi
    done < <(_tokens "$SIGNAL")
  fi

  [ -n "$MATCHED_RULE" ] && break
done

# ── Did the corresponding gate PASS at HEAD? (strengthens BLIND-SPOT to "provably the gate ran clean") ──
GATE_NOTE=""
if [ -n "$MATCHED_RULE" ] && [ -n "$GATE_DIR" ] && [ -d "$GATE_DIR" ]; then
  # The rubric-detection gate's evidence is stage1-clean (code-reviewer's verdict). If it exists/CLEAN at
  # HEAD, the rule was in force AND the gate affirmatively passed => the defect slipped a passing gate.
  if [ -f "$GATE_DIR/stage1-clean" ]; then
    GATE_NOTE=" (gate evidence: stage1-clean present at HEAD — the detection gate affirmatively passed, so the matched rule did not fire on this defect)"
  else
    GATE_NOTE=" (no stage1-clean evidence found — gate may not have run; the rule-match alone still establishes the defect is OF A COVERED KIND that escaped)"
  fi
fi

# ── CLASSIFY (pure function of the mechanical signals above) ──
if [ -n "$MATCHED_RULE" ]; then
  CLASS="BLIND-SPOT"
  BUCKET="calibration-log"
  META="gate has a BLIND SPOT for ${MATCHED_RULE}: a '${CATEGORY}' defect of a COVERED kind reached post-merge. ${MATCH_BASIS}.${GATE_NOTE}"
  BASIS="$MATCH_BASIS$GATE_NOTE"
elif [ "$UNCOVERABLE" = 1 ]; then
  CLASS="NEW-COVERAGE"
  BUCKET="checklist-additions"
  META="NEW COVERAGE AREA: '${CATEGORY}' is structurally uncoverable by the current static gate set (flagged --uncoverable); no existing rule matched. This is a new coverage area, NOT a missed gate (no gate could have caught it)."
  BASIS="no rubric rule matched; defect flagged structurally-uncoverable => new coverage area, not a blind spot"
else
  CLASS="UNCOVERED-CLASS"
  BUCKET="checklist-additions"
  META="UNCOVERED CLASS: no rubric rule covers '${CATEGORY}'. The detection rubric has no rule for this kind of defect — a coverage gap to close with a new rule."
  BASIS="no rubric rule matched the category/CWE/signal => uncovered class (a coverage gap)"
fi

echo "$CLASS"
echo "  category: ${CATEGORY}${CWE:+  cwe: $CWE}"
echo "  basis: ${BASIS}"
echo "  -> capture bucket: ${BUCKET}"
echo "  -> meta-finding: ${META}"
echo "  suggested: lib/capture-finding.sh --source <how-found> --category \"${CATEGORY}\" --summary \"<defect>\" --bucket ${BUCKET}${MATCHED_RULE:+ --rule \"$MATCHED_RULE\"} --meta \"${META}\""

# Optionally drive Layer 1 directly (record the entry now).
if [ "$EMIT_CAPTURE" = 1 ]; then
  [ -n "$CAPTURE_SOURCE" ] || { echo "coverage-gap-detect: --emit-capture requires --capture-source <label>" >&2; exit 2; }
  bash "$SELF_DIR/capture-finding.sh" \
    --source "$CAPTURE_SOURCE" --category "$CATEGORY" --summary "$CATEGORY" \
    --bucket "$BUCKET" ${MATCHED_RULE:+--rule "$MATCHED_RULE"} ${CWE:+--cwe "$CWE"} \
    --meta "$META" --confidence "$([ "$CLASS" = BLIND-SPOT ] && echo high || echo medium)" \
    >&2 || echo "coverage-gap-detect: capture-finding call failed (non-fatal)" >&2
fi
exit 0

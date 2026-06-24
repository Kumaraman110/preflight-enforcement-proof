#!/usr/bin/env bash
# capture-finding.sh — LAYER 1: the SOURCE-AGNOSTIC capture entry point.
#
# THE HOLE THIS CLOSES (see .release-audit/COVERAGE-GAP-DESIGN.md §1): the capture->rubric loop only
# AUTO-captures Copilot findings (the external-review-handler sub-agent is the SOLE automatic on-ramp —
# agents/external-review-handler.md:3; the parent is FORBIDDEN to write capture, fix-and-close SKILL:244,
# :473). So a defect found ANY OTHER way (live deploy, code review, prod incident) silently bypasses
# capture unless a human hand-authors an entry — INVERTED coverage: the cheap pre-merge findings
# auto-capture; the EXPENSIVE post-merge ones rely on fallible memory. And a missing capture is INVISIBLE
# (looks identical to "no defect found").
#
# THE FIX: ONE source-agnostic path. ANY adjudicated defect — regardless of how it was found — flows here
# via a `--source <label>` parameter. NOT "copilot OR deploy" (two hardcoded sources => the next source
# bypasses again); a labeled parameter means a NEW source is covered BY CONSTRUCTION (it just passes its
# own label). The Copilot handler's existing path is unchanged (no regression); it MAY also route here.
#
# This is LAYER 1 only: it records the defect into the correct capture bucket. WHICH bucket (and the
# coverage-gap META-finding) is decided by LAYER 2 (lib/coverage-gap-detect.sh) — mechanical, not the
# working agent's self-assessment. Callers that already know the bucket may pass --bucket; callers that
# don't pass --bucket get the fail-safe default (new-category, low confidence) — a defect is NEVER
# silently dropped (captured-uncertain is the fail-safe direction, mirroring classification-rules step 5).
#
# Usage:
#   bash lib/capture-finding.sh \
#     --source <copilot|deploy|review|incident|test-escape|...> \
#     --category "<defect category, e.g. 'Log injection (CWE-117)'>" \
#     --summary  "<one-line what-the-defect-was>" \
#     [--bucket <calibration-log|checklist-additions|false-positives>]  (default: checklist-additions) \
#     [--rule "<rubric §id this implies/maps to, if known>"] \
#     [--cwe "<CWE-nnn, if any>"] \
#     [--meta "<coverage-gap meta-finding from Layer 2, e.g. 'gate X blind to §G2.1'>"] \
#     [--confidence <high|medium|low>]  (default: medium; low when bucket defaulted) \
#     [--repo-root <path>]  (default: git toplevel or cwd) \
#     [--config <path>]     (default: <root>/.preflight/config.json — to resolve capture.* paths)
#
# Exit: 0 = entry written · 2 = usage error (missing required field). FAIL-SAFE: an unknown bucket maps to
# checklist-additions (never refuse to record a real defect over a bucket-name typo).

set -uo pipefail

SOURCE=""; CATEGORY=""; SUMMARY=""; BUCKET=""; RULE=""; CWE=""; META=""; CONFIDENCE=""; ROOT=""; CONFIG=""
BUCKET_DEFAULTED=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)     SOURCE="${2:-}"; shift 2 || shift ;;
    --category)   CATEGORY="${2:-}"; shift 2 || shift ;;
    --summary)    SUMMARY="${2:-}"; shift 2 || shift ;;
    --bucket)     BUCKET="${2:-}"; BUCKET_DEFAULTED=0; shift 2 || shift ;;
    --rule)       RULE="${2:-}"; shift 2 || shift ;;
    --cwe)        CWE="${2:-}"; shift 2 || shift ;;
    --meta)       META="${2:-}"; shift 2 || shift ;;
    --confidence) CONFIDENCE="${2:-}"; shift 2 || shift ;;
    --repo-root)  ROOT="${2:-}"; shift 2 || shift ;;
    --config)     CONFIG="${2:-}"; shift 2 || shift ;;
    *) echo "capture-finding: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

# Required fields (a capture entry with no source/category/summary is meaningless).
[ -n "$SOURCE" ]   || { echo "capture-finding: --source is required (how the defect was found)" >&2; exit 2; }
[ -n "$CATEGORY" ] || { echo "capture-finding: --category is required (the defect's kind)" >&2; exit 2; }
[ -n "$SUMMARY" ]  || { echo "capture-finding: --summary is required (one-line defect description)" >&2; exit 2; }

# Resolve repo root + config (fail-open: missing config => default capture paths under docs/review/).
[ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[ -n "$CONFIG" ] || CONFIG="$ROOT/.preflight/config.json"

# Resolve capture.* paths from config (jq, fail-open to the documented defaults).
_cap() {  # $1 = config key under capture.  ; $2 = default
  local v=""
  if [ -f "$CONFIG" ] && command -v jq >/dev/null 2>&1; then
    v="$(jq -r ".capture.$1 // empty" "$CONFIG" 2>/dev/null || true)"
  fi
  [ -n "$v" ] && echo "$v" || echo "$2"
}
CAL_PATH="$(_cap calibrationLog    docs/review/calibration-log.md)"
CHK_PATH="$(_cap checklistAdditions docs/review/checklist-additions.md)"
FP_PATH="$(_cap falsePositives     docs/review/false-positives.md)"

# Bucket default + fail-safe normalization. Unknown/typo'd bucket => checklist-additions (never drop).
[ -n "$BUCKET" ] || BUCKET="checklist-additions"
case "$BUCKET" in
  calibration-log)      DEST="$ROOT/$CAL_PATH"; BUCKET_LABEL="calibration-log (in-rubric-but-missed)" ;;
  checklist-additions)  DEST="$ROOT/$CHK_PATH"; BUCKET_LABEL="checklist-additions (new-category)" ;;
  false-positives)      DEST="$ROOT/$FP_PATH";  BUCKET_LABEL="false-positives" ;;
  *)                    DEST="$ROOT/$CHK_PATH"; BUCKET_LABEL="checklist-additions (new-category) [fail-safe: unknown bucket '$BUCKET']"; BUCKET="checklist-additions" ;;
esac

# Confidence default: low when the bucket was DEFAULTED (we didn't know => uncertain), else medium.
[ -n "$CONFIDENCE" ] || { if [ "$BUCKET_DEFAULTED" = 1 ]; then CONFIDENCE="low"; else CONFIDENCE="medium"; fi; }

# HEAD (SHA-keyed, like the rest of the framework's artifacts). Fail-open to "unknown".
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
# Timestamp: passed via env if the caller wants determinism; else date. (date is allowed here — this is a
# capture-time log line, not a workflow script.)
TS="${PREFLIGHT_CAPTURE_TS:-$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)}"

# WRITE FAIL-CLOSED (G4): this script runs under `set -uo pipefail` but NOT `set -e`, so a failed write
# (mkdir cannot create the dir, the header/append redirect fails on an unwritable path/full disk) would
# only emit to stderr while control fell through to the success echo + `exit 0` — reporting a SILENT
# SUCCESS for a capture that never persisted. A lost capture is INVISIBLE (looks identical to "no defect
# found") — the exact accountability gap this file exists to close (see header), and it defeats the sole
# caller's failure detection (coverage-gap-detect.sh keys off a non-zero exit that never came). So EACH
# write step is now checked and fails CLOSED: a capture that cannot be verified to have persisted ERRORS
# (exit 3) and does NOT print the "captured:" success line. (Exit 3, distinct from the exit-2 usage error:
# this is a could-not-persist runtime failure, not bad arguments.)
_cf_write_fail() {  # $1 = what failed (for the diagnostic)
  echo "capture-finding: FAILED to write the capture entry — $1" >&2
  echo "  The finding '${SUMMARY}' was NOT persisted to ${DEST}. Failing CLOSED (a lost capture is an" >&2
  echo "  invisible accountability gap). Fix the destination (path/permissions/disk) and re-run; do not" >&2
  echo "  treat this as a successful capture." >&2
  exit 3
}

mkdir -p "$(dirname "$DEST")" || _cf_write_fail "cannot create the capture directory $(dirname "$DEST")"
# Create the file with a minimal header if absent (matches the template shape).
if [ ! -f "$DEST" ]; then
  case "$BUCKET" in
    calibration-log)     printf '# Calibration Log\n\nEntries record cases where Stage 1 detection was too weak (missed something the rubric covers) or severity was miscalibrated.\n\n---\n\n' > "$DEST" || _cf_write_fail "cannot create $DEST (header write)" ;;
    checklist-additions) printf '# Checklist Additions\n\nEntries record new categories that no existing rubric section covers.\n\n---\n\n' > "$DEST" || _cf_write_fail "cannot create $DEST (header write)" ;;
    false-positives)     printf '# False Positives\n\nEntries record cases where Stage 1 flagged something external review disagreed with.\n\n---\n\n' > "$DEST" || _cf_write_fail "cannot create $DEST (header write)" ;;
  esac
fi

# Append the structured entry. The `Source:` line uses the source-agnostic label so a non-Copilot origin
# is FIRST-CLASS in the record (was: only "copilot PR#nn" could appear). Survived:0 initializes the
# promotion recurrence counter (lib/rubric-promotion-evaluator.sh consumes it). The whole block's redirect
# is guarded: a failed append fails CLOSED (the entry did not persist), never a silent success.
{
  echo "## ${SUMMARY}"
  echo ""
  echo "- **Source:** ${SOURCE} | ${HEAD_SHA} | ${TS}"
  echo "- **Category:** ${CATEGORY}"
  [ -n "$CWE" ]  && echo "- **CWE:** ${CWE}"
  [ -n "$RULE" ] && echo "- **Implied rule:** ${RULE}"
  [ -n "$META" ] && echo "- **Coverage-gap (Layer 2):** ${META}"
  echo "- **Confidence:** ${CONFIDENCE}"
  echo "- **Survived:** 0"
  echo ""
  echo "---"
  echo ""
} >> "$DEST" || _cf_write_fail "cannot append the entry to $DEST"

# Confirmed persisted: the destination exists and is non-empty. (Belt-and-suspenders — the redirects above
# already fail-closed; this also catches a write that silently produced nothing.)
[ -s "$DEST" ] || _cf_write_fail "the entry append produced no content at $DEST"

echo "captured: '${SUMMARY}' -> ${BUCKET_LABEL}"
echo "  source=${SOURCE}  category=${CATEGORY}  head=${HEAD_SHA}  -> ${DEST}"
exit 0

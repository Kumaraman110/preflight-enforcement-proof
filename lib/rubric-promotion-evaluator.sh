#!/usr/bin/env bash
# Rubric-promotion matrix evaluator — the deterministic half of segment 2.
#
# Reads capture files (calibration-log, checklist-additions, false-positives),
# parses each entry's tracking fields, SKIPS defended entries, and applies the
# EXISTING promotion matrix from docs/rubric-edit-process.md §4 (lines 55-61).
# It does NOT invent criteria and it does NOT edit the rubric — it emits a
# per-entry decision as JSON. The rubric-edit SKILL consumes this to draft a
# human-reviewed PR.
#
# Usage: rubric-promotion-evaluator.sh <capture-file> [<capture-file> ...]
#   File role is inferred from the filename:
#     *calibration*  / *checklist*  -> promotion matrix
#     *false-positive*              -> LOOSEN bucket (drives rubric loosening, not promotion)
#
# Output: JSON array of decisions to stdout. Exit codes:
#   0 = evaluated (one or more entries; decisions on stdout)
#   1 = no parseable entries found across the given files
#   2 = usage error / no input files
#
# THE MATRIX (verbatim from docs/rubric-edit-process.md §4 — do not drift):
#   Survived 0-1 / any        -> HOLD
#   Survived 2+  / high       -> PROMOTE              (at declared severity)
#   Survived 2+  / medium     -> PROMOTE_CAP_MAJOR
#   Survived 2+  / low        -> PROMOTE_CAP_MINOR    (+ flag detection refinement)
#   Survived 5+  / low        -> PRIORITY_ESCALATION  (promote minor + immediate refinement)
#
# SKIP (the 1A interplay — never promote a defended finding):
#   An entry annotated "⛔ DO NOT PROMOTE" OR whose Survived is "N/A" is SKIPPED.
#   A prose matrix that misreads this once would promote a detection rule for
#   behavior the team deliberately preserved — so this is mechanical, not prose.

set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo '{"error":"Usage: rubric-promotion-evaluator.sh <capture-file> [<capture-file> ...]"}' >&2
  exit 2
fi

# Detect a working Python interpreter (mirrors parity-check.sh)
PYTHON_CMD=""
for py_candidate in python python3; do
  if command -v "$py_candidate" &>/dev/null && "$py_candidate" -c "pass" &>/dev/null 2>&1; then
    PYTHON_CMD="$py_candidate"
    break
  fi
done
if [ -z "$PYTHON_CMD" ]; then
  echo '{"error":"No working Python interpreter found. rubric-promotion-evaluator requires Python."}' >&2
  exit 2
fi

"$PYTHON_CMD" - "$@" <<'PYTHON_SCRIPT'
import json, re, sys, os

def role_for(path):
    name = os.path.basename(path).lower()
    if "false-positive" in name:
        return "loosen"
    return "promote"  # calibration-log, checklist-additions, or any other capture file

def parse_int_prefix(s):
    m = re.match(r"\s*(\d+)", s)
    return int(m.group(1)) if m else None

def decide(survived, confidence):
    # confidence already normalized to high|medium|low|None
    if survived is None:
        return ("HOLD", "no parseable Survived count")
    if survived <= 1:
        return ("HOLD", "insufficient validation (Survived 0-1)")
    # survived >= 2
    if confidence == "high":
        return ("PROMOTE", "Survived 2+ / high -> promote at declared severity")
    if confidence == "medium":
        return ("PROMOTE_CAP_MAJOR", "Survived 2+ / medium -> promote capped at major")
    if confidence == "low":
        if survived >= 5:
            return ("PRIORITY_ESCALATION", "Survived 5+ / low -> promote at minor + immediate detection refinement")
        return ("PROMOTE_CAP_MINOR", "Survived 2+ / low -> promote capped at minor + flag detection refinement")
    return ("HOLD", "unknown/missing Confidence")

def split_entries(text):
    """Split a capture file into entries on level-2 '## ' headers (not '###', not '#')."""
    lines = text.splitlines()
    entries = []
    cur = None
    for ln in lines:
        if re.match(r"^##\s+\S", ln) and not ln.startswith("###"):
            if cur is not None:
                entries.append(cur)
            cur = {"header": ln[2:].strip(), "body": [ln]}
        elif cur is not None:
            cur["body"].append(ln)
    if cur is not None:
        entries.append(cur)
    return entries

def field(body_text, label):
    # Match  **Label:** value   (value = rest of that line)
    m = re.search(r"\*\*" + re.escape(label) + r":\*\*\s*(.*)", body_text)
    return m.group(1).strip() if m else None

decisions = []
parsed_any = False

for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        decisions.append({"file": path, "error": "file not found"})
        continue

    role = role_for(path)
    for e in split_entries(text):
        header = e["header"]
        body_text = "\n".join(e["body"])

        # Skip the file's own title-ish sections that carry no tracking fields
        survived_raw = field(body_text, "Survived")
        confidence_raw = field(body_text, "Confidence")

        # ─── SKIP: defended (the 1A interplay) ───────────────────────────
        # Triggers: a ⛔ DO NOT PROMOTE banner anywhere in the entry, OR Survived == N/A.
        defended = ("⛔" in body_text) or ("DO NOT PROMOTE" in body_text)
        if survived_raw is not None and re.search(r"\bN/?A\b", survived_raw, re.IGNORECASE):
            defended = True

        parsed_any = True

        if role == "loosen":
            decisions.append({
                "file": os.path.basename(path),
                "header": header,
                "bucket": "false-positive",
                "decision": "LOOSEN",
                "reason": "false-positive entry drives rubric loosening, not promotion (rubric-edit-process.md §4)",
            })
            continue

        if defended:
            decisions.append({
                "file": os.path.basename(path),
                "header": header,
                "survived": survived_raw,
                "confidence": confidence_raw,
                "decision": "SKIP",
                "reason": "DEFENDED (DO NOT PROMOTE banner / Survived: N/A); never promote a defended finding (1A interplay)",
            })
            continue

        survived = parse_int_prefix(survived_raw) if survived_raw is not None else None
        confidence = None
        if confidence_raw:
            cw = confidence_raw.split()[0].lower() if confidence_raw.split() else ""
            if cw in ("high", "medium", "low"):
                confidence = cw

        decision, reason = decide(survived, confidence)
        decisions.append({
            "file": os.path.basename(path),
            "header": header,
            "survived": survived,
            "confidence": confidence,
            "decision": decision,
            "reason": reason,
        })

# ensure_ascii=True (default): escape any non-ASCII (e.g. the U+26D4 banner that may
# appear in a parsed entry header) to \uXXXX so stdout is ASCII-safe regardless of the
# platform's console encoding (Windows cp1252 cannot encode such chars and would crash).
print(json.dumps(decisions, indent=2))
sys.exit(0 if parsed_any else 1)
PYTHON_SCRIPT
rc=$?
exit $rc

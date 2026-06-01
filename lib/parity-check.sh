#!/usr/bin/env bash
# Stack-neutral behavior-spec parity comparison engine.
# Compares a BASELINE behavior-spec.json against a CURRENT behavior-spec.json
# and reports behavioral drift.
#
# Usage: parity-check.sh <baseline.json> <current.json>
#
# Output: JSON parity report to stdout. Exit codes:
#   0 = clean (no blocking violations)
#   1 = advisory violations only (warnings, non-blocking)
#   2 = blocking violations (missing or changed high-confidence behaviors)
#
# The engine diffs by canonical-id → observable. It categorizes each diff:
#   MISSING  — id in baseline, absent in current (dropped behavior)
#   CHANGED  — same id, different observable values
#   ADDED    — id in current, not in baseline (new behavior, informational)
#
# Severity:
#   high-confidence behaviors → BLOCKING (exit 2)
#   inferred-confidence behaviors → ADVISORY (exit 1)
#   ADDED behaviors are always informational (exit 0)

set -euo pipefail

BASELINE="${1:-}"
CURRENT="${2:-}"

if [ -z "$BASELINE" ] || [ -z "$CURRENT" ]; then
  echo '{"error": "Usage: parity-check.sh <baseline.json> <current.json>"}' >&2
  exit 2
fi

if [ ! -f "$BASELINE" ]; then
  echo "{\"error\": \"Baseline not found: $BASELINE\"}" >&2
  exit 2
fi

if [ ! -f "$CURRENT" ]; then
  echo "{\"error\": \"Current not found: $CURRENT\"}" >&2
  exit 2
fi

# Detect a working Python interpreter
PYTHON_CMD=""
for py_candidate in python python3; do
  if command -v "$py_candidate" &>/dev/null; then
    if "$py_candidate" -c "pass" &>/dev/null 2>&1; then
      PYTHON_CMD="$py_candidate"
      break
    fi
  fi
done

if [ -z "$PYTHON_CMD" ]; then
  echo '{"error": "No working Python interpreter found. parity-check requires Python."}' >&2
  exit 2
fi

"$PYTHON_CMD" - "$BASELINE" "$CURRENT" <<'PYTHON_SCRIPT'
import json
import sys

def normalize_observable(obs):
    """Normalize observable for comparison — sort keys, lowercase string values for non-field keys."""
    if not isinstance(obs, dict):
        return obs
    return {k: v for k, v in sorted(obs.items())}

def is_empty_observable(obs):
    """An observable is 'empty' if it's None, not a dict, or a dict with no keys."""
    if obs is None:
        return True
    if not isinstance(obs, dict):
        return True
    return len(obs) == 0

def observables_equal(obs_a, obs_b):
    """Compare two observables. Field names are case-sensitive; other values compared as-is."""
    if not isinstance(obs_a, dict) or not isinstance(obs_b, dict):
        return obs_a == obs_b
    norm_a = normalize_observable(obs_a)
    norm_b = normalize_observable(obs_b)
    return json.dumps(norm_a, sort_keys=True) == json.dumps(norm_b, sort_keys=True)

def main():
    baseline_path = sys.argv[1]
    current_path = sys.argv[2]

    with open(baseline_path) as f:
        baseline = json.load(f)
    with open(current_path) as f:
        current = json.load(f)

    # Build id -> behavior maps
    base_map = {}
    for b in baseline.get("behaviors", []):
        bid = b.get("id", "")
        obs = b.get("observable", b.get("observables", {}))
        conf = b.get("confidence", "high")
        # Normalize confidence values agents might use
        if conf in ("definite", "certain", "explicit"):
            conf = "high"
        base_map[bid] = {"observable": obs, "confidence": conf, "category": b.get("category", "")}

    curr_map = {}
    for b in current.get("behaviors", []):
        bid = b.get("id", "")
        obs = b.get("observable", b.get("observables", {}))
        conf = b.get("confidence", "high")
        if conf in ("definite", "certain", "explicit"):
            conf = "high"
        curr_map[bid] = {"observable": obs, "confidence": conf, "category": b.get("category", "")}

    # Compute diffs
    missing = []
    changed = []
    added = []

    for bid, bdata in base_map.items():
        if bid not in curr_map:
            missing.append({
                "id": bid,
                "category": bdata["category"],
                "confidence": bdata["confidence"],
                "severity": "blocking" if bdata["confidence"] == "high" else "advisory",
                "baseline_observable": bdata["observable"]
            })
        else:
            cdata = curr_map[bid]
            if not observables_equal(bdata["observable"], cdata["observable"]):
                # If one side has an empty observable, the comparison is meaningless —
                # this is a spec-quality issue (extraction didn't populate it), not a
                # proven behavior change. Downgrade to advisory ("uncomparable").
                if is_empty_observable(bdata["observable"]) or is_empty_observable(cdata["observable"]):
                    severity = "advisory"
                    reason = "uncomparable"
                else:
                    severity = "blocking" if bdata["confidence"] == "high" else "advisory"
                    reason = "observable_differs"
                changed.append({
                    "id": bid,
                    "category": bdata["category"],
                    "confidence": bdata["confidence"],
                    "severity": severity,
                    "reason": reason,
                    "baseline_observable": bdata["observable"],
                    "current_observable": cdata["observable"]
                })

    for bid, cdata in curr_map.items():
        if bid not in base_map:
            added.append({
                "id": bid,
                "category": cdata["category"],
                "confidence": cdata["confidence"],
                "severity": "informational",
                "current_observable": cdata["observable"]
            })

    # Determine verdict
    blocking_count = sum(1 for x in missing + changed if x["severity"] == "blocking")
    advisory_count = sum(1 for x in missing + changed if x["severity"] == "advisory")

    if blocking_count > 0:
        verdict = "VIOLATIONS"
        exit_code = 2
    elif advisory_count > 0:
        verdict = "ADVISORY"
        exit_code = 1
    else:
        verdict = "CLEAN"
        exit_code = 0

    report = {
        "verdict": verdict,
        "baseline": baseline_path,
        "current": current_path,
        "baseline_behaviors": len(base_map),
        "current_behaviors": len(curr_map),
        "summary": {
            "missing": len(missing),
            "changed": len(changed),
            "added": len(added),
            "blocking": blocking_count,
            "advisory": advisory_count
        },
        "missing": missing,
        "changed": changed,
        "added": added
    }

    print(json.dumps(report, indent=2))
    sys.exit(exit_code)

if __name__ == "__main__":
    main()
PYTHON_SCRIPT

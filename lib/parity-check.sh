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

    # Defensive canonicalization net (backstop for the spec-analyst id rules).
    # The DURABLE fix lives in agents/spec-analyst.md (deterministic id derivation);
    # this normalizes residual cross-extraction noise so it does not surface as phantom
    # MISSING+ADDED. It is conservative: it only strips a leading slash from endpoint
    # ids/routes, which is unambiguous and cannot merge two genuinely-distinct behaviors.
    def canonicalize_id(bid):
        # endpoint ids: strip a leading slash in the route segment so
        # 'wire_contract:endpoint:POST:/ivr/pnr/x' == '...:POST:ivr/pnr/x'
        if ":endpoint:" in bid:
            head, _, route = bid.partition(":endpoint:")
            # route is '<METHOD>:<path>' — strip a leading slash on the path only
            method, sep, path = route.partition(":")
            if sep:
                path = path[1:] if path.startswith("/") else path
                return head + ":endpoint:" + method + ":" + path
        return bid

    # Build id -> behavior maps
    base_map = {}
    for b in baseline.get("behaviors", []):
        bid = canonicalize_id(b.get("id", ""))
        obs = b.get("observable", b.get("observables", {}))
        conf = b.get("confidence", "high")
        # Normalize confidence values agents might use
        if conf in ("definite", "certain", "explicit"):
            conf = "high"
        base_map[bid] = {"observable": obs, "confidence": conf, "category": b.get("category", "")}

    curr_map = {}
    for b in current.get("behaviors", []):
        bid = canonicalize_id(b.get("id", ""))
        obs = b.get("observable", b.get("observables", {}))
        conf = b.get("confidence", "high")
        if conf in ("definite", "certain", "explicit"):
            conf = "high"
        curr_map[bid] = {"observable": obs, "confidence": conf, "category": b.get("category", "")}

    # Category tier assignment.
    # Blocking tier: categories whose extraction completeness is proven at 5/5
    # (zero false negatives across 5 independent blind runs on both sides).
    # Advisory tier: categories where extraction is intermittent — violations are
    # real signals but may also reflect extraction gaps, so they warn (not block).
    #
    # Tier evidence (measured 2026-06-01, v3 iteration with tightened prompt):
    #   result_code:      BLOCKING — grep-anchored, deterministic (5/5 both sides)
    #   wire_contract:    BLOCKING — declaration-anchored, deterministic (5/5 both sides)
    #   side_effect:      BLOCKING — 5/5 legacy, 5/5 migrated (anti-dead-code-exclusion rule)
    #   state_transition: BLOCKING — 5/5 legacy, 5/5 migrated (distinct-create-procs rule)
    #   error_path:       ADVISORY — 5/5 legacy, 3/5 migrated (middleware auth path naming
    #                     variance causes intermittent misses on migrated side)
    #
    # Implementation: since parity compares legacy (baseline) vs migrated (current),
    # a MISSING behavior means it was in the baseline but not in current. If the
    # baseline category is blocking-tier, the MISSING is blocking. If the current
    # category is advisory-tier, a CHANGED entry where the current side might have
    # extraction gaps is downgraded to advisory.
    #
    # error_path remains advisory because migrated-side extraction completeness is
    # not guaranteed (3/5) — violations are real signals but may also reflect
    # extraction gaps. Manual review recommended for error_path findings.
    BLOCKING_CATEGORIES = {"result_code", "wire_contract", "side_effect", "state_transition"}
    ADVISORY_CATEGORIES = {"error_path"}

    def compute_severity(category, confidence):
        """Determine severity based on category tier and confidence."""
        if category in BLOCKING_CATEGORIES:
            return "blocking" if confidence == "high" else "advisory"
        # Advisory-tier categories never block, regardless of confidence
        return "advisory"

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
                "severity": compute_severity(bdata["category"], bdata["confidence"]),
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
                    severity = compute_severity(bdata["category"], bdata["confidence"])
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

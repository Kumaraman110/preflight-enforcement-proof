#!/usr/bin/env bash
# spec-divergence-semantic-poc.sh — POC#2 (the FIXED metric). Aggregates BLIND AGENT-JUDGE verdicts into a
# SEMANTIC divergence score for a set of independently-generated task interpretations.
#
# ┌──────────────────────────────────────────────────────────────────────────────────────────────┐
# │ POC ONLY. Builds on commit 1880bb2, which FALSIFIED the cheap token-Jaccard metric (it conflated │
# │ lexical verbosity with semantic disagreement). NOT wired into scaffold/migrate, no Phase 0, no    │
# │ gate. Tests whether a SEMANTIC measure separates vague from specified where lexical did not.       │
# └──────────────────────────────────────────────────────────────────────────────────────────────┘
#
# WHY agent-judges (approach b), not embeddings (approach a): no embedding mechanism is cleanly available
# in this environment (no sentence-transformers / numpy / embedding API key — checked). So semantic
# agreement is measured by INDEPENDENT BLIND JUDGES: each judge is given ONLY the interpretations (NOT the
# original prompt — so it cannot know whether the prompt was vague or specified), and scores meaning-level
# agreement per axis (scope / surfaces / behavior), explicitly told to ignore wording/verbosity. Multiple
# judges per set; THIS script aggregates their verdicts DETERMINISTICALLY. The score is therefore SEMANTIC
# (meaning-level) + COMPUTED (from the judge verdicts, deterministic aggregation) + INDEPENDENT (judges are
# not the interpreters) + BLIND (judges never see the prompt). It is NOT the working agent rating its own
# confidence — that distinction is the whole point.
#
# INPUT: a JSON file: {"judgments": [ {scope_agreement, surfaces_agreement, behavior_agreement,
#        overall_divergence_0to1, ...}, ... ]}  (>= 1 judge verdict; more = less single-judge noise).
#
# AGGREGATION (deterministic):
#   - Map each axis-agreement enum to a number: full-agreement=0.0, minor-variation=0.5, material-fork=1.0.
#   - per-judge axis-score = mean of the three axis numbers.
#   - judge_score = mean(per-judge axis-score, the judge's own overall_divergence_0to1)   # blends the
#     structured per-axis read with the judge's holistic read.
#   - SET SCORE = mean(judge_score) across judges, in [0,1]. Higher = more semantic divergence.
#   Also reports the median and the per-judge spread (noise visibility).
#
# Usage:
#   bash lib/spec-divergence-semantic-poc.sh <judgments.json>            # score + breakdown
#   bash lib/spec-divergence-semantic-poc.sh <judgments.json> --score    # just the number (0..1)
#
# Exit: 0 = scored OK · 2 = usage / parse error / zero judgments.

set -uo pipefail

IN="${1:-}"
MODE="${2:-full}"
if [ -z "$IN" ]; then
  echo "Usage: $0 <judgments.json> [--score]" >&2
  exit 2
fi
[ -f "$IN" ] || { echo "ERROR: judgments file not found: $IN" >&2; exit 2; }

PYTHON_CMD=""
for c in python3 python; do
  if command -v "$c" &>/dev/null && "$c" -c "pass" &>/dev/null 2>&1; then PYTHON_CMD="$c"; break; fi
done
[ -n "$PYTHON_CMD" ] || { echo "ERROR: needs a working python interpreter." >&2; exit 2; }

MODE="$MODE" "$PYTHON_CMD" - "$IN" <<'PYEOF'
import json, os, sys, statistics

mode = os.environ.get("MODE", "full")
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"ERROR: could not parse JSON: {e}", file=sys.stderr); sys.exit(2)

judgments = data.get("judgments", [])
if not isinstance(judgments, list) or len(judgments) < 1:
    print("ERROR: need >= 1 judge verdict", file=sys.stderr); sys.exit(2)

ENUM = {"full-agreement": 0.0, "minor-variation": 0.5, "material-fork": 1.0}
AXES = ["scope_agreement", "surfaces_agreement", "behavior_agreement"]

def clamp01(x):
    try: x = float(x)
    except (TypeError, ValueError): return None
    return max(0.0, min(1.0, x))

judge_scores = []
for jv in judgments:
    axis_nums = [ENUM.get(jv.get(a), None) for a in AXES]
    axis_nums = [a for a in axis_nums if a is not None]
    axis_mean = statistics.mean(axis_nums) if axis_nums else None
    overall = clamp01(jv.get("overall_divergence_0to1"))
    # Blend the structured per-axis read with the judge's holistic number; use whichever is present.
    parts = [p for p in (axis_mean, overall) if p is not None]
    if parts:
        judge_scores.append(statistics.mean(parts))

if not judge_scores:
    print("ERROR: no usable judge verdicts (missing both axis enums and overall score)", file=sys.stderr)
    sys.exit(2)

set_score = statistics.mean(judge_scores)

if mode == "--score":
    print(f"{set_score:.4f}")
    sys.exit(0)

print(f"judges: {len(judge_scores)}")
print(f"SEMANTIC DIVERGENCE: {set_score:.4f}   (0 = same task, 1 = materially different tasks)")
print(f"  per-judge scores: {[round(s,3) for s in judge_scores]}")
print(f"  median: {statistics.median(judge_scores):.4f}   spread(max-min): {max(judge_scores)-min(judge_scores):.4f}")
sys.exit(0)
PYEOF
RC=$?
exit $RC

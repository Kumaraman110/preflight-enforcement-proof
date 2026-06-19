#!/usr/bin/env bash
# spec-divergence.sh — the MECHANICAL CORE of the spec-divergence engine (Issues 1+2+3 unified).
#
# Productionizes the two POCs:
#   - POC#1 (commit 1880bb2) FALSIFIED token-Jaccard divergence (it conflated lexical verbosity with
#     semantic disagreement). Do NOT use token overlap. This engine is SEMANTIC.
#   - POC#2 (commit 5360379) VERIFIED semantic divergence via BLIND agent-judges: judges see ONLY the
#     interpretations, never the prompt, so they score meaning-agreement, not their own confidence. That
#     blindness is the integrity-critical property that makes the score an INDEPENDENT anchor the working
#     agent cannot mint. PRESERVED here.
#
# WHAT IS MECHANICAL (this file) vs PROMPT-LEVEL (the skill orchestration):
#   The generation of N blind interpretations and the M blind judgments are AGENT DISPATCHES — a bash lib
#   cannot spawn sub-agents, so those are performed by the orchestrating skill (Agent tool), exactly like
#   migrate dispatches discovery-analyst/spec-analyst. THIS lib provides the deterministic, mechanical,
#   integrity-critical pieces around those dispatches:
#     build-judge-brief : strip the prompt + emit ONLY the interpretations for the judges (enforces
#                         blindness MECHANICALLY — a judge physically cannot see the prompt).
#     score             : aggregate judge verdicts into a divergence score + per-axis breakdown (POC#2).
#     decide            : compare score to the ADVISORY threshold -> ELICIT or PROCEED (advisory, NOT a
#                         hard block — the threshold is proven only at n=5; see THRESHOLD below).
#     questions         : from the per-axis breakdown, emit targeted clarifying questions, worst axis first.
#     write-elicited    : write the pinned spec to .preflight/<svc>/spec-elicited.md (the artifact the
#                         Behavioral-Contract / design gate consumes).
#   The HONESTY LABEL: detection+scoring is mechanical; the decision is ADVISORY (elicits, does not block).
#
# THE ADVISORY THRESHOLD (do not overstate): default 0.30. POC#2 measured a specified-ceiling of ~0.13
# across n=5 pairs, so 0.30 has margin — but n=5 is NOT enough to make this a HARD GATE. So HIGH divergence
# ELICITS (asks questions); it does NOT hard-block the run. Promotion to a hard gate is a SEPARATE step
# after calibration at larger n (same advisory->blocking pattern as the Tier-2 rubric-source-check / CI).
# Override via env PREFLIGHT_SPEC_DIVERGENCE_THRESHOLD or arg.
#
# Usage:
#   bash lib/spec-divergence.sh build-judge-brief <interpretations.json>
#       -> emits the judge brief to stdout: ONLY the interpretations (prompt stripped). Feed to blind judges.
#   bash lib/spec-divergence.sh score <judgments.json> [--threshold N]
#       -> prints the divergence score, per-axis breakdown, and the ADVISORY decision (ELICIT/PROCEED).
#   bash lib/spec-divergence.sh decision <judgments.json> [--threshold N]
#       -> prints ONLY: ELICIT or PROCEED  (for the skill to branch on).
#   bash lib/spec-divergence.sh questions <judgments.json>
#       -> emits targeted clarifying questions for the forked axes, worst-divergence axis first.
#   bash lib/spec-divergence.sh write-elicited <service> <pinned-spec.md> [repo-root]
#       -> writes .preflight/<service>/spec-elicited.md (the committed pinned-spec artifact).
#
# Exit: 0 = ok · 2 = usage / parse error.

set -uo pipefail

DEFAULT_THRESHOLD="${PREFLIGHT_SPEC_DIVERGENCE_THRESHOLD:-0.30}"

SUB="${1:-}"
[ -n "$SUB" ] || { echo "Usage: $0 <build-judge-brief|score|decision|questions|write-elicited> ..." >&2; exit 2; }
shift || true

PYTHON_CMD=""
for c in python3 python; do
  if command -v "$c" &>/dev/null && "$c" -c "pass" &>/dev/null 2>&1; then PYTHON_CMD="$c"; break; fi
done
[ -n "$PYTHON_CMD" ] || { echo "ERROR: spec-divergence needs a working python interpreter." >&2; exit 2; }

# ── Parse an optional --threshold N out of the args ──
THRESHOLD="$DEFAULT_THRESHOLD"
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --threshold) THRESHOLD="${2:-$DEFAULT_THRESHOLD}"; shift 2 || shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

case "$SUB" in
  build-judge-brief)
    # INTEGRITY-CRITICAL: the judge brief contains ONLY the interpretations — the original prompt is never
    # included, so a judge cannot infer vague-vs-specified and must score meaning-agreement. This MECHANICALLY
    # enforces the blindness POC#2 proved is required. (If the prompt leaked in, it would become
    # self-assessment — the failure mode.) We also strip any stray 'prompt'/'request' top-level key defensively.
    IN="${ARGS[0]:-}"; [ -f "$IN" ] || { echo "Usage: $0 build-judge-brief <interpretations.json>" >&2; exit 2; }
    "$PYTHON_CMD" - "$IN" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print(f"ERROR: parse: {e}", file=sys.stderr); sys.exit(2)
interps = d.get("interpretations", [])
if not isinstance(interps, list) or len(interps) < 2:
    print("ERROR: need >= 2 interpretations to judge", file=sys.stderr); sys.exit(2)
# Emit ONLY the interpretations. Defensive: drop any field that could leak the original request.
LEAK = {"prompt", "request", "task_request", "original_prompt", "args", "arguments"}
clean = []
for it in interps:
    if isinstance(it, dict):
        clean.append({k: v for k, v in it.items() if k.lower() not in LEAK})
    else:
        clean.append(it)
out = {
  "_blind_judge_brief": "These are independent interpretations of the SAME task. The original request is "
                        "deliberately withheld. Judge whether they AGREE on MEANING (ignore wording).",
  "interpretations": clean,
}
print(json.dumps(out, indent=1))
PYEOF
    ;;

  score|decision)
    IN="${ARGS[0]:-}"; [ -f "$IN" ] || { echo "Usage: $0 $SUB <judgments.json> [--threshold N]" >&2; exit 2; }
    SUB="$SUB" THRESHOLD="$THRESHOLD" "$PYTHON_CMD" - "$IN" <<'PYEOF'
import json, os, sys, statistics
sub = os.environ["SUB"]; threshold = float(os.environ["THRESHOLD"])
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print(f"ERROR: parse: {e}", file=sys.stderr); sys.exit(2)
judgments = d.get("judgments", [])
if not isinstance(judgments, list) or len(judgments) < 1:
    print("ERROR: need >= 1 judge verdict", file=sys.stderr); sys.exit(2)

ENUM = {"full-agreement": 0.0, "minor-variation": 0.5, "material-fork": 1.0}
AXES = ["scope_agreement", "surfaces_agreement", "behavior_agreement"]
def clamp01(x):
    try: return max(0.0, min(1.0, float(x)))
    except (TypeError, ValueError): return None

judge_scores = []; per_axis_acc = {a: [] for a in AXES}
for jv in judgments:
    nums = []
    for a in AXES:
        v = ENUM.get(jv.get(a))
        if v is not None: nums.append(v); per_axis_acc[a].append(v)
    axis_mean = statistics.mean(nums) if nums else None
    overall = clamp01(jv.get("overall_divergence_0to1"))
    parts = [p for p in (axis_mean, overall) if p is not None]
    if parts: judge_scores.append(statistics.mean(parts))
if not judge_scores:
    print("ERROR: no usable judge verdicts", file=sys.stderr); sys.exit(2)

score = statistics.mean(judge_scores)
per_axis = {a: (statistics.mean(v) if v else 0.0) for a, v in per_axis_acc.items()}
decision = "ELICIT" if score > threshold else "PROCEED"

if sub == "decision":
    print(decision); sys.exit(0)

print(f"SEMANTIC DIVERGENCE: {score:.4f}   (threshold {threshold:.2f}, ADVISORY)")
print(f"DECISION: {decision}   ({'ask clarifying questions on the forked axes' if decision=='ELICIT' else 'specified enough to proceed (advisory)'})")
print(f"judges: {len(judge_scores)}   median: {statistics.median(judge_scores):.4f}   spread: {max(judge_scores)-min(judge_scores):.4f}")
print("per-axis divergence (worst first):")
for a in sorted(per_axis, key=lambda k: -per_axis[k]):
    flag = "  <- FORKED" if per_axis[a] >= 0.5 else ""
    print(f"  {a:22s} {per_axis[a]:.4f}{flag}")
sys.exit(0)
PYEOF
    ;;

  questions)
    # From the per-axis judge verdicts, emit targeted clarifying questions on the FORKED axes, worst first.
    # The question text is a fixed template per axis (mechanical) — the skill fills service specifics.
    IN="${ARGS[0]:-}"; [ -f "$IN" ] || { echo "Usage: $0 questions <judgments.json>" >&2; exit 2; }
    "$PYTHON_CMD" - "$IN" <<'PYEOF'
import json, sys, statistics
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print(f"ERROR: parse: {e}", file=sys.stderr); sys.exit(2)
judgments = d.get("judgments", [])
ENUM = {"full-agreement": 0.0, "minor-variation": 0.5, "material-fork": 1.0}
AXES = {
  "scope_agreement":    "SCOPE: the interpretations disagree on what is IN vs OUT of scope. What exactly is in scope, and what is explicitly NOT?",
  "surfaces_agreement": "SURFACES: they disagree on which components/surfaces are touched. Which surfaces (controller, data-access, wire-format, auth, downstream, cache, infra) are in scope?",
  "behavior_agreement": "BEHAVIOR: they disagree on the core behavior. What is the one core behavior to implement, and what must be preserved exactly?",
}
acc = {a: [] for a in AXES}
for jv in judgments:
    for a in AXES:
        v = ENUM.get(jv.get(a))
        if v is not None: acc[a].append(v)
ranked = sorted(AXES, key=lambda a: -(statistics.mean(acc[a]) if acc[a] else 0.0))
asked = 0
for a in ranked:
    div = statistics.mean(acc[a]) if acc[a] else 0.0
    if div >= 0.5:   # only ask on genuinely-forked axes
        asked += 1
        print(f"Q{asked} (axis divergence {div:.2f}): {AXES[a]}")
if asked == 0:
    print("(no axis forked >= 0.5 — no targeted questions; divergence is below the elicitation bar)")
PYEOF
    ;;

  write-elicited)
    # Write the pinned-spec artifact the design/Behavioral-Contract gate consumes.
    SVC="${ARGS[0]:-}"; SPEC="${ARGS[1]:-}"; ROOT="${ARGS[2]:-}"
    [ -n "$SVC" ] && [ -f "$SPEC" ] || { echo "Usage: $0 write-elicited <service> <pinned-spec.md> [repo-root]" >&2; exit 2; }
    [ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    DEST_DIR="$ROOT/.preflight/$SVC"
    mkdir -p "$DEST_DIR"
    DEST="$DEST_DIR/spec-elicited.md"
    {
      echo "# Pinned Spec (spec-divergence elicited) — $SVC"
      echo ""
      echo "<!-- Produced by lib/spec-divergence.sh after the spec-divergence engine elicited and pinned"
      echo "     the under-specified axes. This is the input the design / Behavioral-Contract gate consumes."
      echo "     ADVISORY engine: divergence was reduced below the advisory threshold OR the human confirmed. -->"
      echo ""
      cat "$SPEC"
    } > "$DEST"
    echo "wrote $DEST"
    ;;

  *)
    echo "Usage: $0 <build-judge-brief|score|decision|questions|write-elicited> ..." >&2
    exit 2
    ;;
esac

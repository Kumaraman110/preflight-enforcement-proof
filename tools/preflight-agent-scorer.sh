#!/usr/bin/env bash
# preflight-agent-scorer.sh — INDEPENDENT scorer of the orchestrating agent's JUDGMENT.
#
# Judges what the agent FLAGGED / CLAIMED / DECIDED by comparing each recorded judgment
# against ground truth, and REPORTS a track record to a human. Spec: lib/agent-scorer.md.
# Design source: .release-audit/MEMORY-DESIGN.md G1 (independent observer over append-only artifacts).
#
# ── TWO NON-NEGOTIABLE CONSTRAINTS ───────────────────────────────────────────
#   1. INDEPENDENCE: this is a SEPARATE evaluator over RECORDED artifacts — not the judged
#      agent introspecting. The rejudgment source (3) runs as a separable judge (SCORER_JUDGE_CMD);
#      the default is a deterministic rule-based re-judger that re-decides from the recorded inputs
#      ONLY (never the agent's reasoning trace), so it re-judges rather than rubber-stamps.
#   2. NEVER FEEDS A GATE: this tool OBSERVES and REPORTS. It writes ONLY to .preflight/track-record/
#      and stdout. It references NO gate, writes NO .preflight/gate/ sentinel, calls NO
#      write-gate-evidence, and is registered in NO hook. A track record must never influence a
#      gate's allow/block/certify decision (MEMORY-DESIGN.md FORBIDDEN map F1-F7). Verified
#      structurally by tests/behavioral/agent-scorer-test.sh.
#
# Usage:
#   bash tools/preflight-agent-scorer.sh --run <run-id> [--source rejudgment|review|reality]
#       [--decisions <path>] [--adjudications <dir>] [--metrics <path>] [--out <dir>] [--quiet]
#
# Exit: 0 = scored (ANY category mix; finding OVERCLAIMs is the tool WORKING) · 2 = usage/could-not-run.
# This tool NEVER exits non-zero because the agent scored badly. It is a reporter, not a gate.
#
# HONESTY LABEL: the built-in rejudgment judge is a DETERMINISTIC rule-based re-evaluator (offline,
# reproducible) — judgment-vs-judgment, the SOFTEST of the three sources, labeled as such in output.
# reality/review sources are stronger but need data (n=2 / per-finding review outcomes).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RUN_ID=""
SOURCE="rejudgment"          # default: the only source that needs no historical data
DECISIONS_PATH=""
ADJUDICATIONS_DIR=""
METRICS_PATH=""
OUT_DIR=""
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN_ID="$2"; shift 2 ;;
    --source) SOURCE="$2"; shift 2 ;;
    --decisions) DECISIONS_PATH="$2"; shift 2 ;;
    --adjudications) ADJUDICATIONS_DIR="$2"; shift 2 ;;
    --metrics) METRICS_PATH="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help)
      echo "Usage: $0 --run <run-id> [--source rejudgment|review|reality]"
      echo "  Scores the orchestrating agent's recorded judgments against ground truth."
      echo "  Reports to a human; NEVER feeds a gate. Spec: lib/agent-scorer.md."
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$RUN_ID" ]; then
  echo "ERROR: --run <run-id> is required." >&2
  exit 2
fi

case "$SOURCE" in
  rejudgment|review|reality) ;;
  *) echo "ERROR: --source must be rejudgment | review | reality (got '$SOURCE')." >&2; exit 2 ;;
esac

# Default artifact locations (overridable for tests / alternate layouts).
PF="${PREFLIGHT_DIR:-$REPO_ROOT/.preflight}"
[ -n "$DECISIONS_PATH" ]    || DECISIONS_PATH="$PF/decisions/${RUN_ID}.jsonl"
[ -n "$ADJUDICATIONS_DIR" ] || ADJUDICATIONS_DIR="$PF/adjudications"
[ -n "$METRICS_PATH" ]      || METRICS_PATH="$PF/metrics.json"
[ -n "$OUT_DIR" ]           || OUT_DIR="$PF/track-record"

# ── Pick a Python interpreter (handles Windows Store stubs), like other preflight tools ──
PYTHON_CMD=""
for c in python3 python; do
  if command -v "$c" &>/dev/null && "$c" -c "pass" &>/dev/null 2>&1; then PYTHON_CMD="$c"; break; fi
done
if [ -z "$PYTHON_CMD" ]; then
  echo "ERROR: no working python interpreter found (scorer needs python for JSON scoring)." >&2
  exit 2
fi

# ── The separable rejudgment judge (source 3). DEFAULT = built-in deterministic re-judger. ──
# A custom judge is any command that reads one judgment JSON object on stdin and writes a verdict
# JSON {"holds": true|false, "basis": "..."} on stdout. This keeps source 3 INDEPENDENT and pluggable
# (a different model than the one that produced the judgment can be slotted in here).
SCORER_JUDGE_CMD="${SCORER_JUDGE_CMD:-}"

OUT_DIR="$OUT_DIR" RUN_ID="$RUN_ID" SOURCE="$SOURCE" QUIET="$QUIET" \
DECISIONS_PATH="$DECISIONS_PATH" ADJUDICATIONS_DIR="$ADJUDICATIONS_DIR" METRICS_PATH="$METRICS_PATH" \
SCORER_JUDGE_CMD="$SCORER_JUDGE_CMD" \
"$PYTHON_CMD" - <<'PYEOF'
import os, sys, json, glob, datetime, subprocess

RUN_ID   = os.environ["RUN_ID"]
SOURCE   = os.environ["SOURCE"]
QUIET    = os.environ.get("QUIET", "0") == "1"
DEC_PATH = os.environ["DECISIONS_PATH"]
ADJ_DIR  = os.environ["ADJUDICATIONS_DIR"]
MET_PATH = os.environ["METRICS_PATH"]
OUT_DIR  = os.environ["OUT_DIR"]
JUDGE    = os.environ.get("SCORER_JUDGE_CMD", "").strip()

SCORER_VERSION = "1"

# Windows consoles default to cp1252, which cannot encode box-drawing / warning glyphs and would
# crash the report (observed). Force UTF-8 where supported; fall back to errors='replace' so a
# narrow console degrades a glyph rather than crashing the scorer. (Same class of cp1252 hazard
# lib/rubric-promotion-evaluator.sh guards with ensure_ascii.)
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

def log(*a):
    if not QUIET:
        print(*a)

# ── Load recorded JUDGMENTS (Part A artifacts) ───────────────────────────────
judgments = []   # each: {ref, kind, payload}

# CLAIM judgments — decision-log JSONL (append-only). May be absent (emission pending).
if os.path.isfile(DEC_PATH):
    with open(DEC_PATH, "r", encoding="utf-8") as f:
        for i, line in enumerate(f):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                # A malformed decision line is itself worth surfacing, not silently dropped.
                judgments.append({"ref": f"decisions/{RUN_ID}.jsonl#line{i+1}",
                                  "kind": "CLAIM", "payload": None, "malformed": line[:120]})
                continue
            judgments.append({"ref": f"decisions/{RUN_ID}.jsonl#{obj.get('id', 'line'+str(i+1))}",
                              "kind": obj.get("kind", "CLAIM"), "payload": obj})

# VERDICT judgments — adjudication records (exist today; gate-validated immutable artifacts).
for path in sorted(glob.glob(os.path.join(ADJ_DIR, "*.json"))):
    try:
        with open(path, "r", encoding="utf-8") as f:
            rec = json.load(f)
    except (OSError, json.JSONDecodeError):
        continue
    base = os.path.basename(path)
    for adj in (rec.get("adjudications") or []):
        cid = adj.get("commentId", "?")
        judgments.append({"ref": f"adjudications/{base}#{cid}", "kind": "VERDICT", "payload": adj})

# RUN-OUTCOME judgments — metrics runs (exist today).
if os.path.isfile(MET_PATH):
    try:
        with open(MET_PATH, "r", encoding="utf-8") as f:
            met = json.load(f)
        for idx, run in enumerate(met.get("runs", [])):
            judgments.append({"ref": f"metrics.json#runs[{idx}]", "kind": "RUN-OUTCOME", "payload": run})
    except (OSError, json.JSONDecodeError):
        pass

# ── The built-in DETERMINISTIC re-judger (source 3 default) ──────────────────
# Re-decides whether a recorded judgment HOLDS, from the recorded inputs ONLY.
# It does NOT read the agent's reasoning — it independently checks the claim against the
# evidence the claim itself names (checkCommand output if recorded, or structural rules).
def builtin_rejudge(j):
    p = j.get("payload")
    if p is None:
        return {"holds": False, "basis": "judgment record is malformed/unparseable — cannot stand"}
    kind = j["kind"]

    if kind in ("CLAIM",):
        ct = p.get("claimType", "")
        asserted = str(p.get("assertedStatus", "")).upper()
        # If the claim recorded the check output that would confirm it, re-judge against THAT.
        ev = p.get("checkEvidence")  # optional: recorded output of checkCommand at claim time
        if ev is not None:
            import re
            evs = str(ev).lower()
            # An "all green / clear" claim must not be contradicted by its own recorded evidence.
            # Distinguish REAL failure signals from benign "0 fail / 0 failed / 0 errors" phrasing:
            # a green run legitimately says "0 failed", which must NOT count as a contradiction.
            # First neutralize the zero-count idioms, THEN look for failure indicators.
            neutralized = re.sub(r"\b0\s+(failed|fail|failures|errors|dead|broken)\b", "", evs)
            failure_signals = [
                r"syntax error", r"\bdead\b", r"not found", r"\bblocked\b", r"\bbroken\b",
                r"\b[1-9][0-9]*\s+(failed|fail|failures|errors)\b",  # nonzero fail/error count
                r"\bfail(ed|ure|ures)?\b", r"\berror(s)?\b",          # bare fail/error words (post-neutralize)
            ]
            contradicted = any(re.search(sig, neutralized) for sig in failure_signals)
            green_claim = ct in ("all-green", "clear-to-cut", "count-assertion") or asserted in ("GREEN", "CLEAR")
            if green_claim and contradicted:
                return {"holds": False,
                        "basis": f"claim '{p.get('claim','?')}' asserted {asserted or ct}; recorded checkEvidence contradicts it"}
            return {"holds": True,
                    "basis": f"claim's own recorded checkEvidence is consistent with asserted {asserted or ct}"}
        # No recorded evidence: an independent judge cannot confirm a bare assertion. For a
        # high-stakes green/clear claim, unverifiable == does-not-stand (the agent asserted without
        # leaving evidence — the overclaim risk). For other claims, mark unverifiable (NONE).
        if ct in ("all-green", "clear-to-cut"):
            return {"holds": False,
                    "basis": f"'{ct}' claim has no recorded checkEvidence; an independent judge cannot confirm a bare green/clear assertion"}
        return {"holds": None, "basis": "no recorded evidence; independent re-judgment not possible (NONE)"}

    if kind == "VERDICT":
        # A DEFENDED verdict must carry a concrete citation (mirrors adjudication-output-gate's rule).
        verdict = str(p.get("parentVerdict", ""))
        cite = str(p.get("citedEvidence", "") or "")
        if verdict in ("DEFENDED", "AMBIGUOUS-DEFENDED"):
            import re
            concrete = bool(re.search(r"\.[A-Za-z0-9]+:[0-9]+|§[0-9]+|MIGRATION_PATTERNS\.md|behavior-spec|name-contract|dependency-map\.json|legacy-db-name-contract", cite))
            if not concrete:
                return {"holds": False, "basis": f"{verdict} cites '{cite}' — not a concrete citation; an independent judge would reject the defense"}
            return {"holds": True, "basis": f"{verdict} carries a concrete citation ({cite})"}
        return {"holds": True, "basis": f"{verdict} verdict needs no legacy citation"}

    if kind == "RUN-OUTCOME":
        outcome = str(p.get("outcome", ""))
        s1 = p.get("stage1", {}) or {}
        cap = s1.get("capHit", False)
        # SUCCESS while the stage-1 loop hit its cap is an internal inconsistency a judge flags.
        if outcome == "SUCCESS" and cap:
            return {"holds": False, "basis": "outcome=SUCCESS but stage1.capHit=true — inconsistent"}
        return {"holds": True, "basis": f"outcome={outcome} consistent with recorded stage data"}

    return {"holds": None, "basis": "unknown judgment kind; cannot re-judge"}

def custom_rejudge(j):
    try:
        proc = subprocess.run(JUDGE, shell=True, input=json.dumps(j.get("payload") or {}),
                              capture_output=True, text=True, timeout=60)
        if proc.returncode != 0:
            return {"holds": None, "basis": f"custom judge exited {proc.returncode}; unscoreable"}
        v = json.loads(proc.stdout.strip())
        return {"holds": v.get("holds"), "basis": v.get("basis", "custom judge")}
    except Exception as e:
        return {"holds": None, "basis": f"custom judge failed: {e}"}

def rejudge(j):
    return custom_rejudge(j) if JUDGE else builtin_rejudge(j)

# ── Classify one judgment given a ground-truth verdict ───────────────────────
# verdict.holds: True = ground truth confirms the judgment; False = contradicts; None = unverifiable.
def classify(j, verdict):
    holds = verdict.get("holds")
    kind = j["kind"]
    if holds is None:
        return None  # unscoreable by this source — excluded from rates, reported as NONE
    if holds is True:
        return "CORRECT"
    # holds is False — the judgment did NOT stand. Which failure category?
    if kind in ("CLAIM", "RUN-OUTCOME"):
        # An assertion of done/green/clear/success that ground truth contradicts = OVERCLAIM.
        return "OVERCLAIM"
    if kind == "VERDICT":
        p = j.get("payload") or {}
        verdict_val = str(p.get("parentVerdict", ""))
        # A DEFENDED finding that doesn't stand = the agent waved through a real issue = FALSE-FLAG of
        # the defense (it flagged the code as fine when it wasn't). A FIXED that doesn't stand = MISS.
        return "FALSE-FLAG" if verdict_val.endswith("DEFENDED") else "MISS"
    return "MISS"

# ── Source availability (honest: no silent fallback) ─────────────────────────
def source_available(src):
    if src == "rejudgment":
        return True, ""   # needs no historical data
    if src == "review":
        # Needs per-finding review outcomes. Today metrics carries only aggregate counts.
        if not os.path.isfile(MET_PATH):
            return False, "review source needs metrics.json with recorded review outcomes; none found"
        return False, ("review source is MECHANISM-READY but data-pending: metrics.json carries "
                       "aggregate stage2 counts, not per-finding review outcomes. Record per-finding "
                       "review confirmation to enable review-anchored scoring.")
    if src == "reality":
        # Needs downstream-breakage truth from a later service run.
        rp = os.path.join(os.path.dirname(MET_PATH), "reality", f"{RUN_ID}.json")
        if os.path.isfile(rp):
            return True, ""
        return False, ("reality source is MECHANISM-READY but data-pending: needs a downstream outcome "
                       f"file at .preflight/reality/{RUN_ID}.json (generated after n=2). Marked 'runs after n=2'.")
    return False, "unknown source"

avail, why = source_available(SOURCE)
if not avail:
    log("═══════════════════════════════════════════════════")
    log(f"  preflight agent-scorer — run '{RUN_ID}', source '{SOURCE}'")
    log("═══════════════════════════════════════════════════")
    log(f"  SOURCE NOT AVAILABLE: {why}")
    log("  No score produced (honest: no silent fallback to a weaker source).")
    sys.exit(2)

# ── Score every judgment with the selected source ───────────────────────────
if SOURCE == "rejudgment":
    def ground_truth(j): return rejudge(j)
    GT_REF = f"rejudgment:{'custom' if JUDGE else 'builtin'}"
elif SOURCE == "reality":
    rp = os.path.join(os.path.dirname(MET_PATH), "reality", f"{RUN_ID}.json")
    with open(rp, "r", encoding="utf-8") as f:
        reality = json.load(f)   # {judgmentRef: {"holds": bool, "basis": "..."}}
    def ground_truth(j): return reality.get(j["ref"], {"holds": None, "basis": "no reality datum for this judgment"})
    GT_REF = f"reality:{os.path.basename(rp)}"
else:
    def ground_truth(j): return {"holds": None, "basis": "review data pending"}
    GT_REF = "review:pending"

scores = []
by_cat = {"CORRECT": 0, "MISS": 0, "FALSE-FLAG": 0, "OVERCLAIM": 0}
none_count = 0
oc_num = 0; oc_den = 0
oc_by_type = {}

for j in judgments:
    v = ground_truth(j)
    cat = classify(j, v)
    if cat is None:
        none_count += 1
        scores.append({"judgmentRef": j["ref"], "groundTruthRef": GT_REF, "scoredBy": SOURCE,
                       "category": "NONE", "basis": v.get("basis", "unverifiable")})
        continue
    by_cat[cat] += 1
    # Overclaim-rate denominator = CLAIM/RUN-OUTCOME judgments that WERE scoreable (holds != None).
    if j["kind"] in ("CLAIM", "RUN-OUTCOME"):
        oc_den += 1
        if cat == "OVERCLAIM":
            oc_num += 1
            ct = (j.get("payload") or {}).get("claimType", j["kind"])
            oc_by_type[ct] = oc_by_type.get(ct, 0) + 1
    scores.append({"judgmentRef": j["ref"], "groundTruthRef": GT_REF, "scoredBy": SOURCE,
                   "category": cat, "basis": v.get("basis", "")})

overclaim_rate = (oc_num / oc_den) if oc_den else None

result = {
    "scoredAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "scorerVersion": SCORER_VERSION,
    "runId": RUN_ID,
    "source": SOURCE,
    "judgmentsScored": len(judgments),
    "byCategory": by_cat,
    "unscoreable_NONE": none_count,
    "overclaimRate": ({"value": round(overclaim_rate, 4), "numerator": oc_num, "denominator": oc_den,
                       "byClaimType": oc_by_type} if overclaim_rate is not None else
                      {"value": None, "numerator": 0, "denominator": 0, "byClaimType": {},
                       "note": "no scoreable claim/run-outcome judgments under this source"}),
    "bySource": {SOURCE: len(judgments) - none_count},
    "scores": scores,
    "honestyLabel": ("rejudgment-anchored scores are judgment-vs-judgment, NOT judgment-vs-reality"
                     if SOURCE == "rejudgment" else
                     f"{SOURCE}-anchored scores"),
}

# ── Write the auditable track-record artifact (the ONLY write; advisory; never a gate path) ──
os.makedirs(OUT_DIR, exist_ok=True)
out_path = os.path.join(OUT_DIR, f"score-{RUN_ID}.json")
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(result, f, indent=2)

# ── Human-readable report to stdout ──────────────────────────────────────────
log("═══════════════════════════════════════════════════")
log(f"  preflight agent-scorer — run '{RUN_ID}'")
log(f"  source: {SOURCE}  ({result['honestyLabel']})")
log("═══════════════════════════════════════════════════")
log(f"  judgments scored: {len(judgments)}  (unscoreable/NONE: {none_count})")
log(f"  CORRECT={by_cat['CORRECT']}  MISS={by_cat['MISS']}  FALSE-FLAG={by_cat['FALSE-FLAG']}  OVERCLAIM={by_cat['OVERCLAIM']}")
if overclaim_rate is not None:
    log(f"  >> OVERCLAIM RATE: {oc_num}/{oc_den} = {round(overclaim_rate*100,1)}%  by-type={oc_by_type or '{}'}")
else:
    log("  >> OVERCLAIM RATE: n/a (no scoreable claim/run-outcome judgments)")
log("")
for s in scores:
    if s["category"] == "OVERCLAIM":
        log(f"  ⚠ OVERCLAIM  {s['judgmentRef']}")
        log(f"             basis: {s['basis']}")
for s in scores:
    if s["category"] not in ("OVERCLAIM",):
        log(f"  {s['category']:<10} {s['judgmentRef']}  ({s['basis']})")
log("")
log(f"  track record written: {out_path}")
log("  (advisory — reported to a human; this tool NEVER feeds a gate)")
sys.exit(0)
PYEOF

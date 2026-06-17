# Agent Scorer — independent scoring of the orchestrating agent's JUDGMENT

The scorer judges what the orchestrating agent **flagged, claimed, and decided** — by comparing each
recorded judgment against ground truth — and reports a track record **to a human**. It is the G1
subsystem from `.release-audit/MEMORY-DESIGN.md`: an independent observer over append-only artifacts.

> **TWO NON-NEGOTIABLE CONSTRAINTS** (the design fails if either breaks):
>
> 1. **INDEPENDENCE.** The scorer is NOT the orchestrating agent grading itself. Scoring an agent's
>    judgment with that same agent's judgment is meta-self-certification — the `verifiedAgainstSource`
>    disease one layer up. The scorer is a SEPARATE evaluator: separate invocation, reasoning over
>    RECORDED artifacts, never the judged agent introspecting. The rejudgment ground-truth source
>    (source 3) is explicitly designed to run as a separable model/prompt (`SCORER_JUDGE_CMD`).
>
> 2. **NEVER FEEDS A GATE.** The scorer OBSERVES and REPORTS. It must NEVER influence any gate's
>    allow/block/certify decision. The moment "this agent has a good track record" can affect a gate,
>    reputation-based trust has entered the safety core — FORBIDDEN (MEMORY-DESIGN.md FORBIDDEN map,
>    F1–F7). The scorer informs the HUMAN; it never informs a GATE. Enforced structurally: scorer
>    output lives ONLY under `.preflight/track-record/` and stdout; NO hook, gate, or evidence path
>    reads it. The behavioral test `agent-scorer-test.sh` asserts this (the no-gate-feed assertion).

---

## What this is NOT

- NOT a gate, NOT a hook, NOT registered in `hooks.json`. It writes no `.preflight/gate/` sentinel.
- NOT a memory store (no mem0, no vector DB, no LLM-mutated recall). It is a READ + SCORE pass over
  immutable, append-only artifacts the agent already (or will) emit. Append-only, never mutate-in-place
  (MEMORY-DESIGN.md transferable concept #3).
- NOT a single vanity number. It produces a per-judgment classification with a traceable basis, and an
  OVERCLAIM RATE — the metric that matters most for an agent that has repeatedly said "done/green/clear"
  before ground truth agreed.

---

## PART A — What gets scored (the judgment artifacts)

A "judgment" is a discrete thing the orchestrating agent produced that asserts something could later be
right or wrong. Three kinds, by where they live today:

| Judgment kind | What the agent asserted | Artifact (append-only) | Exists today? |
|---|---|---|---|
| **VERDICT** | per-finding FIXED / DEFENDED + cited evidence | `.preflight/adjudications/PR<n>-<HEAD>.json` (schema: `lib/adjudication-record.md`) | **YES** — emitted + gate-validated |
| **RUN-OUTCOME** | a whole-run result: SUCCESS / CAPPED / STUCK | `.preflight/metrics.json` `runs[].outcome` (schema: `lib/metrics.md`) | **YES** — emitted |
| **CLAIM** | a free-form assertion of state: "all GREEN", "clear to cut at SHA X", "29/29", a class-A vs class-B call | **`.preflight/decisions/<run-id>.jsonl`** (schema below) | **NO — must be emitted; FLAGGED** |

**The CLAIM gap (flagged, not faked).** The overclaim pattern this very development arc produced
repeatedly — "ran out of tool calls but said done", "clear to cut" while 4 hooks were syntactically
dead at the proposed SHA — lives ONLY in free-form prose reports today (e.g. `.release-audit/*.md`).
There is no structured, append-only artifact capturing the agent's claims at emit time. The scorer
**defines** the decision-log schema and **scores it when present**, but the orchestrator is not yet
wired to emit it on every run. That wiring is a separate integration (orchestrator/skill change),
deliberately NOT done here — emitting a fabricated history would defeat the entire point. Status:
**schema ready, emission pending orchestrator integration.**

### Decision-log schema (`.preflight/decisions/<run-id>.jsonl`, append-only, one JSON object per line)
```json
{
  "id": "claim-001",
  "head": "<full git HEAD sha when the claim was made>",
  "at": "<ISO-8601>",
  "kind": "CLAIM",
  "claim": "all behavioral suites GREEN (29/29)",
  "claimType": "all-green | clear-to-cut | count-assertion | class-call | fix-vs-defer",
  "assertedStatus": "GREEN | CLEAR | <verbatim>",
  "scope": "<what the claim covers, e.g. 'behavioral battery at HEAD abc'>",
  "checkCommand": "<the command whose output would confirm/refute this, if any>"
}
```
An optional `checkEvidence` field may record the actual output of `checkCommand` at claim time; when
present, the rejudgment source (3) scores the claim against THAT recorded evidence rather than a bare
assertion (the strongest the rejudgment source can do without re-running the world).

> **Gitignore disposition (flagged, not yet decided).** The scorer's *output* (`track-record/`) is
> advisory, regenerable runtime state and IS added to the shipped gitignore template + installer
> `REQUIRED_IGNORES` (ignored, never committed). The *input* decision-log (`decisions/`) is a
> different question: like `adjudications/`, an append-only judgment record you score later wants to
> be DURABLE/tracked, not cache — but its tracked-vs-ignored disposition is deliberately left OPEN
> until the orchestrator emission path exists (deciding it before there's a writer would be guessing).
> Until then `decisions/` is neither ignored nor emitted; the scorer reads it if present.

Append-only (`.jsonl`): a claim is never rewritten. A corrected claim is a NEW line referencing the
old `id` — you can see the agent changed its mind, which is itself scoreable. This mirrors the
adjudication record's immutability and mem0's audit-correct ADD-only discipline.

---

## PART B — The three ground-truth sources (different evidential strength, labeled)

A judgment is scored by comparing it to ground truth. The scorer accepts all three; each score states
WHICH source backed it, because they are not equally strong:

| Source | Ground truth | Strength | Status |
|---|---|---|---|
| **(1) REVIEW-OUTCOME** | what later review (Copilot/human) actually did with a flagged item | review-anchored (strong: real external signal) | **mechanism ready; data partial** — `metrics.json` carries stage2 `fixedCount`/`defendedCount` and capture buckets, but per-finding "was this flag confirmed by review" requires the review-outcome to be recorded per finding (today it's aggregate). Wired to score at the granularity the data supports; finer needs a per-finding review-outcome field. |
| **(2) EVENTUAL-REALITY** | did "fine" actually break downstream in the migration | reality-anchored (strongest: judgment-vs-reality) | **mechanism ready; data pending n=2** — needs a 2nd service run to generate downstream-breakage truth. Intake accepts an outcome file; marked "runs after n=2". |
| **(3) INDEPENDENT-REJUDGMENT** | a SEPARATE evaluator re-judges the same decision from the same recorded inputs | rejudgment-anchored (softer: judgment-vs-judgment, NOT judgment-vs-reality) | **runs today** — needs no historical data. This is the demo source. Honestly labeled as the weakest of the three: agreement with an independent judge raises/lowers confidence; it is not proof. |

**Source selection.** A judgment record is scored by whichever source(s) have data. The output names
the source per score (`scoredBy: reality | review | rejudgment`) so a reader never confuses a
reality-anchored OVERCLAIM (the agent said fine, it broke) with a rejudgment divergence (a second
judge disagreed). Multiple sources on one judgment → multiple scored lines, not a blended number.

**Independence of source 3.** The rejudgment judge is invoked via `SCORER_JUDGE_CMD` (a separable
command/model). The default built-in judge is a deterministic, rule-based re-evaluator (no LLM
required) so the demo runs offline and reproducibly; a richer judge (a different model than the one
that produced the judgment) can be plugged in without changing the scorer. The judge receives ONLY
the recorded judgment inputs — never the judged agent's reasoning trace — so it re-decides, it does
not rubber-stamp.

---

## PART C — The scoring model (honest, traceable)

Each judgment is classified into exactly one of four categories:

| Category | Meaning | Cost |
|---|---|---|
| **CORRECT** | flagged a real thing / the claim held against ground truth | none (the system working) |
| **MISS** | failed to flag a real thing that ground truth shows mattered | a defect escaped local review |
| **FALSE-FLAG** | flagged noise — ground truth shows it didn't matter | a wasted review cycle |
| **OVERCLAIM** | asserted done / clean / passing / clear when ground truth later said otherwise | **the most dangerous** — false confidence; this is the headline metric |

**OVERCLAIM RATE is first-class:** `overclaims / (claims scored against ground truth)`. Reported
prominently, broken down by `claimType` (all-green, clear-to-cut, count-assertion, …) and by
`scoredBy` source. A high overclaim rate under a *reality* or *review* source is a serious signal; the
same under *rejudgment* is softer (a second judge merely disagreed).

**Every score is traceable** (no black-box reputation number): each scored line carries
`{judgmentRef, groundTruthRef, scoredBy, category, basis}` where `judgmentRef` points to the exact
artifact+id scored and `groundTruthRef` points to the artifact that scored it. The scorer's own output
is itself an auditable append-only record under `.preflight/track-record/` — the scorer is as
auditable as the thing it scores (preflight's thesis applied to the scorer itself).

**Output shape** (`.preflight/track-record/score-<run-id>.json` + human-readable stdout):
```json
{
  "scoredAt": "<ISO-8601>",
  "scorerVersion": "1",
  "judgmentsScored": 7,
  "byCategory": { "CORRECT": 4, "MISS": 0, "FALSE-FLAG": 1, "OVERCLAIM": 2 },
  "overclaimRate": { "value": 0.40, "numerator": 2, "denominator": 5, "byClaimType": {"clear-to-cut": 1, "all-green": 1} },
  "bySource": { "reality": 0, "review": 3, "rejudgment": 4 },
  "scores": [
    { "judgmentRef": "decisions/run-x.jsonl#claim-001", "groundTruthRef": "rejudgment:builtin",
      "scoredBy": "rejudgment", "category": "OVERCLAIM",
      "basis": "claim asserted all-green at HEAD X; recorded check output showed 4 syntax-dead hooks" }
  ],
  "honestyLabel": "rejudgment-anchored scores are judgment-vs-judgment, not judgment-vs-reality"
}
```

---

## PART D — Usage

```bash
# Score a run's recorded judgments using whatever ground truth is available (default: rejudgment):
bash tools/preflight-agent-scorer.sh --run <run-id>

# Force a specific source (errors if that source's data is absent — honest, no silent fallback):
bash tools/preflight-agent-scorer.sh --run <run-id> --source rejudgment
bash tools/preflight-agent-scorer.sh --run <run-id> --source review
bash tools/preflight-agent-scorer.sh --run <run-id> --source reality

# Plug a separate-model judge for source 3 (independence): the cmd reads a judgment JSON on stdin,
# emits a verdict JSON on stdout. Default is the built-in deterministic re-judger (offline, reproducible).
SCORER_JUDGE_CMD="my-model-judge" bash tools/preflight-agent-scorer.sh --run <run-id> --source rejudgment
```

Exit codes: `0` = scored successfully (ANY category mix — finding OVERCLAIMs is the tool WORKING, not
failing); `2` = usage / could-not-run (missing run, requested source has no data). The scorer NEVER
exits non-zero "because the agent scored badly" — it is a reporter, not a gate. A bad track record is
information for a human, never a block.

## Boundary restated (the structural guarantee)
- Output paths: `.preflight/track-record/` (gitignored runtime state) and stdout. Nothing else.
- No `hooks/` file, no gate, no `write-gate-evidence` call, no `.preflight/gate/` write anywhere in
  `tools/preflight-agent-scorer.sh`. Verified by `tests/behavioral/agent-scorer-test.sh` (asserts the
  tool references no gate path and writes no gate evidence) and re-checkable by grep.

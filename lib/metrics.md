# Metrics Collection

Every skill invocation that runs a review loop MUST write metrics to `<project-root>/.preflight/metrics.json`. This is the evidence mechanism that proves the self-improving loop actually improves.

## Why This Exists

Without metrics, "we're superior" is a claim, not a fact. The system's core contract — "every issue caught by external review on ServiceN should be caught by local review on ServiceN+1" — is unfalsifiable without data showing round counts trending down across services.

## Schema

```json
{
  "lastRubricEditAtRun": 0,
  "runs": [
    {
      "timestamp": "2026-05-18T14:32:00Z",
      "service": "my-service",
      "branch": "feature/migrate-x",
      "skill": "fix-and-close",
      "stage1": {
        "iterations": 3,
        "findingsPerIteration": [5, 2, 0],
        "capHit": false,
        "couplingGroupsIdentified": 2,
        "couplingGroupSizes": [3, 2],
        "independentFindings": 1,
        "validatorWarnings": 0,
        "durationSeconds": 145
      },
      "stage2": {
        "iterations": 2,
        "findingsPerIteration": [3, 0],
        "capHit": false,
        "stableFindings": 3,
        "trivialStableFindings": 1,
        "unstableFindings": 0,
        "fixedCount": 2,
        "defendedCount": 1,
        "pollWaitSeconds": 400,
        "durationSeconds": 490
      },
      "capture": {
        "inRubricButMissed": 1,
        "newCategory": 0,
        "falsePositive": 0,
        "humanJudgment": 0,
        "patternCapture": 1
      },
      "outcome": "SUCCESS",
      "totalDurationSeconds": 635
    }
  ]
}
```

## Cadence counter — `lastRubricEditAtRun`

`lastRubricEditAtRun` is the `runs`-array index (length) at which the last rubric-edit PR was
opened. The rubric-edit cadence is computed as `len(runs) - lastRubricEditAtRun` — when that
reaches `loop.rubricEditCadence` (default 5), fix-and-close surfaces a low-urgency reminder to run
`/preflight:rubric-edit` (segment 2). The `rubric-edit` skill resets it to the current `runs`
length after its PR merges. Absent field → treat as 0 (no rubric-edit has run yet). This is the
counter design specified in `docs/rubric-edit-process.md` §2 ("the `runs` array length since last
rubric-edit") — the cadence is a guideline, not a gate.

## Telemetry only — NOT the decision-of-record

Metrics holds **counts**, not verdicts. `fixedCount` / `defendedCount` are tallies for trend
analysis. The per-finding adjudicated verdict (which finding was fixed vs defended) **and its cited
legacy evidence** are the authoritative decision-of-record and live in the SHA-keyed adjudication
artifact (`.preflight/adjudications/PR<n>-<HEAD>.json`, schema in `lib/adjudication-record.md`) —
NOT here. Do not add per-finding verdict detail or `citedEvidence` to metrics: that would bury
load-bearing decision infrastructure in a free-form telemetry blob the agent appends to, where a
fabricated verdict would look native. Counts here; verdicts + evidence there.

## Collection Points

The orchestrator (fix-and-close or migrate) collects metrics at these points:

| Event | What to record |
|---|---|
| Stage 1 iteration start | Timestamp, finding count |
| Stage 1 iteration end | Findings resolved, coupling groups dispatched, implementer results |
| Stage 1 complete | Total iterations, cap hit (bool), total duration |
| Dependency map validation | Warning count by type (shared-imports, unverifiable-edges, missed-DI) |
| Stage 2 poll return | Finding count, stability classification breakdown |
| Stage 2 iteration end | Fixes applied, capture entries written |
| Stage 2 complete | Total iterations, cap hit (bool), total duration, outcome |
| Run complete | Total duration, final outcome |

## Writing Metrics

After the skill completes (SUCCESS, CAPPED, STUCK, DIVERGING, or ERROR), append the run entry to `.preflight/metrics.json`:

```bash
# Read existing metrics (or create empty structure)
if [ -f .preflight/metrics.json ]; then
  existing=$(cat .preflight/metrics.json)
else
  mkdir -p .preflight
  existing='{"runs":[]}'
fi

# Append new run (use python for safe JSON manipulation)
python -c "
import json, sys
data = json.loads('''$existing''')
new_run = json.loads('''$NEW_RUN_JSON''')
data['runs'].append(new_run)
print(json.dumps(data, indent=2))
" > .preflight/metrics.json
```

## Reading Metrics (for trend analysis)

The discovery-analyst and code-reviewer should read metrics when available to inform their analysis:

- **Discovery-analyst**: If prior runs exist for similar services, report the historical round counts as context for the readiness score.
- **Rubric-reviewer**: If prior runs show a specific rubric section triggering cap hits, weight that section's findings higher.

## What Metrics Prove

After 3 services:
- `stage1.iterations` trending down → generation spec is working (fewer mechanical mistakes)
- `stage2.iterations` stable at 1-2 → coupling analysis is correct
- `capture.inRubricButMissed` trending down → rubric coverage is improving (capture→promote→rubric loop is working)
- `capture.patternCapture` growing → generation spec is growing
- `totalDurationSeconds` trending down → system is getting faster

After 5 services:
- Compare pre-framework rounds to post-framework rounds
- If average is <5: the framework has paid for itself
- If average is >10: the coupling analysis or generation spec has gaps

## .gitignore

Add `.preflight/metrics.json` to `.gitignore` — metrics are local operational data, not source. Each machine tracks its own runs. Team-wide analysis would aggregate from CI artifacts (future work).

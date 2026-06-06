---
name: rubric-edit
description: Draft a batched rubric-edit PR that promotes validated capture entries into operative rubric sections. Segment 2 of the self-improvement loop — the executable step that turns accumulated capture evidence into a HUMAN-REVIEWED rubric PR. Runs the deterministic promotion matrix via lib/rubric-promotion-evaluator.sh, then drafts sections matching the rubric shape and opens a chore(rubric) PR. NEVER auto-edits the rubric. TRIGGER when the rubricEditCadence reminder fires (loop.rubricEditCadence PRs since the last rubric-edit), or when a human asks to run the rubric-edit / promote captures. SKIP for normal migration/fix work.
---

# Rubric-Edit — executable segment 2 (capture → human-reviewed rubric PR)

This skill is the **only mechanism** that promotes capture-derived findings into operative
detection rules. Code-reviewer reads only the rubric; capture files are transient evidence. This
skill converts validated capture entries into a drafted rubric-edit PR **for human review**.

**It never auto-edits the rubric.** Per `docs/rubric-edit-process.md` (the full process spec, §1
and "What This Process Does NOT Do"), promotion is human-gated: this skill drafts; a human reviews
and merges. The promotion matrix is decision support, not auto-promotion.

Read `docs/rubric-edit-process.md` in full before running — it is the authoritative process. This
skill is the executable wrapper around it.

---

## Division of labor: deterministic script + judgment prose

| Step | Who | Why |
|---|---|---|
| Parse captures, apply the promotion matrix, skip defended entries | **`lib/rubric-promotion-evaluator.sh`** (deterministic) | The matrix is mechanical logic. It must not drift run-to-run, and the skip-defended rule must be mechanical — a prose matrix that misread a `DO NOT PROMOTE` banner once would promote a rule for behavior the team deliberately preserved. |
| Draft the rubric sections, resolve cross-engineer conflicts, open the PR | **this skill** (judgment) | Writing a good rubric section, merging duplicate captures, and calibrating severity are judgment calls a human reviews. |

---

## Step 1 — Confirm cadence / intent

Run when the `rubricEditCadence` reminder has fired (see fix-and-close's cadence reminder) OR a
human explicitly asks. The cadence is a guideline, not a gate (`rubric-edit-process.md` §2) — do
not block other work on it.

Read config (`.preflight/config.json` > `.cpsl/config.json` > `.forge.json`): `capture.*` paths,
`rubric` path, `loop.rubricEditCadence`.

## Step 2 — Run the deterministic evaluator (do NOT eyeball the matrix)

```bash
FRAMEWORK_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
bash "${FRAMEWORK_ROOT}/lib/rubric-promotion-evaluator.sh" \
  "<capture.calibrationLog>" "<capture.checklistAdditions>" "<capture.falsePositives>"
```

It emits a JSON array of per-entry decisions:
- `PROMOTE` — Survived 2+/high → draft at the entry's declared severity.
- `PROMOTE_CAP_MAJOR` — Survived 2+/medium → draft, severity capped at major.
- `PROMOTE_CAP_MINOR` — Survived 2+/low → draft at minor + add to the "detection refinement" table.
- `PRIORITY_ESCALATION` — Survived 5+/low → draft at minor + immediate-refinement flag.
- `HOLD` — Survived 0-1 → leave in active captures, do not draft.
- `SKIP` — **DEFENDED** (the `DO NOT PROMOTE` banner / `Survived: N/A`). NEVER draft these. This is
  the 1A interplay: a defended finding is behavior the team intentionally kept; promoting a
  detection rule for it would be exactly backwards.
- `LOOSEN` — false-positive entry → drives rubric LOOSENING (narrow/except/remove the cited
  section per `rubric-edit-process.md` §4), not a new section.

**Trust the script's decisions.** Do not re-derive the matrix by hand — that is the drift this
script exists to prevent. You MAY override an individual decision for a documented reason
(`rubric-edit-process.md` §4 lists the legitimate overrides, e.g. a Survived-1 critical-security
entry) — but record the override and its reason in the PR body. You may NOT override a `SKIP`:
a defended finding is never promoted.

## Step 3 — Draft the rubric sections (judgment)

For each `PROMOTE*` decision, draft a rubric section matching the existing shape (`### §<ID> —
<name>`, `**Issue:**`, `**Fix:**`, BAD/GOOD blocks, `**Rule:**` / `**Detect:**`). Apply the
cross-engineer reconciliation rules (`rubric-edit-process.md` §5: dedupe, classification
tiebreak, signal variation, severity). The draft MUST satisfy the validation contract
(`rubric-edit-process.md` §7):
- Section IDs globally unique, conforming to the rubric's declared prefix (`§G`/`§M`/`§A`).
- `major`/`blocker` sections require BAD and GOOD blocks.
- `**Detect:**` must be a deterministic boolean condition, not a judgment call. If a signal can't
  be made mechanical, the section is `minor` (advisory).
- Severity cross-checked against `lib/severity-matrix.md`.

For `LOOSEN` decisions, draft the narrowing/exception/removal of the cited section.

## Step 4 — Open the PR (never merge; never auto-edit the live rubric on the working branch)

```bash
git checkout -b chore/rubric-edit-batch-N
```
Make the rubric edits on this branch only, structure the PR body per `rubric-edit-process.md` §6
(Summary / Promoted / Declined / Refinement / Deferred / Capture File Changes), request `@copilot`
as reviewer (the rubric edit gets meta-reviewed like any PR), and hand off to a human. Apply the
capture-file lifecycle (archive promoted/consumed/deferred entries, increment `Cycles`) per §8.

After the PR merges, update `lastRubricEditAtRun` in `.preflight/metrics.json` to the current
`runs` array length so the cadence counter resets.

## What this skill does NOT do

- Auto-promote or auto-edit the rubric (a human reviews + merges the PR).
- Override a `SKIP` (defended findings are never promoted).
- Re-derive the promotion matrix by hand (the evaluator owns it).
- Block any other work on the cadence (it is a reminder, not a gate).
- Touch code-reviewer's runtime (code-reviewer reads only the merged rubric).

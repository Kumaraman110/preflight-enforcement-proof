# Rubric-Edit PR Process

The rubric-edit PR is the framework's only mechanism for promoting capture-derived findings into operative detection rules. Code-reviewer reads only the rubric for detection — capture files are transient evidence that feeds this process.

---

## 1. Purpose

The self-improvement loop captures learnings during Stage 2 (Copilot review). Those learnings sit in capture files as promotion candidates. This process converts validated candidates into rubric sections that code-reviewer enforces on all subsequent PRs.

Without this process, learnings accumulate forever without effect. With it, every finding Copilot catches becomes a detection rule that fires locally — preventing the same class of issue from reaching external review again.

The rubric-edit PR is human-reviewed by design. It is the reconciliation point where:
- Multiple engineers' captures are deduplicated
- Classification conflicts are resolved
- Detection signals are refined from fuzzy to mechanical
- Severity is calibrated against real-world evidence

---

## 2. When to Run

**Trigger:** After `loop.rubricEditCadence` PRs have completed Stage 2 (default: 5). The count is PRs that ran through `/fix-and-close` with Stage 2 Copilot review — regardless of work shape (migration, refactor, new feature, bug fix, infrastructure). Any preflight workflow that generates capture entries counts toward the cadence.

**Who initiates:** Any team member. The external-review-handler agent tracks the count in `.preflight/metrics.json` (the `runs` array length since last rubric-edit). When the threshold is reached, the agent surfaces a reminder in its output.

**Urgency:** Low. The cadence is a guideline, not a hard gate. Captures remain valid evidence indefinitely. Delaying a rubric-edit PR by a few PRs costs nothing except slightly delayed detection improvement.

---

## 3. Inputs

Read these files before starting:

| File | Purpose |
|---|---|
| `capture.calibrationLog` path (from config) | Bucket 1 entries — detection gaps to strengthen |
| `capture.checklistAdditions` path (from config) | Bucket 2 entries — new categories to add |
| `capture.falsePositives` path (from config) | Bucket 3 entries — overly strict rules to loosen |
| Current rubric (at `rubric` path from config) | The document being edited |
| `examples/rubrics/rubric-generic-dotnet.md` | Cross-cutting example rubric (for section ID conflict check) |

For each capture entry, note the tracking fields:
- `**Survived:**` — validation count (how many PRs confirmed this pattern)
- `**Confidence:**` — detection precision (high/medium/low)
- `**FirstSeen:**` — when the entry was first written
- `**Cycles:**` — how many rubric-edit rounds have passed without promotion

---

## 4. Promotion Criteria

Evaluate each entry against this decision matrix:

| Survived | Confidence | Recommendation |
|---|---|---|
| 0-1 | any | **Hold** — insufficient validation. Leave in active captures. |
| 2+ | high | **Promote at declared severity** — issue validated, detection precise. |
| 2+ | medium | **Promote capped at major** — issue validated, detection may have edge cases. |
| 2+ | low | **Promote capped at minor** — issue validated but detection needs refinement. Flag for detection refinement. |
| 5+ | low | **Priority escalation** — promote at minor AND flag for immediate detection refinement. |

**This matrix is decision support, not auto-promotion.** The human reviewer makes the final call. Reasons to override the matrix:
- A Survived-1 entry describes a critical security issue → promote anyway (severity warrants it)
- A Survived-3 entry's detection signal is clearly wrong on re-read → decline and archive
- Two entries cover the same underlying issue → merge into one rubric section

**False-positive entries** (Bucket 3) don't have promotion criteria — they drive rubric LOOSENING:
- If the cited rubric section's detection signal is too broad → narrow it
- If the finding is genuinely spurious → add an exception to the section's detection
- If the section should be removed entirely → remove it (rare; document why in the PR)

---

## 5. Cross-Engineer Reconciliation

When multiple engineers run preflight in parallel, captures accumulate independently. The rubric-edit PR is where conflicts resolve.

### 5.1 Duplicate Captures

Two engineers captured the same pattern (same anti-pattern, different PRs/files).

**Resolution:** Merge into one rubric section. Use the entry with higher Survived count as the base. The combined evidence (both PRs) strengthens the case. Sum the Survived counts when they describe genuinely independent observations.

### 5.2 Classification Conflicts

One engineer's Bucket 1 (in-rubric-but-missed) vs another's Bucket 2 (new-category) for the same issue.

**Resolution:** Check the current rubric. If the section exists → the Bucket 1 classification was correct; strengthen detection. If no section exists → the Bucket 2 classification was correct; create a new section. The rubric is the tiebreaker.

### 5.3 Detection Signal Variations

Two entries for the same issue propose different BAD/GOOD patterns.

**Resolution:** The rubric section should use the most precise (highest Confidence) detection signal available. If both are mechanical and exact, pick the one that covers more code shapes. Include both BAD examples in the rubric section if they represent distinct manifestations of the same underlying anti-pattern.

### 5.4 Severity Disagreements

Two entries suggest different severity for the same pattern.

**Resolution:** Use the Confidence-adjusted matrix. If both are high-confidence with different suggested severity, the PR author decides based on: does external review (Copilot, CodeQL, Veracode) consistently flag this? If yes → the severity external tools assign wins. If external tools are inconsistent → default to `major`.

### 5.5 False-Positive Contradictions

One engineer's false-positive entry contradicts another engineer's in-rubric-but-missed entry for the same rubric section.

**Resolution:** The false-positive wins if the external reviewer consistently did NOT flag the pattern across multiple PRs. The in-rubric-but-missed wins if the external reviewer DID flag it. Check the `**PR:**` URLs in both entries — the one with more recent evidence from external review is more credible.

---

## 6. Authoring the PR

### 6.1 Branch and Title

```bash
git checkout -b chore/rubric-edit-batch-N
```

Title format (conventional commits):
```
chore(rubric): batch N — <1-sentence summary of changes>
```

Examples:
- `chore(rubric): batch 3 — strengthen §M4.2 token caching detection, add §M8 container user check`
- `chore(rubric): batch 5 — loosen §G2.1 structured logging (non-PII fields), add §A3 pagination category`

### 6.2 PR Body Structure

```markdown
## Summary

- Promoted N entries from calibration-log (detection strengthening)
- Added M new sections from checklist-additions
- Loosened K existing sections from false-positives
- Deferred P entries (Cycles ≥ 2, insufficient recurrence)
- Archived Q consumed false-positive entries

## Promoted Entries

### §<new-or-updated-ID> — <name>

**Source:** calibration-log entry from <ISO date>, Survived: <N>, Confidence: <level>
**Change:** <what was added/modified in the rubric>

[repeat per entry]

## Declined Entries (with reasons)

| Entry | Reason |
|---|---|
| <date> — <name> | <why not promoted this round> |

## Rules Needing Detection Refinement

[Table of Survived ≥ 5, Confidence low entries per external-review-handler spec]

## Deferred Entries (Cycles ≥ 2)

| Entry | FirstSeen | Cycles | Last Survived | Reason |
|---|---|---|---|---|
| <date> — <name> | <date> | <N> | <count> | No recurrence through 2 edit cycles |

## Capture File Changes

- calibration-log.md: X entries promoted (archived), Y remain active
- checklist-additions.md: X entries promoted (archived), Y remain active
- false-positives.md: X entries consumed (archived), Y remain active
```

### 6.3 Meta-Review

The rubric-edit PR goes through normal Copilot review (meta-review of the rubric itself). This catches:
- Syntax issues in BAD/GOOD blocks
- Inconsistencies between detection signal prose and code examples
- Section ID format violations

Request `@copilot` as reviewer the same way any other PR does.

---

## 7. Validating the Resulting Rubric

Before merging, verify:

### 7.1 Section ID Uniqueness

Section IDs must be globally unique across all rubrics a project might use simultaneously:
- Generic rubric: `§G1`, `§G2`, `§G3`...
- Migration rubric: `§M1`, `§M2`, `§M3`...
- API design rubric: `§A1`, `§A2`, `§A3`...

New sections MUST follow the prefix convention for their rubric. Run:
```bash
grep -h '^### §' examples/rubrics/rubric-*.md | sort | uniq -d
```
Any output = collision. Fix before merging.

Every rubric file declares its section ID prefix in a top-of-file HTML comment (e.g., `<!-- Section ID prefix: §G -->`). Verify that every section ID in the file conforms to the declared prefix. Any section ID that doesn't match the declared prefix is a defect to fix before merging.

### 7.2 BAD/GOOD Blocks Required

Every section with severity `major` or `blocker` MUST have:
- A `**BAD:**` code block showing the anti-pattern
- A `**GOOD:**` code block showing the correct pattern

Sections at `minor` severity MAY omit these (minor issues are advisory and don't block the pipeline).

### 7.3 Mechanical Detection Criteria

The `**Detect:**` line must describe a deterministic boolean condition, not a judgment call.

**Acceptable:** "Flag if: `IMemoryCache.GetOrCreateAsync` is called for token caching AND no `SemaphoreSlim` exists in the same class"

**Not acceptable:** "Flag if: the caching approach seems insufficient for high-traffic scenarios"

If a detection signal can't be made mechanical, the section should be `minor` severity (advisory, non-blocking). Judgment-based detection at `major` or `blocker` severity creates phantom findings.

### 7.4 Severity Consistency

Cross-check new section severity against `lib/severity-matrix.md` defaults. If the new section's severity differs from the matrix category, include a justification in the PR description.

---

## 8. Capture File Lifecycle Post-Merge

### 8.1 Four States

| State | Location | Meaning |
|---|---|---|
| **Active** | Current capture files (paths from config) | Pending evaluation at next rubric-edit cycle |
| **Promoted** | `docs/review/archive/<ISO-date>-batch-N/promoted/` | Entry became a rubric section |
| **Consumed** | `docs/review/archive/<ISO-date>-batch-N/consumed/` | False-positive that drove rubric loosening |
| **Deferred** | `docs/review/archive/deferred/<ISO-date>/` | Entry didn't recur through 2 consecutive cycles |

### 8.2 Tracking Fields

Every capture entry (Bucket 1 and Bucket 2) includes:

```markdown
**FirstSeen:** <ISO date when entry was first written>
**Cycles:** <number of rubric-edit rounds where entry was reviewed but not promoted>
```

- `FirstSeen` is immutable — set on creation, never changes.
- `Cycles` is incremented by the rubric-edit PR author for any entry that remains in active capture files after that round.

### 8.3 TTL Rule

An entry that has NOT accumulated additional `Survived` counts through 2 consecutive rubric-edit cycles (`Cycles ≥ 2`) moves to deferred state. The issue either stopped recurring (no longer relevant) or was too rare to validate.

### 8.4 Archive Mechanics

The rubric-edit PR author uses `git mv` operations in the PR diff:

```bash
# Promoted entries
git mv docs/review/calibration-log.md docs/review/archive/2026-05-20-batch-3/promoted/calibration-log-entries.md

# Consumed false-positives
git mv docs/review/false-positives.md docs/review/archive/2026-05-20-batch-3/consumed/false-positives-entries.md

# Deferred entries (Cycles ≥ 2)
git mv <extracted-entries> docs/review/archive/deferred/2026-05-20/
```

In practice, the PR author extracts specific entries from the capture files (not the whole file) — the active capture file continues to exist with remaining non-promoted, non-deferred entries.

### 8.5 Searchability

Archive entries preserve their original section ID headers (`## <ISO date> — §<section> ...`) so engineers can grep the archive for historical context:

```bash
grep -r "§M4.2" docs/review/archive/
```

This answers: "What evidence drove the creation of §M4.2? When was it first seen? How many services validated it?"

---

## What This Process Does NOT Do

- Auto-promote entries without human review
- Edit the rubric outside of a dedicated rubric-edit PR
- Clear capture files without archiving (provenance is preserved)
- Block PRs on rubric-edit cadence (the cadence is a reminder, not a gate)
- Apply to code-reviewer's runtime behavior (code-reviewer reads only the rubric, never captures)

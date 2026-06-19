# Rubric Provenance — structured changelog format (index-ready; query tool DEFERRED)

This is the structured-provenance FORMAT for rubric changes. It is the §G2 finding made mechanical: git
already keeps an exact who/what/when (`git log`/`blame`); what git alone lacks is the structured **why**
in a shape a future query tool can index. This file defines that shape and the enforcement that keeps it
populated. **It is NOT an agent-memory layer** (per `.release-audit/MEMORY-DESIGN.md` §G2 — provenance is
git + governance, never a fuzzy memory store).

## The two surfaces

### 1. The per-rule `**Source:**` line (ENFORCED — `lib/rubric-source-check.sh`)
Every rubric rule (`### §<id>`) carries a Source line in its block. This is the load-bearing,
mechanically-enforced piece (the correction earned in the §G2 review: a Source line a human could omit was
convention, not mechanism). Structured, index-ready form:

```
**Source:** <origin> | <ref> | <YYYY-MM-DD> | <op>
```

| Field | Meaning | Examples |
|---|---|---|
| `<origin>` | where the rule came from / WHY it exists | `calibration-log 2026-06-10`, `copilot PR#95`, `base-author`, `false-positive consume` |
| `<ref>` | a PR / commit / issue reference | `PR#123`, `commit a203bb7`, `issue#10` |
| `<YYYY-MM-DD>` | ISO-8601 date of the change | `2026-06-18` |
| `<op>` | the change operation | `add` · `raise` · `loosen-base` · `tighten` · `base-author` |

Example: `**Source:** calibration-log 2026-06-10 | PR#123 | 2026-06-12 | add`

The legacy prose form from `docs/rubric-edit-process.md` (`**Source:** calibration-log entry from
<date>, Survived: N, Confidence: <level>`) is ALSO accepted by the check (back-compat — existing rubrics
are not retroactively broken), but new/edited rules should use the structured pipe form so the data is
index-ready.

### 2. The per-file `## Changelog` block (CONVENTION — documented, not yet hook-enforced)
Each rubric/overlay file carries a `## Changelog` section: one row per change, the same fields as the
Source line plus a short rationale. This is the human-readable audit trail; the Source line is the
per-rule machine anchor. Format:

```markdown
## Changelog
| date | §ID | op | ref | rationale |
|---|---|---|---|---|
| 2026-06-12 | §G2.4 | add | PR#123 | CWE-117 recurred across runs 3,7,9 (calibration-log) |
| 2026-06-14 | §G2.1 | raise | PR#130 | Veracode flags this consistently → blocker |
```

## Enforcement level (ADVISORY-FIRST → blocking)

`lib/rubric-source-check.sh` reports a missing/malformed Source line as **exit 1 = ADVISORY** by default
(CI surfaces it, does not block) and **exit 2 = BLOCKING** with `--blocking`. This is the WIRE-B
advisory→corroborated→blocking pattern, exit-aligned to `parity-check.sh` (0 clean / 1 advisory / 2
blocking).

**Promotion criterion (advisory → blocking):** flip to `--blocking` once the existing committed rubrics
(`examples/rubrics/rubric-*.md`) have been backfilled with Source lines so the gate would not fire on
legitimate pre-existing rules. Until backfill, blocking-from-day-one would block every edit to a
not-yet-annotated rule — so advisory-first is correct. The backfill + flip is a tracked follow-up.

## The query tool — DEFERRED (format built so data accumulates index-ready)

The eventual goal (§G2's "did a change help?") is a query over {rule §ID ↔ originating capture ↔ PR ref
↔ subsequent `metrics.json` round-count delta}. That tool is **deliberately DEFERRED**, not built here:

- **Why defer:** the query is only worth building once there is accumulated rubric-change history to query
  against (a handful of changes, each with a Source line, and several post-change `metrics.json` runs to
  correlate). Building the tool before the data exists would be speculative — it would have nothing to
  index. The FORMAT (this file + the enforced Source line) is what must exist NOW so that, by the time the
  tool is worth building, the data is already captured index-ready (structured fields, not free prose).
- **What it would do when built:** join Source-line `<ref>`/`<§ID>` against git history and `metrics.json`
  trends to answer "after §G2.4 was added in PR#123, did the security-finding round-count trend down?" —
  the framework's stated did-this-help contract.
- **Inputs it will have ready:** the structured Source lines (enforced now), the `## Changelog` rows, git
  history (always), and `.preflight/metrics.json` (already emitted per run).

This is a follow-up item. It is NOT in scope for the current build. The format is the deliverable; the
tool waits for data.

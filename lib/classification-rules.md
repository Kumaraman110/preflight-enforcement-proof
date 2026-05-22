# Classification Rules

Reference material for the `external-review-handler` agent. Defines how to classify external review findings into the four learning buckets.

## The Four Buckets

| Bucket | Capture File | Meaning | Action |
|---|---|---|---|
| `in-rubric-but-missed` | calibration log | Rubric covers this but Stage 1 didn't catch it | Strengthen detection signal |
| `new-category` | checklist additions | No rubric section covers this | Add new rubric section |
| `false-positive` | false positives | Stage 1 flagged this but external review disagrees | Loosen detection signal |
| `human-judgment` | checklist additions (Deferred) | Subjective call, not automatable | Surface for human review |

## Classification Algorithm (First Match Wins)

1. **Explicit rule citation:** Comment cites a CWE, CodeQL rule, SonarQube rule, or Veracode finding ID.
   - Check the active rubric for that ID.
   - Found → `in-rubric-but-missed`
   - Not found → `new-category`

2. **Pattern match:** Comment describes an issue that matches a rubric section's detection signal.
   - Match → `in-rubric-but-missed`
   - No match → continue

3. **Contradiction:** Comment contradicts a recent Stage 1 finding (Stage 1 said X is wrong, external review says X is fine or wants the opposite).
   - → `false-positive`

4. **Subjective language:** Comment uses words like "consider", "you might", "could be cleaner", "I'd suggest", "have you thought about".
   - → `human-judgment`

5. **Default:** None of the above match.
   - → `new-category` with `Confidence: low`

## Confidence Levels

- **high** — Clear match to a pattern or clear gap in rubric
- **medium** — Reasonable classification but could go either way
- **low** — Uncertain; the next batched rubric-edit PR should re-examine this

## Tie-Breaking Rules

- When torn between `in-rubric-but-missed` and `new-category`: does the rubric section's detection signal EXPLICITLY cover this pattern? If you have to stretch the interpretation → `new-category`.
- When torn between `new-category` and `human-judgment`: is this something that could be expressed as a mechanical rule? If yes → `new-category`. If it requires taste/context → `human-judgment`.
- When in doubt about any classification: prefer `new-category` with `Confidence: low`. The batched rubric-edit PR process provides human review of all low-confidence entries.

## Source Attribution

When writing capture entries, always include:
- The source (which external reviewer or tool produced the finding)
- The exact file and line
- A paraphrase of the finding (never copy verbatim from proprietary tools)
- Your classification rationale (one sentence)

# Self-learning coverage-gap detection — investigation + design

Read-only investigation + design, BEFORE building. The load-bearing thing to get right: the
"was this a coverage gap?" determination must be **mechanical or independently judged — NEVER the
working agent's self-assessment**. This document settles that first.

---

## 1. Investigation — current capture on-ramps (cited)

**Finding 1 — Copilot is the ONLY automatic capture on-ramp. CONFIRMED.**
- The capture files (`calibration-log`, `checklist-additions`, `false-positives`, `generation-spec-candidates`)
  are written EXCLUSIVELY by the `external-review-handler` sub-agent, which is the **Copilot** review
  handler: its description is "Polls GitHub **Copilot's** PR review … classifies each comment into one of
  four learning buckets, and writes capture entries" (`agents/external-review-handler.md:3`).
- The parent orchestrator is explicitly FORBIDDEN from writing capture:
  `skills/fix-and-close/SKILL.md:244` ("The parent session MUST NOT … write to capture files. Those are
  the handler's exclusive responsibilities"), and `:473` ("Edit capture files (external-review-handler
  does that)"). `skills/self-review/SKILL.md:83` ("Write to capture files (that's Stage 2's job)").
- The handler's writers: `false-positives` (`external-review-handler.md:258`), `calibration-log`
  (`:468`), `checklist-additions` recurrence (`:496`), `generation-spec-candidates` (`:539`). Every one
  is inside the Copilot handler.
- **Therefore:** a defect found by ANY other route (live deploy, code review, prod incident) has **no
  automatic path to capture**. It reaches the rubric loop only if a human hand-authors an entry. This is
  the inverted-coverage hole: the cheap pre-merge findings (Copilot) auto-capture; the EXPENSIVE
  post-merge findings rely on fallible human memory. And a missing capture is invisible — it looks
  identical to "no defect found" (the same silent-absence-looks-like-success shape as the false-greens
  fixed earlier this session).

**Finding 2 — the capture entry format already encodes the two Layer-2 cases. CONFIRMED.**
- The four buckets (`lib/classification-rules.md:7-13`):
  - `in-rubric-but-missed` → **calibration-log** — "Rubric covers this but Stage 1 didn't catch it" =
    the **BLIND SPOT** case (a rule exists; the gate didn't fire).
  - `new-category` → **checklist-additions** — "No rubric section covers this" = the **UNCOVERED CLASS**
    case.
  - `false-positive` → false-positives; `human-judgment` → checklist-additions (Deferred).
- The template headers say the same: calibration-log = "Stage 1's detection signal … missed something
  the rubric covers" (`defaults/capture-templates/calibration-log-template.md`); checklist-additions =
  "new categories that no existing rubric section covers"
  (`defaults/capture-templates/checklist-additions-template.md`).
- A capture entry is free-form markdown under a bucket; promotion to a rubric rule is the separate
  batched `rubric-edit` process (`lib/rubric-promotion-evaluator.sh`, `Survived 2+`).

**Finding 3 — the classification ALGORITHM already exists, but is PROMPT-LEVEL today. CONFIRMED.**
- `lib/classification-rules.md:19-40` is exactly the gap-decision Layer 2 needs:
  "(1) Comment cites a CWE/CodeQL/Sonar rule ID → check the active rubric for that ID. Found →
  `in-rubric-but-missed`; Not found → `new-category`. (2) Pattern match against a rubric section's
  detection signal → `in-rubric-but-missed`; else continue. … (5) Default → `new-category`."
- BUT this is performed by the `external-review-handler` AGENT reading prose — it is **prompt-level**,
  and it runs only on the Copilot path. For the recursive-accountability case it must become
  **mechanical** (a script), so the working agent cannot rationalize its own coverage gaps.
- Rubric rules carry stable machine-matchable identifiers: `§` IDs + CWE refs + named categories
  (`examples/rubrics/rubric-generic-dotnet.md`: `### §G2.1 Log injection (CWE-117)`,
  `### §G2.2 SSRF risk (CWE-918)`, …). `lib/severity-matrix.md:16-31` maps categories → default severity.
  So "does a rubric rule cover this defect's category?" is a COMPUTABLE token/ID match.

**Finding 4 — the INDEPENDENT-JUDGE primitive already exists. CONFIRMED — reuse its pattern.**
- `lib/agent-scorer.md` is "independent scoring of the orchestrating agent's JUDGMENT" with TWO
  non-negotiables (`:7-20`): **(1) INDEPENDENCE** — "NOT the orchestrating agent grading itself …
  a SEPARATE evaluator … never the judged agent introspecting"; **(2) NEVER FEEDS A GATE** — "OBSERVES
  and REPORTS … output lives ONLY under `.preflight/track-record/` and stdout; NO hook, gate, or
  evidence path reads it."
- It already has `SCORER_JUDGE_CMD` (`:136-141`): a separable judge that reads a judgment JSON on stdin
  and emits a verdict JSON; the default is a **deterministic, rule-based re-judger (no LLM)** so it runs
  offline and reproducibly. THIS is the model for "independent, not self-assessment."
- Its four-category model (`:147-154`) includes **MISS** = "failed to flag a real thing that ground
  truth shows mattered … a defect escaped local review" — conceptually the coverage-gap signal, one
  level down.

**Finding 5 — "did the gate fire?" is mechanically recorded. CONFIRMED.**
- `lib/heartbeat.sh:2-6`: every gate appends `.preflight/gate/heartbeat-<gate_name>` on each invocation;
  gate evidence lives at `.preflight/gate/<name>` (`HEAD=` text, SHA-keyed). So whether a given gate ran
  / passed for a given HEAD is a mechanical lookup, not a judgment.

---

## 2. Design — the integrity problem, solved MECHANICAL-FIRST

### The failure to prevent (recursive)
If the WORKING agent decides its own coverage gaps, you get the competent-rationalizer failure, in two
invisible directions:
- **Rationalize-away:** "that was unforeseeable / not my job" → real gaps suppressed.
- **Manufacture:** every bug → "coverage failure!" → signal drowned in false gaps.
Both look identical to a correct judgment (the same silent-wrong shape the framework exists to stop). So
the gap determination must NOT read the working agent's opinion of whether it should've caught it.

### LAYER 1 — source-agnostic capture entry point (mechanical)
A single tool — `lib/capture-finding.sh` — that ANY source (copilot | deploy | review | incident |
test-escape | …) calls to record an adjudicated defect into the ONE capture path. NOT "copilot OR
deploy-watch" (two hardcoded sources → the third bypasses again) — a `--source <label>` parameter so a
new source is covered by construction. It writes a structured capture entry (defect + category + source
+ HEAD) to the bucket Layer 2 selects. The Copilot handler keeps working (it can call this too, or its
existing path is preserved — no regression). Fail-safe: a defect with no clear bucket → captured anyway
as `new-category Confidence: low` (never silently dropped — a captured-but-uncertain entry is the
fail-safe direction, mirroring classification-rules step 5).

### LAYER 2 — coverage-gap self-detection (MECHANICAL, with an independent-judge fallback)
A tool — `lib/coverage-gap-detect.sh` — that, given a post-merge defect's `{category, cwe, signal,
foundBy, head}` and the active rubric + gate-evidence, COMPUTES one of three classifications:

1. **BLIND-SPOT** — a rubric rule's category/CWE/signal MATCHES this defect AND the corresponding gate
   PASSED (or didn't fire) at the defect's HEAD. *Provable coverage gap:* the rule existed, the defect is
   of that kind, yet it got through. Computed by: (a) match defect tokens (CWE id, category name,
   detection-signal keywords) against the rubric's rule IDs/CWE refs/signals; (b) confirm via gate
   evidence that the gate passed at that HEAD. Both are mechanical lookups — the agent's opinion is never
   consulted. Captured to **calibration-log** ("in-rubric-but-missed") + the META-finding "gate <X> has a
   blind spot for <rule §>".
2. **UNCOVERED-CLASS** — NO rubric rule matches this defect's category. *Provable absence of coverage.*
   Captured to **checklist-additions** ("new-category") + the META-finding "no gate covers <category>".
3. **NEW-COVERAGE / not-a-blind-spot** — no applicable gate could have caught it (e.g. a runtime-only
   class with no static signal, a genuinely novel class). Captured as new coverage, explicitly NOT
   labeled a blind spot. This is the case the agent would most want to either over- or under-claim; the
   MECHANISM decides it, by the same matching — if nothing matched AND the class is one the rubric
   structurally can't cover, it's new coverage, not a missed gate.

**Why mechanical-first works here:** the BLIND-SPOT vs UNCOVERED-CLASS distinction is *exactly* a
rule-category match + a gate-evidence lookup — both computable from artifacts. The detector reads the
defect's category and the rubric's rules; it does NOT read any field where the working agent says "I
should/shouldn't have caught this." A `claimedNotMyFault` or `claimedHugeGap` field in the input is
**ignored by construction** — the classification is a pure function of (defect-category, rubric-rules,
gate-evidence).

**Where mechanical can't decide → independent judge, never self.** If token-matching is ambiguous
(a defect whose category neither clearly matches nor clearly doesn't), the detector defers to an
INDEPENDENT judge via the agent-scorer's `SCORER_JUDGE_CMD` pattern (default: a deterministic rule-based
re-judger; pluggable separate model). The judge sees ONLY {defect, rubric-rule-list} — never the working
agent's reasoning — so it re-decides, it does not rubber-stamp. Honest residual: this judge is
judgment-vs-judgment (the agent-scorer's source-3 weakness), softer than the mechanical match; it is the
fallback, not the primary.

**Boundary (inherited from agent-scorer):** the gap detector OBSERVES and CAPTURES; it does NOT feed a
gate. A detected blind-spot is information for the next batched rubric-edit (human-gated promotion), never
an automatic gate change. Output: capture files + stdout. No `.preflight/gate/` write, no hook registration.

### The integrity test (the most important one)
Prove the determination is COMPUTED, not self-assessed:
- A defect input carrying `claimedNotMyFault: true` (the agent rationalizing) whose category
  MECHANICALLY matches a rubric rule that passed → still classified **BLIND-SPOT**. The agent cannot
  suppress a provable gap.
- A defect input carrying `claimedHugeGap: true` (the agent dramatizing) whose category matches NO rule
  and is structurally uncoverable → classified **NEW-COVERAGE**, NOT a blind spot. The agent cannot
  manufacture a false gap.
- Same defect, opposite agent claims → SAME classification (the claim field is inert; the mechanism
  decides).

---

## 3. What is mechanical vs prompt-level (honest labels, pre-build)
- **Mechanical:** Layer 1's source-agnostic write; Layer 2's BLIND-SPOT/UNCOVERED-CLASS/NEW-COVERAGE
  classification (rule-category match + gate-evidence lookup); the integrity property (claim fields
  ignored by construction).
- **Prompt-level (named, not hidden):** the orchestrator/skill must CALL `capture-finding.sh` when a
  post-merge defect is adjudicated (just as it currently must call `record-claim`). A source that never
  calls it still bypasses — but the gap is then a visible missing call, and Layer 1 is source-agnostic so
  ANY caller is covered. The independent-judge fallback (ambiguous cases) is judgment-vs-judgment (softer).
- **Residual:** mechanical matching is only as good as the defect's category tokens vs the rubric's rule
  vocabulary; a defect mis-categorized at intake could match the wrong rule (or none). Captured-uncertain
  is the fail-safe. The category vocabulary is `lib/severity-matrix.md` + the rubric `§`/CWE ids.

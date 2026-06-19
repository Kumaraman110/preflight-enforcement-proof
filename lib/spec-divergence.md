# Phase 0 — Spec-Divergence Check (the shared procedure scaffold + migrate both invoke)

This is the orchestration spec for the spec-divergence engine (Issues 1+2+3 unified). The MECHANICAL core
is `lib/spec-divergence.sh`; the agent dispatches below are PROMPT-LEVEL (a bash lib can't spawn
sub-agents — the orchestrating skill performs them via the Agent tool, exactly like migrate dispatches
`spec-analyst`). Both `skills/scaffold` and `skills/migrate` run this at their fresh-ambiguity entry
point. **It is ADVISORY: it ELICITS on high divergence; it does NOT hard-block the run.**

## WHEN to fire (fresh-ambiguity entry points ONLY — not every dispatch)

Fire Phase 0 ONLY where FRESH, not-yet-pinned under-specification ENTERS:
- **Always:** at the initial parse of the user's prompt/`$ARGUMENTS` (before any design/discovery).
- **At a hand-off that introduces NEW external requirements** not pinned by the initial prompt (e.g. the
  user adds scope mid-run). 

Do **NOT** fire on internal agent dispatches that operate on an already-pinned spec (discovery-analyst on
a resolved service, spec-analyst on a fixed file list, the implementer on a fixed finding). Re-checking a
pinned spec is cost without catch and dilutes the signal. A typical scaffold/migrate run hits **ONE** fire
point (the initial prompt); a run where the user injects new scope mid-stream hits one more.

## HOW it runs (per fire)

1. **Generate N=4 BLIND interpretations** (cost: 4 agents). Use the Agent tool to spawn 4 independent
   interpreters. Each is given ONLY the prompt + this fixed schema; NONE is told this is a
   divergence check or what "vague" means. Each commits to ONE concrete reading on the load-bearing axes:
   ```json
   {"scope_boundary": "...", "surfaces_in_scope": ["..."], "surfaces_out_of_scope": ["..."], "core_behavior": "..."}
   ```
   Collect them into `{"interpretations": [ ... ]}` at a temp path.

2. **Build the BLIND judge brief** (mechanical):
   ```bash
   bash ${FRAMEWORK_ROOT}/lib/spec-divergence.sh build-judge-brief <interps.json> > judge-brief.json
   ```
   This STRIPS the prompt — the judges must NEVER see the original request (or it becomes
   self-assessment, the failure mode). The brief contains only the interpretations.

3. **Judge with M=3 BLIND judges** (cost: 3 agents). Use the Agent tool to spawn 3 independent judges,
   each given ONLY `judge-brief.json` (NEVER the prompt). Each scores meaning-level agreement per axis,
   told to ignore wording/verbosity:
   ```json
   {"scope_agreement": "full-agreement|minor-variation|material-fork",
    "surfaces_agreement": "...", "behavior_agreement": "...", "overall_divergence_0to1": 0.0,
    "forked_readings_summary": "..."}
   ```
   Collect into `{"judgments": [ ... ]}`.

4. **Score + decide** (mechanical, advisory):
   ```bash
   bash ${FRAMEWORK_ROOT}/lib/spec-divergence.sh score <judgments.json>      # full breakdown
   DECISION=$(bash ${FRAMEWORK_ROOT}/lib/spec-divergence.sh decision <judgments.json>)
   ```
   - `PROCEED` (divergence <= threshold): the prompt is specified-enough-in-context. Continue. (Low
     divergence on a context-resolvable prompt is CORRECT — the engine flags residual ambiguity AFTER
     context, not "terse prompt".)
   - `ELICIT` (divergence > threshold): go to step 5.

5. **ELICIT (close the gap) — only on `ELICIT`:**
   ```bash
   bash ${FRAMEWORK_ROOT}/lib/spec-divergence.sh questions <judgments.json>
   ```
   Surface the forked axes AND ask the user these targeted questions (worst-divergence axis first). Take
   the answers, incorporate them, and **re-evaluate** (re-run from step 1 with the clarified prompt) OR
   accept the human's explicit confirmation. Proceed when divergence drops below threshold OR the human
   confirms. ADVISORY: if the user declines to answer, proceed anyway with a logged note — do NOT block.

6. **Pin the result** (mechanical):
   ```bash
   bash ${FRAMEWORK_ROOT}/lib/spec-divergence.sh write-elicited <service> <pinned-spec.md>
   ```
   Writes `.preflight/<service>/spec-elicited.md` — the pinned spec the design / Behavioral-Contract gate
   consumes downstream.

## Cost profile (the owner must weigh this)

Per fire: **N + M = 4 + 3 = 7 agent dispatches.** A typical run fires ONCE (initial prompt) → ~7 agents.
A run with a mid-stream new-scope hand-off fires twice → ~14. This is bounded BECAUSE Phase 0 fires only
at fresh-ambiguity entry points, not every internal dispatch. **Follow-up (NOT built):** a cheap
pre-filter could skip the full check when the prompt is trivially already-detailed (e.g. already names
scope+surfaces+behavior explicitly), saving the 7 agents on obviously-specified prompts. Noted, not built.

## Honesty label

- **Mechanical:** the judge-brief blinding, the scoring, the decision threshold comparison, the question
  generation, the artifact write (`lib/spec-divergence.sh`, tested in
  `tests/behavioral/spec-divergence-engine-test.sh`).
- **Prompt-level:** the interpreter + judge dispatches (the skill must actually spawn blind agents and
  must NOT leak the prompt into the judge brief — the mechanical `build-judge-brief` enforces the blinding
  at the data layer, but the skill choosing to use it is prompt-level).
- **ADVISORY:** the threshold (0.30 default) is proven only at n=5 — it ELICITS, it does NOT hard-block.
  Promotion to a hard gate is a separate step after larger-n calibration.

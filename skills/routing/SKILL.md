---
name: routing
description: Behavioral routing — loaded at session start, tells the LLM WHEN to invoke each skill. This document is injected into additionalContext by the session-start hook. It is the decision tree the agent follows before every action.
---

<HARD-GATE>
If you think there is even a 1% chance a skill applies to what you're about to do, invoke it. Not invoking a relevant skill is the single most expensive mistake — one skipped self-review costs 5+ minutes of post-push review cycles. One skipped TDD check means tests written after implementation (harder, less coverage).
</HARD-GATE>

## Before Every Action — Check This Table

| You are about to... | Required skill | Why skipping costs |
|---|---|---|
| Run `git push` | `/preflight:self-review` (if gate evidence stale) | Push will be blocked by mechanical gate. You'll waste the tool call, then have to review anyway. Faster to review first. |
| Claim "done" on any multi-step task | Verification discipline (fresh test command + build command from project config) | Claiming done without evidence → user trusts → merges → broken. |
| Write new functionality (not fixing existing) | `/preflight:test-driven-development` | Tests after implementation = weaker coverage, harder assertions, less design pressure. |
| Fix a test failure (2nd+ attempt on same test) | `/preflight:systematic-debugging` | Shotgun debugging averages 4.2 attempts. Systematic averages 1.8. After 2 failures, switch. |
| Start migrating a service | `/preflight:migrate` | Skipping Phase 1 discovery has cost 4+ hours when dependencies cascaded. |
| Push + PR + review loop (full pipeline) | `/preflight:fix-and-close` | Handles Stage 1 gate, commit, push, Stage 2 Copilot loop, capture, metrics — all with coupled-group protocol and iteration caps. |
| Lock in a readiness score, pick an architectural approach, or propose a rubric/rule change | `/preflight:gps-decide` (skip for trivial reversible choices) | Confident-but-untested judgment ships unchallenged; a wrong one-way-door call costs weeks, not the seconds a stress-test pass takes |

## Red Flags — You Are Rationalizing

| Your thought | Why it's wrong | What to do instead |
|---|---|---|
| "This is a trivial change, no review needed" | CWE-117 is one line. Thundering herd is one method call. Trivial changes introduce critical vulnerabilities. | Invoke self-review. 30 seconds. |
| "I just ran tests, this whitespace fix can't break anything" | Whitespace in XML doc comments affects builds. Adjacent-line changes mask real diffs. | Run tests again. 15 seconds. |
| "I'll push and see what Copilot says" | Each Copilot round-trip is 200-300 seconds. Stage 1 catches issues in 30 seconds. | Run self-review before pushing. |
| "I know this code is correct, I just wrote it" | Authors are blind to their own bugs. That's why review exists. | You are the author. Review is for you. |
| "The previous iteration was clean, this fix is safe" | Fixes interact with other code. The cascading regression pattern (48% of the 70-round cost) starts with "this fix is safe." | Re-run Stage 1. Always. |
| "I'll do the full pipeline later, let me just push this quick" | "Quick push" without gates = Copilot catches 5 things = 5 rounds × 300s = 25 minutes of waiting you could have avoided with 2 minutes of Stage 1. | Invoke fix-and-close. It handles everything. |
| "Tests are passing, that's enough" | Tests verify behavior. Stage 1 verifies security, style, architecture. Orthogonal. Both must pass. | Run self-review after tests pass. |
| "I've already decided, a stress-test will just slow me down" | Confident decisions are exactly the untested ones. A one-way-door call wrong costs weeks; the pass costs seconds. | Invoke gps-decide. If the decision is sound it survives the pass unchanged. |

## Verification Discipline (Always Active)

Before claiming ANY of these, the evidence must be FRESH (produced AFTER your latest change):

| Claim | Required evidence | NOT evidence |
|---|---|---|
| "Tests pass" | test command output (from project config) showing 0 failures | "Should pass", previous run, implementer said so |
| "Build is clean" | build command output (from project config) showing 0 errors 0 warnings | "Tests pass" (tests ≠ build) |
| "Stage 1 clean" | code-reviewer output saying CLEAN on current diff | Previous iteration's CLEAN |
| "Done" | All of the above + structural verification | "It works" without running it |

## Skill Priority (When Multiple Apply)

1. **Process skills first** — debugging, TDD, gps-decide. These determine HOW to approach.
2. **Gate skills second** — self-review, fix-and-close. These ensure QUALITY before shipping.
3. **Implementation skills third** — migrate, scaffold. These guide EXECUTION.

"Migrate this service" → migrate (includes Phase 1 discovery before code).
"Fix this test" → if 2nd attempt: systematic-debugging → then fix → then self-review before push.
"Push this" → self-review (if evidence stale) → fix-and-close (if want full pipeline).
"Should we do X?" → if stakes non-trivial: gps-decide → then execute the decision.

## What This Document Is NOT

- Not a requirement to invoke ALL skills on every message (wasteful)
- Not a replacement for user invocation (users can still type `/preflight:skill-name`)
- Not a gate that blocks work (that's the mechanical gate's job) — this is the FRIENDLY NUDGE that prevents hitting the gate

## Subagent Exception

If you were dispatched as a subagent (implementer, code-reviewer, external-review-handler, discovery-analyst), skip this routing. You have a specific task. Do it. Don't invoke other skills from within a subagent.

---
name: gps-decide
description: >-
  Help make decisions fast and ship, scaling scrutiny to stakes instead of
  over-analyzing everything. Uses the GPS framework (Ground / Push back /
  Stress test) gated behind a triage step, so most decisions skip analysis
  entirely. Use this skill when the user is weighing a consequential or
  hard-to-reverse choice, asking "should we do X" about something with real
  cost, evaluating options where the stakes are non-trivial, or is visibly
  stuck, circling, or repeatedly pressure-testing a decision. Also applies to
  consequential judgment calls in automated work — migration-readiness scores,
  recommended approaches, proposed rule or rubric changes — surfacing the
  strongest counter-case before the call is locked in. Do NOT trigger on
  trivial, cheap, easily reversible choices; the skill's own triage would only
  tell you to ship anyway, so loading it is wasted scrutiny. Do NOT trigger on
  code review of diffs or pull requests — that is handled separately by the
  dedicated code-reviewer; this skill is for decisions and judgment calls, not
  code.
---

# GPS-Decide

This skill exists to make decisions *get made*. It is built for a team whose
real risk is over-deliberation — careful people who pressure-test cheap,
reversible choices as if they were expensive, irreversible ones, and so ship
slower than the quality of their thinking warrants.

It uses the GPS framework — **G**round, **P**ush back, **S**tress test — but
corrects the assumption most decision frameworks get backwards:

> **Scrutiny is a cost, not a virtue.** A pass of analysis spends time,
> momentum, and team attention. It is worth paying only when the decision is
> expensive *and* hard to undo. For everything else — which is most things —
> the right amount of analysis is close to zero, and the correct output is
> "decide and move."

So GPS's three passes still exist here, but they are **gated**. Most decisions
never reach them. The gate is the skill.

## Step 1 — Triage (always do this first)

Before any analysis at all, ask one question:

> **If this decision turns out wrong, how hard is it to undo?**

- **Cheap and reversible** — fixable within roughly a week, no lasting damage.
  *The email subject line, the meeting format, which tool to trial, page copy,
  most contractor hires, small pricing experiments.* → **Ship now. Do not run
  GPS.** Decide in one sentence and move on. This is the large majority of
  decisions, and routing them through scrutiny is the exact failure mode this
  skill exists to stop.
- **Expensive or irreversible** — costs months to undo, burns a key
  relationship, is a one-way door, or bets the quarter. *Dropping a product
  line, the anchor-client pricing move, a senior hire, a long lock-in
  contract.* → **Run the full pass (Step 3).**
- **Genuinely unsure which** — do not deliberate about whether to deliberate.
  Treat it as cheap and ship, *unless* you can name a specific irreversible
  harm in one sentence. Vague unease does not promote a decision to
  "expensive."

The threshold is team-calibrated. For a team whose typical wrong decision costs
about a bad week, the bar for "expensive" is high — most of your work sits
below it. **When in doubt, the answer is ship.**

## Step 2 — The ship path (the default, ~90% of decisions)

Triage said cheap and reversible. Then:

1. State the decision in one sentence.
2. Give the one main reason.
3. Move on.

That is the entire procedure. A ten-second gut check is allowed. A second one
is not. If you catch yourself opening a doc to weigh a reversible decision,
that is the signal to stop and ship — the cost of being wrong is a week, and
you will know within days.

## Step 3 — The full GPS pass (the rare path)

Triage flagged the decision as expensive or irreversible. Only now do the three
passes earn their cost. Run them **once**.

- **Ground.** Name the real downside of being wrong and who the decision is
  for. Note whether it is a one-way door. Use real stakes — never inflate them
  to feel rigorous.
- **Push back.** State the strongest argument *against* your choice. Ask what a
  sharp competitor would exploit. List the load-bearing assumptions and mark
  which are verified vs. guessed.
- **Stress test.** What context is missing? Check for confirmation,
  survivorship, recency, and comfort bias. Then decide: ship, soften, test
  small first, or attach a warning.

Then go to the stop rule. Do not run a second pass.

## The external-test rule

When a Step 3 decision is still genuinely uncertain after one pass, **do not
analyze it again.** A second pass cannot manufacture information you do not
have. Instead, name the cheapest real-world test that would resolve the
uncertainty — call five customers, run a small ad test, ship a pilot to twenty
users — and run that. A day of real signal beats a week of good introspection,
and it is usually cheaper. For an over-thinking team, this is the most
important line in the skill: when stuck, test, do not think.

## The stop rule

You are done pressure-testing when one of these is true:

- Triage said cheap → you were done before you started.
- The full pass ran once and produced a specific, one-sentence reason the
  decision is dangerous → act on that reason, then ship.
- The full pass ran once and produced no specific danger → ship.

"I am still not comfortable" is **not** a reason to re-run GPS. It is a reason
to either name the specific risk in one sentence or ship. Discomfort is the
normal feeling of deciding under uncertainty; it is not new information.

## Team guards (because frameworks rot at team scale)

- **GPS runs once per decision** — one person or one meeting. Not iteratively,
  not "let's take another look next week."
- **"Did you GPS it?" is not a veto.** Anyone blocking a decision must name a
  specific, concrete, irreversible harm. "I have concerns" does not qualify.
- **The burden of proof is on delay, not on action.** The default is ship; the
  person arguing to wait carries the argument.
- **Log decisions, not deliberations.** One line — what was decided and the
  one reason — so it can be revisited. Not a scrutiny transcript.

## Honest inputs

GPS only improves a decision if its inputs are true. Use the real downside, not
an inflated one. Surface real flaws, not manufactured ones to seem rigorous. If
a choice survives the pass, ship it with that confidence — do not hollow it out
to perform caution.

## Worked examples

**Cheap decision — the common case.**
*"Should we change our onboarding email subject line?"* Triage: wrong answer
costs nothing lasting; changing it back takes two minutes. → **Ship.** Pick the
better-sounding one, send it, watch the open rate. Total deliberation: one
sentence. This decision must never see a GPS pass.

**Expensive decision — the rare case.**
*"Should we drop our second product line?"* Triage: rebuilding it later costs
months of work and lost customers — a one-way-ish door. → **Full pass.**
Ground: it is ~15% of revenue and the team is half its headcount. Push back:
the strongest counter is that the line is a feeder for the main product, not a
standalone bet — killing it may quietly cost main-product growth. Assumption:
that those customers do not cross-buy — unverified. Stress test → external
test: before deciding, pull the actual cross-buy numbers; that data, not more
debate, settles it. The pass ran once and handed off to a real test.

## Failure modes to refuse

- **Scrutinizing cheap decisions.** The central failure. If it is reversible
  within a week, it does not get a pass.
- **Re-running GPS because the answer felt uncomfortable.** Discomfort is not
  new information; the stop rule applies.
- **Using "did you pressure-test it" to stall or kill an idea.** A block needs
  a named, specific, irreversible harm.
- **Substituting another analysis pass for a real-world test.** When stuck,
  test, do not think.
- **Promoting vague unease to "expensive."** Only a one-sentence specific harm
  promotes a decision.

## Reference

`references/prompt-library.md` — short prompts for each step, written to bias
toward action: triage prompts, ship-path prompts, and the rare full-pass
prompts. Load it when you want the prompts themselves or a concrete one to run.

# GPS-Decide Prompt Library

Short prompts for running GPS-Decide. They are written to bias toward action,
because this skill is built for a team that over-deliberates. Every prompt
assumes honest inputs — real stakes, real flaws, no fabrication.

The order matters: triage first, ship by default, full pass only when triage
demands it.

---

## Triage prompts (always first)

**The gate.**
> "If this decision turns out wrong, how hard is it to undo — a bad week, or
> months? Be concrete."

**Force the call when unsure.**
> "I can't tell if this is cheap or expensive. Name a specific, one-sentence
> irreversible harm — or we treat it as cheap and ship."

**Catch a decision being over-weighted.**
> "This is reversible within a week. What would shipping it right now actually
> cost us? If the answer is 'not much,' decide and move."

---

## Ship-path prompts (the default, most decisions)

**Decide and move.**
> "State this decision in one sentence, give the single main reason, and that's
> the answer. No second pass."

**Stop a spiral.**
> "I've been weighing this for a while. The mistake costs a bad week at most.
> Pick the better option now and tell me what we'd watch to know if it's
> working."

---

## Full-pass prompts (rare — only when triage flags expensive/irreversible)

Run these once. Then go to the stop rule.

**Ground.**
> "What's the real downside if this is wrong, who is it for, and is it a
> one-way door? Use real stakes, not inflated ones."

**Push back.**
> "Give me the strongest argument against this choice, what a sharp competitor
> would exploit, and the load-bearing assumptions — marked verified or guessed."

**Stress test.**
> "What context is missing? Check for confirmation, survivorship, recency, and
> comfort bias. Then: ship, soften, test small, or warn?"

**External test (when still uncertain after one pass).**
> "Don't analyze this again. Name the single cheapest real-world test — a few
> calls, a small spend, a pilot — that would settle it, and let's run that."

---

## Stop-rule prompt

> "We've run one pass. Either there's a specific, one-sentence reason this is
> dangerous — say it and act on it — or we ship. 'Still not comfortable' isn't
> a reason to go again."

---

## Team-use prompts

**When someone blocks a decision.**
> "What's the specific, concrete, irreversible harm here? If it's 'I have
> concerns,' that's not a block — the default is ship."

**Logging.**
> "One line: what we decided and the one reason. Not a transcript. So we can
> revisit it later if needed."

---

## The whole thing in one rule

If you remember nothing else: **most decisions are reversible and cheap — ship
those immediately; for the rare expensive one, run one pass, and if you're
still unsure, run a real test instead of thinking again.**

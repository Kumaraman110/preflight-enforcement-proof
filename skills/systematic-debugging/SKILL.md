---
name: systematic-debugging
description: Root cause analysis before fixes. Use when a bug or test failure resists quick fixes, when the same issue recurs after fixing, or when you've made 3+ attempts at a fix without success. Enforces investigate-before-fix discipline. Prevents the "try random things until it works" anti-pattern.
argument-hint: [description of the bug or failing behavior]
allowed-tools: Read, Glob, Grep, Bash
---

# /code-forge:systematic-debugging — Root Cause First

You are in systematic debugging mode. The user (or your own judgment) has determined that a bug requires structured investigation rather than trial-and-error fixes.

<HARD-GATE>
Do NOT write any fix until you have completed Phase 2 (hypothesis with evidence). Jumping to fixes without root cause understanding is how you create cascading divergence — fixing symptom A while the real cause B remains, producing symptoms C, D, E in subsequent rounds.
</HARD-GATE>

## When This Activates

- Test failure that persists after 1 fix attempt
- Runtime error with non-obvious cause
- Stage 1 finding that recurs after being "fixed"
- Copilot comment that you've addressed but keeps returning
- Any time you think "I don't understand WHY this is happening"

## The Four Phases

### Phase 1: Observe (DO NOT FIX ANYTHING)

1. **Reproduce the symptom.** What exactly fails? What is the error message/behavior? What is the expected behavior?
2. **Scope the blast radius.** What files are involved? What changed recently that could have caused this?
3. **Trace the data flow.** From input to failure point — what path does execution take? Where does the value/state go wrong?
4. **Identify the earliest divergence.** At what point does actual behavior first differ from expected? This is usually NOT where the error manifests — it's upstream.

### Phase 2: Hypothesize (DO NOT FIX ANYTHING)

5. **Formulate exactly ONE hypothesis.** "The bug occurs because [X] causes [Y] at [location]." Be specific — file, line, mechanism.
6. **Identify evidence that would CONFIRM the hypothesis.** What would you see if this hypothesis is correct?
7. **Identify evidence that would REFUTE the hypothesis.** What would you see if this hypothesis is wrong?
8. **Gather the evidence.** Read code, run tests with specific inputs, add diagnostic output. Does the evidence confirm or refute?

### Phase 3: Validate

9. **If confirmed:** You now know the root cause. Proceed to fix.
10. **If refuted:** Return to Phase 1 with new information. Formulate a new hypothesis. Do NOT attempt a fix based on a refuted hypothesis.

### Phase 4: Fix (ONLY after validated root cause)

11. **Design the fix based on the validated root cause.** Not on the symptom.
12. **Predict the fix's effects.** What other code paths does this change affect? Could it introduce new issues?
13. **Apply the fix.**
14. **Verify the fix resolves the original symptom AND does not introduce regressions.**

## Rationalization Prevention

| Your thought | Why it's wrong |
|---|---|
| "I can see the bug, let me just fix it quick" | If you could see it, you'd have fixed it already. The thing you're seeing is the symptom, not the cause. |
| "This is taking too long, let me try something" | Trying without understanding is how you got here. 10 minutes of investigation saves 60 minutes of trial-and-error. |
| "The fix is obvious — just add a null check" | Null checks are band-aids. WHY is it null? If you don't know, the null will resurface elsewhere. |
| "I've been debugging for 3 rounds, let me just ask the user" | Did you complete Phases 1-3? If not, you haven't debugged — you've been guessing. Complete the phases first. |

## Anti-Patterns This Prevents

- **Shotgun debugging:** changing multiple things hoping one works
- **Symptom fixing:** adding guards/checks without understanding the cause
- **Cascade creation:** fixing A introduces B, fixing B introduces C
- **Time waste:** 17 rounds of review because round 3's fix was based on a wrong hypothesis

## Output

Report your findings as:
```
## Root Cause Analysis

**Symptom:** [what fails]
**Root cause:** [why it fails — file:line, mechanism]
**Evidence:** [what confirmed this]
**Fix:** [what to change]
**Risk:** [what else this change affects]
```

Begin investigation. Do not write code until Phase 3 validates your hypothesis.

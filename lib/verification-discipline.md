# Verification Discipline

Adopted from Superpowers' `verification-before-completion` principle. This is not a workflow step — it is an always-on behavioral discipline that applies at EVERY point where the system is about to claim something succeeded.

## The Iron Law

```
NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE
```

If you haven't run the verification command in THIS interaction, you cannot claim it passes. Memory of a previous pass is not evidence — it's stale.

## Where This Applies

| Claim | Requires | NOT Sufficient |
|---|---|---|
| "Tests pass" | `dotnet test` output showing 0 failures, run AFTER latest change | Previous run, "should pass", implementer said they pass |
| "Build succeeds" | `dotnet build` output showing 0 errors 0 warnings | "Tests pass" (tests ≠ build), linter clean |
| "Stage 1 clean" | rubric-reviewer output saying CLEAN on current diff | Previous iteration's CLEAN, "I only changed whitespace" |
| "Implementer fixed it" | `dotnet build` + `dotnet test` run BY THE ORCHESTRATOR after accepting the fix | Implementer's report of DONE |
| "Coverage meets baseline" | Coverage report showing ≥ threshold | "All tests pass" (pass ≠ coverage) |
| "Dependency map is valid" | Validator script output showing 0 blocking warnings | "I generated it from the code" |

## Rationalization Prevention

| Thought | Reality |
|---|---|
| "Should work now" | RUN the verification |
| "The implementer already tested it" | Implementer's context might have been degraded. Verify independently. |
| "I just ran tests 2 minutes ago" | You've made changes since. Run again. |
| "It's just a comment change, can't break anything" | Comment changes in XML doc strings affect build. Run build. |
| "Stage 1 was clean, this tiny fix can't introduce anything" | The fix INTERACTS with other code. Stage 1 catches interactions. Review. |
| "Linter passed so build will pass" | Linter checks style. Build checks compilation. Orthogonal. |

## The Gate Function

BEFORE claiming any status (writing gate evidence, marking a stage complete, reporting to user):

1. **IDENTIFY:** What command proves this claim?
2. **RUN:** Execute the FULL command (fresh, complete, not cached)
3. **READ:** Full output — exit code, failure count, specific results
4. **VERIFY:** Does the output confirm the claim?
   - NO → State actual status with evidence. Do not round up.
   - YES → State claim with evidence. Write gate evidence.
5. **ONLY THEN:** Make the claim.

Skipping any step = lying, not verifying.

## Integration with Mechanical Gates

The verification discipline feeds the mechanical gate system:
- Verification passes → write gate evidence file → pre-push gate accepts
- Verification fails → no evidence written → pre-push gate blocks

This means: even if the LLM's verification discipline degrades at high context (skipping step 2), the mechanical gate catches it — no evidence file exists, so push is blocked regardless. Defense in depth: behavioral discipline (fast feedback) + mechanical enforcement (hard block).

## The Superpowers Principle We Adopt

> "Claiming work is complete without verification is dishonesty, not efficiency."

This applies to every sub-agent handoff in preflight:
- Discovery-analyst says the map is complete → orchestrator verifies file exists and parses
- Implementer says DONE → orchestrator runs build + test independently
- Rubric-reviewer says CLEAN → orchestrator verifies the reviewed diff matches current state
- Copilot-loop says SUCCESS → orchestrator runs structural verification

**Never trust a sub-agent's success report. Verify the claim against ground truth.**

# Proactive Skill Triggering

Adopted from Superpowers' "1% rule." Skills activate automatically based on context signals, not only on user invocation. The user should never need to remember which skill applies — the system detects and triggers.

## The Rule

If there is a reasonable chance a skill applies to what you are about to do, invoke it. Do not wait for the user to type `/preflight:skill-name`. The skills exist to prevent failures — waiting for explicit invocation means they only help users who already know they need help.

## Trigger Conditions

| Signal | Skill to trigger | Rationale |
|---|---|---|
| About to run `git push` | `self-review` (if gate evidence is stale/missing) | Pre-push gate may block; better to catch issues now than hit a wall |
| Test failure after a fix attempt | `systematic-debugging` (if 2+ fix attempts failed) | Prevents shotgun debugging; forces root cause investigation |
| Writing new functionality (not fixing existing) | `test-driven-development` | Prevents tests-after-implementation anti-pattern |
| About to claim "done" on any multi-step task | Verification discipline check | Prevents false completion claims |
| Starting a new service migration | `migrate` | Ensures Phase 1 discovery runs; prevents "looks simple" skip |
| Multiple findings on the same file after fixing | Coupled-group protocol re-check | Prevents independent-fix cascade |

## How This Works in Practice

The main Claude Code session (the orchestrator, or the user's direct conversation) should check these triggers at natural decision points:

1. **Before any git operation:** Is gate evidence fresh? If not, suggest running self-review.
2. **After test failure:** Is this the 2nd+ failure on the same test? If so, announce systematic-debugging activation.
3. **Before writing implementation code:** Is there a failing test for this behavior? If not, suggest TDD mode.
4. **Before reporting completion:** Have you run fresh verification? If not, run it now.

## What This Is NOT

- Not a requirement to invoke ALL skills on every message (that's wasteful)
- Not a replacement for user invocation (users can still explicitly invoke skills)
- Not a hard gate (proactive triggering suggests, mechanical gates block)

## Relationship to Mechanical Gates

Proactive triggering is the SOFT layer. It surfaces suggestions BEFORE you hit the hard mechanical gate:

```
Proactive trigger: "You're about to push. Self-review hasn't run on this HEAD."
  ↓ (user ignores)
Mechanical gate: "BLOCKED: Stage 1 review has not run."
```

The proactive trigger is the friendly nudge. The mechanical gate is the wall. Both exist because neither alone is sufficient: nudges can be ignored (context degradation), walls can't give early warning (user hits them after doing work that needs to be redone).

## Integration

The session-start hook outputs context that includes which mode is active. Skills should check this context and self-activate when their trigger conditions are met. No central dispatcher is needed — each skill's Step 0 (self-detection) can include trigger-condition awareness.

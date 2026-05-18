---
name: fix-and-close
description: Stage 1 gate → commit → push → Stage 2 Copilot review loop → clean PR. Use when you have changes ready to push and want the full review pipeline. Works with any project that has (or doesn't have) a code-forge config. Handles oscillation, divergence detection, and learning capture.
argument-hint: [optional commit-message hint]
allowed-tools: Read, Glob, Grep, Bash, Edit, Write, Agent
---

# /code-forge:fix-and-close — Full Review Pipeline

You are running the full push-to-clean pipeline: Stage 1 gate → commit → push → Stage 2 Copilot loop → clean PR.

The user may have passed `$ARGUMENTS` as a commit-message hint.

## Architectural Commitment

**Stage 1 runs before every push. No exceptions.**

<HARD-GATE>
Do NOT push until Stage 1 returns CLEAN AND tests pass (if a test runner is configured). No rationalization overrides this. If you find yourself thinking "just this once I can skip Stage 1," stop. That thought is the bug.
</HARD-GATE>

<HARD-GATE>
Do NOT claim success without fresh verification evidence. "It should work" is not evidence. `dotnet test` output showing 0 failures IS evidence. Stage 1 returning CLEAN IS evidence. Assertion without proof is not completion.
</HARD-GATE>

## Rationalization Prevention

| Your thought | Why it's wrong |
|---|---|
| "Stage 1 was clean last round, this whitespace fix doesn't need re-review" | Whitespace-only diffs can mask real changes in adjacent lines. Review. Always. |
| "I've been looping for 6 rounds, let me just push this and see what Copilot says" | Pushing dirty code costs 200-300s of Copilot latency per issue. Stage 1 catches it in 30s. |
| "Tests are passing, Stage 1 findings must be false positives" | Tests verify behavior. Stage 1 verifies security, style, and architectural rules. They are orthogonal. Both must pass. |
| "Copilot won't care about this minor finding" | You don't know what Copilot will flag. Eat the 30s cost now rather than gamble 300s later. |
| "The divergence detector is being too conservative, I'm making progress" | If findings aren't converging after 3 rounds, you're shuffling issues, not fixing them. Stop and rethink. |

## Configuration

Read project config (`.code-forge/config.json` > `.cpsl/config.json` > `.forge.json`). Extract:
- `branch.base` (default: `main`)
- `branch.remote` (default: `origin`)
- `review.*` (Copilot settings)
- `loop.*` (oscillation, coverage)
- `capture.*` (file paths)
- `test.command` (default: `dotnet test` if a `.csproj`/`.sln` exists, otherwise skip)
- `test.coverageBaseline` (default: none — skip coverage check if not set)

## Execution

### Pre-flight

1. Confirm branch is a feature/fix/chore branch. If on main/base branch, abort.
2. Determine diff scope (uncommitted + unpushed).
3. If nothing to push, inform user and exit.

### Stage 1 Gate

4. **Run tests** (if configured): `dotnet test` or equivalent. Must pass.
5. **Invoke `rubric-reviewer` sub-agent.** Always. Even for one-line changes.
6. If `NEEDS_FIXES` → fix blockers and majors. Re-run tests. Re-invoke Stage 1. Loop.
7. **Divergence detection:** if `findings[N] >= findings[N-2]`, emit warning. If it persists one more round, STOP and surface to user as DIVERGING.
8. If `CLEAN` → proceed.

### Commit and Push

9. Stage changed files explicitly (never `git add .`).
10. Compose conventional-commit message (biased by user's hint).
11. Push to remote feature branch (never `--force`).

### Stage 2 — Copilot Review Loop

12. **Invoke `copilot-loop` sub-agent.**
13. Handle status codes:
    - `SUCCESS` → final summary, exit.
    - `NEEDS_PARENT_FIXES` → apply fixes. Run tests. Invoke Stage 1 (the gate applies on EVERY push). When clean, commit + push. Re-invoke Stage 2.
    - `STUCK` / `DIVERGING` → surface to user with evidence. Do not push more.
    - `FAILED` → surface error. Do not retry blindly.
    - `ERROR` → abort.

### Final Summary

14. PR URL, total iterations, capture entries by bucket, coverage achieved, any STUCK/FAILED encountered.
15. Tell user PR is ready for human review. Do NOT merge.

## Structured Status

At any point, if you cannot proceed, report one of:
- **DONE** — PR clean, human can merge
- **BLOCKED** — external dependency (Copilot never responds, auth expired, rate limited). Surface to user.
- **DIVERGING** — findings not converging. Structural rethink needed.
- **STUCK** — oscillation detected. Human must investigate.

## What This Does NOT Do

- Merge the PR
- Force-push
- Skip Stage 1 for any push (including post-Copilot fixes)
- Skip tests before push
- Edit capture files (the copilot-loop agent does that)

Begin now. Run pre-flight checks.

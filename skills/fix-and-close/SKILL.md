---
name: fix-and-close
description: Stage 1 gate → commit → push → Stage 2 Copilot review loop → clean PR. Use when you have changes ready to push and want the full review pipeline. Works with any project that has (or doesn't have) a code-forge config. Handles coupled-finding grouping, hard iteration caps, oscillation, divergence, and learning capture.
argument-hint: [optional commit-message hint]
allowed-tools: Read, Glob, Grep, Bash, Edit, Write, Agent
---

# /code-forge:fix-and-close — Full Review Pipeline

You are running the full push-to-clean pipeline: Stage 1 gate → commit → push → Stage 2 Copilot loop → clean PR.

The user may have passed `$ARGUMENTS` as a commit-message hint.

## Why This Exists (The 70-Round Reality)

A prior migration took 70+ Copilot review rounds. Analysis shows:
- ~23% were mechanical mistakes preventable by patterns (shouldn't exist if code was generated correctly)
- ~29% were genuine semantic issues (legitimate review value)
- ~48% were **cascading regressions** — fixing finding A introduced finding B, fixing B introduced C

The 48% is caused by one specific failure mode: fixing COUPLED findings independently instead of as a group. This skill's primary job is to prevent that cascade.

## Architectural Commitment

**Stage 1 runs before every push. No exceptions.**

<HARD-GATE>
Do NOT push until Stage 1 returns CLEAN AND tests pass. No rationalization overrides this. If you find yourself thinking "just this once I can skip Stage 1," stop. That thought is the bug.
</HARD-GATE>

<HARD-GATE>
Do NOT claim success without fresh verification evidence. `dotnet test` output showing 0 failures IS evidence. Stage 1 returning CLEAN IS evidence. "It should work" is NOT evidence.
</HARD-GATE>

<HARD-GATE>
Do NOT fix coupled findings independently. When multiple findings touch the same file or the same call chain, you MUST read all of them first, design ONE coherent change that addresses all of them simultaneously, then apply that single change. Sequential independent fixes to coupled findings is the primary cause of cascading regressions.
</HARD-GATE>

## Hard Iteration Caps

These are non-negotiable. The system does NOT loop indefinitely.

| Loop | Maximum iterations | On cap hit |
|---|---|---|
| Stage 1 (pre-push) | **5** | STOP. Surface remaining findings to user. The issues are architecturally coupled and need human judgment. |
| Stage 2 (Copilot) | **8** | STOP. Surface to user. The remaining findings likely require rethinking the approach, not more patches. |

**Why these numbers:** After 5 Stage 1 iterations, remaining issues are structurally coupled (each fix creates a new finding). After 8 Copilot rounds, you're in cascading territory. More rounds won't converge — they'll oscillate. The previous 70-round migration proved that rounds 15-70 produced net-zero progress.

If you hit a cap, DO NOT:
- Attempt to push with known issues
- Try "one more round" by reframing it
- Summarize remaining findings as "minor" to bypass the cap

Instead: report the cap hit, list remaining findings, and ask the user for direction.

## Rationalization Prevention

| Your thought | Why it's wrong |
|---|---|
| "Stage 1 was clean last round, this whitespace fix doesn't need re-review" | Whitespace-only diffs can mask real changes in adjacent lines. Review. Always. |
| "I've been looping for 6 rounds, let me just push this and see what Copilot says" | Each push costs 200-300s of Copilot latency per finding. Stage 1 catches issues in 30s. Over 70 rounds, that's 6+ hours of waiting you could have avoided. |
| "Tests are passing, Stage 1 findings must be false positives" | Tests verify behavior. Stage 1 verifies security, style, and architectural rules. They are orthogonal. Both must pass. |
| "The iteration cap is being too conservative, I'm making progress" | You're not. Count-based convergence shows you're shuffling issues between files. The cap exists because 70-round data proved rounds past the cap produce negative value. |
| "These findings look independent, I can fix them one by one" | If they touch the same file or call chain, they INTERACT. Fixing one changes the correct fix for the others. Read ALL coupled findings before writing ANY fix. |

## Configuration

Read project config (`.code-forge/config.json` > `.cpsl/config.json` > `.forge.json`). Extract:
- `branch.base` (default: `main`)
- `branch.remote` (default: `origin`)
- `review.*` (Copilot settings)
- `loop.*` (oscillation, coverage, iteration caps)
- `capture.*` (file paths)
- `test.command` (default: `dotnet test` if `.csproj`/`.sln` exists, otherwise skip)
- `test.coverageBaseline` (default: none)

## Execution

### Pre-flight

1. Confirm branch is feature/fix/chore. If on main/base, abort.
2. Determine diff scope (uncommitted + unpushed).
3. If nothing to push, inform user and exit.

### Stage 1 Gate

4. **Run tests.** Must pass. If they fail, fix compilation/test errors FIRST (these are not rubric findings — they're broken code).

5. **Invoke `rubric-reviewer` sub-agent.** Always. Even for one-line changes.

6. **If NEEDS_FIXES — apply the Coupled-Group Fix Protocol:**

   a. **Read ALL findings at once.** Do not start fixing after reading the first one.
   
   b. **Group by coupling.** Use the dependency map (if Phase 1 produced one) as the primary source. Otherwise, findings are coupled if they share ANY of:
      - Same file
      - Same class/method
      - Same call chain (method A calls method B — findings on both are coupled)
      - Same DI registration (finding on the service + finding on the consumer are coupled)
      - Causal relationship (fixing A would change the lines where B exists)
   
   c. **Fix independent findings directly.** Findings that touch isolated files with no interaction (Dockerfile, CI yaml, standalone config) — fix these yourself, one by one. They can't cascade.
   
   d. **Dispatch each coupled group to the `implementer` sub-agent.** Compose a fix brief containing:
      - The files in the group (and ONLY those files)
      - All findings in the group (they MUST be fixed simultaneously)
      - The coupling reason
      - The applicable generation-spec pattern (if one exists)
      - What was tried previously on those files (from your fix history this session)
      - The constraint (typically: `dotnet build` + `dotnet test` must pass)
      
      The implementer returns DONE or BLOCKED.
      - DONE: accept the fix, continue.
      - BLOCKED: either re-scope the group (split differently, provide more context) or escalate to user.
   
   e. **After all groups fixed:** re-run tests. Re-invoke Stage 1.
   
   **Why dispatch to implementer instead of fixing yourself:** Your context accumulates Phase 1 output, fix histories, previous diffs, and orchestration state. After 3 rounds, you're at 70%+ context utilization. The implementer starts fresh at ~5% with exactly the files and findings it needs. It can't be confused by stale context from previous rounds. This is how we avoid the 70-round pattern where late-round fixes degraded because the session was saturated.

7. **Track convergence:**
   - Record finding count per iteration: `[iter1: 5, iter2: 3, iter3: 4, iter4: 2, ...]`
   - If `count[N] >= count[N-2]` → DIVERGING warning. One more chance.
   - If still not converging → STUCK. Hit the cap early.
   - If iteration count reaches 5 → HARD STOP regardless of convergence.

8. **If CLEAN** → proceed to commit/push.

### Commit and Push

9. Stage files explicitly (never `git add .`). Exclude: `bin/`, `obj/`, `*.user`, `coverage.opencover.xml`.
10. Compose conventional-commit message (biased by user's hint if given).
11. Push to remote feature branch (never `--force`).

### Stage 2 — Copilot Review Loop

12. **Invoke `copilot-loop` sub-agent.**

13. **Handle status codes:**

    - `SUCCESS` → final summary, exit.
    
    - `NEEDS_PARENT_FIXES` → **Apply the same Coupled-Group Fix Protocol (step 6 above).** Group Copilot's findings by coupling. Fix coupled groups as single coherent changes. Then: run tests → invoke Stage 1 → when clean → commit + push → re-invoke Stage 2. **Track Stage 2 iteration count separately. Cap at 8.**
    
    - `STUCK` / `DIVERGING` → surface to user with evidence. Do not push more.
    
    - `FAILED` → surface error verbatim. Do not retry blindly.
    
    - `ERROR` → abort.

### Structural Verification (Before Declaring Success)

After Stage 2 returns `SUCCESS`, before declaring done, verify:
- Tests still pass (fresh run — not cached result from earlier)
- If project config has a `migration.referenceService`: verify the migrated service has the same directory structure (Program.cs, Services/, Models/, Configuration/, Health/ — whatever the reference has)
- Health endpoint responds (if service can be started locally)

If structural verification fails, DO NOT declare success. Surface the gap.

### Final Summary

14. PR URL, total Stage 1 iterations, total Stage 2 iterations, capture entries by bucket, coverage achieved.
15. Tell user PR is ready for human review. Do NOT merge.

## Operative Capture Rules

When capture files contain entries with `**IMMEDIATE DETECTION RULE:**` blocks, these are LIVE rules that supplement the rubric in real time. The rubric-reviewer reads them. They take effect immediately — not after a batched PR.

The capture entry format for operative rules:
```markdown
## <date> — §<section> missed

**IMMEDIATE DETECTION RULE:**
Flag as `<severity>` if: <condition>

**BAD (literal match):**
\`\`\`csharp
<anti-pattern code>
\`\`\`

**GOOD (must coexist):**
\`\`\`csharp
<required pattern>
\`\`\`
```

This means learnings take effect on the NEXT Stage 1 invocation — not 5 services later.

## Structured Status

At any point, if you cannot proceed:
- **DONE** — PR clean, human can merge
- **CAPPED** — hit iteration limit. Remaining findings listed. Needs human direction.
- **BLOCKED** — external dependency (Copilot timeout, auth expired, rate limit)
- **DIVERGING** — findings not converging. Structural rethink needed.
- **STUCK** — oscillation detected (same file/line churning)

## What This Does NOT Do

- Merge the PR
- Force-push
- Skip Stage 1 for any push
- Skip tests before push
- Fix coupled findings independently (the #1 cascade cause)
- Loop past iteration caps
- Edit capture files (copilot-loop does that)

Begin now. Run pre-flight checks.

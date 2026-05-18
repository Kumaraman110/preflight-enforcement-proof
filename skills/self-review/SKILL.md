---
name: self-review
description: Run a Stage 1 self-review against the current diff. Walks the project's rubric (or defaults), surfaces findings, fixes them locally, and loops until clean. Never pushes, never commits, never opens a PR. Use when preparing code for push or wanting to validate quality before committing.
argument-hint: [optional scope hint, e.g. "just the new file" or "skip tests"]
allowed-tools: Read, Glob, Grep, Bash, Edit, Agent
---

# /code-forge:self-review — Stage 1 Standalone

You are running a standalone Stage 1 self-review. This is the same gate that `/code-forge:fix-and-close` runs before every push, invoked here on demand.

The user may have passed `$ARGUMENTS` as scope hint. Treat it as advisory — actual scope is always the current diff.

## Step 0 — Environment Detection

If session context already contains `code-forge active | mode=...` with config path and rubric path, trust it — the session-start hook already parsed the config. Skip to step 5 (rubric existence check only).

If session context is empty or this skill was invoked cold (no hook ran):

1. Search for config: `.code-forge/config.json` > `.cpsl/config.json` > `.forge.json` (in working directory, then up to 5 parent levels).
2. If found: extract `mode`, `rubric`, `branch.base`, `test.command`, `loop.*`, `capture.*`.
3. If not found: use defaults — mode `generic`, rubric from `${CLAUDE_PLUGIN_ROOT}/defaults/rubric-generic.md`, base branch `main`, test command auto-detected.
4. Check for `CLAUDE.md` at project root for supplementary conventions.
5. Confirm the rubric file exists at the resolved path. If missing, warn and fall back to the generic default.

## The Behavior Contract

You orchestrate the **`rubric-reviewer`** sub-agent. You do NOT review code yourself — that is the sub-agent's job. Your job is loop control and fixing.

<HARD-GATE>
Always invoke the rubric-reviewer sub-agent. Do not skip invocation because the diff "looks trivial" or "is just a one-liner." That judgment belongs to the sub-agent. Every time you think "this doesn't need review," that is the exact moment it does.
</HARD-GATE>

### Rationalization Prevention

| Your thought | Why it's wrong |
|---|---|
| "I just wrote this code, I know it's correct" | You are the author. Authors are blind to their own bugs. That's why Stage 1 exists. |
| "Running the sub-agent on 3 changed lines wastes tokens" | Missing a CWE-117 in those 3 lines costs 300+ seconds of Copilot round-trip. 30 seconds of review is cheap. |
| "The previous iteration was clean, this tiny fix can't have introduced anything" | Fixes introduce issues. That's the cascading divergence pattern. Always re-verify. |
| "I'll batch these changes and review them all at once later" | Batching hides interaction effects between changes. Review incrementally. |

## Execution

1. **Confirm project state.** Look for a project root indicator (`.git/`, `CLAUDE.md`, `.code-forge/config.json`). If nothing found, inform user but proceed — the sub-agent will use default rubric.

2. **Determine diff scope:**
   - Feature branch (starts with `feature/`, `chore/`, `fix/`): scope = `<base>...HEAD` + uncommitted
   - Other branch: scope = uncommitted changes only
   - Clean + not feature branch: nothing to review, exit

3. **Invoke `rubric-reviewer` sub-agent.** Pass diff scope context.

4. **Read the sub-agent's output** (verification discipline: the sub-agent's report is a CLAIM — verify the diff it reviewed matches your current state):
   - `CLEAN` → verify the sub-agent's "Files reviewed" list matches current diff (`git diff --name-only`). If it does, declare success, summarize, exit. Do not push, commit.
   - `NEEDS_FIXES` → continue to step 5.
   - `ERROR` → surface to user, exit.

5. **Present findings.** Blocker first, then major, then minor. For each: file, line, section, issue, suggestion.

6. **Apply Coupled-Group Fix Protocol:**

   a. Read ALL findings before fixing ANY.
   b. Group by coupling: same file, same call chain, same DI graph, causal relationship.
   c. Fix independent findings first (isolated files, no interaction).
   d. Fix each coupled group as ONE coherent change — design a single edit that satisfies all constraints in the group simultaneously.
   e. Ambiguous or judgment-requiring findings → ask user.

7. **Re-invoke `rubric-reviewer`.** Same scope, post-fix. Back to step 4.

8. **Hard cap: maximum 5 iterations.** On cap hit: STOP. Report remaining findings. Inform user: "Hit iteration cap. Remaining findings are likely structurally coupled. Recommend addressing them as a group with fresh context or asking for human direction."

9. **Divergence detection.** Track finding counts per iteration. If `count[N] >= count[N-2]` → STOP. Inform user: "Findings not converging. Remaining issues interact — each fix creates a new finding elsewhere."

10. **Oscillation detection.** If same findings appear in two consecutive iterations → STOP. Report.

## What This Does NOT Do

- Push to any remote
- Commit (user decides when)
- Open a PR
- Invoke the Copilot loop (that's `/code-forge:fix-and-close`)
- Write to capture files (that's Stage 2's job)

## Communication

- Report iteration number on every loop
- Show finding counts and severity breakdown
- When you fix something, explain what and why (cite rubric section)
- When you stop, summarize: iterations, findings fixed, what's unresolved

## Proactive Triggering

This skill self-activates (see `${CLAUDE_PLUGIN_ROOT}/lib/proactive-triggering.md`) when:
- The session is about to run `git push` and gate evidence is stale or missing
- The parent agent has just finished writing code and is about to claim "done"

Begin now. Invoke the `rubric-reviewer` sub-agent.

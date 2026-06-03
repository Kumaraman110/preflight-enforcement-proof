---
name: fix-and-close
description: Stage 1 gate → commit → push → Stage 2 Copilot review loop → clean PR. Use when you have changes ready to push and want the full review pipeline. Works with any project that has (or doesn't have) a preflight config. Handles coupled-finding grouping, hard iteration caps, oscillation, divergence, and learning capture.
argument-hint: [optional commit-message hint]
allowed-tools: Read, Glob, Grep, Bash, Edit, Write, Agent
---

# /preflight:fix-and-close — Full Review Pipeline

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

<CRITICAL-INSTRUCTION>
Do NOT push until Stage 1 returns CLEAN AND tests pass. No rationalization overrides this. If you find yourself thinking "just this once I can skip Stage 1," stop. That thought is the bug.
</CRITICAL-INSTRUCTION>

<CRITICAL-INSTRUCTION>
Do NOT claim success without fresh verification evidence. Test command output showing 0 failures IS evidence. Stage 1 returning CLEAN IS evidence. "It should work" is NOT evidence.
</CRITICAL-INSTRUCTION>

<CRITICAL-INSTRUCTION>
Do NOT fix coupled findings independently. When multiple findings touch the same file or the same call chain, you MUST read all of them first, design ONE coherent change that addresses all of them simultaneously, then apply that single change. Sequential independent fixes to coupled findings is the primary cause of cascading regressions.
</CRITICAL-INSTRUCTION>

## Hard Iteration Caps

These are non-negotiable. The system does NOT loop indefinitely.

| Loop | Maximum iterations | On cap hit |
|---|---|---|
| Stage 1 (pre-push) | **5** | STOP. Surface remaining findings to user. The issues are architecturally coupled and need human judgment. |
| Stage 2 (Copilot) | **3** (override: `--max-stage2=N` up to 8) | STOP. Surface to user. If 3 rounds of STABLE-only fixes don't converge, the coupling map is wrong — more rounds will cascade, not converge. |

**Why 3 for Stage 2:** The stability filter routes all non-deterministic findings to the user. Only STABLE findings (mechanical: wrong method, missing annotation, incorrect type) drive auto-fixes in Stage 2. Deterministic fixes on correctly-coupled groups converge in 1-2 rounds. If round 3 still has findings, exactly one thing is true: the dependency map missed a coupling edge, so fixes are cascading. Rounds 4+ would repeat the cascade. The old cap of 8 predates the stability filter — it existed because unstable findings drove slow-convergence cycles that no longer occur.

**Why 5 for Stage 1:** Stage 1 uses YOUR rubric (deterministic boolean conditions) against YOUR code (freshly written). No external oracle. Progressive detection (the rubric catching more instances as it sees the pattern) legitimately takes 3-4 rounds. Cap at 5 gives one buffer round.

If you hit a cap, DO NOT:
- Attempt to push with known issues
- Try "one more round" by reframing it
- Summarize remaining findings as "minor" to bypass the cap

Instead: report the cap hit, list remaining findings, and ask the user for direction.

## Step 0 — Environment Detection

If session context already contains `preflight active | mode=...` with config path and rubric path, trust it — the session-start hook already parsed the config. Skip to step 5 (rubric existence check only).

If session context is empty or this skill was invoked cold (no hook ran):

1. Search for config: `.preflight/config.json` > `.cpsl/config.json` > `.forge.json` (in working directory, then up to 5 parent levels).
2. If found: extract all fields below.
3. If not found: use defaults below.
4. Check for `CLAUDE.md` at project root for supplementary conventions.
5. Confirm the rubric file exists at the resolved path. If missing, warn and fall back to `${CLAUDE_PLUGIN_ROOT}/examples/rubrics/rubric-generic-dotnet.md`.

## Configuration

From config (or defaults):
- `branch.base` (default: `main`)
- `branch.remote` (default: `origin`)
- `review.*` (Copilot settings)
- `loop.*` (oscillation, coverage, iteration caps)
- `capture.*` (file paths)
- `test.command` (default: auto-detect — `dotnet test` if `.csproj`/`.sln`/`.fsproj`/`.vbproj` exists, `mvn test` if `pom.xml` exists, `pytest` if `pyproject.toml`/`requirements.txt` exists, `npm test` if `package.json` exists; otherwise skip with warning)
- `test.coverageBaseline` (default: none)

## Execution

### Pre-flight

1. Confirm branch is feature/fix/chore. If on main/base, abort.
2. Determine diff scope (uncommitted + unpushed).
3. If nothing to push, inform user and exit.

### Stage 1 Gate

4. **Run tests.** Must pass. If they fail, fix compilation/test errors FIRST (these are not rubric findings — they're broken code). **On pass:** write gate evidence: `bash "${CLAUDE_PLUGIN_ROOT}/hooks/write-gate-evidence" tests-pass`

5. **Invoke `code-reviewer` sub-agent.** Always. Even for one-line changes.

6. **If NEEDS_FIXES — apply the Coupled-Group Fix Protocol:**

   a. **Read ALL findings at once.** Do not start fixing after reading the first one.
   
   b. **Group by coupling.** Use the dependency map (if one exists at `<service-folder>/dependency-map.json`) as the primary source.
   
      **Freshness check (before every consumption):** Run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/dependency-map-validator"` before reading the map. If exit 0: map is fresh (or was re-stamped). Proceed. If exit 1: map is stale — dispatch the `discovery-analyst` sub-agent with brief: "dependency-map-only refresh — produce updated dependency-map.json for the current code state without re-running Phase 1 technical debt scan." When the analyst returns DONE, re-run the validator to confirm freshness, then proceed.
      
      **Structural validation (first use per session):** Run the mechanical validation from `${CLAUDE_PLUGIN_ROOT}/lib/dependency-map-validator.md` — never consume the map without validation. If validation passes (with or without corrections applied), write gate evidence: `bash "${CLAUDE_PLUGIN_ROOT}/hooks/write-gate-evidence" map-validated`. If validation produces warnings, apply the corrections (merge groups, move files from independent) before grouping.
   
      If no dependency map exists, findings are coupled if they share ANY of:
      - Same file
      - Same class/method
      - Same call chain (method A calls method B — findings on both are coupled)
      - Same DI registration (finding on the service + finding on the consumer are coupled)
      - Causal relationship (fixing A would change the lines where B exists)
   
   b2. **Write active groups to the mechanical gate.** After grouping is complete:
      ```bash
      bash "${CLAUDE_PLUGIN_ROOT}/hooks/write-active-groups" '<json>'
      ```
      Where `<json>` is the array of groups with files, findings summary, and `"acknowledged": false`. This activates the coupled-edit-gate — any Edit to a file in an unacknowledged group will be BLOCKED by the PreToolUse hook. This is the mechanical enforcement of "read ALL before fixing ANY."
   
   c. **Fix independent findings directly.** Findings that touch isolated files with no interaction (Dockerfile, CI yaml, standalone config) — fix these yourself, one by one. They can't cascade.
   
   d. **For each coupled group, acknowledge before editing:**
      ```bash
      bash "${CLAUDE_PLUGIN_ROOT}/hooks/write-group-ack" "<group-index>"
      ```
      This signals you've read all findings in the group and designed a coherent fix. Only AFTER acknowledgment will edits to files in that group be allowed by the mechanical gate.
   
   e. **Dispatch each coupled group to the `implementer` sub-agent.** Compose a fix brief containing:
      - The files in the group (and ONLY those files)
      - All findings in the group (they MUST be fixed simultaneously)
      - The coupling reason
      - The applicable generation-spec pattern (if one exists)
      - What was tried previously on those files (from your fix history this session)
      - The constraint (typically: build + test commands must pass)
      
      The implementer returns DONE or BLOCKED.
      - DONE: **Do NOT trust the report.** Run the build and test commands YOURSELF after accepting the implementer's changes. If build/test fails, the implementer's DONE was wrong — re-dispatch with the failure output as "what was tried previously." Only after YOUR verification passes: if the group required 2+ iterations OR the pattern recurred across multiple files, flag it for **pattern-capture** (bucket 5) when reporting back to Stage 2.
      - BLOCKED: either re-scope the group (split differently, provide more context) or escalate to user.
   
   f. **After all groups fixed:** clear the active groups: `bash "${CLAUDE_PLUGIN_ROOT}/hooks/write-active-groups" '[]'`". Re-run tests. Re-invoke Stage 1.
   
   **Why dispatch to implementer instead of fixing yourself:** Your context accumulates Phase 1 output, fix histories, previous diffs, and orchestration state. After 3 rounds, you're at 70%+ context utilization. The implementer starts fresh at ~5% with exactly the files and findings it needs. It can't be confused by stale context from previous rounds. This is how we avoid the 70-round pattern where late-round fixes degraded because the session was saturated.

7. **Track convergence:**
   - Record finding count per iteration: `[iter1: 5, iter2: 3, iter3: 4, iter4: 2, ...]`
   - If `count[N] >= count[N-2]` → DIVERGING warning. One more chance.
   - If still not converging → STUCK. Hit the cap early.
   - If iteration count reaches 5 → HARD STOP regardless of convergence.

8. **If CLEAN** → write gate evidence: `bash "${CLAUDE_PLUGIN_ROOT}/hooks/write-gate-evidence" stage1-clean` → proceed to commit/push.

### Commit and Push

9. Stage files explicitly (never `git add .`). Exclude: `bin/`, `obj/`, `*.user`, `coverage.opencover.xml`.
10. Compose conventional-commit message (biased by user's hint if given). For Copilot-fix-round commits (after Stage 2 returns NEEDS_PARENT_FIXES), use this format:

    ```
    fix(<scope>): apply Copilot fixes round N

    - <fix description per comment>
    - <fix description per comment>

    Capture: <X> entries to calibration-log.md, <Y> to checklist-additions.md
    Stage 1: clean
    ```

    Include the `Capture:` line counting entries by bucket whenever the external-review-handler sub-agent has written capture entries alongside the fix. Include `Stage 1: clean` as a footer to signal the gate passed.

11. Push to remote feature branch (never `--force`).

### Stage 2 — Copilot Review Loop

#### Polling Defaults

These values come from config (`review.*`). If config is absent, use these defaults:

| Parameter | Default | Description |
|---|---|---|
| `review.pollIntervalSeconds` | 200 | Seconds between Copilot review status polls |
| `review.initialWaitSeconds` | 90 | Seconds to wait before the first poll (Copilot needs time to analyze) |
| Heartbeat interval | 30 minutes | If Copilot has been silent for 30+ minutes, emit a status update so the user reading the chat later knows polling continued and approximately how long it has been waiting |

**Polling endpoint:** The external-review-handler polls `pulls/{n}/comments` filtered by `user.login == config.review.copilotReviewerLogin` (the inline review comments), NOT `pulls/{n}/reviews`. Copilot posts inline comments without always finalizing a top-level review object — if the loop only checks the reviews endpoint, it will hang indefinitely. The comments-by-author endpoint is the authoritative source for detecting that Copilot has reviewed.

11.5. **Resolve threads for findings fixed this round (Copilot fix rounds only).**

    On the SECOND and subsequent pushes (i.e., after Stage 2 has returned NEEDS_PARENT_FIXES at least once and you've fixed + pushed), invoke thread resolution for the findings you just fixed:

    ```bash
    source "${CLAUDE_PLUGIN_ROOT}/lib/resolve-review-thread.sh"
    resolve_review_check_auth
    ```

    If auth check passes, for each STABLE/TRIVIAL-STABLE finding from the previous Stage 2 round that you fixed in this push:
    - Call `resolve_review_post_reply <thread_node_id> "Fixed in <SHA> — <one-line summary>"`
    - Call `resolve_review_resolve_thread <thread_node_id>`

    For CONTRADICTS_RUBRIC findings: post reply only (`"Won't fix — contradicts rubric §<N.N>"`), do NOT resolve.
    For UNSTABLE findings: post reply only (`"Deferred — surfaced to user"`), do NOT resolve.

    If auth check fails (returns non-zero), skip silently — the loop still works without resolution, threads just stay open.

    **Why here and not in external-review-handler:** The handler classifies and captures. Resolution happens AFTER the parent fixes and pushes — because only after the push does the fix SHA exist. The handler provides the thread node IDs in its JSON output; this step consumes them.

12. **Invoke `external-review-handler` sub-agent.**

13. **Handle status codes:**

    - `RE_REVIEW_NOT_RECEIVED` → Copilot did not re-review after the fix push. The polling window expired with no review event dated after the HEAD commit. This is NOT success — it means confirmation is absent. Surface to user: "Copilot has not re-reviewed. Re-request review or wait longer." Do NOT declare done.

    - `SUCCESS` → final summary, exit.
    
    - `NEEDS_PARENT_FIXES` → **Apply the same Coupled-Group Fix Protocol (step 6 above).** Group Copilot's findings by coupling. Fix coupled groups as single coherent changes. Then: run tests → invoke Stage 1 → when clean → commit + push → re-invoke Stage 2. **Track Stage 2 iteration count separately. Cap at 3.**
    
      **Context-before-fix — parity defends (MANDATORY for behavioral findings):**
      
      Copilot reviewing the code is not authority that the code is wrong. Copilot does not know legacy behavior. The migration's correctness standard is legacy parity, not Copilot's approval. Do NOT change correct, intentional, or legacy-faithful behavior to satisfy a Copilot comment.
      
      For EACH finding that touches BEHAVIOR (result codes, status mappings, validation logic, error handling, conditional operations), BEFORE applying any fix:
      
      1. **Gather legacy context.** What does the legacy service actually do in this case? Check the legacy source, the behavior spec, the ground-truth inventory, or the name-contract. This is a 30-second grep, not a research project.
      2. **Classify the finding as one of:**
         - **REAL BUG** → the migrated code's behavior is wrong vs legacy, or it's a genuine non-behavioral defect (misleading log message, doc out of sync, security gap that also existed in legacy but should be fixed). Fix it.
         - **INTENTIONAL / LEGACY-FAITHFUL** → the migrated code matches legacy behavior, or the behavior is a deliberate design decision documented in MIGRATION_PATTERNS.md. Do NOT fix. Reply on the PR thread explaining WHY it's intentional (cite the legacy behavior or the design decision). Defending is a valid outcome.
         - **AMBIGUOUS / UNCERTAIN** → legacy evidence is inconclusive or the finding identifies a genuine tension. Make an evidence-based decision (fix or defend), RECORD the rationale including what evidence was found and what doubt remains, and post the rationale on the PR thread. The supervisor audits these after the fact. Do not hang waiting for input — the loop owns the decision.

      **Evidence requirement for DEFENDED classification:**
      A finding may be classified DEFENDED only with CITED EVIDENCE: a specific legacy file:line showing the legacy behavior matches, OR a rubric section that explicitly sanctions it. A bare assertion ("intentional", "matches CLAUDE.md", "legacy-faithful") without a specific citation is NOT sufficient. The PR thread reply MUST include the citation (e.g., "Legacy CPSLTokenRepository.cs:47 does the same — returns true when profiles are null").

      **SECURITY-shaped findings NEVER auto-defend:**
      Findings touching auth, authz, fail-open behavior, SSRF, injection, secrets exposure, or privilege escalation can NEVER be silently defended by the loop. If a security finding is to be defended, it requires:
      (a) Specific legacy file:line evidence showing the same behavior in production, AND
      (b) Explicit escalation to the human for sign-off — it is never auto-resolved.
      Fail-open auth (validation bypassed when config is missing/empty) is specifically a must-fix-or-escalate pattern, never a routine defend. The loop may propose a defense rationale, but the human decides.

      3. **Only REAL BUG findings proceed to the Coupled-Group Fix Protocol.** INTENTIONAL findings get a PR reply (with cited evidence) and are terminal. AMBIGUOUS findings get a documented decision (fix-with-rationale or defend-with-rationale) and are terminal. SECURITY findings classified as INTENTIONAL are escalated to the human with the proposed rationale — the loop does not auto-resolve them.
      
      **Why this rule exists:** PR #12's failure mode was fixing every Copilot finding reflexively. Several findings flagged intentional legacy behavior as "bad practice." Fixing them introduced wire-format deviations and status-code changes that broke callers. The rule: when a finding touches behavior, check legacy FIRST, then decide fix vs defend vs escalate.
    
      **Handle stability categories (applies only to REAL BUG findings after context-before-fix):**
      - STABLE / TRIVIAL-STABLE → fix automatically via Coupled-Group Protocol
      - UNSTABLE → surface to user, do NOT auto-fix. Present the finding and ask for direction.
      - CONTRADICTS_RUBRIC → surface to user with BOTH the Copilot suggestion AND the rubric section it violates. Default: rubric wins. If user overrides, implement Copilot's suggestion and note the override in `calibration-log.md` for the next batched rubric PR to evaluate.
    
    - `STUCK` / `DIVERGING` → the iteration cap has been reached or oscillation detected. Do NOT push more rounds. But the resolution requirement still applies: any finding not yet FIXED must be DEFENDED-WITH-RATIONALE before the run can complete. The cap limits ROUNDS (cannot hang chasing churn), not OUTCOMES (cannot leave findings undecided). For each remaining finding: apply context-before-fix, decide fix-vs-defend, and record the terminal state. If a finding was DEFENDED in a prior round but the same file churned (causing STUCK), the defense stands — the finding is already terminal.
    
    - `FAILED` → surface error verbatim. Do not retry blindly.
    
    - `ERROR` → abort.

### Structural Verification (Before Declaring Success)

**Verification Discipline applies here.** (See `${CLAUDE_PLUGIN_ROOT}/lib/verification-discipline.md`.) Stage 2 returning SUCCESS is a CLAIM, not evidence. Verify independently:

- **Test command** — run the configured `test.command` (or auto-detected command). Fresh run, not cached. Read the output. Count failures. 0 = pass.
- **Build command** — run the configured `build.command` (or auto-detected command). Fresh run. Read warnings count. 0 = pass.
- If project config has a `migration.referenceService`: verify the migrated service has the same directory structure as the reference. LIST the directory. Don't assume.
- Health endpoint responds (if service can be started locally). Actually curl it. Read the response.

If ANY verification fails, DO NOT declare success. Surface the gap with the actual output that proves it failed.

### Metrics Collection (MANDATORY)

14. After outcome is determined (SUCCESS, CAPPED, STUCK, DIVERGING, ERROR), write a run entry to `<project-root>/.preflight/metrics.json` following the schema in `${CLAUDE_PLUGIN_ROOT}/lib/metrics.md`. Record:
    - Stage 1: iterations, findingsPerIteration, capHit, couplingGroupsIdentified, validatorWarnings, durationSeconds
    - Stage 2: iterations, findingsPerIteration, capHit, stableFindings, trivialStableFindings, unstableFindings, durationSeconds
    - Capture: counts per bucket
    - Outcome and total duration

    Create the `.preflight/` directory if it doesn't exist. Do NOT skip metrics because the run failed — failed runs are the most valuable data points (they reveal where the system breaks).

### Stage 2 Resolution Gate (MANDATORY — checked before completion)

<CRITICAL-INSTRUCTION>
The run is NOT complete while ANY Copilot finding is neither FIXED nor DEFENDED-WITH-REPLY. Stopping at "PR opened" is NOT complete (that was the PR-85 failure). Opening a PR and walking away with findings unprocessed is the known failure mode this gate exists to prevent.

Before declaring DONE, verify: every finding from the Copilot review has reached a TERMINAL STATE, which is one of exactly two:
- **FIXED** — a real bug vs legacy (or genuine non-behavioral defect); code was changed, tests pass, Stage 1 is clean. The review thread is RESOLVED via `resolveReviewThread` mutation.
- **DEFENDED-WITH-REPLY** — legacy-faithful or intentional; a rationale was posted ON THE PR THREAD (not only in a commit message) explaining WHY (citing the legacy behavior or design intent). "Defended" means a POSTED RATIONALE ON THE PR, NOT "Copilot marked it resolved." A correctly-defended legacy-faithful finding is TERMINAL even if Copilot never clears the comment. The loop's standard is legacy parity, NOT Copilot's approval.

**Full-resolution artifact gate:** Query the PR's review threads via GraphQL (`pullRequest.reviewThreads`). Every thread must either be resolved (isResolved=true) OR have a visible reply from the automation. Zero threads may be left without a posted reply — reasoning that exists only in commit prose is invisible on the PR artifact and does not satisfy this gate.

If any finding is not in a terminal state, the run cannot complete. Go back and resolve it.
</CRITICAL-INSTRUCTION>

**The uncertainty corner** — when legacy behavior is ambiguous:

With no human exit, a finding the loop can't confidently classify (legacy ambiguous, can't determine from disk, no clear evidence either way) STILL must reach FIXED or DEFENDED. It must NOT:
- Fix-to-clear (cave — change maybe-correct behavior on a guess to make the comment go away)
- Defend-to-clear (falsely assert "intentional" when the evidence is inconclusive)

It MUST make an EVIDENCE-BASED decision and RECORD the rationale INCLUDING:
- The legacy evidence found (or "no evidence found — legacy source does not cover this path")
- The reasoning for the decision taken
- Any residual uncertainty ("this may be wrong if legacy actually does X, but on-disk evidence supports Y")

Terminal state = "fixed-with-rationale OR defended-with-rationale" — where the rationale exposes the reasoning and any doubt for the supervisor's after-the-fact review. The loop decides; the rationale makes thin reasoning auditable. A hard finding produces a documented decision, never a silent guess.

**Cap-vs-resolution interaction:**

The iteration cap (`maxStage2Iterations`, oscillation detection) bounds CHURN — repeated fix-and-re-review rounds. It does NOT permit leaving findings undecided. If the cap is reached with findings not yet in a terminal state, those findings must be DEFENDED-WITH-RATIONALE (decided + documented), not left open. The cap limits ROUNDS (cannot hang); the resolution requirement limits OUTCOMES (cannot silently drop). They do not conflict:
- Bounded rounds: can't hang chasing Copilot feedback indefinitely
- Every finding terminal: can't silently drop findings by hitting a cap and walking away
- After cap hit: remaining unresolved findings are decided (context-before-fix → fix or defend) and documented without further push/poll rounds

### Final Summary

15. PR URL, total Stage 1 iterations, total Stage 2 iterations, capture entries by bucket, coverage achieved, findings resolved (N fixed + M defended).
16. Tell user PR is ready for human review. Do NOT merge.

## Capture Files and the Rubric

Capture files are **transient evidence** — they record what Copilot flagged, how it was classified, and how many services have validated the pattern. They do NOT take immediate operative effect. Code-reviewer reads only the rubric for detection rules.

Capture entries become operative detection rules through the **batched rubric-edit PR process**: after `loop.rubricEditCadence` migrations, the external-review-handler drafts a PR that promotes validated entries (Survived 2+, Confidence high/medium) into new rubric sections. A human reviews and merges that PR. Only then do those rules fire on subsequent services.

This trades "learnings take effect next invocation" for conflict-free parallel execution — multiple engineers can run preflight simultaneously without race conditions on shared capture files.

## Structured Status

At any point, if you cannot proceed:
- **DONE** — all findings in terminal state (fixed or defended-with-reply), PR ready for human merge
- **CAPPED-RESOLVING** — hit iteration limit; remaining findings being decided (context-before-fix → fix or defend) without further push/poll rounds. NOT a resting state — resolution continues until all findings are terminal.
- **BLOCKED** — external dependency (Copilot timeout, auth expired, rate limit)
- **DIVERGING** — findings not converging; cap triggered. Remaining findings still must reach terminal state via defend-with-rationale.
- **STUCK** — oscillation detected (same file/line churning); cap triggered. Remaining findings still must reach terminal state via defend-with-rationale.

## What This Does NOT Do

- Merge the PR
- Force-push
- Skip Stage 1 for any push
- Skip tests before push
- Fix coupled findings independently (the #1 cascade cause)
- Loop past iteration caps
- Edit capture files (external-review-handler does that)

## Appendix: Rationalization Prevention

Reference table. If you catch yourself thinking any of these, you're drifting.

| Your thought | Why it's wrong |
|---|---|
| "Stage 1 was clean last round, this whitespace fix doesn't need re-review" | Whitespace-only diffs can mask real changes in adjacent lines. Review. Always. |
| "I've been looping for 6 rounds, let me just push this and see what Copilot says" | Each push costs 200-300s of Copilot latency per finding. Stage 1 catches issues in 30s. |
| "Tests are passing, Stage 1 findings must be false positives" | Tests verify behavior. Stage 1 verifies security, style, and architecture. Orthogonal. Both must pass. |
| "The iteration cap is being too conservative, I'm making progress" | Count-based convergence shows you're shuffling issues between files. The cap exists because rounds past it produce negative value. |
| "These findings look independent, I can fix them one by one" | If they touch the same file or call chain, they INTERACT. Read ALL coupled findings before writing ANY fix. |
| "The dependency map says they're independent, so I can fix them separately" | The map is LLM-generated. Run the mechanical validator first. Trusting one LLM pass over a structural claim is how cascades start. |
| "Stage 2 hit the cap at 3, I should override to 8 and keep going" | If 3 rounds of STABLE-only fixes didn't converge, the coupling map is wrong. More rounds cascade on the same structural error. |

Begin now. Run pre-flight checks.

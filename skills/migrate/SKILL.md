---
name: migrate
description: >-
  Orchestrates legacy-to-modern service migration. Delegates Phase 1 discovery
  to discovery-analyst, drives Phase 2 execution from configured generation spec,
  hands off post-migration cleanup to fix-and-close.
  TRIGGER when: user asks to migrate a service; user asks to port/move/modernize
  a legacy service to a new framework (e.g. .NET 10, Spring Boot 3); user names
  a specific service to migrate; project config mode is "migration" and the user's
  intent is service migration; user says "run the migration" or equivalent.
  SKIP: net-new API development (use scaffold-api); single-file edits or bug fixes;
  non-migration tasks (refactoring, docs, CI); user explicitly asks to follow steps
  manually without the skill.
argument-hint: <ServiceName>
allowed-tools: Read, Glob, Grep, Bash, Edit, Write, Agent
---

# /preflight:migrate — End-to-End Migration

You are running an end-to-end migration of a legacy service to a modern target platform. The migration orchestration is stack-neutral — the analyst loads stack-specific scan profiles, the migrate skill consumes stack-specific generation specs. This skill is the orchestrator, not the implementer.

When the user types `/preflight:migrate <something>`, they expect to walk away and come back to a clean, mergeable PR.

The user passed `$ARGUMENTS` as input. Parse generously:
- Service name is the value passed as the skill argument. If the team uses a naming convention (e.g., a standard prefix), it should be documented in `CLAUDE.md` and prepended at config-resolution time, not hardcoded in this skill.
- Free-form description (e.g. "migrate the seat lookup thing") → extract the service identifier. Ask for clarification only if genuinely ambiguous (multiple plausible services match).
- No argument → ask which service.

## A note on enforcement

This skill uses CRITICAL-INSTRUCTION blocks to mark behavioral requirements. These are prose-level instructions — the model is expected to comply, but no mechanical hook prevents the model from proceeding if it doesn't. Mechanical enforcement (hook-level blocks) is provided separately by the pre-push-gate and coupled-edit-gate hooks. Treat CRITICAL-INSTRUCTION blocks as "you must follow this" guidance, not as a system-level block.

## The Architectural Commitment

**Every issue caught by external review on ServiceN should be caught by local review on ServiceN+1.** Your job, beyond migrating the code, is to make this real on this migration. The Stage 2 orchestrator + learning agent does the capture; you ensure it runs and that its output gets committed.

## Step 0 — Environment Detection

If session context already contains `preflight active | mode=migration` with config path and rubric path, trust it — the session-start hook already parsed the config. Skip to step 5 (rubric existence check only).

If session context is empty or this skill was invoked cold (no hook ran):

1. Search for config: `.preflight/config.json` > `.forge.json` (in working directory, then up to 5 parent levels).
2. If found: extract `mode`, `rubric`, `branch.base`, `branch.remote`, `branch.migrationPrefix`, `test.*`, `loop.*`, `capture.*`, `migration.*`.
3. If not found: use defaults — mode `generic`, base branch `main`, test command auto-detected.
4. Check for `CLAUDE.md` at project root for supplementary conventions.
5. Confirm the rubric file exists at the resolved path. If missing, warn and fall back to `${CLAUDE_PLUGIN_ROOT}/examples/rubrics/rubric-migration-dotnet.md` (example rubric — teams should configure their own).

## Pre-requisites

<CRITICAL-INSTRUCTION>
This skill requires project config with `"mode": "migration"`. If the config is missing or mode is not "migration", inform the user: "This project is not configured for migration. Create a `.preflight/config.json` with `mode: migration` and a `migration.legacyRepoPath`, or use `/preflight:scaffold` for net-new development."
</CRITICAL-INSTRUCTION>

Verify from config:
- `migration.legacyRepoPath` exists and points to a directory that exists on disk
- `rubric` path exists (or the example migration rubric is available at `${CLAUDE_PLUGIN_ROOT}/examples/rubrics/rubric-migration-dotnet.md`)
- `branch.base` is set (default from config; no hardcoded branch name)
- `branch.remote` is set (default from config; no hardcoded remote name)

## Setup

1. **Confirm repo state.** `CLAUDE.md` exists at project root (or whatever supplementary conventions the team uses). If not, warn but do not abort — the config is sufficient.

2. **Read the team contract.** `CLAUDE.md` (if it exists), plus the rubric at the configured path, plus the capture files (whichever exist at the paths in `capture.*` from config).

3. **Resolve the legacy repo path.** Read `migration.legacyRepoPath` from `.preflight/config.json`. If the value is a placeholder (e.g. `<set-this-to-...>`), the user has not configured it. Ask them where their legacy clone lives, then proceed.

4. **Resolve the target service.** From the argument, determine the legacy service folder. Confirm with the user before proceeding: "Migrating `<ServiceName>` from `<legacyRepoPath>` to `<targetFolder>` in this repo. Confirm?"

5. **Determine the base branch.** From config: `branch.base`. From config: `branch.remote`.

6. **Check for existing checkpoint.** Run: `test -f .preflight/migrate-checkpoint.json && cat .preflight/migrate-checkpoint.json`. If a checkpoint exists for the same service, surface to the user: "Found checkpoint from previous run. Last completed phase: <phase>. Resume from <next_phase>? (yes/no/restart)". If yes: skip completed phases. If restart: delete checkpoint and branch, start fresh. If a different service: warn and ask.

7. **Cut the migration branch.**
   - Ensure the working tree is clean. If there are uncommitted changes that are not yours, stop and ask the user what to do.
   - Switch to `branch.base`, pull `branch.remote/branch.base`, cut a new branch named per the config's `branch.migrationPrefix` (default: `feature/migrate-<service>`). Teams that want to encode target platform in the branch name can configure `branch.migrationPrefix` in `.preflight/config.json`.

## Phase 1 — Discovery (NEVER SKIP)

<CRITICAL-INSTRUCTION>
Phase 1 runs on every migration, even when the service "looks simple." The readiness score is what tells you whether it actually IS simple. Skipping Phase 1 has cost 4+ hours in prior migrations when undiscovered dependencies cascaded.
</CRITICAL-INSTRUCTION>

### Rationalization Prevention

| Your thought | Why it's wrong |
|---|---|
| "This service is tiny, I can skip discovery" | Tiny services have hidden shared-library dependencies that break at link time. Discover them. |
| "I already know this codebase from a previous migration" | You are a fresh session. You know nothing. Discover from scratch. |
| "Phase 1 is just documentation, the code is what matters" | Phase 1 IS the code. It's reading the legacy project file, mapping references, finding anti-patterns. Skip it and you'll write code that compiles but crashes at runtime. |

### Execution

1. **Project structure** — locate the project file in the legacy repo (e.g., `.csproj` for .NET, `pom.xml` for Java, `package.json` for Node), map internal and external dependencies, identify shared libraries, document the legacy target framework.

2. **Technical debt scan** — use the Agent tool with `subagent_type: discovery-analyst` to spawn the analyst as a separate sub-agent against the legacy service directory. This is required — do not role-play the analyst within this skill's context. The analyst MUST run in its own agent context to honor its READ-ONLY tool constraints (Read, Glob, Grep, Bash only). If you find yourself reading code and producing analyst-style output from within this skill, STOP and use the Agent tool instead.

   The analyst loads the appropriate scan profile for this project's stack (configured in `.preflight/config.json`, or auto-detected from project files). It produces:
   - Technical debt inventory with category IDs, severity levels, counts, and file:line locations
   - Architecture assessment (coupling to intermediary layers, consolidation candidates)
   - Readiness score (1-10 per category)
   - Dependency map (`dependency-map.json`)

   If the analyst returns BLOCKED or ERROR, surface the reason and ask the user how to proceed. Do not attempt to run the scan yourself — the analyst has the profile-loading logic and pattern expertise.

   After the analyst returns DONE, verify dependency-map.json exists at the path specified in the analyst's status block. Run: `test -f <service-folder>/dependency-map.json && echo EXISTS || echo MISSING`. If MISSING, the analyst failed to persist the dependency map to disk despite returning DONE. Re-invoke the analyst with explicit instruction: "Write the dependency-map.json file to disk before returning DONE. The file is required for downstream coupling analysis." If the second attempt also fails, STOP and report to the user — do not proceed to Phase 2 without a valid dependency map.

   Report the analyst's findings as Phase 1 output.

2b. **Behavioral extraction** — use the Agent tool with `subagent_type: spec-analyst` to spawn the behavioral analyst against the legacy service directory. The spec-analyst consumes the dependency map produced in step 2 (or an explicit file list derived from the comparison surfaces in CLAUDE.md if no map exists for the legacy path). It produces:
   - `behavior-spec.json` documenting all externally-observable behaviors with citation-grounded evidence
   - A completeness check verifying all pattern matches in scope are accounted for

   If CLAUDE.md has no "Behavioral Contract" section, the spec-analyst will return BLOCKED. Surface this to the user — they need to declare the recognition pattern, category vocabulary, and comparison surfaces before behavioral extraction can proceed. This is not a fatal error for the migration — proceed to step 3 without a behavior spec, but warn that parity checking will be unavailable post-migration.

   If the spec-analyst returns DONE_INCOMPLETE, surface the missing entries. The user decides whether to investigate or accept.

   The behavior spec is the BASELINE for the future parity gate. After Phase 2, the same extraction runs against the migrated code and the two specs are diffed to detect behavioral drift.

3. **Business architecture rules** — assess coupling to intermediary layers (shared gateways, dispatch proxies, etc.):
   - **Decouple from intermediary layers.** Remove the shared dispatch component (or equivalent gateway) dependency entirely.
   - **Move gateway logic into the target microservice.** Connect directly to downstream/backend services without going through intermediary dispatchers.
   - **Plan for microservice consolidation.** Identify candidate services that could merge with this one later. For each candidate, verify it exists by checking the legacy repo (directory listing). Only list verified services as confident candidates; list unverified candidates separately under [unverified — needs human confirmation]. Do not pad the list.
   - Both the decoupling assessment and the consolidation candidates are required outputs; do not skip them even on small services.

4. **Readiness score** — rate 1-10 across five categories:

   | Category | What to evaluate |
   |---|---|
   | Dependency Isolation | Can this service migrate without breaking others? |
   | Dependency Compatibility | Are dependencies compatible with the target framework? |
   | Code Pattern Complexity | How much legacy-pattern refactoring is needed? |
   | Performance Opportunity | What async / serialization gains are possible? |
   | Cloud Readiness | How much config and secrets modernization is needed? |

   Produce an **Overall Migration Complexity Score: [X/10]** with a one-paragraph justification, then select the strategy:
   - **Green (8-10):** Direct migration.
   - **Yellow (5-7):** Staged migration.
   - **Red (1-4):** Preparation-first — surface this to the user, recommend pausing migration and handling prep first.

5. **Present Phase 1 outputs to the user** as a single message before any code is written. Wait for them to either say "go" or correct your understanding. This is the only human gate inside the migration pipeline — it exists because mis-scoping a migration here costs hours later.

6. **Write checkpoint:** `phase: phase1_complete`, service name, branch, readiness score, dependency map path, timestamp.

## Phase 2 — Execution

<CRITICAL-INSTRUCTION>
Before writing ANY code, read the generation spec. Resolve the path from project config (`generation-spec` field) or fall back to `${CLAUDE_PLUGIN_ROOT}/examples/generation-specs/` and select the spec matching the detected stack. If the config specifies a path but the file doesn't exist, warn and attempt the stack-detection fallback. If no spec resolves at all, STOP — inform the user that a generation spec is required for Phase 2. For every pattern that applies to this service, PASTE the code block verbatim into the target file as a literal text copy — character for character, preserving whitespace, ordering, and structure. Then modify ONLY at marked `/* ADAPT */` points. Do not "use" patterns (interpretation + reconstruction degrades at high context). Do not "apply" patterns. PASTE them, then adapt at marked points only. The generation spec is pre-validated against the detection spec — verbatim paste means Stage 1 will never flag those patterns. Reconstruction from memory WILL produce drift that gets flagged.
</CRITICAL-INSTRUCTION>

Read ALL of:
- Generation spec (resolved via project config or stack-detection fallback — mandatory, one must resolve)
- Project's `CLAUDE.md` (if exists — team conventions)
- `MIGRATION_PATTERNS.md` from the configured reference service (if `migration.referenceService` exists in config). If `migration.referenceService` is not configured, skip this — proceed without reference patterns.

Apply generation spec patterns FIRST (deterministic, pre-validated). Then write service-specific business logic (the part that requires reasoning).

### Standard Migration Phases

The migration phases are defined by the generation spec. The generation spec is the authoritative source for what patterns to apply, in what order, using what tools.

**Loading the generation spec:**
1. Check project config (`generation-spec` field in `.preflight/config.json`) for an explicit path.
2. If not configured, fall back to `${CLAUDE_PLUGIN_ROOT}/examples/generation-specs/` and look for a spec matching the detected stack.
3. If no spec resolves, STOP — cannot proceed with Phase 2 without a generation spec. Surface this to the user: "No generation spec found. Configure one in `.preflight/config.json` or place one at `examples/generation-specs/<stack>.md`."

**Execution discipline:**
- Do not run build commands between every micro-step — that wastes cycles. Build at the end of each logical phase.
- Apply the PASTE discipline from the CRITICAL-INSTRUCTION block above — verbatim copy, adapt only at `/* ADAPT */` markers. Build verification at the end of each phase confirms the paste produced compilable code.

**Standard execution phases (generation spec provides the specifics for each):**

1. **Core migration:** Convert project format, update target framework, migrate dependency management, replace legacy DI container.

2. **Modernization:** Modern hosting patterns, async I/O end-to-end, modern serialization, configuration management (secrets + parameters), structured logging with sanitization, observability instrumentation.

3. **Test migration:** Match the reference service test project layout and framework. Coverage baseline from config (`test.coverageBaseline`) is the floor. If `test.coverageBaseline` is not configured, default to 80% (or team standard documented in CLAUDE.md).

4. **Infrastructure:** Cloud infrastructure as code matching the reference service pattern. Compute, networking, container registry, auto-scaling, secrets management.

5. **Container:** Secure container image — non-root user, fixed port, health check defined in orchestrator config (not in container image).

6. **Build verification** — must be 0 errors, 0 warnings (treat warnings as errors). Fix anything that breaks.

7. **Test verification** — all pass, coverage meets `test.coverageBaseline`. Fix anything that fails.

The generation spec fills in the stack-specific details for each phase. The migrate skill orchestrates the sequence. The generation spec provides the patterns.

**Write checkpoint** after each completed phase: update `phase: phase2_step_N_complete`.

## Post-Migration Dependency Map Refresh

After Phase 2 completes and before the first Stage 1 run, rebuild the dependency map from the MIGRATED code:

1. **Why:** Phase 1's analysis reflects the LEGACY structure (intermediary layers, shared gateways, old class hierarchies). The migrated code has a different coupling graph (direct downstream clients, new DI registrations, different call chains). Using the stale legacy map for coupling analysis during Stage 1 fixes will produce wrong groupings.

2. **Action:** Use the Agent tool with `subagent_type: discovery-analyst` to spawn the analyst against the NEW service directory (not the legacy repo). It produces a fresh `dependency-map.json` with:
   - `files` — current imports, injectedBy, callsInto, calledBy for each migrated file
   - `couplingGroups` — coupling based on the NEW architecture
   - `independent` — files that can always be fixed in isolation (container config, infrastructure-as-code, IDE settings)

3. **Place the output** at `<service-folder>/dependency-map.json`.

4. **Run mechanical validation** from `${CLAUDE_PLUGIN_ROOT}/lib/dependency-map-validator.md`. This catches missed DI-graph coupling, false independence claims, and unverifiable group edges. Apply any corrections to the map before proceeding. Never consume an unvalidated map.

5. **If the discovery-analyst is unavailable** (e.g., cap hit, error): fall back to CONSERVATIVE coupling — treat ALL findings as one coupled group. Slow but safe.

**Write checkpoint:** `phase: phase2_complete`.

## Behavioral Parity Verification

After Phase 2 completes and the dependency map is validated, verify behavioral preservation before handing off to the review pipeline. This step uses the SAME spec-analyst that produced the legacy baseline (step 2b) — now pointed at the migrated code — and the parity engine to detect drift.

<CRITICAL-INSTRUCTION>
Do NOT skip parity verification. Gate 4 will block the push if a behavior-spec baseline exists and no parity-clean evidence is present. Running parity here prevents hitting that block during fix-and-close (where the fix loop has no context for parity violations — only rubric findings).
</CRITICAL-INSTRUCTION>

### Step 1 — Extract migrated behavior spec

Use the Agent tool with `subagent_type: spec-analyst` to spawn the behavioral analyst against the MIGRATED service directory. The spec-analyst consumes the fresh dependency map produced by the post-Phase-2 discovery refresh (the same map at `<service-folder>/dependency-map.json` that was just validated). It produces:
- `behavior-spec.json` documenting all externally-observable behaviors of the MIGRATED implementation with citation-grounded evidence
- A completeness check verifying all pattern matches in scope are accounted for

The output path is `.preflight/<service>/behavior-spec-current.json` — distinct from the legacy baseline at `.preflight/<service>/behavior-spec.json`.

**Status handling (mirrors step 2b):**
- **DONE**: proceed to parity comparison.
- **DONE_INCOMPLETE**: surface the missing entries. The user decides whether to investigate or accept. If accepted, proceed with the incomplete spec (parity will flag missing behaviors as ADDED on the legacy side — i.e., things the migrated code doesn't have).
- **BLOCKED**: surface the reason. If the Behavioral Contract section is missing from CLAUDE.md, parity cannot proceed — warn and skip to handoff (same as step 2b's fallback). Gate 4 will not activate if no baseline was produced in step 2b either.
- **ERROR**: surface verbatim. Do not retry automatically.

### Step 2 — Run parity comparison

Run the parity engine:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/lib/parity-check.sh" \
  ".preflight/<service>/behavior-spec.json" \
  ".preflight/<service>/behavior-spec-current.json"
```

Interpret the exit code:

| Exit | Meaning | Action |
|---|---|---|
| **0** (CLEAN) | No blocking or advisory violations | Write evidence and proceed |
| **1** (ADVISORY) | Advisory-only violations (error_path gaps, uncomparable observables) | Write evidence and proceed — advisory findings are informational warnings, not blockers |
| **2** (BLOCKING) | Blocking violations exist (dropped result codes, changed wire contract, removed side effects, removed state transitions) | Do NOT write evidence. Surface the full parity report to the user. |

**On exit 2 (blocking violations):**

Surface the parity report showing all MISSING and CHANGED blocking-tier entries. Present to the user:

> "Parity check found **N blocking violations** — behaviors present in the legacy service that are missing or changed in the migrated code. These represent observable behavioral drift that the gate will block on.
>
> [list violations by category: result_code, wire_contract, side_effect, state_transition]
>
> Options:
> 1. **Fix** — address the violations (add missing behaviors, restore wire contract fields, etc.) and re-run parity
> 2. **Accept** — these are intentional architectural changes (e.g., removing a legacy intermediary). Write parity-clean evidence with an override note and proceed.
> 3. **Investigate** — review specific violations before deciding"

If the user chooses **Fix**: apply the fixes (using the same coupled-group discipline — multiple violations in the same file/chain are coupled), re-run spec-analyst on the migrated code, re-run parity-check.sh. Loop until exit 0 or 1, or user chooses Accept.

If the user chooses **Accept**: write parity-clean evidence (the user has reviewed and acknowledged the intentional drift). Proceed to handoff.

### Step 3 — Write parity evidence

On exit 0 or exit 1 (or user-accepted exit 2):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/write-gate-evidence" parity-clean
```

This satisfies Gate 4. The push in fix-and-close will not be blocked by parity.

**Write checkpoint:** `phase: parity_verified`.

## Handoff to /preflight:fix-and-close

Once Phase 2 is complete, the dependency map is validated, parity is verified (or user-accepted), and code compiles + tests pass, invoke `/preflight:fix-and-close` to run the full Stage 1 → push → Stage 2 pipeline.

Pass the commit-message hint derived from Phase 1 (e.g. `feat(<service>): migrate to <target-platform>`).

The fix-and-close skill handles:
- Stage 1 gate (code-reviewer sub-agent, hard cap 5 iterations, Coupled-Group Fix Protocol)
- Commit + push (conventional-commits, explicit file staging)
- Stage 2 Copilot loop (external-review-handler sub-agent, hard cap 3 iterations, polling, STUCK detection)
- Structural verification (build command, test command from project config, directory structure, health endpoint)
- Metrics collection

**PR opening:** Before the first push, open the PR via `gh pr create --base <branch.base> --head <branch-name>`. Title and body follow conventional-commits format. Include Phase 1 outputs in the PR description so reviewers see your reasoning. Do not prompt for confirmation — open automatically.

**Write checkpoint:** `phase: handoff_complete`.

## Final Step — Summary

Once /fix-and-close reports DONE:

- Surface the summary: PR URL, Stage 1 iterations, Stage 2 iterations, capture entries written by classification bucket, coverage achieved, any STUCK or FAILED states encountered.
- Tell the user the PR is ready for human review and merge. **Do not merge** — humans merge.
- Delete the checkpoint file (`.preflight/migrate-checkpoint.json`).

## Communication

The user invoked this command expecting to walk away. They will be reading the chat history later, possibly after sleeping. Optimize your output for that reader:

- **Phase boundaries should be clear.** Mark them: `## Phase 1 — Discovery`, `## Phase 2 — Execution Step 4: Infrastructure`, `## Stage 2 — Iteration 3`. Future-them is scrolling through this looking for "where did it stop?" and "what did it do?"
- **Decisions you made autonomously should be logged.** If you had to choose between two reasonable approaches, say which you picked and why.
- **Numbers, always.** Iteration counts, capture entry counts, coverage percentages, line counts. Specifics make the run reviewable.
- **Do not narrate every tool call.** Talk about what you concluded from the output, not what you ran.
- **30-minute heartbeat.** If the Copilot review loop has been polling with no response for 30+ minutes, emit a status update so the user reading later knows polling continued.

## Interruption Recovery

Long migrations can hit context limits, network errors, or session interruptions mid-Phase-2. To support recovery, write a checkpoint file at each phase boundary.

**Checkpoint file:** `.preflight/migrate-checkpoint.json`

**Write the checkpoint:**
- After Phase 1 completes (analyst DONE, readiness score captured): write checkpoint with `phase: phase1_complete`, `service: <name>`, `branch: <name>`, `readinessScore: <X/10>`, `dependencyMapPath: <path>`, `timestamp: <ISO8601>`.
- After each Phase 2 execution step completes: update checkpoint with `phase: phase2_step_N_complete`, where N is the standard execution phase (1-7).
- After Phase 2 fully completes (build verification passed, test verification passed): update checkpoint with `phase: phase2_complete`.
- After handoff to fix-and-close: update checkpoint with `phase: handoff_complete`.
- On any phase failure or session interruption, the checkpoint reflects the LAST successful step.

**Resume protocol:**
At the start of each migrate invocation, check for an existing checkpoint (see Setup step 6).

**Cleanup:**
After the migration completes successfully (PR merged or explicit cleanup command), delete the checkpoint file.

**Schema:**
```json
{
  "service": "<service-name>",
  "branch": "<branch-name>",
  "phase": "<current-phase-marker>",
  "phase1": {
    "completed": true,
    "readinessScore": "8/10",
    "dependencyMapPath": "src/<service>/dependency-map.json",
    "timestamp": "2026-05-27T14:00:00Z"
  },
  "phase2": {
    "completedSteps": [1, 2, 3],
    "currentStep": 4,
    "timestamp": "2026-05-27T14:30:00Z"
  },
  "timestamp": "2026-05-27T14:30:00Z"
}
```

This checkpoint is local-only — `.preflight/migrate-checkpoint.json` is in `.gitignore`.

## Edge Cases

- **Argument is ambiguous** ("seat lookup" matches three legacy services): ask the user to pick. Do not guess.
- **Migration branch already exists** (from a prior interrupted run): check for checkpoint and follow resume protocol above.
- **Phase 1 reveals Red readiness score:** do not silently proceed. Surface this, recommend pausing migration and handling the prep first.
- **Stage 1 keeps finding new things after several rounds:** suggests the rubric and the codebase have a structural mismatch. Surface, ask user.
- **Copilot review never arrives** (after many poll cycles): periodically emit heartbeat updates so the user reading the chat later knows polling continued.
- **The legacy repo is not on this machine** (`migration.legacyRepoPath` invalid): cannot proceed. Ask the user to either clone the legacy repo or update the config.

## What This Does NOT Do

- Skip Phase 1 — even for "obviously simple" services
- Push before Stage 1 is clean (enforced by /fix-and-close)
- Merge the PR — humans merge
- Force-push under any circumstances
- Modify the legacy repo — it is read-only reference material
- Mix feature work with migration
- Fix coupled findings independently (enforced by /fix-and-close's Coupled-Group Protocol)
- Loop past iteration caps (5 for Stage 1, 3 for Stage 2 — enforced by /fix-and-close)
- Write to capture files directly — only the external-review-handler sub-agent writes captures
- Confuse sub-agent roles — code-reviewer reads/reports, external-review-handler orchestrates/captures, discovery-analyst maps dependencies, implementer fixes coupled groups, this skill orchestrates the overall flow
- Auto-bump the rubric cadence — `loop.rubricEditCadence` is read from config (default 5); the rubric-edit PR is a separate batched effort

## Reminders

- The rubric is wisdom, not law. Findings that seem wrong should still be surfaced — disagreements get captured into `false-positives` via the external-review-handler, not silently dropped.
- The goal is not just to migrate this service. It is to make the next migration faster than this one. Every Copilot finding the orchestrator captures is a future-finding the Stage 1 reviewer will catch locally.
- One service per PR. If the migration reveals that another service must also be touched, stop and ask. Do not chain.

Begin now. Parse `$ARGUMENTS`, discover the project config, and start Phase 1.

---
name: migrate-service
description: End-to-end migration of a legacy service to modern .NET. Runs discovery, readiness assessment, migration execution, gates every push with Stage 1 review, drives Copilot review loop until clean. Only activates when project config mode is "migration". Use when the user wants to migrate a specific service from legacy to modern framework.
argument-hint: <service name, e.g. "PaxLookup" or "migrate the seat assignment lookup service">
allowed-tools: Read, Glob, Grep, Bash, Edit, Write, Agent
---

# /preflight:migrate-service — End-to-End Migration

You are running an end-to-end migration of a legacy service to modern .NET, driving both review loops, and feeding the self-improvement system.

The user passed `$ARGUMENTS` as input. Parse generously:
- Bare service name → assume standard prefix (e.g., `CTI.MicroService.IVR.<Name>`)
- Free-form description → extract identifier. Ask only if genuinely ambiguous.
- No argument → ask which service.

## Step 0 — Environment Detection

If session context already contains `preflight active | mode=migration` with config path and rubric path, trust it — the session-start hook already parsed the config. Skip to step 5 (rubric existence check only).

If session context is empty or this skill was invoked cold (no hook ran):

1. Search for config: `.preflight/config.json` > `.cpsl/config.json` > `.forge.json` (in working directory, then up to 5 parent levels).
2. If found: extract `mode`, `rubric`, `branch.base`, `branch.remote`, `test.*`, `loop.*`, `capture.*`, `migration.*`.
3. If not found: use defaults — mode `generic`, base branch `main`, test command auto-detected.
4. Check for `CLAUDE.md` at project root for supplementary conventions.
5. Confirm the rubric file exists at the resolved path. If missing, warn and fall back to `${CLAUDE_PLUGIN_ROOT}/defaults/rubric-migration.md`.

## Pre-requisites

<HARD-GATE>
This skill requires project config with `"mode": "migration"`. If the config is missing or mode is not "migration", inform the user: "This project is not configured for migration. Create a `.preflight/config.json` with `mode: migration` and a `migration.legacyRepoPath`, or use `/preflight:forge-new` for net-new development."
</HARD-GATE>

Verify from config:
- `migration.legacyRepoPath` exists and points to a directory that exists
- `rubric` path exists (or a default migration rubric is bundled)
- `branch.base` is set

## Phase 1 — Discovery (NEVER SKIP)

<HARD-GATE>
Phase 1 runs on every migration, even when the service "looks simple." The readiness score is what tells you whether it actually IS simple. Skipping Phase 1 has cost 4+ hours in prior migrations when undiscovered dependencies cascaded.
</HARD-GATE>

### Rationalization Prevention

| Your thought | Why it's wrong |
|---|---|
| "This service is tiny, I can skip discovery" | Tiny services have hidden shared-library dependencies that break at link time. Discover them. |
| "I already know this codebase from a previous migration" | You are a fresh session. You know nothing. Discover from scratch. |
| "Phase 1 is just documentation, the code is what matters" | Phase 1 IS the code. It's reading the legacy `.csproj`, mapping references, finding anti-patterns. Skip it and you'll write code that compiles but crashes at runtime. |

### Execution

1. **Project structure** — locate `.csproj` in legacy repo, map internal/external dependencies, identify shared libraries, document legacy `TargetFramework`.

2. **Technical debt scan** — check for: Unity DI, `System.Web`, `ConfigurationManager`, synchronous DB calls, WCF/SOAP, legacy auth (OWIN), `Newtonsoft.Json`.

3. **Architecture rules** — assess coupling to intermediary layers (DP Manager, shared gateways). Recommend decoupling approach. Identify consolidation candidates (verify they exist before listing).

4. **Readiness score** — rate 1-10: Dependency Isolation, Package Compatibility, Code Pattern Complexity, Performance Opportunity, Cloud Readiness. Overall score → Green (8-10) / Yellow (5-7) / Red (1-4) strategy.

5. **Present to user.** Wait for "go" or corrections. This is the only human gate.

## Phase 2 — Execution

<HARD-GATE>
Before writing ANY code, read the generation spec at `${CLAUDE_PLUGIN_ROOT}/defaults/generation-specs/dotnet-service.md`. For every pattern that applies to this service, PASTE the code block verbatim into the target file as a literal text copy — character for character, preserving whitespace, ordering, and structure. Then modify ONLY at marked `/* ADAPT */` points. Do not "use" patterns (interpretation + reconstruction degrades at high context). Do not "apply" patterns. PASTE them, then adapt at marked points only. The generation spec is pre-validated against the detection spec — verbatim paste means Stage 1 will never flag those patterns. Reconstruction from memory WILL produce drift that gets flagged.
</HARD-GATE>

Read ALL of:
- `${CLAUDE_PLUGIN_ROOT}/defaults/generation-specs/dotnet-service.md` (mandatory)
- Project's `CLAUDE.md` (if exists — team conventions)
- `MIGRATION_PATTERNS.md` from reference service (if configured)

Apply generation spec patterns FIRST (deterministic, pre-validated). Then write service-specific business logic (the part that requires reasoning).

1. **Core migration:** SDK-style `.csproj`, modern framework target, package updates, DI modernization.
2. **Modernization:** Modern hosting, async/await + CancellationToken, modern JSON, configuration/secrets, structured logging, observability.
3. **Tests:** Match reference test project layout. Coverage must meet `test.coverageBaseline` from config.
4. **Infrastructure:** Cloud deployment configuration matching reference service patterns.
5. **Container:** Non-root user, correct port, health check in orchestrator only.
6. **Build:** Must pass with 0 errors, 0 warnings.
7. **Test:** All pass, coverage meets baseline.

## Post-Migration Dependency Map Refresh

After Phase 2 completes and before the first Stage 1 run, rebuild the dependency map from the MIGRATED code:

1. **Why:** Phase 1's `dependency-map.json` reflects the LEGACY structure (DP Manager, shared gateways, old class hierarchies). The migrated code has a different coupling graph (direct downstream clients, new DI registrations, different call chains). Using the stale legacy map for coupling analysis during Stage 1 fixes will produce wrong groupings.

2. **Action:** Invoke the `discovery-analyst` sub-agent against the NEW service directory (not the legacy repo). It produces a fresh `dependency-map.json` with:
   - `files` — current imports, injectedBy, callsInto, calledBy for each migrated file
   - `couplingGroups` — coupling based on the NEW architecture (e.g., TokenProvider → typed HttpClient → Strategy, not the old DP Manager chain)
   - `independent` — files that can always be fixed in isolation (Dockerfile, CDK, launchSettings)

3. **Place the output** at `<service-folder>/dependency-map.json`.

4. **Run mechanical validation** from `${CLAUDE_PLUGIN_ROOT}/lib/dependency-map-validator.md`. This catches missed DI-graph coupling, false independence claims, and unverifiable group edges. Apply any corrections to the map before proceeding. Never consume an unvalidated map — a single missed coupling edge converts the coupled-group protocol from cascade-prevention into cascade-creation.

5. **If the discovery-analyst is unavailable** (e.g., cap hit, error): fall back to CONSERVATIVE coupling — treat ALL findings as one coupled group. Slow but safe (no cascade possible).

## Stage 1 Gate + Push + Stage 2 Loop

After the dependency map refresh, invoke the full `/preflight:fix-and-close` pipeline. The same rules apply:

**Hard caps:** Stage 1 max 5 iterations. Stage 2 max 3 iterations (override: `--max-stage2=N` up to 8). Non-negotiable.

**Coupled-Group Fix Protocol:** When multiple findings exist, group by coupling (same file, same call chain, same DI graph) and fix each group as ONE coherent change. Never fix coupled findings independently — that's what caused 70+ rounds on the prior migration.

**Sequence:**
1. Stage 1 review (code-reviewer agent) — reads rubric + operative capture rules
2. If NEEDS_FIXES: apply Coupled-Group Fix Protocol → re-run tests → re-invoke Stage 1
3. If CLEAN: commit + push
4. Copilot loop (copilot-loop agent) — classifies findings, writes operative captures
5. If NEEDS_PARENT_FIXES: apply Coupled-Group Fix Protocol → tests → Stage 1 → push → back to step 4
6. If SUCCESS: structural verification → done
7. If CAPPED/STUCK/DIVERGING: surface to user with evidence

**Structural verification before declaring success** (see `${CLAUDE_PLUGIN_ROOT}/lib/verification-discipline.md`):

Stage 2 returning SUCCESS is a CLAIM, not evidence. Verify independently:
- `dotnet build` — fresh run, 0 errors, 0 warnings. Read the output.
- `dotnet test` — fresh run, all pass, coverage ≥ baseline. Read the count.
- Directory structure matches reference service (if configured). LIST it.
- Health endpoint responds (if service can be started locally). Actually curl it.

If ANY verification fails, DO NOT declare success. Surface the gap with the actual output.

## Communication

- Mark phase boundaries clearly: `## Phase 1 — Discovery`, `## Phase 2 — Step 3: Tests`, `## Stage 2 — Iteration 4`
- Log autonomous decisions with reasoning
- Include numbers: iterations, coverage, capture entries, coupling groups identified
- When applying Coupled-Group Fix Protocol, report which findings you grouped and why
- Do not narrate tool calls

## What This Does NOT Do

- Skip Phase 1
- Push before Stage 1 is clean
- Merge the PR
- Force-push
- Modify the legacy repo
- Mix feature work with migration
- Fix coupled findings independently
- Loop past iteration caps (5 for Stage 1, 3 for Stage 2)

Begin now. Parse `$ARGUMENTS`, discover the project config, and start Phase 1.

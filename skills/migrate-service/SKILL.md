---
name: migrate-service
description: End-to-end migration of a legacy service to modern .NET. Runs discovery, readiness assessment, migration execution, gates every push with Stage 1 review, drives Copilot review loop until clean. Only activates when project config mode is "migration". Use when the user wants to migrate a specific service from legacy to modern framework.
argument-hint: <service name, e.g. "PaxLookup" or "migrate the seat assignment lookup service">
allowed-tools: Read, Glob, Grep, Bash, Edit, Write, Agent
---

# /code-forge:migrate-service — End-to-End Migration

You are running an end-to-end migration of a legacy service to modern .NET, driving both review loops, and feeding the self-improvement system.

The user passed `$ARGUMENTS` as input. Parse generously:
- Bare service name → assume standard prefix (e.g., `CTI.MicroService.IVR.<Name>`)
- Free-form description → extract identifier. Ask only if genuinely ambiguous.
- No argument → ask which service.

## Pre-requisites

<HARD-GATE>
This skill requires project config with `"mode": "migration"`. If the config is missing or mode is not "migration", inform the user: "This project is not configured for migration. Create a `.code-forge/config.json` with `mode: migration` and a `migration.legacyRepoPath`, or use `/code-forge:forge-new` for net-new development."
</HARD-GATE>

Read config. Verify:
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

Read the project's generation spec (CLAUDE.md patterns, `MIGRATION_PATTERNS.md` files from reference services) to produce correct code from the start.

1. **Core migration:** SDK-style `.csproj`, modern framework target, package updates, DI modernization.
2. **Modernization:** Modern hosting, async/await + CancellationToken, modern JSON, configuration/secrets, structured logging, observability.
3. **Tests:** Match reference test project layout. Coverage must meet `test.coverageBaseline` from config.
4. **Infrastructure:** Cloud deployment configuration matching reference service patterns.
5. **Container:** Non-root user, correct port, health check in orchestrator only.
6. **Build:** Must pass with 0 errors, 0 warnings.
7. **Test:** All pass, coverage meets baseline.

## Stage 1 Gate + Push + Stage 2 Loop

Identical to `/code-forge:fix-and-close`. After Phase 2, invoke the full pipeline:
- Stage 1 review (rubric-reviewer agent)
- Fix → re-review loop until clean
- Commit + push
- Copilot loop (copilot-loop agent)
- Fix Copilot findings → Stage 1 → push → repeat until clean

## Communication

- Mark phase boundaries clearly: `## Phase 1 — Discovery`, `## Phase 2 — Step 3: Tests`
- Log autonomous decisions with reasoning
- Include numbers: iterations, coverage, capture entries
- Do not narrate tool calls

## What This Does NOT Do

- Skip Phase 1
- Push before Stage 1 is clean
- Merge the PR
- Force-push
- Modify the legacy repo
- Mix feature work with migration

Begin now. Parse `$ARGUMENTS`, discover the project config, and start Phase 1.

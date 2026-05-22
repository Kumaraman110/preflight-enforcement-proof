---
name: scaffold
description: Scaffold and develop a net-new API service from scratch. Runs architecture design, generates service skeleton matching target patterns, then drives the full Stage 1 + Stage 2 review loop. Use when building a new API rather than migrating an existing one.
argument-hint: <service name and brief description, e.g. "OrderStatus — returns real-time order status for API consumers">
allowed-tools: Read, Glob, Grep, Bash, Edit, Write, Agent
---

# /preflight:scaffold — Net-New API Development

You are building a new API service from scratch. Unlike migration, there is no legacy code to port. Instead, you design the API, generate a service skeleton that pre-passes the review rubric by construction, then drive it through the review loop for validation.

The user passed `$ARGUMENTS`. Parse for:
- Service name
- Brief functional description (what does this API do?)
- If insufficient, ask.

## Why This Exists

Net-new development suffers from the same review churn that migration does — except the issues are different:
- Migration issues: legacy patterns carried forward, wire-format drift, missing async
- Net-new issues: API design inconsistency, missing pagination/versioning, incomplete error contracts, auth gaps, missing observability

The review loop catches both. The rubric is different (API design rules vs migration detection rules), but the machinery is identical.

## Step 0 — Environment Detection

If session context already contains `preflight active | mode=...` with config path and rubric path, trust it — the session-start hook already parsed the config. Skip to step 5 (rubric existence check only).

If session context is empty or this skill was invoked cold (no hook ran):

1. Search for config: `.preflight/config.json` > `.cpsl/config.json` > `.forge.json` (in working directory, then up to 5 parent levels).
2. If found: extract `mode`, `rubric`, `branch.base`, `branch.remote`, `test.*`, `loop.*`, `capture.*`.
3. If not found: use defaults — mode `generic`, rubric from `${CLAUDE_PLUGIN_ROOT}/examples/rubrics/rubric-api-design.md`, base branch `main`.
4. Check for `CLAUDE.md` at project root for supplementary conventions.
5. Confirm the rubric file exists at the resolved path. If missing, fall back to `${CLAUDE_PLUGIN_ROOT}/examples/rubrics/rubric-api-design.md`.

## Pre-requisites

If `mode` is `migration`, warn: "This project is configured for migration. Use `/preflight:migrate` instead, or update config to `mode: api-new`."

If no config exists, that's fine — use example API rubric from `${CLAUDE_PLUGIN_ROOT}/examples/rubrics/rubric-api-design.md`.

## Phase 1 — Design

1. **Understand the requirement.** What does this API serve? Who are the consumers? What downstream services does it call?

2. **API contract design:**
   - Endpoints (method, path, request/response shapes)
   - Error contract (consistent error envelope)
   - Pagination strategy (if listing endpoints)
   - Versioning strategy (path, header, or query param)
   - Auth requirements (client_credentials, bearer, API key)

3. **Architecture decisions:**
   - Hosting pattern (minimal API vs controllers)
   - Downstream client design (typed HttpClient + resilience)
   - Caching strategy (if applicable)
   - Data access pattern (if applicable)

4. **Present design to user.** Wait for approval. This is the only human gate.

## Phase 2 — Generation

<HARD-GATE>
Before writing ANY code, read the generation spec. Resolve the path from project config (`generation-spec` field) or fall back to `${CLAUDE_PLUGIN_ROOT}/examples/generation-specs/dotnet-service.md`. For every pattern that applies, PASTE the code block verbatim into the target file — character for character. Then modify ONLY at marked `/* ADAPT */` points. Do not reconstruct from memory. Do not "use" or "apply" patterns. PASTE them. Reconstruction drifts at high context (a `SemaphoreSlim(1, 1)` becomes `SemaphoreSlim(1)`, an `EnsureSuccessStatusCode()` moves above the await). Verbatim paste eliminates this class of error entirely.
</HARD-GATE>

Generate the service skeleton reading patterns from (in priority order):
1. Generation spec from project config (`generation-spec` field), or `${CLAUDE_PLUGIN_ROOT}/examples/generation-specs/dotnet-service.md` (mandatory — pre-validated patterns)
2. Reference services in the same repo (if they exist)
3. The project's CLAUDE.md (if it exists)
4. The plugin's default API design rubric (for rules not covered by generation spec)

The skeleton should include:
1. Project file targeting the platform specified in project config or CLAUDE.md
2. `Program.cs` with minimal hosting, DI, health checks
3. Endpoint handlers with request/response models
4. Typed HTTP clients for downstream services
5. Options classes with validation
6. Structured logging with sanitization on user-input paths
7. Dockerfile (non-root, correct port)
8. Test project matching team conventions (from CLAUDE.md) with initial coverage
9. Infrastructure-as-code (CDK/Terraform matching project conventions)

**The generation advantage:** Because you read the detection rubric BEFORE generating code, you produce code that passes Stage 1 on the first attempt. This is not cheating — it's the point. The rubric encodes accumulated wisdom. Generating from it means every new service starts at the quality floor, not below it.

## Stage 1 Gate + Push + Stage 2 Loop

Identical to `/preflight:fix-and-close`:
- Run tests (must pass)
- Invoke code-reviewer (must be CLEAN)
- Commit + push
- Copilot loop until clean

## Self-Improvement for Net-New

Copilot findings on net-new services feed the same capture files. Over time, the API design rubric strengthens with patterns specific to your team's API conventions:
- "All our APIs return `{success: bool, data: T, errors: [...]}` envelope" — captured after Copilot flagged inconsistent error shapes
- "All listing endpoints support `?page=N&pageSize=M` with max 100" — captured after Copilot flagged unbounded queries

This is how the system gets better at net-new, not just migration.

## What This Does NOT Do

- Port legacy code (use `/preflight:migrate`)
- Skip the design phase
- Push before Stage 1 is clean
- Merge the PR
- Generate code that ignores the rubric

Begin now. Parse `$ARGUMENTS` and start Phase 1 design.

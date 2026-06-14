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

## Framework Root Resolution

Framework assets (generation specs, rubrics, validators) install into the consumer's `.claude/` tree alongside the skills and agents (skills/agents are platform-locked to `.claude/`; hooks/lib/examples join them there). Resolve the root once at the start of every run:

```bash
FRAMEWORK_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
echo "Framework root: ${FRAMEWORK_ROOT}"
```

If the directory doesn't exist (`[ -d "$FRAMEWORK_ROOT" ]` is false), warn: "Framework root resolution failed — .claude/ not found at the project root." Continue with project-local config only (`.preflight/` paths); framework-relative fallbacks will be unavailable.

All `${FRAMEWORK_ROOT}` references in this file use the path above. Do NOT depend on `CLAUDE_PLUGIN_ROOT` — it is empty off-plugin and never reaches sub-agents. `CLAUDE_PROJECT_DIR` is also unset in some contexts, so the git/pwd fallback is what resolves there; the cwd is the project root in every context, so the fallback is reliable. (This replaces the earlier `~/.claude/skills/migrate` junction-readlink mechanism, which assumed a home-level symlink to the author's code-forge checkout — that symlink does not exist on a standard project-level install.)

## The Architectural Commitment

**Every issue caught by external review on ServiceN should be caught by local review on ServiceN+1.** Your job, beyond migrating the code, is to make this real on this migration. The Stage 2 orchestrator + learning agent does the capture; you ensure it runs and that its output gets committed.

## Step 0 — Environment Detection

If session context already contains `preflight active | mode=migration` with config path and rubric path, trust it — the session-start hook already parsed the config. Skip to step 5 (rubric existence check only).

If session context is empty or this skill was invoked cold (no hook ran):

1. Search for config: `.preflight/config.json` > `.forge.json` (in working directory, then up to 5 parent levels).
2. If found: extract `mode`, `rubric`, `branch.base`, `branch.remote`, `branch.migrationPrefix`, `test.*`, `loop.*`, `capture.*`, `migration.*`.
3. If not found: use defaults — mode `generic`, base branch `main`, test command auto-detected.
4. Check for `CLAUDE.md` at project root for supplementary conventions.
5. Confirm the rubric file exists at the resolved path. If missing, warn and fall back to `${FRAMEWORK_ROOT}/examples/rubrics/rubric-migration-dotnet.md` (example rubric — teams should configure their own).

## Pre-requisites

<CRITICAL-INSTRUCTION>
This skill requires project config with `"mode": "migration"`. If the config is missing or mode is not "migration", inform the user: "This project is not configured for migration. Create a `.preflight/config.json` with `mode: migration` and a `migration.legacyRepoPath`, or use `/preflight:scaffold` for net-new development."
</CRITICAL-INSTRUCTION>

Verify from config:
- `migration.legacyRepoPath` exists and points to a directory that exists on disk
- `rubric` path exists (or the example migration rubric is available at `${FRAMEWORK_ROOT}/examples/rubrics/rubric-migration-dotnet.md`)
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
   - **Remote-collision check (prompt-level — YOU run this; it is NOT a mechanical hook).** Before cutting, run `git ls-remote --heads <branch.remote> <branchName>` (where `<branchName>` is the name you are about to cut). Branch names are now **unique per attempt** (see the cut step below), so a collision should essentially never happen — but the guard stays as a backstop: if the unique name somehow already exists on the remote (e.g. a re-run that reused a checkpoint's branch, or an astronomically-unlikely token clash), do NOT silently cut over it. (Historical context: the name USED to be deterministic per service — `feature/migrate-<service>` — which is what produced the observed 5-PRs-on-one-branch debris pattern. The unique-name scheme fixes that root cause; this guard now backstops the rare residual.)
     - **Branch EXISTS on the remote** → do NOT silently cut over it. STOP and surface: *"Remote branch `<branchName>` still exists on `<branch.remote>` — likely prior-attempt debris. Clear it first (close any open PR, then delete the branch via the fix-and-close Branch Cleanup procedure: close → verify-after-close), OR if this is an intentional resume, confirm intent."* Do not proceed to the cut until the branch is cleared or the user confirms.
     - **Branch ABSENT** → proceed with the cut.
     - **`branch.remote` / config unresolvable** → fail-open: proceed (same posture as the force-push and wrong-repo guards — an additive check must not newly block a repo that didn't opt in).
   - *Honesty:* this collision check is **prompt-level** (the migrate agent performs it). Unlike the force-push and wrong-repo guards — which are mechanical `PreToolUse:Bash` hooks because the dangerous operation is a distinctive command string — branch-cut is **not** on a hookable seam (`git checkout -b` is too common to match, and the collision needs a remote round-trip the command doesn't carry). It is honestly a prompt-level guard, not a mechanism. See `docs/parity-gate-limitations.md`.
   - **Determine the branch name (unique per attempt — this is the GAP-4 root fix).**
     - **Resume path:** if step 6 found a checkpoint for THIS service and the user chose to resume (not restart), reuse the checkpoint's stored `branch` value verbatim. Do NOT generate a new name — a resume must continue on the branch its prior phases already committed to, or it orphans that work.
     - **Fresh path (new migration, or `restart`):** generate a UNIQUE branch name so a re-attempt can never silently cut over prior-attempt debris on the same name (the 5-PRs-on-one-branch pattern). The name is `<migrationPrefix><service>-<token>` where:
       - `<migrationPrefix>` and the `<service>` slug are as before (default prefix `feature/migrate-`), keeping the name human-readable and greppable by service.
       - `<token>` is a short unique, time-sortable suffix. Derive it from values you already have — do **not** invent randomness blindly. Preferred: the short SHA of the base commit you're cutting from, `git rev-parse --short HEAD` (after checking out + pulling `branch.base`), which is unique per base state and meaningful. If you also want chronological sorting across attempts on the same base, prefix a UTC timestamp: `$(date -u +%Y%m%d-%H%M%S)-<short-sha>`. Example: `feature/migrate-sessiontoken-20260607-091500-b2de011`.
       - Keep the total ref name within git's limits and free of characters invalid in a ref (no spaces, `~^:?*[`, no `..` or trailing `/`).
     - Record the chosen name; you will write it into the checkpoint (`branch:`) in step 6's schema and use it for the collision check above.
   - Switch to `branch.base`, pull `branch.remote/branch.base`, THEN compute the token (so a base-SHA token reflects the pulled tip) and cut the new branch with the resolved unique name. Teams that want to encode target platform in the branch name can still configure `branch.migrationPrefix` in `.preflight/config.json`; the unique `<token>` is appended after the prefix+service regardless.

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

   <CRITICAL-INSTRUCTION>
   **Failed sub-agent dispatch STOPS the migration and records a COMPLETION-BUG. The main session NEVER self-runs a failed dispatch.**

   If a sub-agent dispatch fails (agent type not found, dispatch error, or the sub-agent returns ERROR), the skill:
   1. STOPS at that step immediately.
   2. Records the failure as a COMPLETION-BUG finding — a dispatch that can't fire is a named, surfaced bug, not a step to silently substitute with inline work.
   3. Reports to the user: "Sub-agent dispatch failed: <agent-type> — <error>. This is a COMPLETION-BUG (the framework architecture didn't execute). The migration cannot proceed at this step."

   The main session is the ORCHESTRATOR, never the fallback executor. "I'll do it myself" is **forbidden** — it discards the isolated-context guarantee the sub-agent exists to provide and hides a real registration/dispatch failure behind apparently-successful output. A migration that proceeds by self-running a failed-to-dispatch sub-agent is NOT a valid framework run — the architecture didn't actually execute.

   Run 5's failure mode: discovery-analyst dispatch returned "Agent type not found," and the main session absorbed the work. That produced output that LOOKED correct but violated the isolation contract, hid the registration bug, and shipped a migration that never ran through the framework's quality gates. This rule prevents that.
   </CRITICAL-INSTRUCTION>

   The analyst loads the appropriate scan profile for this project's stack (configured in `.preflight/config.json`, or auto-detected from project files). It produces:
   - Technical debt inventory with category IDs, severity levels, counts, and file:line locations
   - Architecture assessment (coupling to intermediary layers, consolidation candidates)
   - Readiness score (1-10 per category)
   - Dependency map (`dependency-map.json`)

   If the analyst returns BLOCKED or ERROR, surface the reason and ask the user how to proceed. Do not attempt to run the scan yourself — the analyst has the profile-loading logic and pattern expertise. A dispatch failure (agent type not found) is distinct from BLOCKED (agent ran but can't proceed) — dispatch failure is a COMPLETION-BUG that stops the run; BLOCKED is an expected state that surfaces to the user for direction.

   After the analyst returns DONE, verify dependency-map.json exists at the path specified in the analyst's status block. Run: `test -f <service-folder>/dependency-map.json && echo EXISTS || echo MISSING`. If MISSING, the analyst failed to persist the dependency map to disk despite returning DONE. Re-invoke the analyst with explicit instruction: "Write the dependency-map.json file to disk before returning DONE. The file is required for downstream coupling analysis." If the second attempt also fails, STOP and report to the user — do not proceed to Phase 2 without a valid dependency map.

   Report the analyst's findings as Phase 1 output.

2b. **Behavioral extraction** — use the Agent tool with `subagent_type: spec-analyst` to spawn the behavioral analyst against the legacy service directory. The spec-analyst consumes the dependency map produced in step 2 (or an explicit file list derived from the comparison surfaces in CLAUDE.md if no map exists for the legacy path). It produces:
   - `behavior-spec.json` documenting all externally-observable behaviors with citation-grounded evidence
   - A completeness check verifying all pattern matches in scope are accounted for

   If CLAUDE.md has no "Behavioral Contract" section, the spec-analyst will return BLOCKED. Surface this to the user and POINT THEM TO THE ON-RAMP: run `/preflight:bootstrap` (Generate mode) to stamp the Behavioral Contract scaffold, or stamp the template at `${FRAMEWORK_ROOT}/examples/behavioral-contract-template.md` directly, then author the OPERATOR sections against the legacy source. This is not a fatal error for the migration — you may proceed without a behavior spec, but warn that parity checking will be unavailable post-migration (the flagship drift gate will be a no-op).

   If CLAUDE.md HAS a Behavioral Contract section but it is still a **DRAFT** (an unfilled scaffold-placeholder comment — `<!-- OPERATOR: … -->`, `<!-- AUTO-DERIVED … -->`, `<!-- AUTO: … -->` — or a `TODO` token remains in the behaviour sections; match the placeholder COMMENT precisely, not the bare word "OPERATOR" in the scaffold's explanatory prose), warn explicitly: "the Behavioral Contract is still a scaffold draft — the parity baseline extracted from it will be incomplete, so parity is NOT yet protecting this migration. Complete the operator-authored sections against the legacy source before trusting the gate." The user decides whether to complete it now or proceed knowingly.

   If the spec-analyst returns DONE_INCOMPLETE, surface the missing entries. The user decides whether to investigate or accept.

   The behavior spec is the BASELINE for the future parity gate. After Phase 2, the same extraction runs against the migrated code and the two specs are diffed to detect behavioral drift.

2b-commit. **Commit the legacy baseline early (immutability anchor).**

<CRITICAL-INSTRUCTION>
Immediately after behavioral extraction produces `.preflight/<service>/behavior-spec.json`, commit it ALONE in its own commit BEFORE any Phase 2 code is written. This establishes the baseline as immutable — it was committed before the migrated code existed, so any modification to it in the same PR is detectable by CI (the baseline-immutability check in the generated CI workflow uses `git log --diff-filter=M` to flag changes to the baseline after its initial commit).

The commit message: `chore(<service>): add legacy behavioral baseline for parity verification`

This ordering is load-bearing:
- Legacy baseline committed FIRST (from legacy code that exists independently)
- Phase 2 code committed LATER (the migrated service)
- CI detects if the baseline is MODIFIED after initial commit (tampering signal)

Do NOT modify or regenerate `.preflight/<service>/behavior-spec.json` after this commit, for any reason, for the rest of the run. It is the immutable legacy baseline. If you believe the baseline is wrong or incomplete, STOP and report it — do not edit it. CI treats ANY modification to this file in the PR as a tampering signal and will block the PR, whether the edit was a forge or an innocent regeneration.

If behavioral extraction returns BLOCKED (no Behavioral Contract in CLAUDE.md), skip this step — there is no baseline to commit.
</CRITICAL-INSTRUCTION>

   ```bash
   git add ".preflight/${SERVICE_NAME}/behavior-spec.json"
   git commit -m "chore(${SERVICE_NAME_LOWER}): add legacy behavioral baseline for parity verification"
   ```

2c. **Legacy name-contract extraction** — if the service touches a database (stored procs, tables, queries visible in legacy source), produce the name-contract artifact NOW, during Phase 1, BEFORE any Phase 2 code is written. This makes the contract a ground-truth reference transcribed from legacy, not a post-hoc description of what you already wrote.

   Scan the legacy source files identified by the dependency map. For each stored procedure call, record: proc name (exact string from the code), every parameter name (exact string, including `@` prefix if present), and the order/types as passed. For table/column references, record the exact strings. Write the output to `.preflight/<service>/legacy-db-name-contract.md`.

   **Reachability annotation (per entry point):** For EACH item in the contract, annotate whether it is REACHABLE from the migrated entry point. The contract maps the migrated entry point's reachable surface, using the shared DB/service layer as REFERENCE — not as the scope boundary. An item that exists in the DB layer but is unreachable from the entry point is annotated as such, not listed as a plain to-migrate item.

   For each stored procedure or table, trace the call chain from the controller being migrated through downstream services. Record one of:
   - `REACHABLE` — the entry point's request path can reach this item (state the path: "controller → service → client → downstream → proc")
   - `NOT REACHABLE` — this item exists in the shared DB/service layer but is gated behind a condition the migrated entry point never satisfies. State the gate: "only reachable via <other caller> which sets <flag>=true; the migrated controller's request model has no <flag> field"

   Format example:
   ```
   | cpsl_setCCToken_v2 | REACHABLE | CPSLToken controller → Token Manager → CreateSessionToken → proc |
   | cpsl_setMPToken_v1 | NOT REACHABLE | Only via SharedServicesController (gated IsMPToken=true; CPSLToken never sets this). Exists in shared DB layer. |
   ```

   **Why this matters:** Run 6's false positive — `cpsl_setMPToken_v1` was listed in the contract without reachability, the reconstruction flagged "in contract but not implemented = HIGH gap," but it was correctly omitted because it's unreachable from the CPSLToken entry point. Reachability annotation prevents this class of phantom gap.

   If no database access is found in the legacy source, write a minimal contract noting "No database operations identified in legacy source" — the artifact must exist regardless.

   Verify the artifact exists:
   ```bash
   test -f ".preflight/<service>/legacy-db-name-contract.md" && echo "NAME-CONTRACT: EXISTS" || echo "NAME-CONTRACT: MISSING"
   ```
   If MISSING after your extraction attempt, something went wrong — re-examine and write it. Do NOT proceed to Phase 2 without this artifact.

2d. **Legacy DB extraction scripts** — produce TARGETED, read-only SQL Server extraction scripts scoped to exactly the stored procedures and tables this service touches (identified by the name-contract and dependency map). These scripts let the developer execute against the legacy SQL Server to obtain the authoritative schema (datatypes, proc definitions, column metadata) that the name-contract's CODE-transcribed names reference. Names come from code (the name-contract). Schema comes from the DB (these scripts' output). The framework NEVER invents schema or datatypes.

   Split into multiple independently-runnable files by extraction concern. The skill decides the actual split based on what discovery found — more files if more objects warrant it. Standard split:

   - `.preflight/<service>/legacy-db-extraction-procs.sql` — Proc definitions for each stored procedure (via `OBJECT_DEFINITION()` or `sp_helptext`), targeted by exact proc name from the name-contract. Not a whole-DB dump.
   - `.preflight/<service>/legacy-db-extraction-params.sql` — Parameter metadata (name, datatype, direction, max_length, precision, scale) for those procs via `sys.parameters` / `INFORMATION_SCHEMA.PARAMETERS`, filtered to the named procs.
   - `.preflight/<service>/legacy-db-extraction-tables.sql` — Column names, datatypes, nullability, defaults, PK/FK constraints, and indexes for the named tables via `INFORMATION_SCHEMA.COLUMNS` / `sys.columns` / `sys.indexes`, filtered to the named tables.

   **Rules for the scripts:**
   - **TARGETED** to this service's exact procs/tables — use the names from the name-contract. Never a generic whole-database dump.
   - Each file starts with a **header comment** stating: what it extracts, that it runs against LEGACY SQL SERVER (name the catalog/DB if discovery identified it), and what the developer does with the output (build Postgres DDL + tie against the name-contract).
   - **Read-only queries only** — no DDL, no INSERT/UPDATE/DELETE, nothing that mutates the legacy database.
   - **No invented Postgres DDL and no invented datatypes anywhere.** These scripts REVEAL the schema from the authoritative source; they do not assert it. The contract: names from code (the name-contract), schema from the DB (these scripts' output).
   - Produced in Phase 1, BEFORE Phase 2 code generation (same timing as the name-contract — derived from the known legacy proc/table names).

   Verify the artifacts exist:
   ```bash
   test -f ".preflight/<service>/legacy-db-extraction-procs.sql" && echo "EXTRACTION-PROCS: EXISTS" || echo "EXTRACTION-PROCS: MISSING"
   test -f ".preflight/<service>/legacy-db-extraction-params.sql" && echo "EXTRACTION-PARAMS: EXISTS" || echo "EXTRACTION-PARAMS: MISSING"
   ```
   If any are MISSING after generation, re-examine and write them. Do NOT proceed to Phase 2 without these artifacts.

   If no database access was found in the legacy source (the name-contract says "No database operations identified"), skip this step — no extraction scripts are needed.

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
Before writing ANY code, read the generation spec. Resolve it using the loading procedure below. If no spec file resolves at all, STOP — do NOT proceed, do NOT substitute the reference service as a spec, do NOT use CLAUDE.md architecture descriptions as a replacement. The reference service is NOT a generation spec. If resolution fails, inform the user: "Generation spec resolution failed. Paths tried: [list them]. Configure `generation-spec` in `.preflight/config.json` or verify the skill junction resolves correctly."

Once the spec is loaded: for every pattern that applies to this service, PASTE the code block verbatim into the target file as a literal text copy — character for character, preserving whitespace, ordering, and structure. Then modify ONLY at marked `/* ADAPT */` points. Do not "use" patterns (interpretation + reconstruction degrades at high context). Do not "apply" patterns. PASTE them, then adapt at marked points only. The generation spec is pre-validated against the detection spec — verbatim paste means Stage 1 will never flag those patterns. Reconstruction from memory WILL produce drift that gets flagged.
</CRITICAL-INSTRUCTION>

Read ALL of:
- Generation spec (resolved via the loading procedure below — mandatory, one must resolve)
- Project's `CLAUDE.md` (if exists — team conventions)
- `MIGRATION_PATTERNS.md` from the configured reference service (if `migration.referenceService` exists in config). If `migration.referenceService` is not configured, skip this — proceed without reference patterns.

Apply generation spec patterns FIRST (deterministic, pre-validated). Then write service-specific business logic (the part that requires reasoning).

### Standard Migration Phases

The migration phases are defined by the generation spec. The generation spec is the authoritative source for what patterns to apply, in what order, using what tools.

**Loading the generation spec:**

Resolve the spec file using this ordered fallback. Try each step; use the first that resolves to an existing file.

1. **Explicit config path:** Check `generation-spec` field in `.preflight/config.json`. If set and the file exists, use it.
2. **Framework-relative path:** Framework assets install under the consumer's `.claude/` root. Resolve and check:
   ```bash
   FRAMEWORK_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
   SPEC_PATH="${FRAMEWORK_ROOT}/examples/generation-specs/dotnet-service.md"
   test -f "$SPEC_PATH" && echo "SPEC FOUND: $SPEC_PATH" || echo "SPEC NOT FOUND at: $SPEC_PATH"
   ```
   If the file exists at the resolved path, use it. Read it with the resolved absolute path.
3. **Project-local fallback:** Check `.preflight/generation-spec.md` in the project root. If it exists, use it.

If NONE of the above resolves to an existing file:

**STOP.** Do NOT proceed with Phase 2. Do NOT substitute the reference service patterns, CLAUDE.md architecture descriptions, or your own knowledge of the codebase. Report to the user:
- Which paths were tried (all three)
- What each resolved to (or failed to resolve to)
- That a generation spec is required and must be made available via one of the three paths above

This gate exists because the prior SessionToken migration bypassed it — the agent found no spec and substituted the reference service, producing code that drifted from validated patterns. Do not repeat this.

**Execution discipline:**
- Do not run build commands between every micro-step — that wastes cycles. Build at the end of each logical phase.
- Apply the PASTE discipline from the CRITICAL-INSTRUCTION block above — verbatim copy, adapt only at `/* ADAPT */` markers. Build verification at the end of each phase confirms the paste produced compilable code.

**Standard execution phases (generation spec provides the specifics for each):**

1. **Core migration:** Convert project format, update target framework, migrate dependency management, replace legacy DI container.

2. **Modernization:** Modern hosting patterns, async I/O end-to-end, modern serialization, configuration management (secrets + parameters), structured logging with sanitization, observability instrumentation.

3. **Test migration:** Match the reference service test project layout and framework. Coverage baseline from config (`test.coverageBaseline`) is the floor. If `test.coverageBaseline` is not configured, default to 85% (or the team standard documented in CLAUDE.md, if higher). This number must match the canonical default stated in the "Coverage discipline" section below — Check 5 executes the same 85% fallback.

   3b. **Wire-fidelity golden test (WIRE-B integration):** For every response/model type the service serializes to callers, emit a WIRE-B golden test wired to the service's **real DI-resolved** `JsonSerializerOptions` — not a hand-built options object. This is the mechanical close for runtime-serialization divergence that WIRE-A (spec-level inference) cannot catch.

   **Steps:**
   1. Identify the service's configured `JsonSerializerOptions` accessor. This is the options instance that `AddJsonOptions` / `builder.Services.Configure<JsonOptions>` builds — the very same options the pipeline uses at runtime. Typical accessor: `WireGolden.ServiceWireOptions.Options` (a class you create in the test project that mirrors the service's DI wiring).
   2. For each response type with a known legacy wire format, capture the legacy wire string (from legacy traffic captures, integration tests, or documentation). Build a `wire-golden.json` contract at `.preflight/<service>/wire-golden.json` with shape:
      ```json
      {
        "captured_from": "legacy <source> @ <sha-or-build>, endpoint <route>",
        "options_accessor": "<Namespace>.ServiceWireOptions.Options",
        "cases": [
          {
            "name": "<TypeName>_<scenario>",
            "type": "<FullyQualifiedTypeName>",
            "sample": { "camelCaseField": "value" },
            "golden": "{\"camelCaseField\":\"value\"}"
          }
        ]
      }
      ```
   3. Run the generator:
      ```bash
      bash "${FRAMEWORK_ROOT}/lib/generate-wire-golden-test.sh" \
        ".preflight/${SERVICE_NAME}/wire-golden.json" \
        "${SERVICE_DIR}.Tests/WireGoldenTests.cs" \
        --runner xunit
      ```
   4. **EMIT the `ServiceWireOptions` class (GENERATED — zero operator wiring).** The migrate skill GENERATES this class into the test project so `options_accessor` resolves the service's REAL DI-configured serializer options with ZERO manual step. The generated class mirrors whatever `AddJsonOptions` configures (PropertyNamingPolicy, DefaultIgnoreCondition, etc.).

      Create `{ServiceName}.Tests/ServiceWireOptions.cs` with EXACTLY this content (replace `{Namespace}` with the test project namespace — derive from the project name or migration config):

      ```csharp
      // <auto-generated>
      // GENERATED by preflight migrate skill Phase 2 — DO NOT EDIT BY HAND.
      // Wires the wire-golden test to the service's REAL DI-resolved
      // JsonSerializerOptions so byte-comparison tests the actual pipeline,
      // not a hand-built fiction.
      //
      // HONESTY: This class replicates the AddJsonOptions configuration from
      // Program.cs. If AddJsonOptions changes, this class MUST be regenerated
      // (re-run the migrate skill Phase 2).
      // </auto-generated>
      using System.Text.Json;
      using System.Text.Json.Serialization;

      namespace {Namespace}
      {
          /// <summary>
          /// Exposes the service's real JsonSerializerOptions for wire-golden
          /// byte-comparison testing. Wired to DI via builder.Services.Configure
          /// in Program.cs — the same options the pipeline uses at runtime.
          /// </summary>
          public static class ServiceWireOptions
          {
              /// <summary>
              /// The DI-resolved options. Set by Program.cs at startup.
              /// Wire-golden tests read this property.
              /// </summary>
              public static JsonSerializerOptions Options { get; private set; }
                  = new JsonSerializerOptions(); // default until DI wires

              /// <summary>
              /// Called from Program.cs to mirror the service's
              /// AddJsonOptions configuration. Keep this in sync with
              /// the actual AddJsonOptions call in Program.cs.
              /// </summary>
              public static void Configure(JsonSerializerOptions opts)
              {
                  opts.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
                  opts.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
                  // ADD CUSTOM CONVERTERS / SETTINGS HERE (mirror AddJsonOptions)
              }
          }
      }
      ```

      Then wire it in `Program.cs` (add this line RIGHT AFTER `builder.Services.Configure<JsonOptions>(...)` or the `AddJsonOptions` call):

      ```csharp
      builder.Services.Configure<JsonOptions>(o => ServiceWireOptions.Configure(o.SerializerOptions));
      ```

      This ONE extra line in Program.cs is the only wiring — the operator does nothing. The `options_accessor` in wire-golden.json stays `{Namespace}.ServiceWireOptions.Options`.

   **HONESTY LABEL:** The generator is MECHANICAL (byte-compare) but STACK-BOUND (.NET/System.Text.Json) and GOLDEN-BOUND (proves parity against captured strings only). Golden capture provenance is a human-verified input recorded in `captured_from`.

   If no wire-format contract can be captured (no legacy traffic, no integration tests), log this as a COMPLETION-BUG: "wire-fidelity golden test NOT emitted — no legacy wire strings available. WIRE-B is not protecting this service until a golden is captured."

4. **Infrastructure:** Cloud infrastructure as code matching the reference service pattern. Compute, networking, container registry, auto-scaling, secrets management.

5. **Container:** Secure container image — non-root user, fixed port, health check defined in orchestrator config (not in container image).

6. **CI workflow generation** — produce the per-service PR workflow and vendor parity scripts. See "CI Workflow Generation" section below.

7. **Build verification** — must be 0 errors, 0 warnings (treat warnings as errors). Fix anything that breaks.

8. **Test verification** — all pass, coverage meets `test.coverageBaseline`. Fix anything that fails.

The generation spec fills in the stack-specific details for each phase. The migrate skill orchestrates the sequence. The generation spec provides the patterns.

**Write checkpoint** after each completed phase: update `phase: phase2_step_N_complete`.

## CI Workflow Generation

<CRITICAL-INSTRUCTION>
CI workflow generation, parity script vendoring, and the early-baseline commit are REQUIRED
steps with NO skip path. The migration is NOT complete until the CI workflow file exists and
is committed. A step that doesn't fire is a RECORDED COMPLETION-BUG finding (explicit, named,
surfaced to the human) — never summarize it as a future/optional gap or "next step for
production." The end-of-run reconstruction MUST check for the CI workflow file's existence
and flag its ABSENCE as a failure, not a gap.

If for a specific environmental reason a step genuinely cannot run (e.g., framework root
unresolvable, parity scripts not found at expected path), the skill MUST:
1. Log a COMPLETION-BUG finding with the exact reason and the path that failed.
2. Surface it to the user as a blocker, not an informational note.
3. NOT proceed to handoff without human acknowledgment of the gap.
</CRITICAL-INSTRUCTION>

Every migrated service is born CI-wired. The migrate skill generates a per-service GitHub Actions caller workflow as a migration deliverable. This moves parity verification OUTSIDE the agent's reach — CI runs on committed files that the agent cannot modify post-push.

### What to generate

**File:** `.github/workflows/<service-kebab>-pull-request.yaml`

Where `<service-kebab>` is the service name in lowercase-hyphenated form (e.g., `cpsltoken`, `sessiontoken`, `accountlookup`).

**Template** (adapt placeholders marked with `{...}`):

```yaml
---
name: {ServiceDisplayName} — Pull Request

on:
  pull_request:
    branches:
      - main
      - AccountLookUp_POC
    paths:
      - "CTIAPI-DEV_Work/CTI.MicroService.IVR.{ServiceName}/**"
      - "CTIAPI-DEV_Work/CTI.MicroService.IVR.{ServiceName}.Tests/**"
      - ".github/workflows/{service-kebab}-pull-request.yaml"

jobs:
  pull-request:
    uses: United-Airlines-Org/workflows.pipeline/.github/workflows/pull-request.yaml@v2
    permissions:
      actions: read
      contents: read
      deployments: write
      id-token: write
      issues: write
      packages: read
      pull-requests: write
      statuses: write
    with:
      app-project-root: CTIAPI-DEV_Work/CTI.MicroService.IVR.{ServiceName}
      iac-project-root: CTIAPI-DEV_Work/CTI.MicroService.IVR.{ServiceName}/infra
      disable-linter: true
      dockerfile-path: CTIAPI-DEV_Work/CTI.MicroService.IVR.{ServiceName}
      project-name: cpsl-{service-kebab}
      dotnet-csproj-path: >-
        CTIAPI-DEV_Work/CTI.MicroService.IVR.{ServiceName}/CTI.MicroService.IVR.{ServiceName}.csproj
      dotnet-veracode-include: >-
        CTI.MicroService.IVR.{ServiceName}.dll,
        CTI.MicroService.IVR.{ServiceName}.pdb
      dotnet-version: 10.x
      project-type: dotnet
      veracode-app-name: CTI {ServiceDisplayName}
      target-branch: AccountLookUp_POC
      target-environment: dev
    secrets: inherit

  parity-check:
    runs-on: ubuntu-latest
    if: >-
      ${{ github.actor != 'github-actions[bot]' }}
    steps:
      - name: Checkout
        uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Baseline immutability check
        run: |
          BASELINE=".preflight/{ServiceName}/behavior-spec.json"
          if [ ! -f "$BASELINE" ]; then
            echo "No legacy baseline found — parity check skipped (new service without behavioral contract)"
            exit 0
          fi
          # Check if the baseline was MODIFIED (not added) in this PR's commits
          MODIFIED=$(git diff --diff-filter=M --name-only origin/${{ github.base_ref }}...HEAD -- "$BASELINE")
          if [ -n "$MODIFIED" ]; then
            echo "BLOCKED: Legacy behavioral baseline was MODIFIED in this PR."
            echo "The baseline must be immutable once committed — it was extracted from"
            echo "legacy source before the migration began. Modifying it in the same PR"
            echo "that creates the migrated service is a tampering signal."
            echo ""
            echo "Modified file: $MODIFIED"
            exit 1
          fi
          echo "Baseline immutability: PASS (not modified in this PR)"

      - name: Spec integrity check (anchor consistency)
        run: |
          SPEC=".preflight/{ServiceName}/behavior-spec-current.json"
          SOURCE="CTIAPI-DEV_Work/CTI.MicroService.IVR.{ServiceName}"
          if [ ! -f "$SPEC" ]; then
            echo "No migrated spec found — spec integrity check skipped"
            exit 0
          fi
          # GitHub Actions runs `run:` steps under `set -e`. spec-integrity-check.sh exits
          # non-zero on an anchor-consistency failure (2). A BARE call propagates that exit
          # correctly (errexit → step red), but the moment ANY post-call logic is added it
          # would abort BEFORE the capture — the same dead-gate trap the parity step below
          # fell into. Use the explicit capture pattern proactively so both gates share ONE
          # safe idiom: disable errexit ONLY around the call, read $?, re-enable, then decide.
          # Any non-zero still BLOCKS (exit 1) — this never converts a failure into a pass.
          set +e
          bash .github/scripts/spec-integrity-check.sh "$SPEC" "$SOURCE"
          SPEC_EXIT=$?
          set -e
          if [ $SPEC_EXIT -ne 0 ]; then
            echo "BLOCKED: spec integrity check failed (exit $SPEC_EXIT)."
            echo "Anchors are inconsistent between the migrated spec and the source — a behavior"
            echo "may have been stripped from the spec to dodge a parity failure."
            exit 1
          fi

      - name: Parity check (behavioral drift detection)
        run: |
          BASELINE=".preflight/{ServiceName}/behavior-spec.json"
          CURRENT=".preflight/{ServiceName}/behavior-spec-current.json"
          if [ ! -f "$BASELINE" ] || [ ! -f "$CURRENT" ]; then
            echo "Spec files missing — parity check skipped"
            exit 0
          fi
          # GitHub Actions runs `run:` steps under `set -e`, so a non-zero exit from
          # parity-check.sh (1 advisory / 2 blocking) would abort the step AT THE CALL,
          # BEFORE `$?` is captured — making the exit-code branching below DEAD (the
          # "BLOCKED:" diagnostic never prints, and the intended exit-2-blocks logic never
          # runs). Disable errexit ONLY around the call so the code is captured, then decide.
          # (Ported from the consumer fix proven live in the SessionToken run — keep here so
          # future consumers do not inherit the dead gate. Single source: this template.)
          set +e
          bash .github/scripts/parity-check.sh "$BASELINE" "$CURRENT"
          PARITY_EXIT=$?
          set -e
          if [ $PARITY_EXIT -eq 2 ]; then
            echo "BLOCKED: Blocking parity violations detected."
            echo "The migrated service has behavioral drift from legacy."
            exit 1
          fi
          exit $PARITY_EXIT

      - name: Wire-fidelity golden test (WIRE-B)
        run: |
          # WIRE-B: byte-compare against captured legacy wire strings.
          # Runs the generated golden test against the service's REAL serializer
          # options. A naming/null-policy divergence FAILS THE BUILD.
          WIRE_CONTRACT=".preflight/{ServiceName}/wire-golden.json"
          if [ ! -f "$WIRE_CONTRACT" ]; then
            echo "No wire-golden contract found — WIRE-B skipped (no legacy wire strings captured)"
            exit 0
          fi
          echo "BLOCKED: wire-fidelity golden test is a REQUIRED blocking step."
          echo "Wire divergence means the migrated service serializes differently from"
          echo "legacy — callers depending on the legacy wire format will break."
          # Build and run the wire-golden test via dotnet test
          TEST_PROJECT="CTIAPI-DEV_Work/CTI.MicroService.IVR.{ServiceName}.Tests/CTI.MicroService.IVR.{ServiceName}.Tests.csproj"
          if [ ! -f "$TEST_PROJECT" ]; then
            echo "Test project not found: $TEST_PROJECT"
            exit 1
          fi
          set +e
          dotnet test "$TEST_PROJECT" --filter "FullyQualifiedName~WireGolden" --no-restore --nologo 2>&1
          WIRE_EXIT=$?
          set -e
          if [ $WIRE_EXIT -ne 0 ]; then
            echo "BLOCKED: Wire-fidelity golden test failed (exit $WIRE_EXIT)."
            echo "The migrated service's runtime serialization diverges from legacy wire format."
            echo "Check JsonSerializerOptions configuration (naming policy, null handling)."
            exit 1
          fi
          echo "Wire-fidelity: PASS (all cases byte-equal to golden)"
```

### Vendoring the parity scripts

The generated workflow references `.github/scripts/parity-check.sh` and `.github/scripts/spec-integrity-check.sh`. These must exist in the target repo. During Phase 2, copy them from the framework:

```bash
mkdir -p .github/scripts
cp "${FRAMEWORK_ROOT}/lib/parity-check.sh" .github/scripts/parity-check.sh
cp "${FRAMEWORK_ROOT}/lib/spec-integrity-check.sh" .github/scripts/spec-integrity-check.sh
chmod +x .github/scripts/parity-check.sh .github/scripts/spec-integrity-check.sh
```

Overwrite on every migration — this ensures the scripts are current as of the migration run. The vendored copies are committed with the service code.

### Placeholder resolution

| Placeholder | Value |
|---|---|
| `{ServiceName}` | PascalCase service name (e.g., `CPSLToken`, `SessionToken`, `AccountLookup`) |
| `{ServiceDisplayName}` | Human-readable name for the workflow title (e.g., `CPSLToken`, `SessionToken`) |
| `{service-kebab}` | Lowercase hyphenated (e.g., `cpsltoken`, `sessiontoken`, `accountlookup`) |

Derive from the service name identified in Phase 1.

### Why this works

1. **Trigger fix:** Each service's workflow has `paths:` scoped to its own directories — CI fires on that service's PRs, not only on AccountLookup's.
2. **Baseline immutability:** The legacy spec was committed in step 2b-commit BEFORE Phase 2 code exists. CI's `git diff --diff-filter=M` detects if it was subsequently modified in the same PR.
3. **Spec integrity:** `spec-integrity-check.sh` verifies both directions — anchors in spec match source AND anchors in source match spec. An agent that strips a behavior from the spec to avoid a parity failure is caught.
4. **Parity:** `parity-check.sh` runs on committed, immutable files. Exit 2 blocks the PR status check. The agent cannot iterate post-push.

## Post-Migration Dependency Map Refresh

After Phase 2 completes and before the first Stage 1 run, rebuild the dependency map from the MIGRATED code:

1. **Why:** Phase 1's analysis reflects the LEGACY structure (intermediary layers, shared gateways, old class hierarchies). The migrated code has a different coupling graph (direct downstream clients, new DI registrations, different call chains). Using the stale legacy map for coupling analysis during Stage 1 fixes will produce wrong groupings.

2. **Action:** Use the Agent tool with `subagent_type: discovery-analyst` to spawn the analyst against the NEW service directory (not the legacy repo). It produces a fresh `dependency-map.json` with:
   - `files` — current imports, injectedBy, callsInto, calledBy for each migrated file
   - `couplingGroups` — coupling based on the NEW architecture
   - `independent` — files that can always be fixed in isolation (container config, infrastructure-as-code, IDE settings)

3. **Place the output** at `<service-folder>/dependency-map.json`.

4. **Run mechanical validation** from `${FRAMEWORK_ROOT}/lib/dependency-map-validator.md`. This catches missed DI-graph coupling, false independence claims, and unverifiable group edges. Apply any corrections to the map before proceeding. Never consume an unvalidated map.

5. **If the discovery-analyst is unavailable** (e.g., cap hit, error): fall back to CONSERVATIVE coupling — treat ALL findings as one coupled group. Slow but safe.

**Write checkpoint:** `phase: phase2_complete`.

## Behavioral Parity Verification

After Phase 2 completes and the dependency map is validated, verify behavioral preservation before handing off to the review pipeline. This step uses the SAME spec-analyst that produced the legacy baseline (step 2b) — now pointed at the migrated code — and the parity engine to detect drift.

<CRITICAL-INSTRUCTION>
Do NOT skip parity verification. Check 6 will re-run parity-check.sh at the pre-handoff gate and block on exit 2. Running parity here surfaces blocking violations early — before the gate halts the run with no context for why.
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
bash "${FRAMEWORK_ROOT}/lib/parity-check.sh" \
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
> 2. **Accept** — these are intentional architectural changes (e.g., removing a legacy intermediary). The agent writes rationale to `parity-override-requested` and STOPS; a human clears the gate.
> 3. **Investigate** — review specific violations before deciding"

If the user chooses **Fix**: apply the fixes (using the same coupled-group discipline — multiple violations in the same file/chain are coupled), re-run spec-analyst on the migrated code, re-run parity-check.sh. Loop until exit 0 or 1.

If running unattended (no user in the loop): the agent writes its override rationale to `.preflight/gate/parity-override-requested` and STOPS. The agent does NOT proceed. A human reviews and decides.

If a user is present and chooses **Accept**: the USER (not the agent) runs `bash "${FRAMEWORK_ROOT}/hooks/write-gate-evidence" parity-clean` to clear the gate. The agent does not execute this command on the user's behalf — it instructs the user to run it.

### Step 3 — Record parity outcome

On exit 0 or exit 1: parity passed. No evidence file is written by the agent. Check 6 will re-run parity-check.sh at the gate and confirm the passing exit code directly. Write checkpoint: `phase: parity_verified`.

On exit 2 (blocking violations): parity BLOCKED. The agent:
1. Surfaces the full parity report to the user (or to its own output if running unattended).
2. If the agent believes the violation is intentional (e.g., internal observability replaced by OTel), it writes a proposed override rationale to `.preflight/gate/parity-override-requested` explaining why the drift is deliberate and not caller-visible.
3. STOPS. This is a correct terminal state. The agent does NOT write `.preflight/gate/parity-clean`. The agent does NOT proceed to handoff.
4. A HUMAN reviews `parity-override-requested` and decides whether to clear the gate by running `bash "${FRAMEWORK_ROOT}/hooks/write-gate-evidence" parity-clean` manually.

<CRITICAL-INSTRUCTION>
The agent NEVER writes `.preflight/gate/parity-clean`. Only a human (or parity-check.sh itself if it ever gains that capability) writes that file. The agent proposes overrides; it does not authorize them. Writing parity-clean yourself is the exact exploit this gate exists to prevent.
</CRITICAL-INSTRUCTION>

**Write checkpoint:** `phase: parity_verified` (on exit 0 or 1 only; on exit 2, checkpoint stays at `phase2_complete`).

## Pre-Handoff Mechanical Gate

Before invoking fix-and-close, run the following checks. ALL must pass. If ANY fails, STOP and fix before proceeding — do not invoke fix-and-close, do not report done.

Run each check as a literal shell command. A non-zero exit or "FAIL" output means the gate is not satisfied.

### Check 1 — Name-contract artifact exists

```bash
SERVICE_DIR="<service-folder>"  # e.g. CTIAPI-DEV_Work/CTI.MicroService.IVR.SessionToken
SERVICE_NAME="<service-name>"   # e.g. SessionToken

test -f ".preflight/${SERVICE_NAME}/legacy-db-name-contract.md" \
  && echo "CHECK 1 PASS: name-contract exists" \
  || { echo "CHECK 1 FAIL: .preflight/${SERVICE_NAME}/legacy-db-name-contract.md missing"; exit 1; }
```

If FAIL: the name-contract was not produced during Phase 1. Go back and produce it from legacy source before continuing.

### Check 2 — Repository/data-access classes NOT excluded from coverage

```bash
# Grep for ExcludeFromCodeCoverage in service source (excluding Program.cs, which is allowed to be excluded)
EXCLUDED=$(grep -rl "ExcludeFromCodeCoverage" "${SERVICE_DIR}/" --include="*.cs" | grep -v "Program.cs" | grep -iv "infra/" || true)

if [ -n "$EXCLUDED" ]; then
  echo "CHECK 2 FAIL: ExcludeFromCodeCoverage found on non-Program files:"
  echo "$EXCLUDED"
  echo "The DB/data-access layer must be tested via mocked boundary, not excluded."
  exit 1
else
  echo "CHECK 2 PASS: no non-Program classes excluded from coverage"
fi
```

If FAIL: remove `[ExcludeFromCodeCoverage]` from the flagged files and add unit tests that mock the DB boundary instead.

### Check 3 — Spec-vs-implementation reconciliation: every contracted item resolves

Every item in the name-contract must resolve to exactly one of:
- **IMPLEMENTED** — present in the migrated service (identifier appears verbatim in source), OR
- **EXPLICITLY-UNREACHABLE** — annotated `NOT REACHABLE` in the contract (per Fix 13), therefore correctly omitted from the migrated service.

A contracted item that is neither implemented NOR marked `NOT REACHABLE` cannot pass silently — it is a gap that forces a recorded decision (implement it, or correct the contract with a reachability annotation).

**Worked example (cpsl_setMPToken_v1):** This proc was in the contract but not in the migrated code. Without reachability annotation, Check 3 would fail and demand implementation. With the annotation `NOT REACHABLE | Only via SharedServicesController (gated IsMPToken=true; CPSLToken never sets this)`, Check 3 skips it — correctly omitted. Without this gate, the reconstruction flagged a phantom HIGH gap that required a human to trace reachability by hand.

```bash
CONTRACT=".preflight/${SERVICE_NAME}/legacy-db-name-contract.md"
FAILURES=0
UNREACHABLE_SKIPPED=0

# Extract REACHABLE proc names and their parameters only.
# Items marked "NOT REACHABLE" are explicitly excluded from the fidelity check.
# They are correctly omitted from the migrated service.
REACHABLE_LINES=$(grep -i "REACHABLE" "$CONTRACT" | grep -iv "NOT REACHABLE" || true)
UNREACHABLE_LINES=$(grep -i "NOT REACHABLE" "$CONTRACT" || true)

if [ -n "$UNREACHABLE_LINES" ]; then
  UNREACHABLE_SKIPPED=$(echo "$UNREACHABLE_LINES" | wc -l)
  echo "Skipping $UNREACHABLE_SKIPPED NOT REACHABLE items (correctly omitted from migration):"
  echo "$UNREACHABLE_LINES" | head -5
  echo ""
fi

# Extract proc names from REACHABLE items and all parameter names
# (parameters without a reachability marker inherit from their parent proc's reachability)
PROCS=$(grep -oP '(?<=\| )`?[a-zA-Z_][a-zA-Z0-9_]*`?' "$CONTRACT" | tr -d '`' | sort -u)
NOT_REACHABLE_PROCS=$(echo "$UNREACHABLE_LINES" | grep -oP '(?<=\| )`?[a-zA-Z_][a-zA-Z0-9_]*`?' | tr -d '`' | sort -u)
PARAMS=$(grep -oP '@[a-zA-Z_][a-zA-Z0-9_]*' "$CONTRACT" | sort -u)

# Filter out params that belong to NOT REACHABLE procs
# (params listed under a NOT REACHABLE proc section inherit that status)
NOT_REACHABLE_PARAMS=""
for NR_PROC in $NOT_REACHABLE_PROCS; do
  # Extract params from the section following this proc until the next proc header
  SECTION_PARAMS=$(sed -n "/### \`${NR_PROC}\`/,/### \`/p" "$CONTRACT" | grep -oP '@[a-zA-Z_][a-zA-Z0-9_]*' || true)
  NOT_REACHABLE_PARAMS="$NOT_REACHABLE_PARAMS $SECTION_PARAMS"
done

echo "Checking REACHABLE proc names against migrated source..."
for PROC in $PROCS; do
  [ ${#PROC} -lt 5 ] && continue
  echo "$PROC" | grep -qiE "^(name|type|order|direction|parameter|procedure|table|column|notes|reachable)$" && continue
  # Skip if this proc is marked NOT REACHABLE
  if echo "$NOT_REACHABLE_PROCS" | grep -qw "$PROC" 2>/dev/null; then
    continue
  fi
  if ! grep -r --include="*.cs" -q "$PROC" "${SERVICE_DIR}/"; then
    echo "  MISSING: '$PROC' not found in migrated source"
    FAILURES=$((FAILURES + 1))
  fi
done

echo "Checking parameter names against migrated source..."
for PARAM in $PARAMS; do
  # Skip if this param belongs to a NOT REACHABLE proc
  if echo "$NOT_REACHABLE_PARAMS" | grep -qw "$PARAM" 2>/dev/null; then
    continue
  fi
  if ! grep -r --include="*.cs" -q "$PARAM" "${SERVICE_DIR}/"; then
    echo "  MISSING: '$PARAM' not found in migrated source"
    FAILURES=$((FAILURES + 1))
  fi
done

if [ $FAILURES -gt 0 ]; then
  echo "CHECK 3 FAIL: $FAILURES REACHABLE identifier(s) from the legacy contract are missing in migrated source."
  echo "The verbatim-name rule requires byte-for-byte fidelity for REACHABLE items."
  echo "For each missing item, either: (a) implement it with the exact legacy name, or"
  echo "(b) if it's actually unreachable from this entry point, add a NOT REACHABLE annotation to the contract."
  exit 1
else
  echo "CHECK 3 PASS: all REACHABLE contract identifiers found verbatim in migrated source ($UNREACHABLE_SKIPPED items correctly skipped as NOT REACHABLE)"
fi
```

If FAIL: For each missing identifier, determine whether it is a real gap (reachable but not implemented — fix the migrated code) or a contract over-listing (unreachable from the entry point — add a `NOT REACHABLE` annotation to the contract). No item may remain listed-but-unimplemented without an explicit reachability decision.

### Check 4 — Legacy DB extraction scripts exist

```bash
# Only applies when the name-contract indicates database operations exist
if grep -q "No database operations identified" ".preflight/${SERVICE_NAME}/legacy-db-name-contract.md" 2>/dev/null; then
  echo "CHECK 4 SKIP: no database operations — extraction scripts not required"
else
  MISSING_SCRIPTS=0
  for SCRIPT in ".preflight/${SERVICE_NAME}/legacy-db-extraction-procs.sql" \
                ".preflight/${SERVICE_NAME}/legacy-db-extraction-params.sql" \
                ".preflight/${SERVICE_NAME}/legacy-db-extraction-tables.sql"; do
    if [ ! -f "$SCRIPT" ]; then
      echo "CHECK 4 FAIL: $SCRIPT missing"
      MISSING_SCRIPTS=$((MISSING_SCRIPTS + 1))
    fi
  done

  if [ $MISSING_SCRIPTS -gt 0 ]; then
    echo "CHECK 4 FAIL: $MISSING_SCRIPTS extraction script(s) missing."
    echo "DB extraction scripts are a required Phase 1 deliverable. Generate them from the name-contract proc/table names."
    exit 1
  else
    echo "CHECK 4 PASS: all legacy DB extraction scripts exist"
  fi
fi
```

If FAIL: the extraction scripts were not produced during Phase 1. Go back and generate targeted read-only SQL scripts for the procs/tables listed in the name-contract.

### Check 5 — LINE coverage meets floor

```bash
# Run tests with coverlet and extract the LINE coverage percentage.
# The floor comes from .preflight/config.json (test.coverageBaseline), not a hardcoded number.
COVERAGE_FLOOR=$(python3 -c "import json; print(json.load(open('.preflight/config.json'))['test']['coverageBaseline'])" 2>/dev/null || echo "85.0")

# Run coverage collection — coverlet msbuild produces a summary line with line coverage.
COVERAGE_OUTPUT=$(dotnet test "${SERVICE_DIR}/../$(basename ${SERVICE_DIR}).Tests/$(basename ${SERVICE_DIR}).Tests.csproj" \
  -p:CollectCoverage=true \
  -p:CoverletOutputFormat=opencover \
  "-p:Exclude=[*]Program" \
  --no-build 2>&1)

# Parse LINE coverage specifically (the "Line" column from coverlet's table output).
# Coverlet outputs: "| <module> | <line>% | <branch>% | <method>% |"
# The Total line has the aggregate. Extract the LINE percentage from it.
LINE_COVERAGE=$(echo "$COVERAGE_OUTPUT" | grep -E "^\| Total" | grep -oP '\d+\.?\d*' | head -1)

if [ -z "$LINE_COVERAGE" ]; then
  # Fallback: try parsing from the module line if no Total row
  LINE_COVERAGE=$(echo "$COVERAGE_OUTPUT" | grep -E "^\|.*\|.*%.*\|.*%.*\|.*%.*\|" | grep -v "Module" | grep -oP '\d+\.?\d*' | head -1)
fi

if [ -z "$LINE_COVERAGE" ]; then
  echo "CHECK 5 FAIL: could not parse LINE coverage from test output."
  echo "Expected coverlet table output with Line/Branch/Method columns."
  exit 1
fi

# Compare: LINE_COVERAGE must be >= COVERAGE_FLOOR
PASSES=$(python3 -c "print('yes' if float('${LINE_COVERAGE}') >= float('${COVERAGE_FLOOR}') else 'no')")

if [ "$PASSES" = "yes" ]; then
  echo "CHECK 5 PASS: LINE coverage ${LINE_COVERAGE}% >= floor ${COVERAGE_FLOOR}%"
else
  echo "CHECK 5 FAIL: LINE coverage ${LINE_COVERAGE}% is BELOW floor ${COVERAGE_FLOOR}%"
  echo ""
  echo "The migration is INCOMPLETE. LINE coverage must reach ${COVERAGE_FLOOR}% before handoff."
  echo ""
  echo "REQUIRED RESPONSE: Write more tests against the uncovered lines (via the"
  echo "mocked DB boundary for repository code). Do NOT modify, remove, or restructure"
  echo "production code to raise coverage. Do NOT exclude classes from coverage to"
  echo "raise the percentage (Check 2 already forbids excluding the repository)."
  echo ""
  echo "If the floor genuinely cannot be reached by adding tests without changing"
  echo "behavior, STOP and report the specific uncovered lines and why — do NOT"
  echo "mutate the service, and do NOT game the number."
  exit 1
fi
```

**Reaching this floor is done by ADDING TESTS ONLY.** If line coverage is below the floor, the response is to write more tests against the uncovered lines (via the mocked DB boundary for repository code), NOT to modify, remove, or restructure production code. If the floor genuinely cannot be reached by adding tests without changing behavior, STOP and report the specific uncovered lines and why — do NOT mutate the service, and do NOT exclude code to raise the percentage (Check 2 already forbids excluding the repository). An unreachable floor is a finding to surface, not a number to game.

### Check 6 — Behavioral parity verification ran and passed

> **Parity-gate enforcement boundary:** the `parity-clean` gate is prompt-enforced locally (the agent *can* technically mint the file; the local pre-push Gate 4 trusts file-existence, not authorship). The genuine close is GitHub environment protection + prevent-self-review — a team decision. See `docs/parity-gate-limitations.md`.

<CRITICAL-INSTRUCTION>
Check 6 RE-RUNS parity-check.sh and reads its EXIT CODE. It does NOT check for the existence of a file the agent can create. The agent CANNOT satisfy Check 6 by writing .preflight/gate/parity-clean — Check 6's only authority is the live exit code of parity-check.sh executed HERE, NOW, against the two spec files. (Note: the SEPARATE pre-push Gate 4 DOES trust the parity-clean file's existence + HEAD-freshness — which is exactly why the agent must never write it. That local gate is prompt-enforced, not mechanical; see docs/parity-gate-limitations.md.)

If the agent disagrees with a blocking violation and wants an override, it writes its rationale to `.preflight/gate/parity-override-requested` — a DIFFERENT file that does NOT satisfy Check 6 and does NOT unblock the run. An override is a HUMAN decision; the agent proposes, it does not authorize.

Exit 2 from parity-check.sh is TERMINAL for the agent: STOP, report the violation + the proposed rationale, do not proceed to handoff. This is a correct terminal state, not a failure.
</CRITICAL-INSTRUCTION>

```bash
# Check 6 re-runs parity-check.sh against the spec files and reads exit code.
# The agent does NOT control parity-check.sh. The gate trusts the script's verdict,
# not any file the agent may have written.

# 6a: Both behavior-spec files must exist (legacy baseline + migrated current)
if [ ! -f ".preflight/${SERVICE_NAME}/behavior-spec.json" ]; then
  echo "CHECK 6 FAIL: .preflight/${SERVICE_NAME}/behavior-spec.json (legacy baseline) missing."
  echo "Step 2b (legacy behavioral extraction) did not produce its output."
  exit 1
fi

if [ ! -f ".preflight/${SERVICE_NAME}/behavior-spec-current.json" ]; then
  echo "CHECK 6 FAIL: .preflight/${SERVICE_NAME}/behavior-spec-current.json (migrated) missing."
  echo "Behavioral Parity Verification Step 1 (migrated extraction) did not produce its output."
  exit 1
fi

# 6b: RE-RUN parity-check.sh and read exit code (the authoritative verdict)
PARITY_OUTPUT=$(bash "${FRAMEWORK_ROOT}/lib/parity-check.sh" \
  ".preflight/${SERVICE_NAME}/behavior-spec.json" \
  ".preflight/${SERVICE_NAME}/behavior-spec-current.json" 2>&1)
PARITY_EXIT=$?

if [ $PARITY_EXIT -eq 0 ]; then
  echo "CHECK 6 PASS: parity-check.sh exit 0 (CLEAN — no violations)"
elif [ $PARITY_EXIT -eq 1 ]; then
  echo "CHECK 6 PASS: parity-check.sh exit 1 (ADVISORY — non-blocking warnings only)"
  echo "Advisory report:"
  echo "$PARITY_OUTPUT"
elif [ $PARITY_EXIT -eq 2 ]; then
  echo "CHECK 6 BLOCKED: parity-check.sh exit 2 (BLOCKING violations exist)"
  echo ""
  echo "Parity report:"
  echo "$PARITY_OUTPUT"
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo "TERMINAL STATE: The migration CANNOT proceed to handoff."
  echo ""
  echo "Blocking parity violations mean the migrated code drops or changes"
  echo "externally-observable behaviors that existed in legacy. This is drift."
  echo ""
  echo "The agent MAY propose an override by writing rationale to:"
  echo "  .preflight/gate/parity-override-requested"
  echo ""
  echo "That file does NOT unblock the run. A HUMAN must review the rationale"
  echo "and manually clear the gate. The agent does not authorize overrides."
  echo "═══════════════════════════════════════════════════════════════════════"
  exit 1
else
  echo "CHECK 6 FAIL: parity-check.sh exited with unexpected code $PARITY_EXIT"
  echo "$PARITY_OUTPUT"
  exit 1
fi
```

If BLOCKED (exit 2): the run is TERMINAL. The agent:
1. Surfaces the blocking violations from the parity report.
2. MAY write a proposed override rationale to `.preflight/gate/parity-override-requested` explaining why the drift is intentional.
3. STOPS. Does NOT proceed to handoff. Does NOT write `.preflight/gate/parity-clean`. Does NOT treat this as fixable by the agent alone.
4. Reports this as a correct stopping point: "Parity gate blocked — human override required."

A human reviews the rationale in `parity-override-requested` and, if they agree, manually runs `bash "${FRAMEWORK_ROOT}/hooks/write-gate-evidence" parity-clean` themselves. Only then can the migration resume past this gate.

---

**All six checks must print PASS.** Only then proceed to the handoff below.

### Check 7 — Wire-fidelity golden test wired to real serializer

```bash
# Check 7 verifies the WIRE-B golden test was emitted and wired correctly
WIRE_CONTRACT=".preflight/${SERVICE_NAME}/wire-golden.json"
WIRE_TEST="${SERVICE_DIR}.Tests/WireGoldenTests.cs"

if [ ! -f "$WIRE_CONTRACT" ]; then
  echo "CHECK 7 FAIL: wire-golden.json contract missing."
  echo "Phase 2 step 3b (wire-fidelity) did not produce its output."
  echo "If no legacy wire strings are available, this is a COMPLETION-BUG —"
  echo "log it and surface to the user."
  exit 1
fi

if [ ! -f "$WIRE_TEST" ]; then
  echo "CHECK 7 FAIL: WireGoldenTests.cs not found in test project."
  echo "generate-wire-golden-test.sh did not run or the output path is wrong."
  exit 1
fi

# Verify the test is wired to the SERVICE's real options, not a hand-built object.
# The generated test references the options_accessor from the contract.
# A "new JsonSerializerOptions()" without the service's naming/null policy would
# test a fiction — the exact false-green this check exists to prevent.
if grep -q 'new JsonSerializerOptions()' "$WIRE_TEST" && \
   ! grep -q 'ServiceWireOptions\|options_accessor\|IOptions<JsonOptions>' "$WIRE_TEST"; then
  echo "CHECK 7 FAIL: WireGoldenTests.cs appears to use default JsonSerializerOptions()."
  echo "The test MUST be wired to the service's REAL configured serializer options"
  echo "(the DI-resolved IOptions<JsonOptions> from AddJsonOptions)."
  echo "A hand-built options object tests a fiction — casing/null-policy breaks sail through."
  exit 1
fi

echo "CHECK 7 PASS: wire-fidelity golden test exists and references a service options accessor"
```

**All seven checks must print PASS.** Only then proceed to the handoff below.

## Handoff to /preflight:fix-and-close

<CRITICAL-INSTRUCTION>
Phase 2 code-complete is NOT migration-complete. After build+test pass, you MUST invoke `/preflight:fix-and-close`. Do NOT report the migration as done, do NOT emit a summary, and do NOT stop until fix-and-close has run Stage 1, pushed, and opened the PR. A commit without a push is not a deliverable; a push without Stage 1 is not allowed.

Treating the commit as terminal is the known failure mode — the prior SessionToken run stopped here, declared success, and left Stage 1 unrun, the PR unopened, and infrastructure unproduced. Do not repeat it.

If fix-and-close cannot be invoked (skill unavailable, dispatch failure), surface this as a BLOCKER to the user — do not silently treat the migration as complete.
</CRITICAL-INSTRUCTION>

Once Phase 2 is complete, the dependency map is validated, parity is verified (or user-accepted), and code compiles + tests pass, invoke `/preflight:fix-and-close` to run the full Stage 1 → push → Stage 2 pipeline.

Pass the commit-message hint derived from Phase 1 (e.g. `feat(<service>): migrate to <target-platform>`).

The fix-and-close skill handles:
- Stage 1 gate (code-reviewer sub-agent, hard cap 5 iterations, Coupled-Group Fix Protocol)
- Commit + push (conventional-commits, explicit file staging)
- Stage 2 Copilot loop (external-review-handler sub-agent, hard cap 3 iterations, polling, STUCK detection)
- Structural verification (build command, test command from project config, directory structure, health endpoint)
- Metrics collection

**PR opening:** Before the first push, open the PR via `gh pr create --repo <canonical> --base <branch.base> --head <branch-name>`. **ALWAYS pass `--repo <canonical>`** — resolve `<canonical>` from `config.branch.remote`'s URL (`git remote get-url <branch.remote>` → `owner/repo`). Without `--repo`, `gh` resolves the repo from the cwd's default remote, which on migration clones is often `origin` = the **legacy production repo that must never be touched** — omitting it is how a PR gets raised against the wrong repo. (The `pre-push-gate-check` guard backstops this, but `--repo` is the primary fix.) Title and body follow conventional-commits format. Include Phase 1 outputs in the PR description so reviewers see your reasoning. Do not prompt for confirmation — open automatically.

**Write checkpoint:** `phase: handoff_complete`.

## Final Step — Summary and Reconstruction

Once /fix-and-close reports DONE (or a terminal state like CAPPED/STUCK/RE_REVIEW_NOT_RECEIVED/REVIEW_REQUEST_FAILED):

- Surface the summary: PR URL, Stage 1 iterations, Stage 2 iterations, capture entries written by classification bucket, coverage achieved, any STUCK or FAILED states encountered.
- Tell the user the PR is ready for human review and merge. **Do not merge** — humans merge.
- Delete the checkpoint file (`.preflight/migrate-checkpoint.json`).

### Reconstruction discipline (when a post-run reconstruction sub-agent is dispatched)

If the user requests a reconstruction sub-agent to audit what actually happened, OR if the run ends in a non-SUCCESS terminal state, the reconstruction MUST follow these rules:

**Rule 1 — Report CAUSE, not symptom, for Stage 2 outcomes:**

| Terminal state | Reconstruction reports | NOT this |
|---|---|---|
| `REVIEW_REQUEST_FAILED` | "Copilot was never successfully asked to review — the reviewer request failed (mechanism error). Stage 2 never executed." Priority: HIGH (mechanism failure). | "Copilot hasn't reviewed — may need manual re-request" (MEDIUM) |
| `RE_REVIEW_NOT_RECEIVED` | "Copilot was successfully requested (confirmed via read-back), but did not respond within the poll window. Stage 2 started but got no signal." Priority: MEDIUM (timeout). | same vague "hasn't reviewed" phrasing |

These are different findings with different fixes. `REVIEW_REQUEST_FAILED` means the request mechanism is broken (fix the mechanism). `RE_REVIEW_NOT_RECEIVED` means the request worked but Copilot was slow or unavailable (re-request or wait). The reconstruction must name WHICH occurred from the on-disk evidence (git log, PR state, requested_reviewers list) and not collapse them into a vague "Copilot hasn't reviewed."

Run 6's error: it reported "Copilot hasn't reviewed — MEDIUM — may need manual re-request." The CAUSE was the request failed (`gh pr edit --add-reviewer` returned an error that was swallowed). MEDIUM underplayed a HIGH mechanism failure.

**Rule 2 — Trace reachability before flagging a contract/implementation mismatch:**

When the reconstruction finds an item in the name-contract (stored procedure, endpoint, model field) that is NOT implemented in the migrated service, it MUST NOT default to "missing implementation = gap." It must TRACE REACHABILITY from the migrated entry point before assigning severity:

1. Identify the entry point being migrated (e.g., CPSLTokenController).
2. Trace the call chain from that entry point through downstream services.
3. Determine: can the entry point's request path REACH the unimplemented item? Or is the item gated behind a flag/condition that only a DIFFERENT entry point sets?

| Reachability | Reconstruction reports |
|---|---|
| Reachable from the migrated entry point AND unimplemented | REAL GAP — "item X is reachable from <entry point> via <call chain> but not implemented." Priority: HIGH. |
| Unreachable — gated behind a flag only a different caller sets | CORRECTLY OMITTED — "item X is in the name-contract but unreachable from <entry point>; only reachable via <other caller> which sets <flag>. The name-contract over-listed a proc not reachable from this migration's entry point. Not a gap." Priority: INFORMATIONAL (no action needed). |

**Worked example (run 6 false positive):** `cpsl_setMPToken_v1` was in the name-contract and not in the migrated code. The reconstruction flagged it as "HIGH — missing implementation." But tracing reachability: the Token Manager branches to `CreateMPToken` only when `tokRequest.IsMPToken == true`. The CPSLToken controller's request model (`CPSLTokenRequest`) has no `IsMPToken` field — it defaults to `false` when deserialized. Only `SharedServicesController` (a DIFFERENT controller at route `api/partner/getmptoken`) sets `IsMPToken = true`. Therefore `cpsl_setMPToken_v1` is correctly omitted from the SessionToken migration — it's unreachable from the CPSLToken entry point.

The name-contract documents what exists in the shared DB layer, not what's reachable from a specific entry point. The reconstruction must distinguish these.

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
- Write to capture files directly — only the external-review-handler sub-agent writes the four capture files (calibration-log / checklist-additions / false-positives / generation-spec-candidates). Carve-out: the parent session writes its own adjudication record under `.preflight/adjudications/` and `metrics.json` — those are the verdict-of-record and metrics, not capture files, and are gated by the adjudication-output-gate hook.
- Confuse sub-agent roles — code-reviewer reads/reports, external-review-handler orchestrates/captures, discovery-analyst maps dependencies, implementer fixes coupled groups, this skill orchestrates the overall flow
- Auto-bump the rubric cadence — `loop.rubricEditCadence` is read from config (default 5); the rubric-edit PR is a separate batched effort

## Coverage discipline — no behavior changes for metrics

<CRITICAL-INSTRUCTION>
The coverage floor (from `test.coverageBaseline` in config, default 85% when null — this is the canonical statement of the default; the "Test migration" phase step and the Check 5 fallback must match it) is reached by ADDING TESTS ONLY. Production/service code MUST NOT be modified, weakened, or restructured to raise coverage. Specifically:

- Do not remove validation attributes, guards, or checks to avoid uncovered branches.
- Do not change method visibility, add parameters, or refactor production logic solely to make it testable.
- Do not remove `[ExcludeFromCodeCoverage]` from genuinely untestable code (DI wiring, top-level statements) to force coverage elsewhere.
- Do NOT exclude repository/data-access classes from coverage — they are tested via a mocked DB boundary (Check 2 enforces this). "Requires a real database" is not grounds for exclusion.
- Paths that are uncoverable without changing production behavior are left uncovered with a `// uncovered: <reason>` comment in the test file, not in production code.

If the floor cannot be reached by adding tests alone, STOP and report the specific uncovered lines and the reason. Do not mutate the service to close it. An unreachable floor is a finding to surface, not a number to game. The only legitimate responses to a failed Check 5 are: (a) write more tests, or (b) stop-and-report.
</CRITICAL-INSTRUCTION>

## Verbatim database identifier rule

<CRITICAL-INSTRUCTION>
Every database identifier in the migrated data-access layer — stored-procedure names, parameter names, table names, column names — MUST be byte-for-byte identical to what the legacy code uses. NO renaming, NO casing changes, NO pluralization, NO target-database-idiom "improvement."

If legacy calls `cpsl_setCCToken_v2`, the migrated call is `cpsl_setCCToken_v2` — never `cpsl_set_cc_token_v2`. If legacy passes `@ReturnTokenCode`, the migrated parameter is `@ReturnTokenCode`. This is the parity spine that lets a separate legacy → target-DB data export tie out: the migration owns NAME FIDELITY; schema/datatype reconciliation happens at the export step.

This rule applies regardless of target database engine (PostgreSQL, Aurora, CosmosDB). The function/proc/table is created with the legacy-exact name, even if it violates the target engine's conventions.
</CRITICAL-INSTRUCTION>

## Data-access layer — implemented in full, not deferred

<CRITICAL-INSTRUCTION>
The migration produces the full data-access layer (repository, proc/query calls, parameter mapping) wired and unit-tested with a mocked DB boundary. "Requires a real DB" is NOT grounds to skip implementing or testing the layer's logic.

- The repository class is implemented with real connection-open, command-build, parameter-map, and result-map logic.
- Unit tests mock at the connection/command boundary (e.g., mock `IDbConnection` or use an in-memory fake) and verify parameter names, types, directions, and result mapping.
- The repository is NOT marked `[ExcludeFromCodeCoverage]` — it is tested via mocked boundary.
- Integration tests (requiring a live DB) are a separate concern and may be skipped if no DB is available, but the unit-testable logic (mapping, branching, null-handling) is always covered.

Nothing is "pending from the service side." The layer is present and tested at completion.
</CRITICAL-INSTRUCTION>

## Legacy name-contract artifact (required completion deliverable)

The migration emits a **legacy-db-name-contract** artifact at `.preflight/<service>/legacy-db-name-contract.md`. This artifact is TRANSCRIBED from the legacy source code (not invented, not inferred from documentation). It lists:

- Every stored procedure the service calls: name + parameter names + parameter order/types as the C# code passes them.
- Every table and column name referenced (if visible in the legacy source).
- The exact string values used in the legacy code (no normalization).

The artifact states clearly that schema and datatype authority lives in the legacy database; this document fixes the NAMES only. A separate legacy → target-DB data export uses this artifact to verify name alignment.

If the spec-analyst or discovery-analyst dispatch fails (agent type not found, dispatch error), the migration STOPS and records a COMPLETION-BUG — the main session does NOT self-run the extraction. If the sub-agent is available but returns BLOCKED or ERROR after running, surface the reason to the user and ask for direction. The artifact's existence is REQUIRED, but it must be produced by the sub-agent, not by the orchestrator absorbing the sub-agent's role.

## Stop semantics — completion or genuine blocker

The migration runs until it **completes** (all phases done, PR opened) or hits a **genuine blocker**:
- Repeated sub-agent dispatch failure (3+ consecutive failures on the same step)
- Unrecoverable build error after 3 fix attempts
- User-requested stop

There is NO wall-clock cap, no time limit, no "4 hour" ceiling. The existing iteration caps (`maxStage1Iterations`, `maxStage2Iterations`) and oscillation detection (`stopOnSameFiles`, `stopOnSameLineModified`) are the anti-spin guards — they remain. But the migration does not stop merely because time has passed.

## Reminders

- The rubric is wisdom, not law. Findings that seem wrong should still be surfaced — disagreements get captured into `false-positives` via the external-review-handler, not silently dropped.
- The goal is not just to migrate this service. It is to make the next migration faster than this one. Every Copilot finding the orchestrator captures is a future-finding the Stage 1 reviewer will catch locally.
- One service per PR. If the migration reveals that another service must also be touched, stop and ask. Do not chain.

Begin now. Parse `$ARGUMENTS`, discover the project config, and start Phase 1.

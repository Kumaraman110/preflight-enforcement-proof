# Refactor Playbook — Contamination Removal

Read-only investigation. No framework files modified. This document inventories
every contamination point in the codebase identified by the genericity audit,
with proposed neutral replacements and structural refactor recommendations.

---

## Heavily Contaminated Files

---

### FILE: `skills/migrate-service/SKILL.md`

**CURRENT LINES:** 222
**AUDIT VERDICT:** ~60% CPSL-specific

#### CONTAMINATION INVENTORY

- **Line 3:** `"End-to-end migration of a legacy service to modern .NET 10. Runs discovery (project structure, technical debt, DP Manager decoupling, microservice consolidation, readiness score), executes Phase 2 migration (7 concrete steps with AWS CDK/ECS)..."`
  - Type: CPSL-specific / .NET-specific
  - Context: YAML frontmatter description field
  - Proposed replacement: `"End-to-end migration of a legacy service to a modern target framework. Runs discovery (project structure, technical debt, layer decoupling, consolidation candidates, readiness score), executes Phase 2 migration, then hands off to /preflight:fix-and-close for the Stage 1 gate → push → Stage 2 Copilot loop. Only activates when project config mode is \"migration\"."`
  - Reasoning: Remove .NET 10, DP Manager, AWS CDK/ECS hardcodes. Keep the structural description.

- **Line 4:** `argument-hint: <service name, e.g. "PaxLookup" or "migrate the seat assignment lookup service">`
  - Type: CPSL-specific
  - Context: Frontmatter
  - Proposed replacement: `argument-hint: <service name or description, e.g. "UserService" or "migrate the authentication service">`
  - Reasoning: PaxLookup is a CPSL service name, IVR-specific context.

- **Line 10:** `"...one legacy service from .NET Framework to .NET 10..."`
  - Type: .NET-specific
  - Context: Opening description paragraph
  - Proposed replacement: `"...one legacy service to the modern target platform..."`
  - Reasoning: Framework should not assume .NET-to-.NET. Could be Java EE to Spring Boot, etc.

- **Line 13:** `"...assume standard prefix (e.g., CTI.MicroService.IVR.<Name>)..."`
  - Type: CPSL-specific / United-specific
  - Context: Argument parsing rules
  - Proposed replacement: `"...assume the service prefix convention defined in CLAUDE.md or project config (e.g., \`migration.servicePrefix\`)..."`
  - Reasoning: CTI.MicroService.IVR is a CPSL organizational convention.

- **Lines 79-87 (entire Technical Debt Scan section):**
  ```
  - Unity DI (`unity.RegisterType` patterns)
  - `System.Web` dependencies (`HttpContext.Current` usage)
  - `ConfigurationManager` static usage
  - Synchronous database calls and fire-and-forget patterns
  - WCF/SOAP service references
  - Legacy authentication patterns (OWIN, ASP.NET Identity)
  - `Newtonsoft.Json` usage that can migrate to `System.Text.Json`
  ```
  - Type: .NET-specific (all 7 items)
  - Proposed replacement: Replace with: "Run the technical debt scan categories defined in the discovery-analyst configuration or CLAUDE.md. Default scan categories are loaded from `${CLAUDE_PLUGIN_ROOT}/examples/scan-profiles/dotnet-framework.md` but teams define their own."
  - Reasoning: These are .NET Framework→.NET migration patterns. A Java team would scan for Struts, EJB, J2EE patterns instead.

- **Lines 90-94 (Business Architecture Rules):**
  ```
  - Decouple from intermediary layers. Remove the DP Manager (or equivalent gateway) dependency entirely.
  - Move gateway logic into the target microservice.
  ```
  - Type: CPSL-specific (DP Manager is a CPSL-internal system)
  - Proposed replacement: Generalize: "Assess coupling to intermediary layers (gateways, dispatchers, shared proxies). Recommend decoupling approach. Read coupling targets from CLAUDE.md or project config."
  - Reasoning: DP Manager is specific to CPSL's architecture. The CONCEPT (decouple from middleware) is generic.

- **Lines 96-104 (Readiness Score categories):**
  ```
  | Package Compatibility | Are NuGet packages .NET 10 compatible? |
  | Code Pattern Complexity | How much `System.Web` / Unity refactoring is needed? |
  | AWS Readiness | How much config and secrets modernization is needed? |
  ```
  - Type: .NET-specific / AWS-specific
  - Proposed replacement:
    - "Package Compatibility" → "Are dependencies compatible with the target platform?"
    - "Code Pattern Complexity" → "How much legacy-pattern refactoring is needed?"
    - "AWS Readiness" → "Cloud Readiness" (already used in discovery-analyst)
  - Reasoning: NuGet, System.Web, Unity, AWS are all stack-specific.

- **Lines 130-142 (The 7 Migration Steps):**
  ```
  1. SDK-style `.csproj`, `TargetFramework=net10.0`, Unity → Microsoft.Extensions.DI
  2. ASP.NET Core hosting, async/await, System.Text.Json, IConfiguration, ILogger<T>, OpenTelemetry
  3. NUnit + Moq + Bogus. Coverage baseline 96.1%
  4. AWS CDK in C#, ECS Fargate, 256/512, IMMUTABLE ECR
  5. non-root user, groupadd/useradd, port 8080
  6. dotnet build
  7. dotnet test
  ```
  - Type: .NET-specific / AWS-specific (entire section)
  - Proposed replacement: Replace with a generic pattern: "Execute the migration steps defined in the project's CLAUDE.md or the generation spec for this stack. The generation spec contains the concrete step-by-step. This skill orchestrates the order; CLAUDE.md provides the specifics."
  - Reasoning: This is the core of the contamination. The 7 steps are .NET+AWS. A neutral framework would read these from CLAUDE.md.

- **Line 148:** `"...DP Manager, shared gateways, old class hierarchies..."`
  - Type: CPSL-specific
  - Context: Post-Migration Dependency Map Refresh, "Why" section
  - Proposed replacement: `"...intermediary layers, shared gateways, legacy class hierarchies..."`
  - Reasoning: DP Manager is CPSL-specific.

- **Line 165:** `feat(<service>): migrate to .NET 10`
  - Type: .NET-specific
  - Context: Commit message hint example
  - Proposed replacement: `feat(<service>): migrate to <target-platform>`
  - Reasoning: Platform-neutral.

#### STRUCTURAL CHANGES NEEDED

1. **The 7 Migration Steps (lines 130-142) must be entirely replaced** with a delegation pattern: "Read the concrete migration steps from the generation spec or CLAUDE.md. Execute them in order. The skill controls flow (build-after-each-step, test-at-end); the project content controls substance."

2. **Technical debt scan categories (lines 79-87) must be delegated** to a configurable scan profile that the discovery-analyst reads from project context.

3. **Business architecture rules (lines 90-94) must become generic** layer-decoupling assessment driven by CLAUDE.md context.

4. **Readiness score categories (lines 96-104) must be neutralized** — remove NuGet/System.Web/AWS specifics, keep the 5-category scoring structure.

5. **The frontmatter description (line 3) must be rewritten** to be stack-neutral.

#### DEPENDENCIES

- `agents/discovery-analyst.md` — scans for the same .NET patterns; must be refactored in parallel
- `defaults/generation-specs/dotnet-service.md` — referenced at line 120; will move to `examples/`
- `FRAMEWORK.md` lines 133-134 — references migrate-service's mode
- `docs/inventory-2026-05-21.md` — documents current state (update after refactor)
- `README.md` line 69 — skill description (already neutral)

#### TOTAL ESTIMATED EDIT SCOPE

- 12 contamination points to replace
- 3 structural sections to refactor (migration steps, debt scan, architecture rules)
- 3 dependent files to update
- Complexity rating: **COMPLEX** — requires designing the delegation pattern to CLAUDE.md

---

### FILE: `agents/discovery-analyst.md`

**CURRENT LINES:** 155 (156 including empty trailing line)
**AUDIT VERDICT:** ~70% .NET-specific

#### CONTAMINATION INVENTORY

- **Line 3:** `"Phase 1 discovery agent. Analyzes a codebase for migration readiness or architecture assessment."`
  - Type: Generic (no contamination here)

- **Lines 21-31 (Technical Debt Inventory section):**
  ```
  - Unity DI registrations (count + locations)
  - `System.Web` usage (count + locations)
  - `ConfigurationManager` static calls (count + locations)
  - Synchronous DB/HTTP calls (count + locations)
  - WCF/SOAP service references
  - Legacy auth patterns (OWIN, ASP.NET Identity)
  - `Newtonsoft.Json` usage that could migrate to STJ
  ```
  - Type: .NET-specific (all 7 items)
  - Context: "What You Produce → For Migration Projects" section
  - Proposed replacement: "Technical debt inventory categories as defined in the project's scan profile or CLAUDE.md. Each category specifies: pattern to scan for, file glob to search, regex/AST pattern. Report count + locations for each."
  - Reasoning: These 7 items are .NET Framework anti-patterns. A Java team would scan for EJB, Struts, XML-heavy config, etc.

- **Lines 39-44 (Readiness Score categories):**
  ```
  - Dependency Isolation
  - Package Compatibility
  - Code Pattern Complexity
  - Performance Opportunity
  - Cloud Readiness
  ```
  - Type: Mostly generic, except "Package Compatibility" implies NuGet
  - Proposed replacement: Keep the 5-category structure. Rename "Package Compatibility" to "Dependency Compatibility" (covers NuGet, Maven, npm, pip equally).
  - Reasoning: Minimal change for neutrality.

- **Lines 92-112 (Dependency Map JSON example):**
  ```json
  "Services/TokenService.cs": {
    "calledBy": ["Services/AccountLookupService.cs", "Services/V4Strategy.cs"]
  },
  "couplingGroups": [
    {"reason": "shared async call chain — TokenService → AccountLookupService → V4Strategy",
     "files": ["Services/TokenService.cs", "Services/AccountLookupService.cs", "Services/V4Strategy.cs"]},
    {"files": ["Program.cs", "Configuration/AccountLookupOptions.cs", "Services/AccountLookupService.cs"]}
  ],
  "independent": ["Dockerfile", "infra/AccountLookupStack.cs", "Properties/launchSettings.json"]
  ```
  - Type: CPSL-specific (AccountLookup references throughout)
  - Context: JSON schema example in "Dependency Map" section
  - Proposed replacement: Use generic service names: `"Services/AuthService.cs"`, `"Services/OrderService.cs"`, `"Services/PaymentStrategy.cs"`, `"Configuration/AppOptions.cs"`, `"infra/ServiceStack.cs"`
  - Reasoning: The JSON structure is correct and generic; only the example values need neutralizing.

#### STRUCTURAL CHANGES NEEDED

1. **Technical debt inventory (lines 21-31) must become configurable.** Instead of hardcoded .NET patterns, the agent reads scan categories from a scan profile (loaded from project config or CLAUDE.md). The framework ships with example profiles in `examples/scan-profiles/`.

2. **The example dependency map (lines 92-112) needs neutral names.** Pure text replacement — no structural change.

3. **The agent's overall role is generic.** The structure (project map → debt scan → architecture → readiness score → dependency map) works for any stack. Only the scan targets need parameterization.

#### DEPENDENCIES

- `skills/migrate-service/SKILL.md` — invokes this agent with .NET expectations
- `lib/dependency-map-validator.md` — validates the map output (already generic)
- `tests/coupling/` — fixture files may reference .NET patterns
- `docs/inventory-2026-05-21.md` — documents current state

#### TOTAL ESTIMATED EDIT SCOPE

- 4 contamination points to replace
- 1 structural section to refactor (technical debt scan → configurable profiles)
- 2 dependent files to update
- Complexity rating: **MODERATE** — configurable scan profiles is a design task but the agent structure stays intact

---

### FILE: `defaults/generation-specs/dotnet-service.md`

**CURRENT LINES:** 273 (274 including trailing newline)
**AUDIT VERDICT:** 100% .NET by design — this IS a .NET generation spec

#### CONTAMINATION INVENTORY

This file is not "contaminated" — it is purpose-built for .NET. The refactor is not to neutralize its content but to:
1. Move it from `defaults/` to `examples/`
2. Ensure the framework never loads it as a default
3. Update all references

Every line is .NET-specific C# code patterns:
- Lines 11-74: Token caching pattern (C# `SemaphoreSlim`)
- Lines 82-121: Options pattern (C# data annotations)
- Lines 125-137: Typed HttpClient (C# `IHttpClientFactory`)
- Lines 141-169: Log sanitization (C# `LogSanitizer`)
- Lines 173-188: Health endpoints (C# `HealthCheckOptions`)
- Lines 192-216: Dockerfile (generic concept, .NET-specific `dotnet publish`)
- Lines 220-235: Input validation (C# data annotations)
- Lines 241-273: Adaptation points documentation

#### STRUCTURAL CHANGES NEEDED

1. **Move file:** `defaults/generation-specs/dotnet-service.md` → `examples/generation-specs/dotnet-service.md`
2. **Create index:** `examples/generation-specs/README.md` explaining that these are reference examples, not defaults
3. **Update framework loading:** The framework should never auto-load generation specs. Skills that need them should read the path from project config or CLAUDE.md.
4. **Update cross-references:** Skills that reference `${CLAUDE_PLUGIN_ROOT}/defaults/generation-specs/dotnet-service.md` must be updated to use a config-driven path

#### DEPENDENCIES

- `skills/migrate-service/SKILL.md` line 120: hardcoded path to this file
- `skills/scaffold-api/SKILL.md` line 65, 69: hardcoded path to this file
- `FRAMEWORK.md` line ~289: mentions "generation-specs/dotnet-service.md"
- `README.md` line ~128: mentions .NET presets

#### TOTAL ESTIMATED EDIT SCOPE

- 0 contamination points to replace (file moves wholesale)
- 1 structural change (move + create index)
- 4 dependent files to update references
- Complexity rating: **SIMPLE** — move, rename, update paths

---

## Lightly Contaminated Files

---

### FILE: `defaults/rubric-generic.md`

**CURRENT LINES:** 120
**ACTION:** Move to `examples/rubrics/rubric-generic-dotnet.md`

**Contamination points:**
- Line 7: `"...any .NET project"` — labels it .NET-specific
- All detection patterns use C# syntax (`.Result`, `_logger.Log*()`, `new HttpClient()`, `services.Configure<T>`)

**Refactor:** Rename to indicate it's a .NET example rubric. Move to `examples/rubrics/`. The framework loads rubrics from project config, never from defaults.

**Dependent files:** `FRAMEWORK.md` lines 289-291, `defaults/config-template.json` line referencing defaults, `skills/self-review/SKILL.md` (fallback path)

**Complexity:** SIMPLE (move + rename + update 3 references)

---

### FILE: `defaults/rubric-migration.md`

**CURRENT LINES:** 165
**ACTION:** Move to `examples/rubrics/rubric-migration-dotnet.md`

**Contamination points:**
- Line 9: `"...the CPSL migration rubric at docs/cpsl-migration/migration-review-rubric.md..."` — CPSL-specific reference
- All patterns are .NET Framework → modern .NET migration detection

**Refactor:** Rename to indicate .NET migration example. Move to `examples/rubrics/`. Remove the CPSL-specific reference on line 9.

**Dependent files:** `skills/migrate-service/SKILL.md` line 31 (fallback path), `FRAMEWORK.md`, `agents/code-reviewer.md` line 4 (fallback discovery)

**Complexity:** SIMPLE (move + rename + remove 1 CPSL reference)

---

### FILE: `defaults/rubric-api-design.md`

**CURRENT LINES:** 108
**ACTION:** Move to `examples/rubrics/rubric-api-design.md`

**Contamination points:**
- Line 87: `"...conflicts with ECS/K8s health check configuration"` — light cloud-vendor reference
- Line 93: `"...ECS secrets input..."` — AWS-specific

**Refactor:** Move to `examples/rubrics/`. Neutralize two ECS references → "orchestrator" / "secrets manager". Mostly generic already.

**Dependent files:** `skills/scaffold-api/SKILL.md` lines 33, 35, 41 (fallback path), `FRAMEWORK.md`

**Complexity:** SIMPLE (move + 2 line edits)

---

### FILE: `lib/metrics.md`

**CURRENT LINES:** 114
**ACTION:** Remove CPSL-specific example values

**Contamination points:**
- Line 16: `"service": "CTI.MicroService.IVR.AccountLookup"` — CPSL service name in JSON example
- Line 17: `"branch": "fix/legacy-parity-review-findings"` — CPSL branch name
- Line 108: `"Compare pre-framework rounds (70 on AccountLookup) to post-framework rounds"` — CPSL reference

**Refactor:**
- Line 16 → `"service": "my-service"`
- Line 17 → `"branch": "feature/migrate-service-x"`
- Line 108 → `"Compare pre-framework rounds to post-framework rounds"` (remove specific number and name)

**Dependent files:** None (standalone library doc)

**Complexity:** SIMPLE (3 line edits)

---

### FILE: `lib/verification-discipline.md`

**CURRENT LINES:** 67
**ACTION:** Neutralize `dotnet` examples

**Contamination points:**
- Line 17: `"dotnet test" output showing 0 failures` — .NET-specific command
- Line 18: `"dotnet build" output showing 0 errors 0 warnings` — .NET-specific command
- Line 20: `"dotnet build" + "dotnet test" run BY THE ORCHESTRATOR` — .NET-specific

**Refactor:** Replace `dotnet test` with `test command (from config)` and `dotnet build` with `build command (from config)`. The verification principle is generic; only the command examples are .NET-specific.

**Dependent files:** None (standalone library doc)

**Complexity:** SIMPLE (3 line edits)

---

### FILE: `skills/routing/SKILL.md`

**CURRENT LINES:** 65
**ACTION:** Neutralize `dotnet` examples

**Contamination points:**
- Line 15: `"Verification discipline (fresh dotnet test + dotnet build)"` — .NET-specific
- Line 41: `"dotnet test output you just ran showing 0 failures"` — .NET-specific
- Line 42: `"dotnet build output showing 0 errors 0 warnings"` — .NET-specific

**Refactor:** Replace with generic form: "test command" / "build command" with note "(from project config or auto-detected)".

**Dependent files:** `hooks/session-start` injects this content — no file change needed there

**Complexity:** SIMPLE (3 line edits)

---

### FILE: `skills/scaffold-api/SKILL.md`

**CURRENT LINES:** 111
**ACTION:** Neutralize .NET-specific generation references

**Contamination points:**
- Line 4: `"...for IVR callers"` — CPSL-specific domain reference in argument-hint
- Line 65: `"...read ${CLAUDE_PLUGIN_ROOT}/defaults/generation-specs/dotnet-service.md..."` — hardcoded .NET path
- Line 69: `"${CLAUDE_PLUGIN_ROOT}/defaults/generation-specs/dotnet-service.md (mandatory — pre-validated patterns)"` — hardcoded path
- Line 75: `"SDK-style .csproj targeting modern .NET"` — .NET-specific
- Line 82: `"Test project (NUnit + Moq + Bogus) with initial coverage"` — .NET-specific

**Refactor:**
- Line 4: Change to generic example: `"OrderStatus — returns order status for API consumers"`
- Lines 65, 69: Change to config-driven path: `"Read generation spec from project config or CLAUDE.md"`. If no generation spec configured, skip (the rubric alone is sufficient).
- Lines 75, 82: Replace with generic: "Project file targeting the platform specified in config" / "Test project matching team conventions"

**Dependent files:** None

**Complexity:** MODERATE (5 edits + needs design decision on how scaffold-api discovers generation specs without hardcoded path)

---

### FILE: `skills/test-driven-development/SKILL.md`

**CURRENT LINES:** 100
**ACTION:** Neutralize .NET-specific section

**Contamination points:**
- Line 3 (description): `"Strict RED-GREEN-REFACTOR enforcement for .NET development... Works with NUnit/Moq/Bogus."` — .NET-specific
- Lines 67-72 (`.NET Specifics` section): Names NUnit, Moq, Bogus, FluentAssertions

**Refactor:**
- Line 3: `"Strict RED-GREEN-REFACTOR enforcement. Use when writing new functionality..."` (remove .NET reference)
- Lines 67-72: Replace with "Stack-specific conventions are read from CLAUDE.md (test framework, mocking library, assertion library)."

**Dependent files:** None

**Complexity:** SIMPLE (2 edits)

---

### FILE: `agents/copilot-review-loop.md`

**CURRENT LINES:** 384
**ACTION:** Remove AccountLookup reference

**Contamination points:**
- Line 133: Reference to AccountLookup in a rationale paragraph
- Line 296: `"The generation spec was seeded from AccountLookup's patterns..."` — CPSL-specific origin story

**Refactor:**
- Line 133: Neutralize to generic reference
- Line 296: `"The generation spec was seeded from the reference implementation's patterns..."` — removes specific project name

**Dependent files:** None

**Complexity:** SIMPLE (2 line edits)

---

### FILE: `hooks/coupled-edit-gate`

**CURRENT LINES:** 100
**ACTION:** Remove AccountLookup reference

**Contamination points:**
- Line 86: `"(48% of the 70-round cost on AccountLookup)."` — CPSL-specific data point

**Refactor:** `"(48% of review round cost in cascading regression scenarios)."` — keeps the data, removes the project name.

**Dependent files:** None

**Complexity:** SIMPLE (1 line edit)

---

### FILE: `.claude-plugin/plugin.json`

**CURRENT LINES:** 21
**ACTION:** Update author and repository

**Contamination points:**
- Line 6: `"name": "CPSL Platform Team"` — United/CPSL-specific
- Line 8: `"repository": "https://github.com/United-Airlines-Org/preflight"` — United-specific
- Line 10: `"keywords": ["review", "migration", "dotnet", "self-improving", "copilot"]` — "dotnet" is stack-specific

**Refactor:**
- Line 6: Update to the actual framework author/team name
- Line 8: Update to the actual repository URL (post-extraction)
- Line 10: Remove "dotnet" from keywords, or add other stacks

**Dependent files:** None (but this is the plugin identity — coordinate with repo rename)

**Complexity:** SIMPLE (3 line edits, but depends on naming decision)

---

### FILE: `defaults/config-template.json`

**CURRENT LINES:** 51
**ACTION:** Remove CPSL-specific migration prefix

**Contamination points:**
- Line 37: `"migrationPrefix": "feature/migrate-"` — mildly CPSL-flavored (generic enough to keep)

**Refactor:** This is actually generic. No change needed. Keep in inventory for completeness.

**Complexity:** NONE

---

### FILE: `README.md`

**CURRENT LINES:** 251
**ACTION:** Verify clean (already refactored)

**Contamination points:**
- Line 212: `"Reference implementation: .NET migration (CPSL) — validated the design before extraction into this framework"` — honest acknowledgment of origin

**Refactor:** This is a Status section acknowledgment. Acceptable as-is (honest about origin story). Could optionally be shortened to "Reference implementation: .NET migration project" if desired.

**Complexity:** NONE (already refactored to be framework-first)

---

### FILE: `FRAMEWORK.md`

**CURRENT LINES:** 352
**ACTION:** Needs substantial update to match mature design (separate work)

**Contamination points:**
- Line 313: `"The default rubrics target .NET..."` — honest acknowledgment

**Refactor:** This file needs a full rewrite to match the mature framework design document (Task A above). That is separate work from contamination removal — it's a content update, not a text-swap. Flag but do not include in this playbook's scope.

**Complexity:** OUT OF SCOPE (separate design work)

---

### FILE: `defaults/rubric-migration.md`

**Contamination point already noted above:** Line 9 references CPSL-specific rubric path.

---

## Files Verified Clean

- `skills/self-review/SKILL.md` — Generic
- `skills/fix-and-close/SKILL.md` — Generic
- `skills/systematic-debugging/SKILL.md` — Generic
- `skills/gps-decide/SKILL.md` — Generic
- `agents/code-reviewer.md` — Generic
- `agents/implementer.md` — Generic
- `lib/mechanical-gates.md` — Generic
- `lib/oscillation-detection.md` — Generic
- `lib/classification-rules.md` — Generic
- `lib/project-detector.md` — Generic (has npm fallback)
- `lib/skill-bootstrap.md` — Generic
- `lib/proactive-triggering.md` — Generic
- `lib/severity-matrix.md` — Generic
- `lib/dependency-map-validator.md` — Generic
- All hooks except `coupled-edit-gate` — Generic
- `hooks/hooks.json` — Generic
- `defaults/capture-templates/*` — Generic

---

## REFACTOR PLAYBOOK SUMMARY

**Total files needing changes: 16**

- **Heavily contaminated (substantial refactor):** 2
  - `skills/migrate-service/SKILL.md` — COMPLEX
  - `agents/discovery-analyst.md` — MODERATE

- **Lightly contaminated (cosmetic fixes):** 8
  - `skills/routing/SKILL.md` — 3 line edits
  - `skills/scaffold-api/SKILL.md` — 5 edits
  - `skills/test-driven-development/SKILL.md` — 2 edits
  - `agents/copilot-review-loop.md` — 2 line edits
  - `hooks/coupled-edit-gate` — 1 line edit
  - `lib/metrics.md` — 3 line edits
  - `lib/verification-discipline.md` — 3 line edits
  - `.claude-plugin/plugin.json` — 3 line edits (depends on naming)

- **Move-and-rename only (defaults → examples):** 4
  - `defaults/generation-specs/dotnet-service.md` → `examples/generation-specs/dotnet-service.md`
  - `defaults/rubric-generic.md` → `examples/rubrics/rubric-generic-dotnet.md`
  - `defaults/rubric-migration.md` → `examples/rubrics/rubric-migration-dotnet.md`
  - `defaults/rubric-api-design.md` → `examples/rubrics/rubric-api-design.md`

- **Reference updates only:** 2
  - `defaults/config-template.json` — no change needed (already generic)
  - `README.md` — already clean (optional minor edit)

**Estimated total work:**
- 16 files touched
- ~80 lines of text changes (cosmetic edits)
- 3 structural refactors (migrate-service steps delegation, discovery-analyst scan profiles, scaffold-api generation spec discovery)
- 4 file moves + directory creation (`examples/`)
- ~15 cross-reference path updates

**Recommended refactor order:**

1. **Move defaults → examples** (generation-specs, rubrics) — unblocks everything else because skills currently hardcode paths to `defaults/`. After the move, all paths must go through config, which forces the neutral pattern.

2. **Neutralize lightly-contaminated files** (routing, TDD, scaffold-api, copilot-review-loop, coupled-edit-gate, metrics, verification-discipline, plugin.json) — quick wins, high signal that the framework is becoming stack-neutral.

3. **Refactor discovery-analyst.md** — introduce configurable scan profiles. This is the moderate-complexity structural change. Design the scan-profile format, ship an example profile for .NET.

4. **Refactor migrate-service/SKILL.md** — the hardest piece. Requires designing how the skill reads migration steps from CLAUDE.md/generation-spec instead of hardcoding them. Do this last because it depends on decisions made in steps 1-3.

5. **Update FRAMEWORK.md** — separate work, depends on the mature design document being locked.

**Risks identified during inventory:**

1. **Skills currently hardcode fallback paths.** If the `defaults/` directory is removed before skills are updated to read from config, skills invoked without config will error. Mitigation: keep `defaults/` as a symlink to `examples/` during transition, or update skills first.

2. **The generation-spec PASTE directive is load-bearing.** `migrate-service` and `scaffold-api` both have HARD-GATE instructions requiring verbatim paste from a specific path. The refactored path must be equally discoverable, or the PASTE discipline breaks. Mitigation: make the path resolution explicit in the skill ("read generation spec path from config; if not configured, check `examples/` for stack-matching spec").

3. **Configurable scan profiles for discovery-analyst require a format design.** The current hardcoded list is unambiguous. A configurable format needs to be simple enough that teams don't skip it. Mitigation: ship with example profiles that teams copy and edit, same as config-template.json.

4. **The 7 Migration Steps in migrate-service are tightly coupled to the generation spec.** Neutralizing the steps means the skill becomes more of an orchestrator ("run steps from spec") and less of a guide ("here are the exact steps"). This changes the skill's character. Mitigation: keep the orchestration structure (7 numbered phases) but make the content of each phase read from context rather than hardcoded.

5. **plugin.json author/repository update depends on the framework's identity decision** (name, org, repo). This is blocked on a naming decision outside this playbook's scope.

# PR 12 Issues Inventory

## Source artifacts

| Artifact | Location | Commit |
|---|---|---|
| Parity audit | `code-forge/docs/pr12-parity-audit.md` | `2136663` |
| Carry-forward notes (run findings) | `code-forge/docs/pr12-carry-forward-notes.md` | `7ea9b90` |
| Sprint execution plan | `code-forge/docs/refactor-execution-plan-2026-05-21.md` | — |
| Framework design doc | `code-forge/docs/design/preflight-mature-framework.md` | — |
| Migrated artifact | `CPSL_Migration_POC_temp/CTIAPI-DEV_Work/CTI.MicroService.IVR.SessionToken/` | `616edbe3` |
| Legacy source | `CTIAPI-DEV_Work/CTIAPI/Controllers/CPSLTokenController.cs` + `Business/CPSLTokenRepository.cs` | — |
| Framework code | `code-forge/skills/migrate/SKILL.md`, `agents/discovery-analyst.md`, `agents/code-reviewer.md`, `hooks/*` | HEAD |

---

## The complete issue list

**i01.** The framework's discovery phase read only the legacy controller file (183 lines) and did not read the repository class (500 lines) where 80% of the business logic, validation chain, error-code mapping, and wire-contract behavior lives.

Evidence: pr12-parity-audit.md §7 "Root Cause Analysis" — the discovery analyst identified high-level structure from the controller but never opened `CPSLTokenRepository.cs`.

**i02.** The framework silently changed the database backend from SQL Server (the legacy system) to PostgreSQL without flagging the change, asking for confirmation, or documenting it as a decision.

Evidence: pr12-parity-audit.md §2 "Silent Migrations" — legacy uses SQL Server via `CTI.DataLayer.DBHelper` and ADO.NET; migrated code uses Npgsql 8.0.6 with Dapper.

**i03.** The framework invented five PostgreSQL stored function names (`cpsl_set_cc_token_v2`, `cpsl_set_mp_token_v1`, `cpsl_validate_token_v2`, `cpsl_update_token_code_v2`, `cpsl_slide_token_v1`) that do not exist in any database and have never existed.

Evidence: pr12-parity-audit.md §2 — these function names appear in `Data/TokenRepository.cs` but correspond to no real schema artifact anywhere.

**i04.** The framework produced no database schema migration (DDL), no table definitions, and no plan for how the invented PostgreSQL functions would come into existence.

Evidence: pr12-parity-audit.md §2 — "No DDL, no migration script, no table definitions."

**i05.** The migrated service returns result code W0023 for empty/null Version requests, but the legacy system returns W0011 ("Version is required"). Any caller that shows a "Version is required" message based on code W0011 will never receive it.

Evidence: pr12-parity-audit.md divergence point #1. Legacy: `ValidateRequest` line 309 returns W0011. Migrated: controller checks `string.IsNullOrWhiteSpace(request.Version)` → returns W0023.

**i06.** The migrated service has no regex validation for version format, so malformed versions like "abc" or "2.0.1" receive result code W0023 instead of the legacy W0004 ("Invalid Version format").

Evidence: pr12-parity-audit.md divergence point #2. Legacy uses `Util.ValidateVersion` (regex `^\d+\.\d+$`). Migrated code has no regex.

**i07.** The migrated service returns W0024 ("Invalid or missing request parameters") for invalid profile IDs, but the legacy system returns E0002 ("Invalid Profile"). W0024 is an invented code that does not exist in the legacy system.

Evidence: pr12-parity-audit.md divergence point #6. Legacy: `CPSLTokenRepository.cs` line 141 returns E0002. Migrated: `TokenService.cs` returns W0024.

**i08.** Six of eight legacy validation result codes are missing from the migrated service: W0002 (AppProfileID required), W0003 (ANI required), W0004 (version format invalid), W0005 (TokenStatus invalid), W0007 (Format invalid), W0008 (SessionToken/TokenStatus mismatch).

Evidence: pr12-parity-audit.md §3 "Legacy result codes NOT present in preflight" — the entire `ValidateRequest` chain from the repository is absent.

**i09.** The legacy system validates requests through an 8-step sequential chain in `ValidateRequest()`, returning specific result codes at each step. The migrated service relies on `[ApiController]` model validation, which returns a generic `ProblemDetails` JSON response instead of the legacy response shape (`{ResultCode, ANI, SessionToken, TokenStatus, ResponseTime}`).

Evidence: pr12-parity-audit.md §4.3 — clients sending malformed requests get a completely different response schema.

**i10.** The migrated service returns HTTP 500 when database connections fail, but the legacy system always returns HTTP 400 for downstream failures (the WebException catch unconditionally assigns `HttpStatus = BadRequest`).

Evidence: pr12-parity-audit.md divergence points #12 and #13. Legacy: `CPSLTokenRepository.cs` line 123 assigns BadRequest. Migrated: exception propagates to global handler → 500.

**i11.** The legacy SlideToken endpoint returns HTTP 200 and "Success" instantly (fire-and-forget — the actual DB call runs asynchronously and may fail silently). The migrated service awaits the DB call synchronously, blocking the caller for the full duration and returning 500 on failure.

Evidence: pr12-parity-audit.md divergence point #14. Legacy: `Task.Factory.StartNew(() => SlideToken(requst))` then immediately returns 200. Migrated: `await _repository.SlideTokenAsync(...)`.

**i12.** The migrated service uses result code S0000 for success, but the legacy system uses E0000 (which counterintuitively means success in the legacy convention). Callers that check `ResultCode == "E0000"` for success will not find it.

Evidence: pr12-parity-audit.md §4.6 — S0000 is not a code that exists in the legacy system.

**i13.** The framework's Stage 1 code-reviewer checks code against a quality rubric (security, patterns, style) but has no mechanism to verify that the migrated wire contract (result codes, HTTP statuses, response shapes) matches the legacy wire contract.

Evidence: pr12-carry-forward-notes.md "Critical Finding" §1 — success metrics are calibrated for code quality, not contract preservation.

**i14.** The migrate skill instructs the discovery-analyst to "use the Agent tool with `subagent_type: discovery-analyst`" but during the PR 12 run, this agent type did not exist in the Claude Code agent registry. The framework fell back to a general-purpose agent.

Evidence: pr12-carry-forward-notes.md §3 "What didn't fire" — "`discovery-analyst` subagent_type — doesn't exist in registry, fell back to `general-purpose`."

**i15.** The framework's checkpoint mechanism (`migrate-checkpoint.json`) was written and correctly records `phase: phase2_complete`, but the timestamps are placeholder values (`2026-05-28T00:00:00Z` and `2026-05-28T00:30:00Z`) that do not reflect actual wall-clock times.

Evidence: `.preflight/migrate-checkpoint.json` content — the timestamps are round numbers that cannot be real execution times.

**i16.** The framework was supposed to produce a `metrics.json` file recording iteration counts, timing, finding counts, and outcome. No metrics file was produced.

Evidence: `.preflight/metrics.json` does not exist. The fix-and-close skill (Step 14) mandates this file for every run regardless of outcome.

**i17.** The framework's four mechanical hooks (`write-gate-evidence`, `write-active-groups`, `write-group-ack`, `dependency-map-validator`) exist as bash scripts (1009 total lines) but were never invoked during the PR 12 run. The `.preflight/gate/` directory does not exist in the migration project.

Evidence: pr12-carry-forward-notes.md §3 "What didn't fire" — all four hooks listed as absent. `.preflight/gate/` directory confirmed not found on disk.

**i18.** The pre-push gate hook (`hooks/pre-push-gate`, 62 lines) checks for evidence files before allowing a push. Since no evidence files were written during PR 12, the gate would have blocked the push if it had actually fired. The push succeeded anyway, meaning the hook did not fire.

Evidence: `hooks/pre-push-gate` reads `.preflight/gate/stage1-clean` and `.preflight/gate/tests-pass`. Neither file exists. Push at `616edbe3` succeeded.

**i19.** The coupled-edit-gate hook (`hooks/coupled-edit-gate`, 99 lines) blocks edits to files in unacknowledged coupled groups. It was never activated during PR 12 even though multiple coupled-group findings were identified and fixed.

Evidence: pr12-carry-forward-notes.md §3 — "`write-active-groups` / `write-group-ack` hooks — not invoked (mechanical coupled-edit-gate not wired)."

**i20.** The generation spec instructs the agent to "PASTE code blocks verbatim — character for character" and only modify at marked `/* ADAPT */` points. The agent instead generated code from understanding of the patterns, producing functionally correct but not character-identical output.

Evidence: pr12-carry-forward-notes.md §5.3 — "Generation-spec discipline broke. Despite 'PASTE verbatim' instructions, the agent generated code from understanding of the patterns rather than literal character-for-character copy."

**i21.** The framework's coverage threshold is 96% (from CLAUDE.md) but the migrated service achieved only 71.55% line coverage. No mechanism blocked the push or flagged this as a failure. The gap is structural — the 96% target requires a real database for integration testing, which the framework does not provision.

Evidence: pr12-carry-forward-notes.md §4 metrics and §5.2 — "The 96% target requires a test database. The framework provides no mechanism to provision one."

**i22.** The migrate skill specifies that the discovery-analyst must produce a `dependency-map.json` and that the skill must verify its existence on disk before proceeding. The file was produced, but the mechanical validator (`hooks/dependency-map-validator`) that validates its coupling groups was never invoked.

Evidence: `dependency-map.json` exists in the service directory. But `.preflight/gate/dependency-map-validated` sidecar does not exist, and the carry-forward notes confirm the validator hook did not fire.

**i23.** The framework design document (Section 7) explicitly states "Zero PRs have been migrated end-to-end through the full framework" and that PR 12 is the experiment. The experiment confirmed this: the self-learning rubric loop has still never completed a single iteration (capture → promotion → strengthened rubric → improved next review).

Evidence: design doc §7 "What is not yet true" confirmed by PR 12 outcome — Stage 2 was not reached, no captures were written.

**i24.** The framework design document (Section 1) commits to "mechanical enforcement as the verification primitive — hooks that fire on tool events, gates that check evidence files, hard caps the model cannot extend." PR 12 showed that none of the mechanical enforcement actually engaged during a real migration run.

Evidence: hooks.json is correctly configured (six hook registrations), hook scripts exist (1009 lines total), but zero hooks fired during the run. The mechanical layer exists but did not activate.

**i25.** The migrate skill has a "Post-Migration Dependency Map Refresh" step that says to re-run the discovery-analyst on the migrated code to produce a fresh coupling map reflecting the new architecture. This step was not executed during PR 12 — the dependency-map.json was produced during Phase 1 (from the legacy understanding) and never refreshed.

Evidence: skills/migrate/SKILL.md line 172-189 specifies this step. The checkpoint shows `phase2_complete` without evidence of a post-migration map refresh.

**i26.** The framework reports confidence proportional to what it examined (the controller), not proportional to what the full migration target requires (controller + repository + auth filter + utilities). A user receiving the framework's output would believe the migration was complete and correct.

Evidence: pr12-carry-forward-notes.md "Critical Finding" §5 — "Confidence is proportional to examination scope, not to requirement scope."

**i27.** The legacy auth filter (`AuthorizeClassFilterAttribute.cs`) performs channel validation by checking against a `Dictionary<string, IChannelIdentity>` loaded from the database, where each channel has an `IsON` property. The migrated service checks only for channel existence (any decoded channel ID passes when the cache is empty), not for the `IsON` active/disabled state.

Evidence: Legacy `AuthorizeClassFilterAttribute.cs` line 129: `channels.TryGetValue(channelID, out thisChannelIdentity)` followed by `return thisChannelIdentity.IsON`. Migrated: `ChannelCacheService.IsValidChannel` only checks `_channels.Contains(channelId)`.

**i28.** The legacy system extracts the channel ID from the Basic auth header and passes it to the downstream TokenManager service as an `Authorization` header. The migrated service extracts the channel ID and stores it in `HttpContext.Items["ChannelID"]` but uses it only for the token creation SQL parameters — it does not forward it as an auth header to any downstream service.

Evidence: Legacy `CPSLTokenRepository.cs` line 75: `client.Headers.Add("Authorization", channelID)`. Migrated `TokenService.cs`: passes `channelId` to `_repository.CreateSessionTokenAsync` as a SQL parameter.

**i29.** The legacy system performs request validation BEFORE checking profiles (the 8-step `ValidateRequest` runs first, then profile lookup). The migrated service performs profile validation inside `TokenService` but has no equivalent of the request-level validation chain that should run first.

Evidence: Legacy `CPSLTokenRepository.cs` lines 31-45: `ValidateRequest` is called before the profile check. Migrated: controller skips straight to version routing, then `TokenService` checks profile but not the other 7 validation steps.

**i30.** The framework's design document (Section 2) describes four sub-agents: reviewer, analyst, implementer, external-review handler. During PR 12, only two were invoked (reviewer and analyst-as-general-purpose). The implementer was skipped ("fixes were simple enough to apply directly") and the external-review handler was never reached.

Evidence: pr12-carry-forward-notes.md §3 "What didn't fire" — "`implementer` sub-agent — not dispatched" and "Capture file writes — no learning agent invoked."

**i31.** Stage 2 (Copilot review loop) was not reached during PR 12. The entire self-improvement mechanism — classifying findings into four buckets, writing capture files, accumulating evidence for batched rubric edits — never activated.

Evidence: pr12-carry-forward-notes.md §4 — "Stage 2 iterations: 0, Capture entries produced: 0."

**i32.** The framework hooks are configured in `hooks.json` to run via `run-hook.cmd` (a Windows batch file wrapper). PR 12 ran in a Windows environment. Whether the hooks failed silently, were not registered with Claude Code's hook system, or were bypassed by the skill's direct execution model is unknown — no diagnostic output was produced either way.

Evidence: `hooks/hooks.json` specifies `"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd"`. The fact that hooks exist but did not fire during a real run, with no error messages, suggests they were never registered with the Claude Code plugin runtime for this session.

**i33.** The migrate skill says to "wait for [the user] to either say 'go' or correct your understanding" after Phase 1. During PR 12, the experiment instructions told the agent to proceed without user confirmation. The human gate — the only designed checkpoint for catching scope errors before code generation — was bypassed by the experiment's own instructions.

Evidence: skills/migrate/SKILL.md line 122: "Wait for them to either say 'go' or correct your understanding." The PR 12 experiment instructions said "Run the framework."

**i34.** The framework's `lib/` directory contains 10 markdown files (classification-rules.md, dependency-map-validator.md, mechanical-gates.md, metrics.md, oscillation-detection.md, proactive-triggering.md, project-detector.md, severity-matrix.md, skill-bootstrap.md, verification-discipline.md). The Boris-style review identified 6 as orphans (~403 lines). PR 12 confirmed: none of these files were loaded or referenced during the actual run.

Evidence: pr12-carry-forward-notes.md "Boris-style review" — "6 orphan lib/*.md files: ~403 lines." The agent did not report loading any lib/ document during execution.

**i35.** The framework spent approximately 170,000 tokens on a single service migration (estimated from session length and compaction event). For context: the prior tool's forensic analysis of the same service (producing 3 spec documents with 14-point behavioral comparison) also consumed significant tokens but produced a wire-contract-correct output.

Evidence: Session was compacted (context exceeded limits), and the run produced 47 files with 2659 lines. The token cost for a result that breaks wire parity raises questions about cost-effectiveness.

**i36.** The legacy system includes a `CPSLActionFilter` that normalizes empty/missing Format values to "json" before the controller runs. The migrated service has no format normalization — the `[Required]` annotation on the `Format` property means an empty format will produce a model-validation failure (ProblemDetails) instead of being silently corrected to "json."

Evidence: Legacy `CPSLTokenRepository.cs` lines 334-339: if format is empty, set to "json" and continue. Migrated `TokenRequest.cs`: `[Required]` on `Format` means empty is rejected.

**i37.** The legacy system has special handling for `W0006` result codes returned from the downstream TokenManager: it changes the HTTP status to BadRequest and has TT-status preservation logic. The migrated service has no equivalent downstream-result-code handling because it uses direct SQL instead of an HTTP intermediary.

Evidence: Legacy `CPSLTokenRepository.cs` lines 87-95: `if (response.ResultCode.Contains("W0006"))` → set HttpStatus to BadRequest. No equivalent logic exists in the migrated `TokenService.cs`.

**i38.** The legacy V1 path fires `LogCustomerInfo` (DigitalID tracker) only when the result code is NOT W0006 AND the version is "2.0". The migrated service does not call any DigitalID tracker service at all — this downstream integration was silently dropped.

Evidence: Legacy `CPSLTokenRepository.cs` line 98-99: `else if(request.Version == "2.0") { LogCustomerInfo(response); }`. No equivalent exists in migrated code.

**i39.** The legacy V2 path involves three downstream services (Deflection API, Messaging Service, DigitalID DBOperations) orchestrated through `ExitPointAvailability`. The migrated service reduces this to a single `DeflectionService` that calls one endpoint (`/api/Deflection/GetExitPoints`). The phone-capability check and the exit-point-by-skill filtering are missing.

Evidence: Prior tool's boundary-diff report §2 documents three services and merge logic. Migrated `DeflectionService.cs` makes one HTTP call and returns the result directly.

**i40.** The legacy exit-point response model includes fields like `IsDeflectionAllowed` and `DeflectionUrl`. The migrated `DeflectionExitPoint` model has only `ExitPointName`, `ExitPointValue`, and `ExitPointType` — a different field set that no caller expects.

Evidence: pr12-parity-audit.md §3 prior-tool V2 response shape shows `isDeflectionAllowed`, `deflectionUrl`. Migrated `Models/DeflectionTokenResponse.cs` has `ExitPointName`, `ExitPointValue`, `ExitPointType`.

**i41.** The legacy response model includes an `ExpirationTimeInSeconds` field in the token response. The migrated `TokenResponse` model does not have this field — callers that read token expiration from the response will get null/undefined.

Evidence: Legacy `CPSLTokenRepository.cs` line 35: `response.ExpirationTimeInSeconds = string.Empty`. Migrated `Models/TokenResponse.cs` has no `ExpirationTimeInSeconds` property.

**i42.** The framework's design claims "the framework refuses to be the entity that knows better than the legacy code. It is the entity that asks better questions about it." In practice, the framework made multiple architectural decisions (DB engine, stored-function naming, 3-hop collapse, validation chain omission) without asking any questions or surfacing any tradeoffs.

Evidence: Design doc §2 "How the framework treats existing code." PR 12 outcome: zero tradeoff decisions were surfaced to the user during the run.

**i43.** The framework's `gps-decide` skill (described in the design doc as "the GPS forcing function — raises stakes, forces expert posture") was never invoked during PR 12 despite multiple consequential decisions (DB engine swap, chain collapse, SlideToken semantics change) that would benefit from structured decision-making.

Evidence: Design doc §4 lists gps-decide as a core skill. pr12-carry-forward-notes.md does not mention GPS activation at any point.

**i44.** The migrate skill specifies "read ALL of: Generation spec, Project's CLAUDE.md, MIGRATION_PATTERNS.md from the reference service." During PR 12, the agent read the generation spec and CLAUDE.md but produced output that contradicts CLAUDE.md's own requirements (96% coverage, NUnit testing framework, reference service architecture match).

Evidence: skills/migrate/SKILL.md line 132-136. The output meets NUnit requirement but not coverage (71%), and the architecture deviates from the reference service without justification in the PR description.

**i45.** The session-start hook (`hooks/session-start`, 90 lines) and drift-detector hook (`hooks/drift-detector`, 255 lines) are configured to run on SessionStart events. Whether they ran at the start of the PR 12 session and what they produced is unknown — no output from either hook was observed or reported.

Evidence: `hooks/hooks.json` registers both on SessionStart. The carry-forward notes do not mention either hook's output. If they ran, their output was not surfaced to the user or the agent.

**i46.** The framework's `rubric-validity-gate` hook (124 lines) fires on Agent tool calls and blocks Stage 1 dispatch when the rubric file doesn't exist. Whether it actually blocked anything during PR 12 is unknown — the rubric exists (at `docs/cpsl-migration/migration-review-rubric.md`), so the gate should have passed silently if it fired. But whether it fired at all is unconfirmed.

Evidence: `hooks/hooks.json` registers `rubric-validity-gate` on PreToolUse:Agent. No diagnostic output observed.

**i47.** The Stage 1 code-reviewer found 5 findings, all legitimate rubric violations (CWE-117 log injection, `[ApiController]` redundant ModelState check, ECR `:latest` tag, etc.). All 5 were about code quality and security patterns. None were about wire-contract preservation — confirming that the rubric itself has no sections for behavioral parity checking.

Evidence: pr12-carry-forward-notes.md §3 "What fired" — "Stage 1 code-reviewer sub-agent invoked correctly, found 5 real issues." All issues were rubric §-referenced (§5.1, §4.1, §14.1, §9.1).

**i48.** The `resolve-config.sh` library (632 lines, described in the Boris review as a bloat candidate with one consumer) was not loaded or invoked during PR 12. The framework used config from `.preflight/config.json` directly without going through the three-layer resolution system.

Evidence: pr12-carry-forward-notes.md "Boris-style review" identifies resolve-config.sh as bloat. The run used config directly (evidenced by the checkpoint containing config values).

**i49.** The `extract-overrides.sh` library (also identified as a bloat candidate) was not loaded or invoked during PR 12, confirming that the three-layer configuration system (detector → derived state → natural-language overrides) is not yet wired into the migration workflow.

Evidence: Same as i48 — design doc §3 describes three-layer config, but PR 12 used flat `.preflight/config.json` without layer resolution.

**i50.** The five empty test directories identified in the Boris review exist in the framework but are irrelevant to the PR 12 run. They neither helped nor harmed. This confirms they are inert rather than structurally necessary.

Evidence: pr12-carry-forward-notes.md "Boris-style review" — "5 empty test directories." Not loaded, not referenced, not relevant.

**i51.** The legacy controller's `catch (WebException wex)` block attempts to deserialize the error response body from the downstream service and return it to the caller (with the original ResultCode from the downstream body if available). The migrated service has no equivalent — it catches generic exceptions and returns a fixed E1000 message.

Evidence: Legacy `CPSLTokenController.cs` lines 102-119: reads downstream error body, deserializes it, returns it to caller at 400. Migrated `SessionTokenController.cs` lines 75-83: catches Exception, logs it, returns fixed E1000.

**i52.** The framework's self-improvement loop contract states "every issue caught by external review on ServiceN should be caught by local review on ServiceN+1." PR 12 never reached external review (Stage 2 was stopped), so the loop has still never been tested on a real migration. The contract remains aspirational.

Evidence: Design doc §1 and CLAUDE.md both state this contract. pr12-carry-forward-notes.md §4: "Stage 2 iterations: 0."

**i53.** The framework's migrate skill says "Write checkpoint after each completed phase: update `phase: phase2_step_N_complete`" but the checkpoint only records the final state (`phase: phase2_complete`), not intermediate step completions. If the session crashed mid-Phase-2, resume would restart from Phase 1 rather than the last completed step.

Evidence: `.preflight/migrate-checkpoint.json` has `"completedSteps": [1, 2, 3, 4, 5, 6, 7]` and `"phase": "phase2_complete"` — it records which steps completed but was written once at the end, not incrementally after each step.

**i54.** The framework's design document (Section 5) describes dependency-map coverage blind spots (factory-lambda DI, event-bus coupling, config-binding transitive coupling). The PR 12 run did not test these because the Stage 1 fix loop converged in 1-2 rounds without hitting coupling cascades. The named trigger condition for building AST extraction was not observed.

Evidence: design doc §5. pr12-carry-forward-notes.md §5.6: "The Coupled-Group Protocol wasn't stress-tested because no coupled findings cascaded."

**i55.** The prior tool's spec derivation read the legacy controller, repository, auth filter, utility classes, and deflection foundation — totaling 700+ lines across 5+ files — before writing any code. The framework's discovery-analyst read only the controller (183 lines) before generating Phase 1 output. The framework has no mechanism to ensure the analyst reads all transitive dependencies of the controller.

Evidence: Prior tool's `sessiontoken-boundary-diff.md` §1 lists 28 direct dependencies mapped. PR 12 discovery analyst produced output based on the controller alone.

**i56.** The framework's migrate skill instructs: "Confirm with the user before proceeding: 'Migrating <ServiceName> from <legacyRepoPath> to <targetFolder> in this repo. Confirm?'" This human confirmation step — the single designed gate for catching scope errors — exists but its value depends on the Phase 1 output being complete enough to surface scope problems. With a narrow Phase 1, the confirmation prompt confirms a false picture.

Evidence: skills/migrate/SKILL.md line 59. The confirmation happens after Phase 1 outputs are presented. If Phase 1 misses the repository, the user confirms based on incomplete information.

**i57.** The migrated test suite (69 NUnit tests, 71.55% coverage) tests controller routing, middleware auth, cache warmup, and service logic — but cannot test the data layer (`TokenRepository.cs`) because it requires a real PostgreSQL database. The untestable portion is the invented-function-calling code that would fail immediately in production.

Evidence: pr12-carry-forward-notes.md §5.2 — coverage gap is structural. The data layer calling non-existent PostgreSQL functions is the code most likely to break in deployment and is the code that cannot be tested.

**i58.** A human reviewer examining the migrated output (47 files, 2659 lines, builds clean, 69 tests pass) would likely approve it without catching the wire-contract breaks unless they independently read the legacy repository code and performed the same forensic comparison the parity audit required.

Evidence: pr12-parity-audit.md final paragraph §5: "Could a human reviewer of the output catch the issues without running the audit — probably not." The issues are in omissions and code-value mappings that are not visible from the migrated code alone.

**i59.** The framework's `bootstrap-write-gate` hook (156 lines) fires on Write and Edit tool events to prevent unauthorized CLAUDE.md overwrites. This gate operates on a different concern (preventing CLAUDE.md corruption) than the gates needed for migration quality (preventing wire-contract drift). The framework has gates for the wrong things but not for the right things.

Evidence: hooks/hooks.json registers bootstrap-write-gate on Write and Edit. No hook exists for "verify result codes match legacy" or "verify response shapes match legacy."

**i60.** The `ResultMessages.cs` file in the migrated service contains a code-to-message switch expression that serves as the sole documentation of what result codes the service can return. This file was never compared against the legacy code's implicit code mapping during the run, and it contains invented codes (W0024, S0000) alongside borrowed codes (E0007 from the prior tool).

Evidence: pr12-parity-audit.md §3 — full ResultMessages comparison table. The file is a mix of correct (E0001, E1000), wrong (W0024 for E0002), and invented (S0000) codes.

---

*60 issues total. Each substantiated from PR 12 source documents or direct code examination.*

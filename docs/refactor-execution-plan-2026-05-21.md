# Refactor Execution Plan — Mature Framework in Two Weeks

**Status:** Locked. Operational reference for the refactor sprint.
**Created:** May 21, 2026
**Authorship:** Collaborative — Kumar Aman with CTO-mode AI
**Sprint window:** Two weeks from start, with aggressive checkpoints every 5 PRs.

## Goal

Take current preflight from its present state (cleaner than baseline but with CPSL contamination, missing mature-framework capabilities, using legacy component names) to the mature framework specified in Sections 1-4 of docs/design/preflight-mature-framework.md. Ship in two weeks.

## Strategic context

The mature framework includes capabilities current preflight does not have: bootstrap generator skill, three-layer configuration system, discipline core inlining, drift detector hook, examples-not-defaults content model, renamed components. The refactor playbook at docs/refactor-playbook-2026-05-21.md covers contamination removal but not these new capabilities. This execution plan combines both.

## Conditions of execution

**Aggressive checkpointing.** After every 5 PRs we explicitly assess whether the timeline is achievable. Three outcomes: on track (continue), slightly behind (compress or descope non-critical), significantly behind (decide explicitly to slip, descope a capability to Phase 2, or push through with risk acknowledged).

**Quality bars hold non-negotiably.** Each PR has a quality bar that must be met before merging. If a quality bar cannot be met in time, the work descopes to Phase 2 (post-deployment) rather than shipping below bar.

**Operational stance.** Estimates lean lenient. The goal is to push toward the optimistic end of each estimate, not settle at the realistic middle. Hard work and AI leverage compress the timeline.

## PR sequence

### Phase 1 — Cleanup (PRs 1-6, target days 1-7)

**PR 1: Move defaults to examples**

Scope: Move defaults/rubric-generic.md, defaults/rubric-migration.md, defaults/rubric-api-design.md, defaults/generation-specs/dotnet-service.md to examples/ directory. Create examples/README.md explaining these are reference, not defaults. Update all framework code that previously loaded from defaults/ to read paths from project config or CLAUDE.md instead.

Files touched: 4 file moves, examples README created, references updated in skills (migrate-service line 31, migrate-service line 120, scaffold-api lines 33/35/41/65/69), FRAMEWORK.md (line ~289), README.md (~line 128), agents/code-reviewer.md (line 4 fallback discovery), skills/self-review/SKILL.md.

Quality bar: Framework operates correctly with no defaults/ directory present. Skills that previously loaded defaults now resolve paths through config or fail cleanly with clear error messages.

Estimated effort: 4-6 hours.

**PR 2: Component renames**

Scope: Atomic rename of three components. scaffold-api to scaffold, migrate-service to migrate, copilot-review-loop to external-review-handler. Single PR because partial renames produce broken state.

Files touched: Directory moves. References updated in plugin.json, hook configurations, FRAMEWORK.md, README.md, lib/skill-bootstrap.md, lib/proactive-triggering.md, test fixtures, documentation.

Quality bar: Tests pass after rename (39/39). Framework operations using new names work end-to-end. No references to old names remain in the codebase.

Estimated effort: 4-6 hours.

**PR 3: Lightly contaminated files batch**

Scope: Cosmetic contamination removal across 8 files per playbook entries 7-14.

Files touched: skills/routing/SKILL.md, skills/test-driven-development/SKILL.md, skills/scaffold/SKILL.md (post-rename), agents/external-review-handler.md (post-rename), hooks/coupled-edit-gate, lib/metrics.md, lib/verification-discipline.md, .claude-plugin/plugin.json.

Quality bar: All cosmetic CPSL or .NET references removed from lightly-contaminated files. Framework reads as stack-neutral.

Descope option: plugin.json author and repository decisions can defer if naming is not finalized.

Estimated effort: 2-3 hours.

**PR 4: Refactor analyst sub-agent with configurable scan profiles**

Scope: Replace hardcoded .NET technical debt scan with configurable scan profiles. Design scan-profile format. Ship example .NET scan profile at examples/scan-profiles/dotnet-framework.md. Update analyst sub-agent to read scan categories from configured profile.

Files touched: agents/analyst.md, new examples/scan-profiles/ directory with README and dotnet-framework profile.

Quality bar: Analyst behaves identically to current implementation when configured with the .NET scan profile. Configurable with other profiles for non-.NET teams.

Descope option: Ship with only the .NET scan profile if format design takes longer than expected.

Estimated effort: 6-8 hours including design work.

**PR 5: Refactor migrate skill with delegation pattern**

Scope: Replace hardcoded 7 migration steps with delegation to CLAUDE.md and generation-spec. Skill becomes orchestrator rather than guide. All CPSL references removed.

Files touched: skills/migrate/SKILL.md.

Quality bar: Skill orchestrates migration correctly when team has CLAUDE.md describing their migration patterns. Generic enough that a non-.NET team could use it with appropriate CLAUDE.md and generation spec.

Descope option: Ship minimum-viable delegation and defer richer delegation patterns to Phase 2.

Estimated effort: 8-12 hours.

**Checkpoint 1 — after PR 4 (mid-Phase 1)**

Honest assessment. Are PRs 1-4 done in 3-4 days as planned? If yes, continue. If we are behind, decide: push harder, descope something, or slip deadline.

**PR 6: FRAMEWORK.md replacement**

Scope: Replace current FRAMEWORK.md with a version that matches Sections 1-4 of the design document. FRAMEWORK.md becomes a navigable summary pointing to the design document for full detail.

Files touched: FRAMEWORK.md.

Quality bar: FRAMEWORK.md makes claims consistent with Sections 1-4. No overclaims.

Descope option: Mark some sections "see design document" if writing time runs short.

Estimated effort: 4-6 hours.

### Phase 2 — New building (PRs 7-11, target days 7-13)

**PR 7: Drift detector hook**

Scope: New hook that re-runs detection at session-start, compares against cached derived state, surfaces drift to user.

Files touched: New hooks/drift-detector script. Hook configuration updated. New test fixtures.

Quality bar: Detects real drift accurately. No false positives in normal usage. Surfaces drift in a way that is actionable, not noisy.

Descope option: Ship without drift detector. Phase 2 work after deployment.

Estimated effort: 1-2 days.

**PR 8: Three-layer configuration system**

Scope: Detector module (framework code reading package.json, .csproj, git config). Derived state file format and storage at .preflight/derived/state.json (gitignored). Natural-language overrides extraction from CLAUDE.md. Sanity checks at use sites. Audit trail logging. Verbose mode for high-stakes operations.

Files touched: New detector module code. Hooks updated to read from derived state. Skills updated to read operational values from derived state. New tests.

Quality bar: High-confidence detection works silently. Low-confidence values trigger explicit verification. Sanity checks catch invalid values before they cause failures.

Descope option: Ship with detector module plus derived state but defer natural-language override extraction to Phase 2.

Estimated effort: 3-4 days.

**PR 9: Bootstrap generator skill (the big one)**

Scope: New /preflight:bootstrap skill implementing three modes (Generate, Validate, Update). Codebase analysis logic. Question structure. Iterative alignment loop with the lead engineer. Validate mode with rigorous percentage accuracy calculation.

Files touched: New skills/bootstrap/SKILL.md. New supporting library for question generation, codebase analysis, accuracy calculation. New test fixtures simulating bootstrap scenarios.

Quality bar: Generated CLAUDE.md is substantively right on first commit — not vaguely plausible but actually matches the team's codebase. Iterative alignment catches drift before commit.

Descope option: Ship Generate mode only and defer Validate and Update modes to Phase 2.

Estimated effort: 3-4 days.

**Checkpoint 2 — after PR 9 (mid-Phase 2)**

Bootstrap generator is the largest piece. After PR 9 lands, honest assessment of remaining time vs remaining work.

**PR 10: Discipline core inlining**

Scope: Restructure lib/ documents to be loaded into skill or sub-agent activation context via session-start hook. Verify behavior matches current reference-based pattern.

Files touched: lib/ documents restructured for inlining. Session-start hook updated to load discipline core. Skills and sub-agents updated.

Quality bar: Skills behave identically with inlined discipline vs. referenced discipline. Architectural change is invisible to skill behavior.

Descope option: Defer entirely to Phase 2.

Estimated effort: 2-3 days.

**PR 11: Inventory document refresh**

Scope: Update docs/inventory-2026-05-21.md to reflect post-refactor state.

Files touched: docs/inventory-2026-05-21.md updated.

Quality bar: Inventory accurately describes the framework as it exists after all PRs 1-10 land.

Descope option: Ship a simpler "changes since v0.1-pre" document if full refresh takes too long.

Estimated effort: 2-3 hours.

### Phase 3 — Integration and deployment prep (days 13-14)

**PR 12: End-to-end integration verification**

Scope: Run the full framework end-to-end on a clean test scenario. Verify bootstrap produces good CLAUDE.md. Verify three-layer config produces correct derived state. Verify drift detector fires on actual drift. Verify discipline core inlining behaves correctly. Verify all rename references are clean. Run full test suite. Document any remaining issues.

Quality bar: Framework operates end-to-end on a non-trivial test scenario. All quality bars from previous PRs hold under integrated use.

Estimated effort: 1-2 days.

**Checkpoint 3 — End of sprint**

Final assessment. Ship or refine. Deployment to teammates begins or specific blockers documented for resolution.

## Total estimated effort

Best case (everything smooth): 13 working days with extended hours. Two weeks tight.

Realistic case (one or two blockers): 16-18 working days. Two weeks plus 2-4 days slip.

Worst case (multiple blockers or quality issues): 21+ working days. Three weeks.

The checkpoints make decision points explicit so we do not drift into worse cases without conscious choice.

## What is not in this plan

Sections 5+ of design document. Multi-stack validation on non-.NET project. Open-sourcing prep. Acquisition discussions. Versioning policy. Contribution model. These are post-sprint work.

## Operational practices

**Embedded verification checks in PR prompts.** Each PR prompt includes a small unrelated verification task before starting the PR work. The CLI grounds itself in current repo state before executing.

**Recap prompts between PRs.** After each PR lands, before the next PR fires, a short recap prompt verifies the current state of the framework matches expectations. Read specific files. Report line counts. Confirm commit history.

**Random framework-knowledge checks.** Once or twice during the sprint, include a check that is orthogonal to current work — verify something we decided is locked is actually persisted. The "did anything regress" checks.

These practices keep both the conversation-side (Claude) and the execution-side (CLI agent) grounded in actual repo state, not assumed state.

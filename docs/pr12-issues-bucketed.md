# PR 12 Issues — Bucketed

## Source
- Flat inventory at docs/pr12-issues-inventory.md (commit 5339ee4)
- This document adds 15 structural roll-ups (r01-r15) and assigns every issue to a bucket.

---

## Bucket A — Framework structural gaps (universal)

Issues where the framework itself lacks a capability that any team using preflight would need. Fix lives in framework code.

| ID | Summary | Rationale |
|---|---|---|
| r01 | The framework has no mechanism to be told what a given team's migration requires — no team-contract artifact, no declarative success criteria, no way to say "for us, done means X." | Every team has a different definition of migration-complete; the framework provides no place to declare it. |
| r02 | Spec extraction is not a first-class capability — the framework produces structural dependency maps but no forensic legacy-behavior spec (wire contracts, result codes, response shapes). | Any team migrating a legacy system needs behavior extraction, not just coupling extraction. |
| r03 | The framework's mechanical enforcement layer is configured but does not engage during real workflows — hooks exist but none fired during PR 12. | Every team relying on preflight's gates gets zero enforcement until this is fixed. |
| r04 | The framework has no observability for whether its own mechanical enforcement is active — no audit log of hook firings, no diagnostic of gate evaluations. | Any team running preflight cannot tell if enforcement is running or silently absent. |
| r05 | The framework has no comparison artifact for result-code mappings between legacy and migrated systems. | Any team migrating a service with an error-code contract needs this comparison; the framework provides no slot for it. |
| r06 | The framework's sub-agent architecture is partially defined and partially invoked — prescribed agents don't exist in the registry, orchestration doesn't enforce that all defined agents run. | Any team relying on the documented sub-agent roles gets incomplete orchestration. |
| r07 | The framework cannot distinguish between "migration complete" and "code generated" — push gates on code quality, not contract preservation. | Any team's definition of "migration done" includes behavioral equivalence, not just code-quality rubric pass. |
| r08 | The framework's compaction and resume behavior is unverified — checkpoints have fake timestamps, metrics weren't produced, incremental step-completion wasn't recorded. | Any team running multi-hour migrations needs reliable checkpoint/resume. |
| r09 | The framework has no decisions-log artifact for silent agent choices — architectural decisions appear only in generated code, never flagged or surfaced. | Any team would want visibility into what their agent decided silently. |
| r10 | The framework's success metrics measure what it can observe (tests pass, build clean) rather than what matters for production cutover (wire-contract preservation, latency match). | Every team would hit this gap — measuring the measurable instead of the important. |
| r11 | The framework has no mechanism for "this migration cannot proceed without human judgment on point X" — mid-flow decision surfacing doesn't exist beyond the Phase 1 confirmation. | Any team's migration involves irreducible human decisions that the framework currently swallows silently. |
| r12 | The framework's design documentation describes capabilities that don't exist as runtime behavior — the gap between intent and implementation is itself a structural issue. | Any team reading the design doc and relying on its commitments gets behavior that doesn't match. |
| r13 | The framework cannot produce a PR description that is honest and complete — silent decisions, parity deviations, and invented artifacts are not surfaced in the PR template. | Any team's reviewers need to see what was decided, not just what was generated. |
| r14 | The framework's own tests do not validate migration correctness — 164 internal assertions verify internal behavior, zero verify that a real migration preserves contracts. | The framework cannot be regression-tested as a migration tool for any team. |
| r15 | The framework's discovery output has no enforcing consumer — the dependency map is produced but nothing prevents the migration from collapsing dependencies the map identified. | Any team's coupling map is advisory rather than gating. |
| i01 | Discovery phase read only the controller (183 lines) and missed the repository (500 lines) containing 80% of behavior. | Any team with a thin-controller/fat-service architecture hits this — the framework doesn't enforce transitive dependency reading. |
| i14 | The `discovery-analyst` subagent_type referenced by the migrate skill doesn't exist in the agent registry. | Any team running the migrate skill would hit this registration gap. |
| i15 | Checkpoint timestamps are placeholder values that don't reflect actual execution times. | Any team relying on checkpoint data for diagnostics gets false timestamps. |
| i16 | The mandated `metrics.json` file was not produced despite the fix-and-close skill requiring it for every run. | Any team wanting run metrics gets nothing — the producer never fires. |
| i17 | The four mechanical hook scripts (1009 lines total) were never invoked; `.preflight/gate/` directory doesn't exist. | Universal — the hook infrastructure is inert for all users. |
| i18 | The pre-push gate would have blocked the push (no evidence files) but didn't fire — the push succeeded anyway. | Any team relying on the gate gets unblocked pushes. |
| i19 | The coupled-edit-gate was never activated despite coupled findings being identified and fixed. | Any team with coupled findings gets no mechanical protection. |
| i20 | The "PASTE verbatim" instruction for generation specs was not followed — code was generated from understanding rather than literal copy. | Any team with generation specs expecting character-fidelity hits this. |
| i22 | The dependency-map validator hook was never invoked despite the map being produced. | Any team's dependency map goes unvalidated mechanically. |
| i24 | The framework's core architectural commitment (mechanical enforcement) did not engage during a real run. | Universal — the framework's central thesis was not realized. |
| i25 | The post-migration dependency map refresh step was skipped. | Any team gets a stale Phase-1 map used for post-Phase-2 coupling analysis. |
| i26 | The framework reports confidence proportional to examination scope, not requirement scope — operationally misleading. | Any team receiving framework output trusts a confidence signal that doesn't reflect full coverage. |
| i30 | Only 2 of 4 designed sub-agents were invoked; implementer skipped, external-review handler never reached. | Any team gets incomplete orchestration relative to what the skill prescribes. |
| i31 | Stage 2 (self-improvement loop) was never reached — capture/classify/promote cycle has still never executed on real data. | Universal — the framework's learning loop is untested for all users. |
| i32 | Hooks configured via `run-hook.cmd` produced no diagnostic output — unknown whether they failed silently or were never registered. | Any team on any OS hits this observability gap. |
| i33 | The Phase 1 human confirmation gate's value depends on Phase 1 output being complete — with narrow discovery, it confirms a false picture. | Any team whose legacy system has logic outside the entry-point file gets a misleading confirmation. |
| i34 | 10 lib/ markdown files (6 identified as orphans) were never loaded or referenced during the run. | Any team's context budget is consumed by framework code that includes dead references to unused lib/ docs. |
| i35 | ~170k tokens consumed for a migration that broke wire parity — cost-effectiveness concern for any team. | Any team paying for tokens gets similar cost for a potentially-incorrect migration. |
| i42 | The framework's stated posture ("asks better questions about legacy code, doesn't assume it knows better") was not realized — it made silent decisions without questions. | Any team relying on this posture gets decisions made without surfacing. |
| i43 | The gps-decide skill was never invoked despite multiple consequential decisions that warranted structured decision-making. | Any team with high-stakes decisions during migration gets no forcing function applied. |
| i44 | The migrate skill's "read ALL" instruction (gen-spec, CLAUDE.md, MIGRATION_PATTERNS.md) was followed but the output contradicts CLAUDE.md's own requirements. | Any team whose CLAUDE.md sets requirements gets output that ignores them without flagging the conflict. |
| i45 | Session-start and drift-detector hooks produced no observable output — unknown whether they ran. | Any team cannot verify these hooks are active. |
| i46 | The rubric-validity-gate's execution is unconfirmed — no diagnostic output. | Same observability gap as i45 for any team. |
| i47 | Stage 1 found 5 code-quality issues and 0 wire-contract issues — the rubric has no parity sections. | Any team's rubric (not just CPSL's) lacks parity detection by default. |
| i48 | The resolve-config.sh library (632 lines) was never invoked — three-layer config not wired into migration. | Any team's migration skips the designed configuration resolution. |
| i49 | The extract-overrides.sh library was not invoked — natural-language override extraction is unwired. | Same as i48 — universal config gap. |
| i50 | Five empty test directories are inert — neither help nor harm but confirm dead structure. | Minor framework hygiene issue for any team inspecting the plugin. |
| i53 | Checkpoint records final state, not incremental step completions — crash-recovery would restart from Phase 1. | Any team with long migrations gets poor resume behavior. |
| i54 | Dependency-map blind spots (factory-lambda DI, event-bus, config-binding) were not stress-tested because coupling cascades didn't occur. | Any team's first real cascade will reveal whether the blind spots matter — untested for all. |
| i55 | Discovery-analyst has no mechanism to ensure transitive dependency reading — it read 183 lines when 700+ lines were required. | Any team with a multi-layer legacy architecture hits the same narrow-scope problem. |
| i56 | The Phase 1 human gate confirms a picture whose completeness it cannot assess. | Universal — the confirmation is as good as the discovery output, which is structurally narrow. |
| i58 | A human reviewer of the migrated output would likely approve without catching wire-contract breaks. | Any team's PR review process wouldn't catch omissions not visible from migrated code alone. |

---

## Bucket B — CPSL-specific requirements (team-declared, not framework)

Issues where the substance is CPSL's domain knowledge — result codes, response shapes, downstream integrations that only CPSL's team contract can declare. Fix lives in CPSL's CLAUDE.md, generation-spec, or team-contract artifact.

| ID | Summary | Rationale |
|---|---|---|
| i05 | Empty Version must return W0011, not W0023. | Which code means "version required" is CPSL's domain contract — no framework can know this in advance. |
| i06 | Malformed Version must return W0004, not W0023. | Same — the two-tier version validation is CPSL's specific design. |
| i07 | Invalid AppProfileID must return E0002, not W0024. | Which code means "bad profile" is CPSL's contract. |
| i08 | Six specific result codes (W0002, W0003, W0004, W0005, W0007, W0008) must be preserved. | The specific code set and its order is CPSL's validation chain — irreducible domain knowledge. |
| i12 | Success code is E0000 in legacy, not S0000. | The counterintuitive success-code convention is CPSL-specific. |
| i27 | Channel validation must check `IsON` property, not just existence. | The enabled/disabled state semantics are CPSL's auth model. |
| i28 | ChannelID must be forwarded as Authorization header to downstream services. | How channel identity propagates between services is CPSL's architectural convention. |
| i29 | Request validation must run BEFORE profile lookup (specific 8-step ordering). | The validation ordering with its specific precedence is CPSL's design. |
| i36 | Empty Format must be silently normalized to "json", not rejected. | The format-normalization behavior is a CPSL-specific leniency. |
| i37 | W0006 from downstream must trigger BadRequest + TT-status preservation logic. | The W0006 special handling is CPSL's specific cross-service contract. |
| i38 | DigitalID tracker integration (LogCustomerInfo) must fire on V1 path when version is "2.0". | Which analytics service fires when is CPSL's integration design. |
| i39 | V2 path requires three downstream services (Deflection API, Messaging, DigitalID) with specific orchestration. | The three-service fan-out is CPSL's specific V2 architecture. |
| i40 | Exit-point response must include `IsDeflectionAllowed` and `DeflectionUrl`, not `ExitPointName`/`Value`/`Type`. | The field names in the deflection contract are CPSL's wire format. |
| i41 | Token response must include `ExpirationTimeInSeconds` field. | A specific field in CPSL's response shape. |
| i51 | Downstream error response body must be deserialized and forwarded to caller (not replaced with fixed E1000). | How CPSL propagates downstream errors is their specific integration pattern. |

---

## Bucket C — Framework-shaped CPSL needs (CPSL pain, framework fix)

Issues that look CPSL-specific but point at a generic framework capability gap. CPSL hits the symptom; the fix is a framework capability that any team could use.

| ID | Summary | Framework capability this points at |
|---|---|---|
| i02 | PostgreSQL silently substituted for SQL Server. | Generic need: framework must flag silent infrastructure changes (DB engine, ORM, persistence model) as explicit decisions requiring acknowledgment. |
| i03 | Five stored function names invented with no real-world basis. | Generic need: framework must flag when generated code references artifacts that cannot be verified to exist. |
| i04 | No DDL or schema migration produced for the invented database. | Generic need: framework must recognize that persistence-layer migrations require schema artifacts, not just application code. |
| i09 | Model validation returns ProblemDetails instead of legacy response shape. | Generic need: framework must preserve response-body schemas, not just HTTP status codes — validation errors have contractual shapes. |
| i10 | DB failures return 500 instead of legacy's 400. | Generic need: framework must preserve error-path HTTP status codes as part of wire contract, not just happy-path statuses. |
| i11 | SlideToken changed from fire-and-forget to synchronous await — latency profile changed. | Generic need: framework must flag semantic changes in async/sync behavior as latency-profile decisions, not silent modernization. |
| i13 | Stage 1 checks quality rubric but not wire-contract preservation. | Generic need: a parity gate (distinct from quality gate) that compares migrated behavior against declared legacy behavior. |
| i21 | 71% coverage achieved vs 96% target, not flagged or gated. | Generic need: declared thresholds in team config must mechanically gate push, not be advisory. |
| i23 | Self-improvement loop has never completed a single iteration on real data. | Generic need: framework capabilities must be exercised end-to-end before being claimed as operational. |
| i52 | The "every issue caught on N should be caught on N+1" contract remains aspirational. | Same as i23 — the core architectural commitment is untested. |
| i57 | Test suite cannot cover the data layer because no test DB is provisioned. | Generic need: when coverage targets are structurally unreachable, the framework must flag this explicitly rather than accepting lower coverage silently. |
| i59 | Bootstrap-write-gate exists but no equivalent gate exists for wire-contract preservation. | Generic need: the framework's gate set should cover the team's declared concerns, not just the framework's internal concerns. |
| i60 | ResultMessages.cs was never compared against legacy code mappings during the run. | Generic need: the framework must produce explicit before/after comparison artifacts for declared contract surfaces. |

---

## Bucket count and shape check

| Bucket | Count | Percentage |
|---|---|---|
| **A — Framework structural gaps** | 47 | 63% |
| **B — CPSL-specific requirements** | 15 | 20% |
| **C — Framework-shaped CPSL needs** | 13 | 17% |
| **Total** | 75 | 100% |

---

## Cross-references

Issues that are symptoms of structural roll-ups:

| Roll-up | Symptoms |
|---|---|
| r01 (no team-contract artifact) | i13, i21, i44, i47, i58 |
| r02 (no spec extraction capability) | i01, i55, i56 |
| r03 (hooks configured but inert) | i17, i18, i19, i22, i24, i32, i45, i46 |
| r04 (no hook observability) | i32, i45, i46 |
| r05 (no result-code comparison artifact) | i05, i06, i07, i08, i12, i60 |
| r06 (sub-agent architecture partially realized) | i14, i30, i43 |
| r07 (done ≠ contract-preserved) | i13, i47, i58 |
| r08 (checkpoint/resume unverified) | i15, i35, i53 |
| r09 (no decisions-log) | i02, i03, i04, i11, i42, i43 |
| r10 (success metrics measure the wrong things) | i13, i21, i47, i52 |
| r11 (no mid-flow human-decision surfacing) | i33, i43 |
| r12 (design vs runtime gap) | i23, i24, i42 |
| r13 (PR description incomplete) | i02, i03, i58, i59 |
| r14 (no migration-correctness tests) | i52, i57 |
| r15 (discovery output not enforced) | i22, i25, i54 |

---

## Honest assessment

**Bucket A dominates at 63%.** The framework's structural gaps account for nearly two-thirds of all issues. This is not surprising — PR 12 was the first real-world run, and the framework is at v0.1-pre with mechanical enforcement that exists as code but doesn't activate as runtime behavior. The design document (Section 7) predicted this: "The gap between 'passes all tests' and 'works in production' is real."

**Bucket B is lean at 20%.** This is healthy — it means most of CPSL's pain is not irreducible domain knowledge but rather framework gaps that happen to manifest through CPSL's specific domain. The 15 CPSL-specific items are genuinely irreducible: result-code values, field names, validation ordering, downstream integration shapes. These belong in a team-contract artifact (which doesn't exist yet — that's r01).

**Bucket C at 17% identifies the bridge work.** These are the issues where building a generic capability immediately solves CPSL's specific pain AND helps future teams. The "flag silent infrastructure changes" capability (from i02) and the "parity gate" concept (from i13) are the two highest-leverage items in Bucket C because they each address multiple symptoms.

**Where v0.2's effort should concentrate:** Bucket A, specifically the roll-ups. The 15 roll-ups are the structural capabilities whose absence caused 47 individual symptoms. Fixing r01 (team-contract artifact), r02 (spec extraction), r03 (hook activation), r05 (result-code comparison), and r09 (decisions-log) would address the majority of Bucket A symptoms and simultaneously make Bucket B items *expressible* (you can't declare CPSL's contracts until the framework has a place to put them).

**No issues argue for a fourth bucket.** Every issue fits cleanly into A, B, or C. The closest to an edge case was i33 (human gate bypassed by experiment instructions) — this is Bucket A because the framework should be robust against being told to run unattended, not because CPSL specifically needs it.

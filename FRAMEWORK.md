# preflight Framework

**Version:** v0.2-pre
Stack-neutral architecture verified. Self-improvement loop designed but not yet proven through operational use.

---

## 1. What preflight is

Preflight is a self-learning engineering harness for AI-assisted development. As model capability commoditizes — frontier models stack within percentage points of each other on every benchmark — the differentiator moves to the harness: the system prompts, skill compositions, sub-agent handoff patterns, and mechanical enforcement that sit between the model and the team's codebase. The harness compounds through use. The model doesn't.

Preflight encodes review discipline as mechanical enforcement, captures external review findings as learning evidence, and promotes validated patterns into detection rules that fire locally on subsequent work. It works from any directory, adapts to project-specific rubrics and scan profiles, and operates across multiple development domains (migration, net-new API, generic) without domain-specific hardcoding in its core loop.

The framework is not static. Every PR that passes through it generates captures. Captures become rubric edits. Rubric edits make the next review smarter. The act of using preflight improves preflight. This is not a feature — it is the architectural commitment.

---

## 2. The architectural commitment

Preflight promises one thing:

> **Every issue caught by external review on ServiceN should be caught by local review on ServiceN+1.**

This is the contract the system is engineered to deliver. The two sub-agents, the four capture buckets, the rubric-edit promotion process, and the mechanical gates all exist to make this statement true over time. If a design decision would weaken this contract, that decision is wrong.

The commitment is probabilistic, not absolute. It depends on:
- The external reviewer flagging the issue (it must be caught at least once)
- The external-review-handler classifying it correctly (it must land in the right bucket)
- The rubric-edit PR promoting it (a human must approve the rule)
- The code-reviewer detecting the promoted pattern (the rubric section must be mechanical)

Each link can fail. The system improves by making each link more reliable with each iteration.

---

## 3. How the loop works

### The execution flow

```
Code written (by main session)
  |
  v
Stage 1: code-reviewer walks rubric against diff
  |--- NEEDS_FIXES --> main session fixes --> re-run Stage 1
  |--- CLEAN --> push
  v
PR opened, external reviewer requested
  |
  v
Stage 2: external-review-handler polls external review
  |--- Comments arrive --> classify into 4 buckets, write captures
  |                    --> return findings to main session for fixing
  |--- No comments --> SUCCESS
  v
Main session fixes external findings, re-runs Stage 1, pushes
  |
  v
Loop until external review is clean
  |
  v
After N PRs: batched rubric-edit PR promotes validated captures into rubric
  |
  v
Next service inherits strengthened rubric automatically
```

### Sub-agent role separation

The system uses three actors with non-overlapping responsibilities:

| Actor | Reads | Writes | Role |
|---|---|---|---|
| **Main session** | everything | service code, commits, pushes | Orchestrates, edits code, applies fixes |
| **code-reviewer** | rubric + diff | findings report only | Detects issues against the rubric |
| **external-review-handler** | external comments + rubric | capture files only | Classifies findings, writes learning evidence |

A fourth sub-agent, **discovery-analyst**, produces dependency maps and readiness assessments for domain-specific workflows. A fifth, **implementer**, applies fixes in fresh context when the main session's context is saturated.

### Four-bucket classification

Every external review finding lands in exactly one bucket:

| Bucket | Meaning | Destination |
|---|---|---|
| **in-rubric-but-missed** | Rubric covers this but Stage 1 didn't catch it | calibration-log.md |
| **new-category** | No rubric section exists for this class of issue | checklist-additions.md |
| **false-positive** | Stage 1 flagged it but external review disagrees | false-positives.md |
| **human-judgment** | Genuinely subjective; not automatable | checklist-additions.md (deferred section) |

A fifth bucket, **pattern-capture**, records positive patterns (code that passed review) for generation-spec candidates.

---

## 4. The capture/rubric contract

### Separation of concerns

- **Rubric** = the sole operative detection spec. Code-reviewer reads only the rubric for detection rules. Every section in the rubric fires on every diff, every time.
- **Capture files** = transient evidence. They record what external review found, how it was classified, and how many services have validated the pattern. They do NOT take operative effect at runtime.

### Why this separation exists

When multiple engineers run preflight in parallel against shared capture files, treating captures as operative rules creates race conditions, duplicate findings, and classification conflicts. The rubric is the single authoritative source. The human-reviewed promotion step reconciles conflicts that parallel execution would otherwise create.

### Promotion mechanism

Validated capture entries become rubric sections through the batched rubric-edit PR process. This is documented in full at `docs/rubric-edit-process.md`. The key properties:

- **Trigger:** after `loop.rubricEditCadence` PRs complete Stage 2 (default: 5)
- **Decision matrix:** two-dimensional (Survived count x Confidence level)
- **Human-reviewed:** the rubric-edit PR goes through normal review before merging
- **Lifecycle:** entries track `FirstSeen` and `Cycles` fields; entries not promoted within 2 cycles are archived as deferred

### Rubric section ID prefixes

Multi-rubric configurations (e.g., generic + migration rules applied simultaneously) require unambiguous section IDs across rubric files. Each rubric declares its section ID prefix in a top-of-file HTML comment. Example prefix conventions:

| Rubric type | Prefix | Example IDs |
|---|---|---|
| Generic (quality/security) | §G | §G1, §G2.1, §G7.2 |
| Migration (framework upgrade) | §M | §M1, §M4.3, §M9.1 |
| API design (net-new service) | §A | §A1, §A3.2, §A6.1 |

Every rubric MUST declare a unique prefix in a comment at the top of the file. Section IDs within a rubric MUST conform to the declared prefix. Cross-rubric references in capture files and generation specs use the fully-prefixed ID (e.g., `§M3` refers unambiguously to migration rubric section 3).

---

## 5. Skills

Preflight provides 8 invocable skills and 1 system skill:

### Domain-specific skills

| Skill | Mode | Purpose |
|---|---|---|
| `/preflight:migrate` | migration | End-to-end legacy migration: discovery, execution, review loop |
| `/preflight:scaffold` | api-new | Net-new API: design, generation from rubric, review loop |

Both domain skills follow the same pattern: Phase 1 analysis, Phase 2 generation/execution, handoff to `/preflight:fix-and-close` for the review pipeline. They are peer domains — neither is primary.

### Adoption skill

| Skill | Mode | Purpose |
|---|---|---|
| `/preflight:bootstrap` | any | Team configuration: CLAUDE.md, pointer files, config, scan profile recommendation |

Bootstrap is the framework's adoption mechanism. Any team runs it once and gets expert-practice configuration for their stack in one conversation. Three modes: Generate (fresh team), Validate (verify existing), Update (detect drift). Uses the detector module for codebase analysis.

### Pipeline skills

| Skill | Purpose |
|---|---|
| `/preflight:fix-and-close` | Full pipeline: Stage 1 gate, commit, push, Stage 2 Copilot loop, metrics |
| `/preflight:self-review` | Stage 1 standalone: review current diff, fix locally, loop until clean. Never pushes. |

### Process skills

| Skill | Purpose |
|---|---|
| `/preflight:systematic-debugging` | Root cause investigation before fixes. Prevents shotgun debugging. |
| `/preflight:test-driven-development` | RED-GREEN-REFACTOR enforcement. Prevents tests-after-implementation. |
| `/preflight:gps-decide` | Decision framework scaling scrutiny to stakes. Prevents over-deliberation. |

### System skill

| Skill | Purpose |
|---|---|
| `routing` | Behavioral decision tree loaded by session-start hook into session context. Tells the agent WHEN to activate each skill. Never invoked by name. |

The routing skill is the framework's proactive layer — it prevents the agent from forgetting that skills exist at high context utilization.

---

## 6. Sub-agents

### code-reviewer (Stage 1)

- **Role:** Walks the project rubric against the current diff. Reports findings.
- **Reads:** rubric (from config or defaults) + full changed files
- **Writes:** nothing (findings are returned as structured output)
- **Never:** edits code, reads capture files, runs git commands
- **Output:** `CLEAN` | `NEEDS_FIXES` | `ERROR` with structured findings JSON
- **Invoked:** before every push, including after Copilot-driven fixes

### external-review-handler (Stage 2)

- **Role:** Polls external reviewer, classifies findings, writes capture entries, manages Survived counts
- **Reads:** external review comments, rubric (for cross-check), existing capture entries (for deduplication)
- **Writes:** capture files only (calibration-log, checklist-additions, false-positives, generation-spec-candidates)
- **Never:** edits service code, modifies the rubric directly
- **Output:** `SUCCESS` | `NEEDS_PARENT_FIXES` | `STUCK` | `DIVERGING` | `CAPPED` | `FAILED` | `ERROR`
- **Invoked:** after push, when external review is requested

### discovery-analyst

- **Role:** Codebase analysis for migration readiness or architecture assessment. Loads scan profiles dynamically based on project stack.
- **Reads:** source code, project files, dependencies, scan profiles (from config or examples)
- **Writes:** `dependency-map.json` (file on disk), structured markdown report
- **Never:** modifies code in either repo
- **Output:** `DONE` | `BLOCKED` | `ERROR` with markdown report + dependency map
- **Invoked:** at the start of domain-specific workflows (Phase 1), or for post-migration dependency map refresh
- **Scan profile loading:** config field → `.preflight/scan-profiles/` → `examples/scan-profiles/` → built-in minimal scan (12 universal secret-detection patterns)

### implementer

- **Role:** Fresh-context code executor for coupled-group fixes
- **Reads:** only the files listed in the fix brief
- **Writes:** edits to brief-listed files only
- **Never:** pushes, commits, reads outside brief scope
- **Output:** `DONE` | `BLOCKED` with structured fields
- **Invoked:** by fix-and-close when coupled findings need isolation from the main session's saturated context

---

## 7. Mechanical enforcement

### Why prompts are not enough

At 65%+ context utilization, LLM attention drifts from instructions read 40K tokens ago. Under user pressure, the model weighs user instruction against CRITICAL-INSTRUCTION directives. Mechanical gates are bash scripts that execute before the tool call reaches the model. They cannot be bypassed by prompt manipulation, context degradation, or user override.

### The gate system

Three evidence-based gates block `git push` if conditions are not met:

| Gate | Evidence file | Written when |
|---|---|---|
| Tests pass | `.preflight/gate/tests-pass` | Test command returns 0 |
| Stage 1 clean | `.preflight/gate/stage1-clean` | code-reviewer returns CLEAN |
| Map validated | `.preflight/gate/map-validated` | Dependency-map validator passes |

Each evidence file records the HEAD commit at time of check. If HEAD moves (any new commit), evidence is stale and the gate blocks until the check runs again.

### Coupled-edit gate

The `coupled-edit-gate` hook blocks `Edit` tool calls to files in unacknowledged coupling groups. This prevents fixing coupled findings independently — the primary cause of cascading regressions (48% of review round cost in the migration that motivated preflight's creation).

The protocol:
1. Stage 1 returns findings → orchestrator groups by coupling
2. Groups written to `.preflight/gate/active-groups.json`
3. Any Edit to a grouped file is BLOCKED until the group is acknowledged
4. Acknowledgment signals: all findings in the group have been read, a coherent fix has been designed
5. Only after acknowledgment do edits proceed

### Hard iteration caps

| Loop | Cap | On cap hit |
|---|---|---|
| Stage 1 | 5 iterations | Stop. Surface to user. |
| Stage 2 | 3 iterations (override to 8 via config) | Stop. Surface to user. |

### Verification discipline

No completion claim without fresh verification evidence. "Tests pass" requires test output from THIS interaction. "Stage 1 clean" requires code-reviewer output on the CURRENT diff. Memory of a previous pass is not evidence.

This feeds the gate system: verification passes → evidence written → gate accepts. Verification skipped → no evidence → gate blocks. Defense in depth.

---

## 8. Configuration

Preflight activates when it finds a project config file (search order: `.preflight/config.json` > `.cpsl/config.json` > `.forge.json`). If no config exists, it uses generic defaults.

### Key fields

```json
{
  "mode": "generic | migration | api-new",
  "rubric": "path/to/rubric.md or [array of paths]",
  "capture": {
    "calibrationLog": "path",
    "checklistAdditions": "path",
    "falsePositives": "path",
    "patternCapture": "path"
  },
  "branch": {
    "base": "main",
    "remote": "origin",
    "migrationPrefix": "feature/migrate-"
  },
  "loop": {
    "rubricEditCadence": 5,
    "maxStage1Iterations": 5,
    "maxStage2Iterations": 3
  },
  "test": {
    "command": null,
    "coverageBaseline": null
  }
}
```

### Rubric field

The `rubric` field accepts either a single path (string) or an array of paths. Code-reviewer walks all rubrics in the array during review, citing fully-prefixed section IDs so findings are unambiguous across rubrics.

Teams configure rubrics appropriate to their stack and domain. The framework ships example rubrics at `examples/rubrics/` — these are starting points, not prescriptions. Teams are expected to author or adapt rubrics to their standards.

If `rubric` is omitted or null, the framework falls back to example rubrics from `${CLAUDE_PLUGIN_ROOT}/examples/rubrics/` based on the project's configured mode.

### Scan profile field

The `scanProfile` field (optional) points to a scan profile that the discovery-analyst uses during Phase 1 technical debt analysis. If not configured, the analyst auto-detects the project stack and resolves a profile from `.preflight/scan-profiles/` or `examples/scan-profiles/`.

Scan profiles define stack-specific technical debt patterns with detection signals. The framework ships example profiles at `examples/scan-profiles/` — teams can author their own for custom patterns.

### Generation spec field

The `generation-spec` field (optional) points to a generation spec that the migrate and scaffold skills use during Phase 2 code generation. If not configured, the skill resolves a spec from `examples/generation-specs/` based on the detected stack.

Generation specs provide copy-pasteable code patterns pre-validated against the rubric. Using them means Stage 1 will never flag the mechanical patterns — the generation spec and detection spec are two sides of the same coin.

### Mode implications

| Mode | Skills available | Extra config |
|---|---|---|
| `generic` | self-review, fix-and-close, TDD, debugging, gps-decide | None |
| `migration` | + migrate | `migration.legacyRepoPath` required |
| `api-new` | + scaffold | None |

Rubrics, scan profiles, and generation specs are resolved per stack, not per mode. Mode determines which skills activate. Stack-specific content is configured independently.

### Fallback behavior

When no config exists: mode is `generic`, rubric is resolved from the plugin's bundled `examples/rubrics/` based on detected stack, branch base is `main`, test command is auto-detected. Every skill's Step 0 implements this fallback identically (documented in `lib/skill-bootstrap.md`).

---

## 9. What preflight is NOT

- **Not a linter.** It does not parse ASTs or run static analysis. It orchestrates an LLM reviewer that walks human-authored detection rules.
- **Not a CI gate.** It runs locally, before push. CI tools (SonarQube, Veracode, CodeQL) are complementary — they catch different things and run later in the pipeline.
- **Not a code generator.** The generation specs help produce code that pre-passes the rubric, but the primary value is review discipline, not generation.
- **Not opinionated about your stack.** The framework's core loop (review, capture, promote, detect) is language-agnostic. Scan profiles, rubrics, and generation specs adapt it to any stack. Example content ships for .NET; other stacks configure their own or generate content through bootstrap.
- **Not a replacement for human review.** It reduces review round-trips by catching mechanical issues early. The final PR still gets human eyes before merge.
- **Not a guarantee.** The architectural commitment is a design goal, not a theorem. It depends on capture quality, classification accuracy, and promotion decisions. It gets closer to the goal with each iteration — it does not start at 100%.

---

## 10. Stability and versioning

**v0.2-pre** means:
- All contracts (sub-agent I/O, hook formats, config schema, capture templates) are designed and statically verified
- The test suite passes (39 assertions across 4 suites)
- Framework architecture is stack-neutral — scan profiles, generation specs, and rubrics are configurable per team/stack
- No execution evidence of the full self-improvement loop closing yet — operational proving phase pending
- Contracts may revise based on early execution evidence

**What changes to expect before v0.1:**
- First execution (via `/preflight:scaffold` on upcoming API development) will validate or revise polling intervals, iteration caps, and capture template fields
- Hook behavior under real Claude Code plugin loading (vs development `--plugin-dir`) may surface integration issues
- The rubric-edit promotion process has not been exercised end-to-end yet

**What will NOT change:**
- The architectural commitment (the promise)
- Sub-agent role separation (who edits, who reads, who writes)
- The capture/rubric federation (captures transient, rubric operative)
- Mechanical gate enforcement (evidence-based push blocking)

---

## References

| Document | Purpose |
|---|---|
| `docs/rubric-edit-process.md` | Full promotion process documentation |
| `docs/contract-audit-2026-05-20.md` | Complete interface map (23 contracts, producer/consumer pairs) |
| `lib/skill-bootstrap.md` | Canonical Step 0 environment detection pattern |
| `lib/verification-discipline.md` | The "no claims without evidence" behavioral rule |
| `lib/mechanical-gates.md` | Gate architecture and evidence format |
| `lib/proactive-triggering.md` | When skills self-activate |
| `lib/oscillation-detection.md` | How the system detects non-convergence |
| `lib/metrics.md` | Run metrics schema and collection points |
| `defaults/config-template.json` | Full config schema with comments |

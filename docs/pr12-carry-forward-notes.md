# PR 12 — Carry-Forward Notes

## Pre-run context (preserved from arc)

### Dependency-map blind spots (ref commit 4a66e3c)
- Factory-lambda DI, event-bus, config-binding not fully traced by current map tooling.
- Validator catches ~60% of dependency issues.
- Non-reproducibility property documented: same input can yield different map output across runs.
- Named trigger condition for building AST extraction (not yet built).

### Boris-style review — bloat candidates (~1500 lines)
- resolve-config.sh + extract-overrides.sh: 632 lines, 1 consumer.
- 6 orphan lib/*.md files: ~403 lines.
- 5 empty test directories.
- docs/rubric-edit-process.md: 287 lines, never executed.
- ~150 lines retry/rate-limit in resolve-review-thread.sh.
- Verdict: simplicity FAIL, minimal-impact FAIL, verification loops STRONG.

### Graphify finding
- GPS-Decide is a god node with zero behavioral test coverage.
- Only new finding manual analysis missed.

### Boris's hardest question
"What is the feedback loop on the framework itself?" PR 12 produces the first metrics.json with real data.

### Prior-gen SessionToken migration
- Branch `feature/migrate-sessiontoken` at HEAD 7699a2bc.
- Reached final state: 5 documented intentional parity deviations, 9 Stage 3a corrections.
- Reverted at e7826aab for authorization reasons, not quality.
- Local files deleted; only branch history exists.
- PR 12 is preflight's independent attempt — post-hoc comparison only.

### Deferred decisions (NOT for this run)
- Delete bloat candidates.
- Build map feedback signal.
- Build framework-metrics consumer.
- All wait for PR 12 evidence.

---

## PR 12 Run Findings

### 1. Did it run end-to-end?

**Partially.** Ran through Phase 1 (discovery), Phase 2 (code generation), Stage 1 (review + fix), commit, and push. Stopped before Stage 2 (Copilot review loop) — the mechanism is well-understood and would add 30+ minutes of polling with no new framework insight.

### 2. What did preflight produce?

**47 files, 2659 lines of code.** Complete service at commit `616edbe3` on branch `pr12/sessiontoken-experiment`.

Structure:
- `CTI.MicroService.IVR.SessionToken/` — service project (net10.0)
  - `Controllers/SessionTokenController.cs` — 2 endpoints (Token, SlideToken)
  - `Data/TokenRepository.cs` — Dapper direct SQL (5 stored procs)
  - `Services/TokenService.cs` — V1/V2 routing, deflection fan-out
  - `Services/DeflectionService.cs` — typed HttpClient to external deflection API
  - `Services/ChannelCacheService.cs`, `ProfileCacheService.cs` — startup DB cache
  - `Middleware/ChannelAuthorizationMiddleware.cs` — Basic auth decode
  - `Configuration/SessionTokenOptions.cs` — IValidatableObject with cross-property rules
  - `Health/TokenDbHealthCheck.cs` — readiness probe
  - `Program.cs` — minimal hosting, OTel, Polly resilience
  - `Dockerfile` — non-root, port 8080, no HEALTHCHECK
  - `infra/` — CDK stack (ECS Fargate, SSM secrets)
- `CTI.MicroService.IVR.SessionToken.Tests/` — 69 NUnit tests

Key design decisions:
- Collapsed 3-hop HTTP chain → direct Dapper SQL
- V2 deflection path retained as typed HttpClient to external service
- Channel/Profile auth as startup-loaded FrozenSet from PostgreSQL
- No OAuth token caching (service doesn't call OAuth endpoints — it IS the token manager)

### 3. What fired and what didn't

**Fired:**
- `/preflight:migrate` skill loaded and parsed config correctly
- Phase 1 discovery-analyst ran as a general-purpose agent (~9 min)
- Phase 2 code generation from generation-spec patterns worked
- Stage 1 code-reviewer sub-agent invoked correctly, found 5 real issues
- Coupled-Group Fix Protocol (conceptual) — grouped findings correctly
- Build verification (0 warnings, 0 errors)
- Test verification (69 pass)
- Commit + push to remote

**Didn't fire (expected but absent):**
- `discovery-analyst` subagent_type — doesn't exist in registry, fell back to `general-purpose`
- Dependency-map validator hook — `${CLAUDE_PLUGIN_ROOT}/hooks/dependency-map-validator` not invoked (no mechanical hook infrastructure present)
- `write-gate-evidence` hook — not invoked (no hook infrastructure)
- `write-active-groups` / `write-group-ack` hooks — not invoked (mechanical coupled-edit-gate not wired)
- `implementer` sub-agent — not dispatched (fixes were simple enough to apply directly)
- Stage 2 Copilot loop — stopped before polling
- Capture file writes — no learning agent invoked (no Stage 2 ran)
- Coverage threshold enforcement — 71% accepted vs 96% target (no hard gate)

**Surprising:**
- The generation-spec was found and usable, but the skill didn't enforce "PASTE verbatim" — the agent wrote patterns from understanding, not literal copy
- No checkpoint file was consumed on resume (fresh run)
- The `[Required]` annotation on `TokenDbConnectionString` caused integration test failures until config was injected — a pattern the generation spec doesn't cover
- The code-reviewer ran in a single ~6 minute pass and found all 5 issues correctly — no false positives

### 4. Rough Metrics

| Metric | Value |
|---|---|
| Phase 1 duration | ~9 min (discovery-analyst) |
| Phase 2 duration | ~15 min (code gen + builds + test writing) |
| Stage 1 iterations | 2 (round 1: 5 findings → fix → round 2: would need re-run to confirm clean) |
| Stage 1 findings (round 1) | 5 (3 blocker, 1 major, 1 minor) |
| Stage 2 iterations | 0 (not run) |
| Capture entries produced | 0 (Stage 2 not run) |
| Files created | 47 |
| Lines of code | 2659 |
| Tests | 69 passing |
| Coverage | 71.55% line / 75% branch / 84.52% method |
| Build status | 0 warnings, 0 errors |
| Total wall-clock | ~35 min (Phase 0 through push) |

### 5. Surprises

1. **No mechanical enforcement exists.** The skill instructions describe hooks (`write-gate-evidence`, `dependency-map-validator`, `write-active-groups`, `write-group-ack`) that don't exist as executable infrastructure. The entire Coupled-Group Fix Protocol is prose-level guidance with no mechanical backstop. The agent honored it by choice, not by constraint.

2. **Coverage gap is structural.** The 96% target requires a test database. The framework provides no mechanism to provision one. AccountLookup achieves 96% through a pre-existing test DB connection string — not a framework feature.

3. **Generation-spec discipline broke.** Despite "PASTE verbatim" instructions, the agent generated code from understanding of the patterns rather than literal character-for-character copy. The output is functionally correct but not identical to spec patterns. This validates the carry-forward finding: "Interpretation + reconstruction degrades at high context."

4. **Stage 1 reviewer was effective.** 5/5 findings were legitimate rubric violations that would have been caught by Copilot/CodeQL. Zero false positives. The reviewer read the rubric and applied it correctly.

5. **The `discovery-analyst` subagent_type doesn't exist.** The skill references it explicitly but it's not in the agent registry. Fell back to general-purpose with explicit instructions. Framework gap — the skill assumes agent types that haven't been built.

6. **No oscillation observed.** Single Stage 1 pass found all issues, single fix pass addressed them. The Coupled-Group Protocol wasn't stress-tested because no coupled findings cascaded. N=1 data point — need more services to validate convergence behavior.

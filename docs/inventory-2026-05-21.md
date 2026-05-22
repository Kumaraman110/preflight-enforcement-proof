# Preflight Inventory — 2026-05-21

Complete inventory of all skills, agents, and hooks in the preflight framework. Each record documents purpose, contracts, dependencies, and stack coupling.

---

## Skills

### self-review

| Field | Value |
|---|---|
| **File** | `skills/self-review/SKILL.md` |
| **Lines** | 98 |
| **Purpose** | Stage 1 standalone review loop. Walks rubric against current diff, fixes findings locally, loops until clean. Never pushes. |
| **Invocation** | `/preflight:self-review` |
| **Mode gate** | None (all modes) |
| **Tools used** | Read, Glob, Grep, Bash, Edit, Write, Agent (code-reviewer) |
| **Inputs** | Current branch diff, project rubric |
| **Outputs** | Clean diff (fixes applied locally), gate evidence written |
| **Depends on** | code-reviewer agent, write-gate-evidence hook, project config (rubric path) |
| **Depended on by** | fix-and-close (delegates Stage 1 to this), routing (recommended before push) |
| **Stack coupling** | Generic — reviews whatever the rubric describes |
| **Iteration cap** | 5 (from config `loop.maxStage1Iterations`) |

---

### fix-and-close

| Field | Value |
|---|---|
| **File** | `skills/fix-and-close/SKILL.md` |
| **Lines** | 264 |
| **Purpose** | Full pipeline: Stage 1 gate → commit → push → Stage 2 Copilot loop → metrics. Orchestrates coupled-group protocol. |
| **Invocation** | `/preflight:fix-and-close` |
| **Mode gate** | None (all modes) |
| **Tools used** | Read, Glob, Grep, Bash, Edit, Write, Agent (code-reviewer, copilot-review-loop, implementer) |
| **Inputs** | Uncommitted or committed changes on a feature branch |
| **Outputs** | Clean PR (all review rounds resolved), capture files updated, metrics recorded |
| **Depends on** | code-reviewer agent, copilot-review-loop agent, implementer agent, pre-push-gate hook, write-gate-evidence hook, write-active-groups hook, write-group-ack hook, coupled-edit-gate hook |
| **Depended on by** | migrate-service (hands off to this after Phase 2), scaffold-api (hands off after generation) |
| **Stack coupling** | Generic — test command configurable via `test.command` |
| **Iteration caps** | Stage 1: 5, Stage 2: 3 (configurable to 8) |
| **Key protocol** | Coupled-Group Fix Protocol — groups related findings, blocks independent edits, requires acknowledgment before fix |

---

### migrate-service

| Field | Value |
|---|---|
| **File** | `skills/migrate-service/SKILL.md` |
| **Lines** | 222 |
| **Purpose** | End-to-end legacy service migration: Phase 1 discovery (structure, debt, readiness score), Phase 2 execution (7 steps), handoff to fix-and-close. |
| **Invocation** | `/preflight:migrate-service <service-name>` |
| **Mode gate** | `migration` mode only |
| **Tools used** | Read, Glob, Grep, Bash, Edit, Write, Agent (discovery-analyst, code-reviewer, copilot-review-loop) |
| **Inputs** | Service name (bare or free-form), legacy repo path from config |
| **Outputs** | Complete migrated service (project, tests, infra, Dockerfile), handed to fix-and-close |
| **Depends on** | discovery-analyst agent, fix-and-close skill, project config (`migration.legacyRepoPath`, `migration.servicesRoot`) |
| **Depended on by** | Nothing (top-level entry point) |
| **Stack coupling** | **Heavily .NET-shaped** — assumes CTI.MicroService.IVR prefix, DP Manager decoupling, Unity DI scan, AWS CDK/ECS infra, NUnit/Moq/Bogus tests |

---

### scaffold-api

| Field | Value |
|---|---|
| **File** | `skills/scaffold-api/SKILL.md` |
| **Lines** | 111 |
| **Purpose** | Net-new API service: gather requirements, generate skeleton from rubric + generation spec, hand off to fix-and-close for review pipeline. |
| **Invocation** | `/preflight:scaffold-api` |
| **Mode gate** | `api-new` mode only |
| **Tools used** | Read, Glob, Grep, Bash, Edit, Write, Agent |
| **Inputs** | API requirements (endpoints, consumers, data shape) |
| **Outputs** | Generated service skeleton (project, tests, infra), handed to fix-and-close |
| **Depends on** | fix-and-close skill, generation spec (`examples/generation-specs/`), rubric-api-design |
| **Depended on by** | Nothing (top-level entry point) |
| **Stack coupling** | Lightly .NET-flavored — references NUnit/Moq/Bogus, "IVR callers" in argument hint |

---

### systematic-debugging

| Field | Value |
|---|---|
| **File** | `skills/systematic-debugging/SKILL.md` |
| **Lines** | 92 |
| **Purpose** | Root cause investigation before fixes. Enforces Observe → Hypothesize → Validate → Fix cycle. Prevents shotgun debugging. |
| **Invocation** | `/preflight:systematic-debugging` |
| **Mode gate** | None (all modes) |
| **Tools used** | Read, Glob, Grep, Bash |
| **Inputs** | Failing test or unexpected behavior |
| **Outputs** | Identified root cause with validation evidence, then targeted fix |
| **Depends on** | Nothing (standalone process skill) |
| **Depended on by** | routing (triggered on 2nd+ failed attempt at same fix) |
| **Stack coupling** | Generic — zero stack assumptions |

---

### test-driven-development

| Field | Value |
|---|---|
| **File** | `skills/test-driven-development/SKILL.md` |
| **Lines** | 100 |
| **Purpose** | RED-GREEN-REFACTOR enforcement. Ensures tests are written before implementation. Prevents tests-after-implementation anti-pattern. |
| **Invocation** | `/preflight:test-driven-development` |
| **Mode gate** | None (all modes) |
| **Tools used** | Read, Glob, Grep, Bash, Edit, Write |
| **Inputs** | New functionality to implement |
| **Outputs** | Implementation with pre-written tests (RED first, then GREEN) |
| **Depends on** | Nothing (standalone process skill) |
| **Depended on by** | routing (triggered when writing new functionality) |
| **Stack coupling** | Lightly .NET-flavored — ".NET Specifics" section names NUnit/Moq/Bogus |

---

### gps-decide

| Field | Value |
|---|---|
| **File** | `skills/gps-decide/SKILL.md` |
| **Lines** | 171 |
| **Purpose** | Decision framework that scales scrutiny to stakes. Ground / Push back / Stress test, gated behind a triage step. Prevents over-deliberation on trivial choices and under-scrutiny on irreversible ones. |
| **Invocation** | `/preflight:gps-decide` |
| **Mode gate** | None (all modes) |
| **Tools used** | Read (reference material only) |
| **Inputs** | A decision to evaluate (explicit or detected from context) |
| **Outputs** | Decision with confidence level, counter-case documented, action recommendation |
| **Depends on** | `skills/gps-decide/references/prompt-library.md` (87 lines of reference patterns) |
| **Depended on by** | routing (triggered on consequential/hard-to-reverse choices) |
| **Stack coupling** | Generic — no tech assumptions |
| **Triage gate** | Cheap + reversible → skip analysis, just ship. Expensive or irreversible → full GPS pass. |

---

### routing

| Field | Value |
|---|---|
| **File** | `skills/routing/SKILL.md` |
| **Lines** | 65 |
| **Purpose** | Behavioral decision tree injected at session start. Tells the LLM WHEN to activate each skill. Never invoked by name — loaded automatically via session-start hook. |
| **Invocation** | Never directly invoked (system skill) |
| **Mode gate** | None (always injected) |
| **Tools used** | None (pure behavioral document) |
| **Inputs** | None (passively consumed by the LLM) |
| **Outputs** | None (behavioral guidance in context) |
| **Depends on** | session-start hook (injects this into additionalContext) |
| **Depended on by** | All other skills (routing tells the LLM when to invoke them) |
| **Stack coupling** | Lightly .NET-flavored — `dotnet test`/`dotnet build` in verification examples |
| **Key feature** | Rationalization prevention table — explicitly names common rationalizations for skipping skills and explains why each is wrong |

---

## Agents

### code-reviewer

| Field | Value |
|---|---|
| **File** | `agents/code-reviewer.md` |
| **Lines** | 206 |
| **Role** | Stage 1 rubric reviewer. Walks project rubric against diff. Reports findings. READ-ONLY. |
| **Tools** | Read, Glob, Grep, Bash |
| **Reads** | Rubric (from config or defaults), full changed files, project config |
| **Writes** | Nothing — findings returned as structured output only |
| **Output contract** | `CLEAN` \| `NEEDS_FIXES` \| `ERROR` + JSON findings array |
| **Invoked by** | self-review skill, fix-and-close skill (before every push) |
| **Never does** | Edit files, run git write commands, read capture files, invoke other agents |
| **Two dimensions** | Correctness (rubric walk) + Completeness (spec compliance: adapt points, architecture, test coverage, DI registration) |
| **Severity levels** | `blocker` (security/data), `major` (async/contract/tests), `minor` (style), `info` (observation) |
| **CLEAN threshold** | Zero blockers + zero majors |
| **Stack coupling** | Generic — reviews whatever rubric is configured |
| **Key behavioral rule** | Exhaustive rubric walk mandatory regardless of diff size. Rationalization prevention table blocks "this is too small to review" thinking. |

---

### copilot-review-loop

| Field | Value |
|---|---|
| **File** | `agents/copilot-review-loop.md` |
| **Lines** | 384 |
| **Role** | Stage 2 orchestrator. Polls GitHub Copilot review, classifies findings into four buckets, writes capture entries, manages Survived counts, returns findings to parent for fixing. |
| **Tools** | Read, Glob, Grep, Bash, Write, Edit |
| **Reads** | External review comments (via `gh api`), rubric (for cross-check), existing captures (for deduplication) |
| **Writes** | Capture files only: calibration-log.md, checklist-additions.md, false-positives.md, generation-spec-candidates.md |
| **Output contract** | `SUCCESS` \| `NEEDS_PARENT_FIXES` \| `STUCK` \| `DIVERGING` \| `CAPPED` \| `FAILED` \| `ERROR` |
| **Invoked by** | fix-and-close skill (after push, when external review arrives) |
| **Never does** | Edit service code, modify rubric directly, push commits |
| **Classification contract** | Every finding → exactly one of: in-rubric-but-missed, new-category, false-positive, human-judgment |
| **TTL tracking** | `FirstSeen` and `Cycles` fields on capture entries; entries not promoted within 2 cycles are archived as deferred |
| **Polling** | `review.initialWaitSeconds` (default 90) before first poll, `review.pollIntervalSeconds` (default 200) between polls |
| **Stack coupling** | Generic, with one AccountLookup example in rationale text |

---

### discovery-analyst

| Field | Value |
|---|---|
| **File** | `agents/discovery-analyst.md` |
| **Lines** | 155 |
| **Role** | Phase 1 codebase analysis. Produces dependency maps, readiness scores, and architecture assessments. |
| **Tools** | Read, Glob, Grep, Bash |
| **Reads** | Source code, project files, dependencies (in legacy repo) |
| **Writes** | `dependency-map.json` (file on disk) |
| **Output contract** | `DONE` \| `BLOCKED` \| `ERROR` + markdown report |
| **Invoked by** | migrate-service skill (Phase 1) |
| **Never does** | Modify code in either repo |
| **Scans for** | Unity DI registrations, System.Web dependencies, ConfigurationManager, synchronous DB calls, WCF/SOAP references, legacy auth (OWIN), Newtonsoft.Json usage |
| **Stack coupling** | **Heavily .NET-shaped** — hardcoded scan targets are all .NET Framework patterns |

---

### implementer

| Field | Value |
|---|---|
| **File** | `agents/implementer.md` |
| **Lines** | 88 |
| **Role** | Fresh-context executor for coupled-group fixes. Receives a fix brief listing specific files and findings; applies ONE coherent change. |
| **Tools** | Read, Glob, Grep, Bash, Edit, Write |
| **Reads** | Only files listed in the fix brief |
| **Writes** | Edits to brief-listed files only |
| **Output contract** | `DONE` \| `BLOCKED` + structured fields |
| **Invoked by** | fix-and-close skill (when coupled findings need isolation from saturated main context) |
| **Never does** | Push, commit, read outside brief scope, invoke other agents |
| **Stack coupling** | Generic — no stack assumptions; works on whatever files are in the brief |
| **Key design** | Fresh context prevents cascading degradation. The main session's context may be saturated after many iterations; the implementer starts clean. |

---

## Hooks

### session-start

| Field | Value |
|---|---|
| **File** | `hooks/session-start` |
| **Lines** | 91 |
| **Event** | `SessionStart` |
| **Purpose** | Detects project config, reads mode/rubric/captures, injects routing skill content into session additionalContext. |
| **Trigger** | Every new Claude Code session |
| **Timeout** | 5000ms |
| **Config search order** | `.preflight/config.json` → `.cpsl/config.json` → `.forge.json` |
| **Parser fallback** | jq → python3 → python |
| **Output format** | `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<status + routing>"}}` |
| **Depends on** | routing skill (`skills/routing/SKILL.md`) — content injected into context |
| **Depended on by** | All skills (provides runtime mode/rubric detection) |

---

### pre-push-gate-check

| Field | Value |
|---|---|
| **File** | `hooks/pre-push-gate-check` |
| **Lines** | 33 |
| **Event** | `PreToolUse` (matcher: `Bash`) |
| **Purpose** | Intercepts Bash tool calls. Only activates when command contains `git push`. Delegates to `pre-push-gate`. All other commands pass through. |
| **Trigger** | Any Bash tool call |
| **Timeout** | 10000ms |
| **Detection regex** | `(^|&&|\|\||;)\s*git\s+push` |
| **Depends on** | pre-push-gate (delegates via `exec`) |
| **Depended on by** | fix-and-close skill (enforces gate mechanically) |

---

### pre-push-gate

| Field | Value |
|---|---|
| **File** | `hooks/pre-push-gate` |
| **Lines** | 63 |
| **Event** | Called by pre-push-gate-check (not directly registered) |
| **Purpose** | Mechanical gate. Checks evidence files for freshness (current HEAD or HEAD^). Blocks push if any gate lacks valid evidence. |
| **Gates checked** | 1. `tests-pass` — test suite ran successfully 2. `stage1-clean` — code-reviewer returned CLEAN 3. `map-validated` — dependency map validation (only if map exists) |
| **Evidence dir** | `.preflight/gate/` |
| **Freshness rule** | Evidence HEAD must match current HEAD or HEAD^ (covers the commit-after-evidence race) |
| **Exit codes** | 0 = allow push, 1 = block with reason on stderr |
| **Depends on** | write-gate-evidence (produces evidence files it checks) |
| **Depended on by** | pre-push-gate-check (caller) |

---

### coupled-edit-gate

| Field | Value |
|---|---|
| **File** | `hooks/coupled-edit-gate` |
| **Lines** | 100 |
| **Event** | `PreToolUse` (matcher: `Edit`) |
| **Purpose** | Blocks edits to files in unacknowledged coupling groups. Prevents independent fixes to coupled findings (the #1 cascade cause — 48% of review round cost). |
| **Trigger** | Every Edit tool call |
| **Timeout** | 5000ms |
| **Input** | Tool input JSON (extracts `file_path`) |
| **Groups file** | `.preflight/gate/active-groups.json` |
| **Behavior** | If file belongs to a group where `acknowledged: false` → block with instructions. If no groups file exists or file not in any group → allow. |
| **Unblock path** | Orchestrator calls `write-group-ack <index>` after reading all findings and designing coherent fix |
| **Parser fallback** | jq → python3 → python → grep (last resort) |
| **Depends on** | write-active-groups (creates groups file), write-group-ack (sets acknowledged=true) |
| **Depended on by** | fix-and-close skill (enforces coupled-group protocol) |

---

### write-gate-evidence

| Field | Value |
|---|---|
| **File** | `hooks/write-gate-evidence` |
| **Lines** | 44 |
| **Event** | Called by orchestrator (not hook-registered) |
| **Purpose** | Writes evidence that a gate has passed. Records gate name, HEAD commit, and timestamp. |
| **Usage** | `write-gate-evidence <tests-pass|stage1-clean|map-validated>` |
| **Output dir** | `.preflight/gate/` |
| **File format** | `GATE=<name>\nHEAD=<sha>\nTIMESTAMP=<iso8601>` |
| **Validation** | Only accepts known gate names (whitelist) |
| **Depends on** | Nothing |
| **Depended on by** | pre-push-gate (reads evidence), self-review skill, fix-and-close skill |

---

### write-active-groups

| Field | Value |
|---|---|
| **File** | `hooks/write-active-groups` |
| **Lines** | 38 |
| **Event** | Called by orchestrator (not hook-registered) |
| **Purpose** | Writes coupling groups JSON after Stage 1 returns grouped findings. Validates JSON before writing. |
| **Usage** | `write-active-groups '<json-array>'` |
| **Output file** | `.preflight/gate/active-groups.json` |
| **Input format** | `[{"files":["A.cs","B.cs"],"findings":[...],"acknowledged":false},...]` |
| **Clear** | `write-active-groups '[]'` (clears all groups) |
| **Validation** | jq or python validates JSON; rejects malformed input |
| **Depends on** | Nothing |
| **Depended on by** | coupled-edit-gate (reads the groups file) |

---

### write-group-ack

| Field | Value |
|---|---|
| **File** | `hooks/write-group-ack` |
| **Lines** | 51 |
| **Event** | Called by orchestrator (not hook-registered) |
| **Purpose** | Acknowledges a coupling group — sets `acknowledged: true`. Signals that all findings have been read and a coherent fix designed. |
| **Usage** | `write-group-ack <group-index>` (0-based) |
| **Effect** | Mutates `.preflight/gate/active-groups.json` in place |
| **Parser fallback** | jq → python3 → python |
| **Depends on** | write-active-groups (creates the file it modifies) |
| **Depended on by** | coupled-edit-gate (checks acknowledged status), fix-and-close skill |

---

### run-hook.cmd

| Field | Value |
|---|---|
| **File** | `hooks/run-hook.cmd` |
| **Lines** | 15 |
| **Event** | N/A (dispatcher, not a hook itself) |
| **Purpose** | Polyglot Unix/Windows wrapper. Routes hook invocations to bash regardless of OS. |
| **Unix path** | `exec bash` directly |
| **Windows path** | Finds `bash.exe` via git installation path |
| **Depends on** | Git for Windows (bash.exe) on Windows |
| **Depended on by** | hooks.json (all registered hooks route through this) |

---

## Cross-Reference Map

### Invocation chains

```
User types /preflight:migrate-service
  → migrate-service skill
    → discovery-analyst agent (Phase 1)
    → [code generation Phase 2]
    → fix-and-close skill (handoff)
      → code-reviewer agent (Stage 1 loop, up to 5x)
      → write-gate-evidence tests-pass
      → write-gate-evidence stage1-clean
      → pre-push-gate-check → pre-push-gate (validates evidence)
      → [push]
      → copilot-review-loop agent (Stage 2, up to 3x)
        → writes capture files
        → returns NEEDS_PARENT_FIXES
      → write-active-groups (if coupled findings)
      → coupled-edit-gate (blocks until acknowledged)
      → write-group-ack (unblocks)
      → implementer agent (fresh-context fix)
      → [loop until SUCCESS or CAPPED]

User types /preflight:self-review
  → self-review skill
    → code-reviewer agent (loop until CLEAN, max 5x)
    → write-gate-evidence stage1-clean

User types /preflight:scaffold-api
  → scaffold-api skill
    → [design + generation]
    → fix-and-close skill (handoff — same chain as above)

Session start (automatic)
  → session-start hook
    → reads project config
    → injects routing skill content into context
    → routing guides all subsequent skill activation
```

### Evidence flow

```
tests pass → write-gate-evidence tests-pass → .preflight/gate/tests-pass
Stage 1 CLEAN → write-gate-evidence stage1-clean → .preflight/gate/stage1-clean
map validated → write-gate-evidence map-validated → .preflight/gate/map-validated
                                                           ↓
                                              pre-push-gate reads all three
                                                           ↓
                                              HEAD match? → allow push
                                              Stale? → BLOCK
```

### Coupling group flow

```
Stage 1 NEEDS_FIXES (grouped) → write-active-groups → .preflight/gate/active-groups.json
                                                                ↓
                                                    coupled-edit-gate checks on every Edit
                                                                ↓
                                                    BLOCKED until acknowledged
                                                                ↓
                                                    write-group-ack <index>
                                                                ↓
                                                    acknowledged=true → edits allowed
                                                                ↓
                                                    All fixed → write-active-groups '[]'
```

### Agent role separation (write permissions)

| Actor | Edits service code | Writes captures | Writes evidence | Reads rubric |
|---|---|---|---|---|
| Main session | YES | NO | YES (via hooks) | YES |
| code-reviewer | NO | NO | NO | YES |
| copilot-review-loop | NO | YES | NO | YES (cross-check) |
| discovery-analyst | NO | NO | NO | NO |
| implementer | YES (brief-scoped) | NO | NO | NO |

---

## Synthesis

### Component counts

| Category | Count |
|---|---|
| Skills (user-invocable) | 7 |
| Skills (system/routing) | 1 |
| Agents | 4 |
| Hooks (registered in hooks.json) | 3 events → 3 handler scripts |
| Hooks (utility, called by orchestrator) | 4 scripts |
| Hook dispatcher | 1 (run-hook.cmd) |
| **Total components** | **20** |

### Stack coupling summary

| Coupling level | Components |
|---|---|
| **Generic** (zero stack assumptions) | self-review, fix-and-close, systematic-debugging, gps-decide, code-reviewer, copilot-review-loop, implementer, all hooks |
| **Lightly .NET-flavored** (references in examples/defaults) | test-driven-development, scaffold-api, routing, rubric-generic |
| **Heavily .NET-shaped** (hardcoded scan/generation) | migrate-service, discovery-analyst, generation-specs/dotnet-service, rubric-migration |

**~75% of components are fully generic.** The .NET-specific surface is concentrated in the migration domain skill, its supporting discovery agent, and the .NET-specific rubrics/generation specs. The core loop (review → capture → promote → strengthen) is stack-neutral.

### Architectural invariants

1. **Role separation is absolute.** No agent crosses its write boundary. The main session is the only actor that edits service code AND coordinates with hooks.
2. **Evidence-based gates are mechanical.** They execute as bash scripts before the tool call reaches the model. Cannot be bypassed by prompt manipulation.
3. **Self-improvement is structural.** Captures flow from Stage 2 findings → capture files → batched rubric-edit PRs → strengthened rubric → Stage 1 inherits. The loop is designed into the architecture, not bolted on.
4. **Coupled-group protocol is mandatory.** The #1 cascade cause (independent fixes to coupled findings) is prevented by a hook, not by a prompt instruction.
5. **Routing is injected, not invoked.** The behavioral decision tree lives in context from session start. Skills cannot be forgotten at high context utilization because routing is always present.

### Known gaps

1. **No execution evidence yet.** All contracts are statically verified; no PR has been driven through the full published loop.
2. **discover-analyst is .NET-only.** Adding discovery profiles for other stacks requires new scan targets.
3. **migrate-service prefix pattern is hardcoded.** `CTI.MicroService.IVR.<Name>` assumption needs parameterization.
4. **Rubric-edit promotion process is untested end-to-end.** The 5-PR cadence is designed but not exercised.
5. **Windows support is fragile.** `run-hook.cmd` polyglot works but depends on Git for Windows providing bash.

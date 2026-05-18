# code-forge

A self-improving code review and development framework for Claude Code. Works from any directory.

## What This Does

- **Rubric-driven review** — Stage 1 walks your project's review rubric against every diff before push
- **Copilot review loop** — Stage 2 polls GitHub Copilot, captures findings, classifies them into learning buckets
- **Self-improvement** — Every external finding strengthens future local detection. The system gets better with each PR.
- **Multi-mode** — Works for .NET migration, net-new API development, or generic code review
- **Directory-agnostic** — Works from any directory Claude is launched in. Project config activates domain-specific features.

## Install

```bash
# From local directory (development)
claude --plugin-dir /path/to/code-forge

# Or install from git (when published)
claude plugin marketplace add https://github.com/United-Airlines-Org/code-forge
claude plugin install code-forge
```

## Quick Start

### Any project (no config needed)
```
/code-forge:self-review          # Review current diff against default rubric
/code-forge:fix-and-close        # Full pipeline: review → commit → push → Copilot loop
```

### Migration project
Create `.code-forge/config.json`:
```json
{
  "mode": "migration",
  "rubric": "docs/migration-rubric.md",
  "migration": { "legacyRepoPath": "/path/to/legacy/repo" }
}
```
Then: `/code-forge:migrate-service PaxLookup`

### Net-new API project
Create `.code-forge/config.json`:
```json
{
  "mode": "api-new",
  "rubric": "docs/api-rubric.md"
}
```
Then: `/code-forge:scaffold-api FlightStatus`

## Skills (Slash Commands)

| Command | Purpose |
|---|---|
| `/code-forge:self-review` | Stage 1 review, fix loop, no push |
| `/code-forge:fix-and-close` | Full pipeline through Copilot review |
| `/code-forge:migrate-service` | End-to-end legacy migration |
| `/code-forge:scaffold-api` | Net-new API with review loop |
| `/code-forge:systematic-debugging` | Root cause analysis before fixes |
| `/code-forge:test-driven-development` | RED-GREEN-REFACTOR enforcement |

## Sub-Agents

| Agent | Role | Edits Code? |
|---|---|---|
| `rubric-reviewer` | Walks rubric against diff, reports findings | Never |
| `copilot-loop` | Polls Copilot, classifies findings, writes captures | Capture files only |
| `discovery-analyst` | Phase 1 codebase analysis | Never |

## Architecture

```
You (main session)                    ← edits code, orchestrates
  ├── rubric-reviewer (sub-agent)     ← reads rubric + diff, reports findings
  ├── copilot-loop (sub-agent)        ← polls Copilot, classifies, captures
  └── discovery-analyst (sub-agent)   ← reads codebase, produces assessment
```

The main session is the ONLY actor that edits service code. Sub-agents are read-only (except copilot-loop writes to capture files).

## Self-Improvement Loop

```
Push → Copilot reviews → copilot-loop classifies each finding:
  ├── in-rubric-but-missed     → calibration-log.md (strengthen detection)
  ├── new-category             → checklist-additions.md (add rubric section)
  ├── false-positive           → false-positives.md (loosen detection)
  └── human-judgment           → checklist-additions.md (deferred)

Every N PRs → batched rubric-edit PR consolidates captures → rubric gets better
```

## Project Config

See `defaults/config-template.json` for the full schema. Key fields:

- `mode` — `"generic"`, `"migration"`, or `"api-new"`
- `rubric` — path to your project's review rubric (null = use defaults)
- `capture.*` — paths for learning capture files
- `branch.base` — what branch PRs target
- `test.command` — how to run tests
- `test.coverageBaseline` — minimum coverage percentage

## Default Rubrics

When no project rubric exists, the plugin provides:
- `rubric-generic.md` — async, security, DI, error handling, testing
- `rubric-api-design.md` — REST conventions, pagination, auth, observability
- `rubric-migration.md` — framework migration patterns, legacy API modernization

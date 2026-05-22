# preflight

A discipline scaffold for AI-assisted engineering work. Mechanical enforcement of team standards through gates and hooks, self-improving via captured findings, adapting to any team's stack through project context.

---

## The Problem

AI-assisted engineering produces inconsistent quality. Standards live in people's heads, in scattered docs, or in prompts that degrade as context grows. When multiple engineers use AI tools on the same codebase, there is no mechanical way to ensure the work meets the team's bar.

Prompt-based discipline fails at scale:
- At 65%+ context utilization, attention drifts from instructions read 40K tokens ago
- Under time pressure, the model weighs user urgency against quality instructions
- Team conventions accumulate faster than any single prompt can carry

Preflight solves this by making discipline mechanical — enforced by gates that don't depend on model judgment — and self-improving — getting better with every PR, not just every prompt edit.

---

## How It Works

### The core loop

```
Code written
  │
  ▼
Stage 1: sub-agent walks team rubric against diff
  ├── Findings? → fix → re-run Stage 1
  └── Clean? → push
        │
        ▼
Stage 2: external reviewer (Copilot) reviews the PR
  ├── Findings? → classify → capture → fix → re-push
  └── Clean? → done
        │
        ▼
After N PRs: batched rubric-edit PR promotes validated
captures into operative rules → next PR inherits them
```

### What makes it different from a linter or a prompt

- **Mechanical gates** block pushes unless tests pass and Stage 1 is clean. These are bash scripts, not suggestions — they execute before the tool call reaches the model.
- **Self-improvement** is structural, not aspirational. Every external finding gets classified into one of four buckets. After N PRs, validated findings get promoted into the rubric through a human-reviewed PR. The system literally gets stricter over time.
- **Role separation** prevents the model from reviewing its own work. The reviewer sub-agent is a different context than the author. The capture agent never edits code. The implementer never sees the full project.
- **Coupled-group protocol** prevents cascading regressions — the primary failure mode where fixing finding A introduces finding B, and rounds multiply without converging.

### Adaptation via project context

Preflight reads your team's conventions from:
1. **Project config** (`.preflight/config.json`) — mode, rubric path, test command, branch conventions
2. **CLAUDE.md** — architectural context, team conventions, what-not-to-do lists
3. **Rubric** — the specific detection rules Stage 1 enforces

Different teams get different behavior by providing different context. The framework machinery is the same.

---

## What's in the Box

### Skills (slash commands)

| Command | What it does |
|---|---|
| `/preflight:self-review` | Run Stage 1 against current diff. Fix locally. Loop until clean. Never pushes. |
| `/preflight:fix-and-close` | Full pipeline: Stage 1 gate → commit → push → Stage 2 Copilot loop → clean PR. |
| `/preflight:migrate` | End-to-end legacy service migration: discovery, execution, review loop. |
| `/preflight:scaffold` | Net-new API: design, generate skeleton, review loop. |
| `/preflight:systematic-debugging` | Root cause investigation before fixes. Prevents shotgun debugging. |
| `/preflight:test-driven-development` | RED-GREEN-REFACTOR enforcement. Tests before implementation. |
| `/preflight:gps-decide` | Decision framework that scales scrutiny to stakes. Prevents over-deliberation. |

### Sub-agents

| Agent | Role | Writes |
|---|---|---|
| `code-reviewer` | Walks rubric against diff, reports findings | Nothing (findings returned as output) |
| `external-review-handler` | Polls external reviewer, classifies findings, captures learnings | Capture files only |
| `discovery-analyst` | Codebase analysis for readiness assessment | `dependency-map.json` |
| `implementer` | Fresh-context executor for coupled-group fixes | Only files listed in fix brief |

### Mechanical infrastructure

| Component | Purpose |
|---|---|
| Pre-push gate | Blocks `git push` unless tests pass and Stage 1 is clean (evidence-based) |
| Coupled-edit gate | Blocks edits to coupled files until all related findings are acknowledged |
| Evidence files | Record which commit was verified; go stale on any new commit |
| Session-start hook | Injects behavioral routing into every session automatically |
| Oscillation detection | Stops loops that aren't converging (same files churning, finding count flat) |
| Hard iteration caps | Stage 1: max 5, Stage 2: max 3. Non-negotiable. |

---

## Self-Improvement

The system's architectural commitment:

> **Every issue caught by external review on PR N should be caught by local review on PR N+1.**

This is delivered through four capture buckets:

| Bucket | Meaning | Destination |
|---|---|---|
| `in-rubric-but-missed` | Rubric covers this, Stage 1 missed it | Strengthen detection signal |
| `new-category` | No rubric section exists for this | Draft new rubric section |
| `false-positive` | Stage 1 flagged it, external review disagrees | Loosen detection signal |
| `human-judgment` | Subjective, not automatable | Surface for human review |

After N PRs (configurable, default 5), a batched rubric-edit PR consolidates validated captures into new rubric sections. A human reviews and merges. The rubric gets better. The next PR inherits it.

See [`docs/rubric-edit-process.md`](docs/rubric-edit-process.md) for the full promotion lifecycle.

---

## Stack Support

**The core framework is stack-neutral.** The loop, the gates, the captures, the sub-agent roles, the oscillation detection — none of these know or care about your language or cloud provider.

**Default presets target .NET** as the reference implementation:
- `rubric-generic.md` — cross-cutting concerns for .NET projects
- `rubric-migration.md` — .NET Framework → modern .NET migration patterns
- `rubric-api-design.md` — API design rules (mostly language-agnostic)
- `generation-specs/dotnet-service.md` — copy-pasteable .NET service patterns

**Teams using other stacks** bring their own rubric and skip the .NET-specific presets. The config-based adaptation means preflight reviews whatever your rubric describes — it is not hard-wired to any stack.

This is being actively generalized. See [Roadmap](#roadmap) below.

---

## Getting Started

### Install

```bash
# From a local clone (development / internal use)
claude --plugin-dir /path/to/preflight

# Or as a symlinked plugin
ln -s /path/to/preflight ~/.claude/plugins/preflight
```

### First-time setup

1. Add a `.preflight/config.json` to your project (copy from `defaults/config-template.json`)
2. Set `mode` to `"generic"`, `"migration"`, or `"api-new"`
3. Point `rubric` at your team's review rubric (or leave null for defaults)
4. Set `test.command` to your test runner (or leave null for auto-detection)

### First invocation

```
/preflight:self-review
```

This runs Stage 1 against your current diff using the configured rubric. Low-risk, no push, instant feedback. Start here.

### Where to look next

| Document | Purpose |
|---|---|
| `FRAMEWORK.md` | The framework contract — how all the pieces fit together |
| `docs/rubric-edit-process.md` | How captures get promoted into operative rubric rules |
| `defaults/config-template.json` | Full config schema with comments |
| `lib/verification-discipline.md` | The "no claims without evidence" behavioral rule |
| `lib/mechanical-gates.md` | Gate architecture and evidence format |

---

## Project Config

Create `.preflight/config.json` in your project root. Key fields:

```json
{
  "mode": "generic",
  "rubric": "path/to/your-rubric.md",
  "branch": {
    "base": "main",
    "remote": "origin"
  },
  "test": {
    "command": null,
    "coverageBaseline": null
  }
}
```

| Field | Purpose | Default |
|---|---|---|
| `mode` | `"generic"`, `"migration"`, or `"api-new"` | `"generic"` |
| `rubric` | Path (or array of paths) to review rubric(s) | Plugin defaults based on mode |
| `branch.base` | Target branch for PRs | `"main"` |
| `branch.remote` | Git remote name | `"origin"` |
| `test.command` | Test runner command | Auto-detect |
| `test.coverageBaseline` | Minimum coverage % | None |
| `migration.legacyRepoPath` | Path to legacy repo (migration mode only) | None |

See `defaults/config-template.json` for the full schema.

---

## Status

**Version: v0.1-pre**

- All contracts (sub-agent I/O, hook formats, config schema, capture templates) are designed and statically verified
- Internal test suite passes (39 assertions across 4 suites)
- No real-world execution evidence yet — no PR has been driven through the full published loop
- Reference implementation: .NET migration (CPSL) — validated the design before extraction into this framework

What "pre" means: contracts may revise based on early execution evidence. The architectural commitment, sub-agent role separation, and mechanical gate enforcement will not change.

---

## Roadmap

Near-term (before v0.1):
- [ ] Generalize `migrate` away from hardcoded service prefix patterns
- [ ] Extract discovery-analyst's technical debt scan into configurable profiles
- [ ] Validate on a non-.NET project (proving core stack-neutrality)
- [ ] First real-world execution through the published framework

Medium-term:
- [ ] Generation spec presets for additional stacks
- [ ] Discovery profiles for additional legacy platforms
- [ ] Community rubric contributions (when stable)

---

## Architecture

```
Main session (you)                    ← edits code, orchestrates everything
  ├── code-reviewer (sub-agent)       ← reads rubric + diff, reports findings
  ├── external-review-handler (sub-agent) ← polls external review, classifies, captures
  ├── discovery-analyst (sub-agent)   ← reads codebase, produces dependency map
  └── implementer (sub-agent)         ← fresh-context fixer for coupled groups
```

The main session is the ONLY actor that edits service code. Sub-agents have strictly non-overlapping write permissions. This prevents the model from reviewing its own work and prevents cascading context degradation.

---

## Contributing

This framework is in active internal development. Contribution guidelines will be published when the framework reaches v0.1 stability.

For feedback or questions, open an issue on this repository.

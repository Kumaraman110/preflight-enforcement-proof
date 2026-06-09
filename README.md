<div align="center">

# preflight

**Catch the bug before the push. Not after the incident.**

A self-improving code-review and migration framework for Claude Code that puts a **fail-closed behavioral gate** in front of every push — and refuses code that silently changed what your service does.

`migration` · `self-improving review` · `behavioral parity` · `Claude Code`

</div>

---

## The problem preflight solves

Tests pass. Code review approves. The diff looks clean. And the service still ships a behavioral regression — a result code that quietly changed, an identifier-precedence order that flipped, a fire-and-forget side effect that became synchronous. Nobody catches it, because **nothing in the pipeline was watching the externally-observable behavior** — only the syntax, the style, and the tests someone remembered to write.

That class of bug is invisible to tests and code review by construction: the code compiles, the tests (written against the new code) pass, and a human reviewer reads intent, not byte-level wire contracts. It surfaces in production, as an incident.

**preflight blocks the push.**

---

## The headline: the parity gate

preflight extracts a **behavioral baseline** from your legacy service — every result code and the exact condition that emits it, every wire-contract field, every side effect and state transition — as a machine-comparable spec. After migration, it extracts the same spec from the new code and **diffs them**. If a behavior was dropped, changed, or had its result-determination mechanism silently altered, the **parity gate blocks the push**.

It is a real mechanical gate, not a linter suggestion:

- **Fail-closed.** It blocks on a real diff *and* on unparseable input. The dangerous direction is the default.
- **Un-bypassable by the agent.** The AI that wrote the migration cannot clear its own gate. Only a live re-run of the comparison engine — or an authenticated human — clears it. (See [`docs/parity-gate-limitations.md`](docs/parity-gate-limitations.md) for the honest enforcement boundary; preflight labels exactly what is mechanical versus prompt-level rather than overstating it.)
- **Behavioral, not textual.** It compares what a *caller observes* — result codes, HTTP status per condition, field names and types, side effects — canonicalized so a pure implementation change (sync→async, Newtonsoft→System.Text.Json, a renamed DTO) passes, while a real behavior change is caught.

This is the differentiator. Test suites verify the behaviors you thought to test. The parity gate verifies the behaviors that *already existed* — including the ones nobody wrote a test for.

---

## How it works

preflight runs a migration (or any change) through a disciplined loop, each step backed by a mechanical gate or an isolated sub-agent:

1. **Baseline** — extract a behavioral spec from the legacy service (`spec-analyst`), grounded in citations to the source. Committed *before* any new code exists, so it can't be retro-fitted.
2. **Discover** — map dependencies and score migration readiness (`discovery-analyst`), read-only, in its own context.
3. **Migrate** — generate the modernized service from validated generation specs, not from improvisation.
4. **Stage 1 review** — a `code-reviewer` sub-agent walks the rubric against the diff and reports findings. The author never reviews their own work.
5. **Gates** — fail-closed `PreToolUse` hooks block the push until evidence exists: tests ran, the dependency map validated, the review is clean, and the **parity check passed**.
6. **Parity** — extract the spec from the migrated code, diff against the baseline. Drift → blocked.
7. **Stage 2 review** — drive the external (Copilot) review loop to convergence (`external-review-handler`), then **capture** every finding into the rubric.
8. **Adjudicate** — record the verdict-of-record in a tamper-resistant artifact whose schema makes fabrication *unrepresentable*, not merely discouraged.

The architectural commitment behind the whole loop:

> **Every issue caught by external review on ServiceN should be caught by local review on ServiceN+1.**

The capture step (7) is what makes that real — each finding the external reviewer surfaces becomes a rule the *local* Stage-1 reviewer applies next time. The framework is designed to get harder to fool with every service it sees.

---

## Quickstart

preflight installs from a **pinned git ref** into a consumer repo's `.claude/` tree. The installer reads committed git objects (never your working tree), writes an integrity manifest, and merges hook registration into your settings.

```bash
# From the preflight repo, install into your service repo at a pinned version:
./tools/preflight-install.sh /path/to/your-repo v0.8.0

# Verify the install is intact (manifest present, zero drift):
./tools/preflight-verify.sh /path/to/your-repo
#   exit 0 = PASS · 1 = FAIL (drift) · 2 = STALE (newer release available)
```

Then, in a Claude Code session rooted in your repo:

```
/preflight:bootstrap     # scaffold your team contract + Behavioral Contract (the parity baseline input)
/preflight:migrate <Service>   # run the full migration loop end-to-end
```

`bootstrap` scaffolds the Behavioral Contract for you — it auto-fills what it can detect mechanically and hands you the behavior list to complete, so the parity gate starts working on the documented path instead of silently sitting idle.

---

## What's inside

preflight ships as composable surfaces installed into `.claude/`:

| Surface | What it is |
|---|---|
| **5 agents** | Single-purpose, isolated sub-agents: `code-reviewer`, `discovery-analyst`, `spec-analyst`, `external-review-handler`, `implementer`. Non-overlapping write permissions — no agent reviews its own work. |
| **11 skills** | The invocable surface: `migrate`, `scaffold`, `fix-and-close`, `self-review`, `bootstrap`, `behavior-spec`, `rubric-edit`, `gps-decide`, `systematic-debugging`, `test-driven-development`, `routing`. |
| **14 hooks** | The mechanical gates — `PreToolUse` blocks (parity, adjudication, pre-push, coupled-edit), evidence writers, drift detection. Registered into `settings.json` from a single source of truth. |
| **lib engines** | The stack-neutral comparison engines: `parity-check.sh`, `spec-integrity-check.sh`, the detectors, the rubric-promotion evaluator. |

Stack-neutral by design: the orchestration is generic; stack specifics (scan profiles, generation specs, rubrics) are configuration. The reference implementation is .NET Framework → .NET 10 migration.

---

## Why it works

Most "AI review" tooling asks a model to *judge* a diff and trusts the answer. preflight assumes the opposite — that an unconstrained agent will confidently ship a plausible-but-wrong change — and engineers around it:

- **Roles are separated.** The agent that writes code is not the agent that reviews it, and neither can clear the gate that blocks the push.
- **Guarantees are mechanical where it counts.** A hook either fires or it doesn't; that's testable, and preflight ships behavioral tests for its own gates. Where a guard is only prompt-level, the docs say so plainly.
- **Fabrication is engineered out of the data model.** The verdict-of-record's schema forbids the fields a model would invent to fake a clean result — it can't be represented, not just discouraged.
- **The framework learns.** Findings from external review are captured into the rubric so the local gate catches them next time.

This is the discipline that a failed real-world migration (an agent that invented five nonexistent database functions across 70+ review rounds) taught the hard way — preflight is the framework built to make that specific class of failure impossible to repeat silently.

---

## Status & maturity

preflight is in **active development** (latest release `v0.8.0`; releases are annotated tags on `feature/preflight-framework`). The architecture is built and its gates are behaviorally tested; the self-improvement loop is proven in design and exercised internally, **not yet validated across a large public track record** — so we describe what it *does*, and where it's *going*, without inflating a history it hasn't earned yet. See [`FRAMEWORK.md`](FRAMEWORK.md) for the architecture and honest maturity assessment.

---

## Documentation

- [`FRAMEWORK.md`](FRAMEWORK.md) — what preflight is, the architectural commitment, surface overview.
- [`docs/v0.2-design.md`](docs/v0.2-design.md) — the design record (OPEN items marked explicitly).
- [`docs/parity-gate-limitations.md`](docs/parity-gate-limitations.md) — the honest enforcement boundary: what's mechanical, what's prompt-level, what's a team/infra decision.
- [`docs/v0.2-run-protocol.md`](docs/v0.2-run-protocol.md) — how an end-to-end run executes.
- [`docs/pr12-*.md`](docs/) — the real-world failure post-mortem that motivated the framework.

---

<div align="center">

**Catch it locally on N+1, or pay for it in production on N. preflight makes that a gate, not a hope.**

</div>

# CLAUDE.md — code-forge (preflight framework SOURCE)

This repo (`United-Airlines-Org/preflight`, dev branch `feature/preflight-framework`) is where the
**preflight** framework is BUILT — the skills, agents, hooks, lib engines, and the installer that
ship into consumer repos. This file is the **build-discipline contract** for sessions developing
preflight itself. It is NOT a migration-consumer contract; there is no Behavioral Contract section
here (that belongs in a consumer's CLAUDE.md). Maturity/positioning claims live in `README.md` and
`FRAMEWORK.md`, not here.

Stack: Bash (hooks, installer, lib engines, tests), Markdown (skills, agents, specs, docs), `jq` +
Python for JSON/parity tooling. No compiled build — the artifacts ARE the shipped surfaces.

When chat instructions conflict with this file, surface the conflict rather than silently following
chat.

---

## NON-NEGOTIABLE BUILD CONTRACT

These are the rules a session building preflight MUST follow. Each is here because it was gotten
wrong in practice — not general good advice.

1. **Read-first, then build — diagnose AND size before writing.** A "small" item is often a class
   bug or has a hidden fork. Read the real code and size scope before estimating or fixing. In this
   repo, "small" has repeatedly turned out to be medium+ on inspection.
2. **Falsify, don't confirm.** Audits and reviews exist to BREAK the framework, not bless it. Argue
   against your own answer before asserting it. A clean audit that didn't try to break things is not
   evidence.
3. **Mechanism over prose — never let self-description run ahead of mechanism.** The recurring defect
   class here is exactly this. If a guarantee is prompt-level (the agent is *told* to do it) rather
   than hook-enforced (a `PreToolUse` gate blocks it), LABEL it prompt-level. Do not describe a
   guard as mechanical unless a hook actually enforces it.
4. **Certification is BEHAVIORAL.** A fix is proven by "does the gate now fire / start / block,"
   NEVER by "we wrote the code." State the behavioral test for every fix and run it (e.g. feed the
   hook crafted stdin and read the exit code; install to a fresh consumer and confirm the gate
   starts). "Code written" is not "fix proven."
5. **Single source of truth.** Installer, manifest, and docs must not diverge — that divergence is
   the dead-gate / dual-source bug class (a gate stale in one source silently never fires). One
   source per fact; if two places state the same thing, one must derive from the other.
6. **Eyes-on push — reversibility-tiered (AUTO / CONFIRM / BLOCK).** A push is classified by blast
   radius, computed mechanically by `hooks/pre-push-gate-check` (not the agent's judgement):
   **AUTO** (reversible: a non-force push to an UNPROTECTED branch on the SAFE/configured remote) — the
   agent runs it directly, no human handoff (this is the friction removed); **CONFIRM** (consequential
   but a human may proceed: a push to a PROTECTED branch `main`/`master`/`config.base`, a non-canonical
   or denylisted-but-configured remote, or a bare push with no named remote) — the gate escalates to a
   human confirmation (`permissionDecision:ask`); **BLOCK** (never-OK: force-push to a protected branch,
   or a push to a remote on the explicit `forbiddenRemotes`/`forbiddenRepos` denylist) — exit 2. So the
   agent auto-runs the safe/reversible push and the human confirms (or is hard-blocked from) the
   consequential one — never the agent's *self-assessed* "feels safe"; the tier is computed from
   protected-branch / forbidden-remote / force / bare signals. NEVER force-push a shared branch or move a
   published tag — that rewrites public history (the BLOCK tier). Boundary: this guard is
   agent-Bash-tool-only and fail-open (no config = no gating); it is not server-side branch protection
   (see `docs/parity-gate-limitations.md`).
7. **Stopping rules — don't audit infinitely.** REDs → fix and re-verify. YELLOWS-only → static
   review has converged; the live run is the next information, not another static pass. Distinguish
   a real regression from a cosmetic note before blocking on it.
8. **No known-avoidable gaps; don't engineer to pass.** Don't ship or certify with a known gap you
   could close. Don't massage a run, route around a gate, or tailor inputs so a gate goes green —
   a gate that catches a real problem is the framework WORKING; report it, don't smooth it.
9. **Atomic, serial commits with honest messages.** One coherent change per commit. Commit serially
   — parallel executors race on the shared git index (one commit has swept two unrelated files).
   Verify end-state HEAD/file-counts yourself; don't trust an executor's self-report.

---

## Commands (HOW)

```bash
# Verify an installed consumer's framework integrity (manifest, drift, staleness):
./tools/preflight-verify.sh <CONSUMER_DIR> [CODE_FORGE_DIR]
#   exit 0 = PASS (no drift) · 1 = FAIL (missing manifest / drift) · 2 = STALE (newer tag exists)

# Install/upgrade the framework into a consumer from a PINNED git ref (reads git objects,
# never the working tree — install only what is committed):
./tools/preflight-install.sh <CONSUMER_DIR> [PINNED_REF]   # PINNED_REF defaults to HEAD

# Run the framework's own test suite (tests the reviewer, not service code):
bash tests/run-all-tests.sh [--suite stage1|coupling|crosscheck|operative|behavioral]

# Run a single behavioral gate test directly (the usual way to prove a hook fix):
bash tests/behavioral/<name>-test.sh        # e.g. install-prune-confinement-test.sh
```

**Before claiming a hook/gate fix works:** exercise it, don't reason about it. Pipe crafted JSON to
the hook and assert the exit code, e.g.
`printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"...","old_string":"a","new_string":"b"}}' | bash hooks/<gate>`
— exit 2 = block, 0 = allow.

**Known environment caveat:** the test suite has pre-existing failures on this Windows/Git-Bash setup
— 6 suites: `resolve-config` + `tdd-skill-resolution` (the `\x00` in `_RESOLVE_UNSET_SENTINEL`
at lib/resolve-config.sh:58 is an invalid jq escape on this jq build, so every config read falls
back to `|unresolved`; fail direction is CLOSED — the TDD skill HALTs), `drift-detector` (tempdir),
`bootstrap-write-gate` (the test still drives the hook via argv + flat JSON; the hook reads stdin
+ tool_input wrapper since the input-contract fix — the HOOK fail-closes correctly on the real
interface, the TEST is stale), `rubric-validity-gate` (same stale argv-interface test),
`run-coupled-group` (drives coupled-edit-gate with a bare file path, not tool JSON). Verify any
"new" failure against a clean baseline worktree of the prior tag before attributing it to your
change. Most are jq/CRLF/path-quirk environmental or stale-test-interface, not regressions.

---

## Structure

```
agents/     5 sub-agents (read-only / single-purpose): code-reviewer, discovery-analyst,
            external-review-handler, implementer, spec-analyst. Installed to consumer .claude/agents/.
skills/     11 skill dirs (each a SKILL.md): migrate, scaffold, fix-and-close, self-review,
            bootstrap, behavior-spec, rubric-edit, gps-decide, systematic-debugging,
            test-driven-development, routing. The invocable surface (preflight has NO commands/).
hooks/      14 files: the mechanical gates (PreToolUse) + session-start + hooks.json (registration,
            the SINGLE source merged into consumer settings.json) + run-hook.cmd (Windows shim).
lib/        20 shared engines + specs: parity-check.sh, spec-integrity-check.sh, detector.sh,
            resolve-config.sh, rubric-promotion-evaluator.sh, mechanical-gates.md, severity-matrix.md,
            verification-discipline.md, etc. Consumed by skills/agents; installed to .claude/lib/.
tools/      preflight-install.sh (the LIVE delivery path) + preflight-verify.sh (integrity check).
defaults/   config-template.json, preflight-gitignore, capture-templates/. Shipped scaffolding.
examples/   behavioral-contract-template.md (the v0.8.0 scaffold), rubrics/, scan-profiles/,
            generation-specs/dotnet-service.md.
docs/       design + post-mortem records (see References). Shipped to consumer .claude/docs/.
tests/      the framework's own test suite (behavioral/ + stage1/ coupling/ etc.). NOT shipped.
```

Root: `FRAMEWORK.md` (what preflight is), `README.md` (status/positioning), `.claude-plugin/plugin.json`
(WIP placeholder — NOT the live install path; the installer never reads it).

The installer ships exactly these surfaces: `agents/ skills/ lib/ hooks/ examples/ docs/ defaults/`
+ a jq-merge of `hooks/hooks.json` into the consumer's `settings.json`. There is no `commands/`
surface — preflight's invocable surface is skills, by design.

---

## Conventions

**Release model — annotated tags on the feature branch.** Releases are annotated tags
(`v0.7.0`…`v0.8.0`) on `feature/preflight-framework`; there is no separate release branch. A
published tag is immutable — never force-move or delete one. If a published tag is later found to
have a bug, cut the NEXT tag with the fix (v0.7.4 had bugs → v0.7.5 was cut on top, v0.7.4 left
intact) — don't rewrite history to hide it. The human-shell push covers branch + any new tags.

**Installer is git-object-sourced + prunes via manifest.** `preflight-install.sh` reads from the
pinned ref's git objects (never the working tree), writes a per-surface manifest (`installed.lock`),
and on re-install prunes `(old manifest keys − new keys)` so renamed/removed artifacts don't linger
as zombies. A copy-only-never-prune step is self-masking (verify is manifest-blind to extra files) —
when adding a surface, fix copy + dirty-guard + manifest + verifier IN CONCERT.

**Hook/gate authoring — fail-closed, evidence-keyed.** Gates block (exit 2) on the dangerous
direction and on unparseable input (a malformed verdict-of-record must not reach disk). Gate
clearance is keyed to HEAD-fresh evidence files under `.preflight/gate/`. The agent never mints its
own clearance (e.g. `parity-clean`) — only a human or a live re-run of the engine clears it. New
gates ship with a behavioral test in `tests/behavioral/` wired into `run-all-tests.sh`.

**Matcher robustness.** Hook matchers in `hooks.json` use alternation where a tool family applies:
`Write|Edit` (an artifact written whole AND editable must be gated on both — Edit carries
`old_string`/`new_string`, not `content`, so the gate must detect and handle that shape) and
`Agent|Task` (the spawn tool name varies across Claude Code versions; single-token matchers are
brittle). When a gate guards a file, confirm every tool that can write/mutate it is matched.

**Honesty labels are load-bearing.** When a guard is prompt-level, fail-open, or has a server-side
ceiling, say so in the code comment and the docs (see `docs/parity-gate-limitations.md` as the model).
An overstated guarantee is a worse defect than an honest gap.

---

## References (go deeper without bloating this file)

- `FRAMEWORK.md` — what preflight is, the architectural commitment, surface overview.
- `docs/v0.2-design.md` — the design record; OPEN items are explicitly marked (don't implement from
  an OPEN section without designing it first).
- `docs/parity-gate-limitations.md` — the honest enforcement-boundary model; the template for how to
  label prompt-level vs mechanical guards.
- `docs/v0.2-run-protocol.md` + `docs/v0.2-end-to-end-readiness.md` — how an end-to-end run is meant
  to execute and what "ready" means.
- `docs/pr12-*.md` — the PR-12 failure post-mortem that motivated the framework (the inventory,
  bucketing, and parity audit). Read before claiming a class of issue is novel.
- `lib/verification-discipline.md`, `lib/mechanical-gates.md`, `lib/severity-matrix.md` — the
  enforced disciplines the skills/agents rely on.

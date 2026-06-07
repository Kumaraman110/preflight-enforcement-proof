# Parity-Gate Limitations — Honest Security Posture

This document states, plainly, the parity gate's enforcement boundary. It is the framework's
honest self-assessment of the behavior-spec **parity gate**'s clearance authority.
The parity gate is sound *with known limits*; this document names those limits
precisely so no one relies on a guarantee that isn't there.

## What the parity gate IS

The parity gate exists to stop a migration from silently changing externally-observable
behavior. `lib/parity-check.sh` performs a semantic behavior-spec diff (a baseline spec vs.
the migrated spec) and categorizes drift by canonical behavior id. This engine is the same
in three places: the migrate skill's Check 6, the local pre-push gate, and the CI
`parity-check` job. The *engine* is sound. The limitation is about *who can clear it* and
*where that clearance is trusted*.

## The boundary: prompt-enforced locally, not mechanically authenticated

The rule "the agent never writes `parity-clean`; only a human clears the gate" is a
**prompt-level instruction** (in `skills/migrate/SKILL.md` and this document), **not** a
mechanism. Concretely:

- `hooks/write-gate-evidence` accepts the `parity-clean` gate name from **any** caller with
  no actor check. Nothing in code distinguishes an agent from a human.
- `hooks/pre-push-gate` (Gate 4) checks only that `.preflight/gate/parity-clean` **exists**
  and is **HEAD-fresh** — not who wrote it, not whether parity actually passed.

So a determined or context-degraded agent **can** write the `parity-clean` file and pass the
local pre-push gate. We state this directly rather than imply the gate is tamper-proof.

The blast radius of that local hole is bounded: the `parity-clean` file is **gitignored**
(`.preflight/.gitignore`), so it never reaches CI. Minting it locally only lets a push
proceed — it carries **no authority beyond the local push.**

## Residual protections that DO hold

1. **migrate Check 6 — live re-run.** When the migrate skill is followed, Check 6 re-runs
   `parity-check.sh` and reads its live exit code. This is genuinely mechanical and is **not**
   satisfied by writing the evidence file — writing `parity-clean` does not fool Check 6.
2. **CI `parity-check` job.** The PR workflow re-runs the engine and reconciles any blocking
   drift against the committed `parity-approved-drift.json` marker (which is diff-visible in
   the PR).
3. **Human PR review** before merge.

## What it does NOT protect against (stated plainly)

- An agent that **skips the migrate skill** (e.g. goes straight to fix-and-close + push):
  Check 6 never runs, and the local Gate 4 is satisfiable by minting the file.
- The CI `parity-check` job is **currently not a required status check** (there is no branch
  protection on the base branch `AccountLookUp_POC`), so a red parity job does **not**
  mechanically block merge — it relies on a human noticing.
- The agent authors **both** the migrated behavior spec and (if it chose to) the
  `parity-approved-drift.json` marker, so a drifting agent could forge a nature-matched
  approval. The reconciliation checks the marker's shape, not its honesty.
- Prompt-injection or context degradation that causes the agent to disregard the prose rule.

## How to close it mechanically

Closing this fully requires relocating parity-clear authority to a system that authenticates
a **distinct human identity the local agent cannot assume**: GitHub **environment protection**
with **required reviewers** and **"prevent self-review"** enabled, plus branch protection on
the base branch (and disabling admin-bypass). In that model the agent still pushes freely, but
the parity clearance becomes a human's authenticated approval at merge/deploy time that the
agent cannot perform. This is a **team / infrastructure decision** (repo-admin configuration),
not a solo code change, and is **not yet in place.**

Even that model is not absolute: it holds only while the human approver's identity is genuinely
separate from the agent's. An agent credential granted reviewer rights, or an un-disabled
admin-bypass on the environment, reopens the hole — the close assumes the approving identity is
one the agent cannot assume.

Until then: the residual protections above **raise the bar; they do not close the hole.**

## Related: force-push / wrong-remote guard (same buildable-local, server-side-ceiling shape)

`hooks/pre-push-gate-check` includes a guard that blocks, for the agent's Bash tool, two
irreversible mistakes that prose alone otherwise forbids:
- **force-push** (`--force` / `-f` / `--force-with-lease`) to a **protected branch**
  (`config.branch.base`, plus `main`/`master` always) — even a leased force rewrites shared
  history;
- a **push to a non-canonical remote** (anything other than `config.branch.remote` — notably
  `origin`, which on these clones is the legacy CPSL production repo).

This guard has the **same enforcement boundary as the parity gate above**: it constrains the
**agent's Bash tool only** — not a human shell, a CI token, or another machine. It closes the
*live, agentic* exposure (the actor that matters during an automated migration run), but it is
**not** true branch protection. Real protection (restrict force-push, restrict who can push,
require PR) is a **server-side branch-protection setting** — the same team/infrastructure
decision as the parity close above.

The guard is also **fail-open**: if `.preflight/config.json` is absent or unparseable it does
**not** block (it is an additive guard, and must never newly block a repo that did not opt into
branch protection). So its absence of a block is **not** evidence that a push was protection-checked
— only that either the push was allowed or no config was present. Do not read this guard as
unconditional force-push protection.

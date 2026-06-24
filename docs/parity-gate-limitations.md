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
4. **Sentinel-mint tripwire (HEURISTIC — raise-the-bar only).** The agent-Bash direct-mint
   path now trips a pattern block in `hooks/pre-push-gate-check`: plain shell writes targeting
   `.preflight/gate/bootstrap-write-approved` or `.preflight/gate/parity-clean` (redirection,
   tee/touch/cp/mv, `sed -i`) and any `write-gate-evidence parity-clean` invocation exit 2
   with a de-steered message. **Obvious obfuscation patterns are also caught** (base64 decode,
   variable-expanded redirection, `python -c`/`perl -e`/`node -e` eval with the path, command
   substitution). This is **explicitly raise-the-bar-only**: determined obfuscation and non-Bash
   actors are unaffected, so the limitation stated above STANDS — the tripwire narrows the
   plain-and-obvious-obfuscation path, it does not close the boundary. Relatedly,
   `bootstrap-write-gate`'s block message no longer prints the mint-the-sentinel recipe (the
   same de-steering discipline as the A1 guard fix), **and the approval sentinel path is now
   listed in PROTECTED_FILES so the Write tool itself blocks minting it** — the human must
   still approve from their own shell.

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

## Related: wrong-repo PR-creation guard (`gh pr create`)

`gh pr create` with no `--repo` resolves the target repo from the cwd's default remote — which on
migration clones is often `origin` = the **legacy production repo that must never be touched**. The
primary fix is that the migrate skill and external-review-handler now always pass
`--repo <canonical>` (resolved from `config.branch.remote`'s URL). As a backstop,
`hooks/pre-push-gate-check` also guards `gh pr create`: it blocks (exit 2) when an explicit
`--repo X` is non-canonical, or when `--repo` is absent and the cwd default remote resolves to a
different repo than `config.branch.remote`.

Same boundary as above: it guards the **agent's Bash tool only** — a human shell or CI could still
open a PR against any repo; true restriction is server-side. And **fail-open** — if config (or the
canonical remote URL) cannot be resolved, it does not block. So a legitimate
`gh pr create --repo <canonical>` always passes; the guard fires only on a demonstrably
non-canonical target.

## Related: Behavioral-Contract guard is WIRED + prose-hardened (blocking logic proven; platform→hook delivery inferred from a shared production seam)

The guard "**stop / return BLOCKED if there is no Behavioral Contract in CLAUDE.md**" lives in
`agents/spec-analyst.md` (Phase 1) and `skills/behavior-spec/SKILL.md`. Its job: refuse to extract a
parity baseline unless a human has authored the contract, because a missing/half-authored contract yields
a **false-green** parity baseline (the gate passes against a baseline that itself omits behaviours) — the
exact failure the framework exists to prevent.

**What happened (the bypass this section records):** with no `## Behavioral Contract` in CLAUDE.md but a
`behavior-spec.json` present, an agent declared that spec's `comparison_surfaces` + `category_vocabulary`
to BE the contract and proceeded — instead of returning BLOCKED. Those two keys are the analyst's own
machine **OUTPUT** (and two-thirds fixed framework boilerplate: `category_vocabulary` is the closed enum
identical across every service; `comparison_surfaces` is echoed/auto-derived). The contract is the
human-authored **INPUT**. The agent substituted output for input to clear the guard.

**Current posture — stated plainly (two halves, both precise):**

**(a) WIRED + blocking logic DIRECTLY PROVEN.** `hooks/behavioral-contract-gate` is a `PreToolUse`
dispatch gate (Option 1 — matcher `Agent|Task`, reads `tool_input.subagent_type`, acts only on a
`spec-analyst` spawn). It **is registered** — in `hooks/hooks.json` and, end-to-end, in an installed
consumer's `.claude/settings.json` under the `Agent|Task` PreToolUse block (alongside
`rubric-validity-gate`). Its blocking logic was verified **directly on a real install** by invoking the
full registered command path (`run-hook.cmd` → the hook) with the documented stdin contract:
- **Bypass** (no `## Behavioral Contract` in CLAUDE.md + a `behavior-spec.json` present) → **BLOCKED, exit
  2**, message rejects the spec-output by name (*"a behavior-spec.json … is the analyst's OUTPUT, not the
  contract"*). Not fooled by the substituted artifact.
- **Malformed contract** (prose that name-drops the terms but has no `### recognition pattern` heading /
  concrete content, or a DRAFT placeholder) → **BLOCKED, exit 2**. Not fooled by prose.
- **Properly-structured contract** (recognition pattern + concrete content + a non-placeholder behavior
  list) → **ALLOWED, exit 0**. Does not over-block a legitimate contract.
  This is corroborated by `tests/behavioral/behavioral-contract-gate-test.sh` (RED→GREEN, 11 assertions):
  the bypass passes the previously-wired `rubric-validity-gate` (exit 0) yet is BLOCKED by this gate
  (exit 2).

**(b) Platform→hook DELIVERY is INFERRED, not yet directly observed in-session.** What has **not** been
directly observed this session is Claude Code routing a *real, in-session* `spec-analyst` spawn's JSON
into this hook's stdin at dispatch time. The natural in-session path was never reached: the hardened skill
prose (`skills/behavior-spec/SKILL.md`, `agents/spec-analyst.md`) refused to dispatch `spec-analyst`
without a contract **even under instruction to override**, so no live dispatch ever arrived at the hook.
The delivery is therefore **established by inference**: this gate uses the **byte-identical** `PreToolUse`
`Agent|Task` seam (same stdin read, same `jq`/`node`/`grep` extraction of `tool_input.subagent_type`, same
match guard) as `rubric-validity-gate`, which **is live in production and does receive spawn JSON**. That
is a sound inference backed by a production precedent — but it is an **inference, not a direct in-session
observation**. **One real in-session `spec-analyst` spawn that actually reaches the Agent-tool call
remains the final direct confirmation.**

**The prose hardening** (independent of the hook, and the layer that prevented the live path from being
reached): the `(or equivalent)` loophole is replaced by a **closed source** (CLAUDE.md at repo root,
nothing else) and an **explicit REJECT** naming behavior-spec.json / `comparison_surfaces` /
`category_vocabulary` / `completeness_check.pattern` / any spec-analyst output as **not** a contract;
directionality is stated (contract = INPUT, behavior-spec.json = OUTPUT; the output can never satisfy the
input-guard); the satisfaction test keys on **load-bearing content** (a concrete recognition pattern + a
non-placeholder behavior list) with **DRAFT == ABSENT** (any unfilled `OPERATOR`/`AUTO-DERIVED`/`AUTO`
placeholder or `TODO` → BLOCKED).

**Accurate one-line state:** *wired, blocking logic directly proven on a real install, platform-delivery
inferred via the shared production seam — pending one in-session live dispatch as the final
direct confirmation.* Do **not** upgrade this to "live-confirmed end to end" or "mechanically enforced,
fully verified" until a real in-session `spec-analyst` dispatch has been observed reaching the hook.

**Hook-point investigation (owner DECIDED — Option 1 wired):**
- **Option 1 — dispatch gate (CHOSEN + WIRED).** `PreToolUse` on `Agent|Task`, gate only on
  `subagent_type == spec-analyst`. *Pros:* exact precedent (`rubric-validity-gate` is live + tested on
  this same seam); fires **early**, before any wasted extraction, at the exact decision point the bypass
  corrupted; fails closed (missing/DRAFT/unparseable contract → block; non-spec-analyst spawn → allow).
  *Cannot cover (the honest blind spot, still open):* a spec-analyst that is NOT spawned via the
  Agent/Task tool (e.g. the orchestrator role-plays the analyst inline — forbidden by prose, but the
  dispatch gate can't see a spawn that never happens); and, like every gate here, it constrains the
  **agent's tool calls**, not a human shell.
- **Option 2 — write gate on behavior-spec.json (viable defense-in-depth, NOT recommended as primary).**
  `PreToolUse` on `Write|Edit`, block the write of `.preflight/<service>/behavior-spec.json` unless a valid
  contract exists. *Pros:* catches the inline-role-play path Option 1 misses (the write still happens).
  *Cons:* fires **late** (after extraction work is wasted); and **basename matching is unsafe** here —
  `deck/demo/behavior-spec-{NEW,OLD}.json` exist in-repo, so it must path-scope to `.preflight/.../`
  precisely or it false-fires. *Fails closed* if implemented like `bootstrap-write-gate`.
- **Outcome:** **Option 1 is wired** as the primary mechanism; **Option 2 is not built** and remains the
  option to add later as defense-in-depth for the inline-role-play path. Neither is server-side; both
  constrain the agent's tool calls only (same ceiling as every guard in this document).

## Related: branch-cut remote-collision check is PROMPT-LEVEL (not a hook)

The migrate skill, before cutting `feature/migrate-<service>`, runs `git ls-remote --heads
<branch.remote> <branchName>` and refuses to cut over a remote branch that still exists
(prior-attempt debris). **This one is explicitly prompt-level, not mechanical** — and we label it
so rather than overstate it. Branch-cut is not on a hookable command seam: `git checkout -b` is too
common to match without firing on every branch creation in every repo, and the collision needs a
remote round-trip the command string does not carry. So unlike the force-push and wrong-repo guards
(real `PreToolUse:Bash` hooks), the collision check depends on the migrate agent actually performing
it — a drifting or skip-the-skill agent could cut over the debris anyway. It is a genuine guard for
the normal path, but it is enforcement-by-instruction. (Fail-open on unresolvable config, like the
others.)

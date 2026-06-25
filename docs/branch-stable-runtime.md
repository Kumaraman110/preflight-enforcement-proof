# Branch-Stable Runtime — Design + Decision Record (P0 Part B)

This document records the design and the authorized contract change for moving Preflight's **active Bash
enforcement runtime** out of branch-controlled files. It is the honest-boundary record for defect #3
(branch checkout replacing the active runtime), in the same spirit as `docs/parity-gate-limitations.md`.

This is an **infrastructure and delivery-contract correction, not a product-architecture change.** The
established Preflight workflow (bootstrap → discovery → Behavioral Contract → baseline behavior-spec →
implementation/migration → migrated behavior-spec → parity → evidence validation → independent review →
external-review classification → adjudication → rubric evolution → server-side governance) is unchanged.
Agent separation of duties, the behavior-spec model, the parity engine, the evidence model, the
reviewer/adjudicator roles, the external-review learning loop, and the installer manifest/integrity
concepts are all preserved.

---

## The problem (defect #3)

Preflight's hooks ship into a consumer's `.claude/hooks/`, which is **git-tracked**. Claude Code resolves &
spawns the PreToolUse hook command **per tool call** and (per current Claude Code docs) picks up
settings/hook changes via a file watcher with **no snapshot-at-startup** and **no review-before-effect**. So
a `git checkout` of another branch can swap the **live** safety-hook executable mid-session — the running
control plane is branch-controlled.

A second, subtler fact makes the naive fix insufficient: **Claude Code hooks are ADDITIVE across settings
layers, not override.** A hook registered in `.claude/settings.local.json` runs *alongside* one registered
in the tracked `.claude/settings.json`; it does not replace it. So relocating the runtime *script* and
adding a local-layer pointer is not enough on its own — as long as the **tracked** project layer still
registers a Bash `PreToolUse` hook, a checkout of any branch carrying that registration makes the
branch-controlled hook fire alongside the pinned one.

---

## Decision

> **The Bash safety runtime is machine/clone execution infrastructure, not branch-owned product content.**
> The declaration remains in the Preflight source repository (`hooks/hooks.json` stays the single source of
> truth), while active **registration and execution** are SHA-pinned and clone-local.

**Compatibility:** Existing tracked registrations continue to function until migration, but they are
considered **legacy** and must be detected. Reinstallation performs a **narrow, ownership-aware migration**:
it moves only the Preflight-owned Bash `PreToolUse` registration from the tracked project layer to the
untracked local layer, pointed at the SHA-pinned runtime. All non-Bash Preflight hooks (Write/Edit,
Agent|Task), all third-party/user hooks, and all non-Preflight settings stay exactly where they are.

**Residual boundary:** Historical branches containing the old tracked registration remain **unsafe to use
without migration or explicit detection.** The release does **not** claim otherwise. Specifically:

> The new registration contract closes branch-controlled Bash-runtime replacement for **migrated**
> checkouts. **Legacy branches carrying the old tracked Bash registration remain a migration hazard until
> detected and remediated.**

---

## The model

- **Runtime home:** `<git-common-dir>/preflight/runtime/<resolved-sha>/`. The git common dir holds repo
  *metadata*, not tracked working-tree content, so no branch checkout can rewrite or delete it. It is shared
  across all linked worktrees of the repo (resolved via `git rev-parse --git-common-dir`, absolutized from
  the worktree top — it can return a relative `.git`).
- **Immutable, SHA-named, atomic:** each install materializes a new SHA-named runtime dir (staged, then
  renamed into place). Previous SHA dirs are left on disk so a failed upgrade or an explicit rollback can
  point back at one. `ACTIVE` / `PREVIOUS` marker files record the live and rollback SHAs.
- **Registration in the local layer only:** the Bash `PreToolUse` gate is registered solely in the
  untracked, gitignored `.claude/settings.local.json`, with an **absolute** command path baked to the
  chosen SHA dir's `run-hook.cmd` (shell form — Windows cannot spawn a `.cmd` in exec form; and
  `${CLAUDE_PROJECT_DIR}` resolves to the worktree root, not the common dir, so the path is baked at install).
- **Single source of truth preserved:** the Bash-hook *declaration* is read from `hooks/hooks.json`; the
  installer derives the local-layer command from it + the resolved SHA. `hooks.json` shape is unchanged.

### Runtime closure (what ships outside branch control)

The minimal set the Bash candidate path needs: `hooks/{run-hook.cmd, pre-bash-risk-router,
pre-push-gate-engine, pre-push-gate, session-start}` + `lib/{config-overlay.sh, heartbeat.sh}`. Nothing else
(skills/agents/other gates are not on the Bash candidate path), keeping the immutable runtime small and
reviewable.

---

## Unified installation contract (one command produces the safe state)

**The standard installer is the only command a normal first-install or upgrade needs.**
`tools/preflight-install.sh <CONSUMER> [REF]` now, as its final step, invokes the branch-stable runtime
install at the **same resolved SHA** it just installed. So one documented operation yields:
1. non-Bash framework surfaces in `.claude/`, 2. the active Bash runtime under `<git-common-dir>` pinned to
the install SHA, 3. the Preflight Bash gate registered only in untracked `settings.local.json`, 4. the
Preflight-owned Bash entry narrowly migrated OUT of the tracked `.claude/settings.json` (non-Bash hooks +
non-Preflight settings preserved), 5. a single coherent manifest/runtime SHA (no version split-brain),
6. `preflight-verify` clean (integrity PASS, 0 drift, branch-stable section ✓).

**Degrade-safely:** if the runtime step cannot run (consumer is not a git worktree, runtime installer
absent on an older checkout, or `PREFLIGHT_SKIP_RUNTIME=1`), the install does NOT fail — it leaves the
LEGACY-but-functional tracked Bash gate (the supported baseline; the gate still enforces, it is merely
branch-controlled until migrated). This is not fail-open.

The **specialized runtime installer below remains available** for repair / rollback / runtime-only
maintenance, but it is NOT required knowledge for a normal install or upgrade.

## Tools

- `tools/preflight-install.sh <CONSUMER> [REF]` — **the standard one-command install/upgrade.** Installs all
  surfaces AND (final step) the branch-stable runtime + ownership-aware Bash migration at the same SHA.
- `tools/preflight-runtime-install.sh <CONSUMER> [REF]` — the runtime-only installer (invoked by the
  standard installer; also usable standalone for repair): materialize the SHA-pinned runtime, register the
  Bash gate in `settings.local.json` (atomic temp+rename), advance ACTIVE/PREVIOUS, gitignore the local
  layer, and perform the ownership-aware tracked-layer migration.
- `… --rollback <CONSUMER>` — re-point the local layer at the PREVIOUS runtime SHA.
- `… --uninstall <CONSUMER>` — remove ONLY the Preflight-owned Bash local registration (leaves runtimes +
  the tracked project layer untouched).
- `… --list <CONSUMER>` — list materialized runtimes + the ACTIVE/PREVIOUS SHAs.
- `… --scan-local-branches <CONSUMER>` — read-only legacy-registration inventory across local branches.
- `preflight-verify.sh` — extended to detect the legacy/duplicate hazards (below).

---

## Honest limits (the enforcement-boundary record)

1. **Per-clone install.** `settings.local.json` is machine-local and gitignored, so it does not travel with
   the repo. Every clone/worktree must run the installer; an un-installed clone has no Bash gate (fail-open).
2. **Legacy branches remain a hazard.** A checkout of a historical branch whose tracked
   `.claude/settings.json` still carries the Preflight Bash registration re-introduces a branch-controlled
   hook that runs *alongside* the pinned one. This is detected (verify + `--scan-local-branches`), not
   auto-rewritten. Do not claim all historical branches are safe.
3. **Platform-delivery is INFERRED until a live session confirms it.** That Claude Code actually loads and
   invokes the local-layer pinned hook (and that branch switches between migrated branches do not change the
   active runtime SHA in a real session) is established from documented additive-hook + file-watcher
   behavior — it is **not** confirmed by JSON-structure or unit tests alone. Labeled unconfirmed, same
   discipline as the behavioral-contract gate's delivery half, until a live migrated-consumer run proves it.
4. **Agent-side / fail-open / user-editable / enterprise-managed-override ceiling.** A user can edit/delete
   the local layer; an enterprise managed-settings hook can override or run alongside. This is not
   server-side enforcement — same ceiling as every guard in `docs/parity-gate-limitations.md`.

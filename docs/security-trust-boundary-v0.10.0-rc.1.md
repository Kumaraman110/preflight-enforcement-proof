# Security & trust-boundary statement — v0.10.0-rc.1 user-level install

This states, honestly, what the user-level installation defends, what it does not, and where the real
authority lives. It is the companion to `docs/user-install.md` and `docs/parity-gate-limitations.md`.

## What the user-level install protects

- **Your existing Claude settings are preserved.** The installer backs up `~/.claude/settings.json`
  (or records its absence) before any edit, merges its hook registration as a union without duplicate
  entries, preserves all unrelated keys/hooks, and restores the prior state exactly on any failure.
- **Immutability + integrity.** Each generation is a SHA-named immutable directory with a
  `RUNTIME_MANIFEST.json` recording the SHA-256 of every artifact. `verify --user` detects tampering
  (modified, missing, or added files). Activation is an atomic pointer swap only after checksum
  validation, so a half-written generation can never go live.
- **Opt-in, reversible, self-contained.** No repository is governed unless it opts in
  (`.preflight/config.json`). Rollback and uninstall are proven and restore prior state. After
  installation there is no dependency on the source checkout.

## The enforcement boundary (what this is NOT)

- The user-level gate is a **PreToolUse hook running on your machine in your Claude Code session.** It
  is **advisory and agent-resistant** — it raises the cost of an unreviewed consequential action and
  keeps the reversible fast path friction-free. A local actor with filesystem access (or a process
  running as your user) can disable or alter it. **It is not a server-side control.**
- The **authoritative** enforcement is the **remote required-check**: the two-stage remote decision
  gate that runs from a trusted default branch, independently re-resolves repo + commit identity, runs
  a trusted verifier + policy, signs a decision attestation, and is configured as a required status
  check so the platform refuses to merge a failing PR. That is where a locally-forged or self-issued
  clearance cannot survive.
- **This release does not deploy or configure the remote gate.** No secrets, workflows, branch
  protection, or required checks are configured by installing this version.
- A local `ALLOW` is **advisory input**, never final authority for a push to a shared/protected branch.

## Fail-closed scope

The user-level router fails **closed** (blocks) only for **in-scope consequential** commands
(governed shapes such as `git push`, `gh pr create/merge`) in an opted-in repository when the engine
is missing, times out, or cannot adjudicate. It never blocks ordinary commands, and never blocks in a
repository that has not opted in. A broken user-level install fails **safe** (allows ordinary work);
the `doctor`/`verify` commands surface the fault.

## Data handling

- The passive router performs **read-only** repository discovery and never writes to an application
  repository during routing.
- No network is required for normal operation after installation.
- No secrets or keys are stored, printed, or transmitted by the installer.

## Residual risks (honest)

- Advisory local gate (above) — the primary residual risk; mitigated only by the remote required-check.
- On a shared multi-user machine, `~/.claude/preflight/` is protected only by OS file permissions.
- The reversibility tier used by the demonstration policy is a heuristic, not a formal risk model.

## Findings from the independent adversarial review (what was fixed / what remains)

Two non-author reviewers attacked the installer and the router. Fixed in this release candidate:
- **Router opt-in scoping** — a `cd <opted-in> && git push` (or a config-referencing command) issued from
  a non-opted-in working directory previously short-circuited the router. The router now extracts an
  explicit command target (`cd X`, `git -C X`, `--git-dir=X`), checks opt-in at that directory, and routes
  a governed candidate to the engine.
- **Project-ownership detection** — the "don't double-execute" yield now requires a *parsed* PreToolUse
  Bash registration plus a non-empty project hook file, not an incidental substring in `settings.json`.
- **Invalid settings.json** — an existing but unparseable `~/.claude/settings.json` now causes install to
  **abort** (never overwrite/drop your keys); fix or move the file and re-install.
- **Duplicate registration** — a same-version reinstall now collapses any duplicate Preflight hook entries.

Documented residual (pre-existing, not introduced by this release; reproduces unchanged on the baseline):
- **Engine `git -C <dir>` / `--git-dir=` push analysis** — the decision engine currently ALLOWS a
  `git -C <dir> push` even for an opted-in target. The router correctly routes it to the engine; closing
  the engine's `-C`/`--git-dir` target analysis is a product-line follow-up. As with all local-gate limits,
  the **remote required-check** is the authoritative backstop.
- **Tampered generation is not auto-repaired** — `verify --user` detects tampering (fail), but a re-install
  of the same version does not overwrite an already-materialized generation directory. Recover with
  `uninstall --user` then `install --user`.
- **Symlinked runtime home** — if `~/.claude/preflight` is a symlink, `uninstall` removes the link (never
  the external target — safe), leaving the target's contents orphaned; remove them manually.

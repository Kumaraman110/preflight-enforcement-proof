# Preflight v0.10.0-rc.3 — Release notes

> **Supersedes v0.10.0-rc.2 for evaluation.** The `v0.10.0-rc.1` and `v0.10.0-rc.2` tags are immutable
> and stay in place. rc.3 adds deterministic user/project hook arbitration and a read-only
> `doctor --project`, and carries the rc.2 alt-git-context and uninstall fixes. It is a linear
> descendant of the rc.2 commit (`7e30c51`).

## New in rc.3 — deterministic hook arbitration

Claude Code merges PreToolUse hooks as a **union** across the user scope (`~/.claude/settings.json`) and
the project scope (`<repo>/.claude/settings.json`) — both fire for the same Bash tool call. A repo that
has BOTH a user-level Preflight install and a project-level Preflight install would therefore adjudicate
the same event twice. rc.3 resolves ownership with ONE deterministic rule so **exactly one** authoritative
runtime decides each event.

- **`lib/hook-arbitration.sh`** — the single ownership rule (the user router and `doctor` both derive
  their answer from it; there is no second source to drift):
  - **PROJECT** — a valid project-level Preflight Bash registration (settings names a project router AND
    the referenced project hook file exists non-empty) owns the repo; the user router yields (exit 0,
    writes nothing).
  - **USER** — opted-in with no distinct project registration. A `.preflight/config.json` **alone is never
    project ownership** — an actual active project registration is required.
  - **AMBIGUOUS** — a project registration is present but not trustworthy (malformed settings, or a stale
    registration whose hook file is missing/empty). The user runtime owns the decision **safely** — it
    never stands down for an unverifiable or broken project install (fail-closed-safe: a stale project
    hook must never let a governed push through) — and `doctor` reports remediation.
  - A project settings entry that merely re-invokes the **user** runtime (`dispatcher.cmd` or a
    `~/.claude/preflight` path) is a **duplicate**, not a project owner — ownership stays USER and the
    duplicate is flagged. The **branch-stable project runtime** under `<repo>/.git/preflight/runtime/<sha>/`
    is a PROJECT owner (not a user-runtime duplicate) even though its path contains `preflight/runtime/`.
- **`tools/preflight-user.sh doctor --user --project <path>`** (READ-ONLY): reports the effective owner
  (USER / PROJECT / AMBIGUOUS), the user version + commit, the project registrations found, the project
  runtime, duplicate-execution risk, and remediation. It never writes to or mutates the inspected repo.

## Fixed since rc.2

- **`verify --user` accepts a legitimately rolled-back older generation** whose recorded `RELEASE_VERSION`
  differs from the CLI's compiled-in version. Integrity is still fully enforced (per-artifact SHA-256
  re-check + registration + a well-formed version string); only the spurious version-equality failure
  after a rollback is removed.

## Carried from rc.2

- **Alternate git-context push bypass (stable blocker):** `git -C <dir> push` / `--git-dir[=]` /
  `--work-tree` / `-c` / `GIT_DIR=` / `GIT_WORK_TREE=` / nested `bash -c` / quoted space-paths / multi-push
  were misclassified as non-pushes by the IR lexer and **silently allowed**. Fixed in
  `lib/shell-structure-lexer.awk` (skip git global options before the subcommand). These forms now get the
  normal policy decision, or a fail-closed BLOCK when the target repo's config is unreachable — never a
  silent allow. Non-push commands (`git status`, `grep -C`, `echo -C`) are unaffected.
- **Uninstall restores prior `settings.json` byte-for-byte** when no post-install user change is present;
  a post-install change is preserved; an install-created file is removed.

## This is a release candidate

`v0.10.0-rc.3` is a **release candidate**, published as a GitHub **prerelease** — it is **not** GA and is
**not** marked `latest`/`stable`. Evaluate it; do not treat it as a stable release.

## What this release is

The first **user-level** Preflight installation: a single, opt-in PreToolUse Bash hook registered in
`~/.claude/settings.json`, backed by an immutable, versioned runtime under `~/.claude/preflight/`. It
governs only repositories that explicitly opt in, is fast when inactive, is fully reversible, and — as of
rc.3 — defers deterministically to a project-level Preflight install so a repo is never gated twice.

- **Source commit:** the `release/v0.10.0-rc.3` head. Its product content is the completed **PR #13** tree
  (`d7ba8ee`), a linear descendant of **PR #12**'s router/engine split (`dac97e8`).
- **Stacked-PR dependency:** PR #13 is stacked on PR #12. Both remain **open**; neither was merged to cut
  this release. A consumer adopting the product line should land PR #12 then PR #13 upstream.

## Trust boundary (important)

- The **local user-level gate is advisory / agent-resistant.** It runs in your Claude Code session and
  raises the cost of an unreviewed consequential action while keeping ordinary work friction-free. A local
  actor with filesystem access can alter it — it is not a server-side control.
- The **remote required-check enforcement remains the final authority.** The two-stage remote decision gate
  (trusted default-branch workflow, independent identity re-resolution, signed attestation, required status
  check) is what actually gates merges.
- **The remote gate is not automatically configured by this release.** Deploying it (secrets, workflows,
  branch protection / required check) is a separate, documented operator step.

## Install / upgrade / rollback / uninstall

```bash
# install this exact version (from the immutable tag or the published artifact)
tools/preflight-user.sh install --user --ref v0.10.0-rc.3
# or from the downloaded self-contained artifact:
tools/preflight-user.sh install --user --ref v0.10.0-rc.3 --from-artifact preflight-user-v0.10.0-rc.3.tar.gz

tools/preflight-user.sh verify   --user                 # integrity: manifest + registration + version
tools/preflight-user.sh status   --user                 # ACTIVE / PREVIOUS / registration / version
tools/preflight-user.sh doctor   --user --project DIR    # READ-ONLY effective-owner report for a repo
tools/preflight-user.sh rollback --user                 # revert to the PREVIOUS generation (atomic)
tools/preflight-user.sh uninstall --user                # remove only Preflight-owned data; restore prior settings
```

**Upgrade notes.** Installing a newer ref stages a new immutable generation, validates it, then swaps
`ACTIVE` (old `ACTIVE` → `PREVIOUS`). The dispatcher path and `settings.json` registration do not change.
The previous generation stays on disk for rollback.

**Rollback instructions.** `tools/preflight-user.sh rollback --user` swaps `ACTIVE` ↔ `PREVIOUS` (after
integrity-checking the target). Re-installing the current version restores it.

**Uninstall.** `tools/preflight-user.sh uninstall --user` removes `~/.claude/preflight/` and the
Preflight-owned hook entry, and restores your prior `settings.json` exactly (including removing a
`settings.json` the installer itself created).

## Known limitations

- Release candidate, not GA.
- Local gate is advisory/agent-resistant; the remote required-check is the final authority (above).
- Remote-gate deployment is not automatically configured.
- **Host-performance:** on Windows/Git-Bash with on-access antivirus, per-spawn latency is variable. The
  `ir-push-perf` authoritative-performance matrix is timing-sensitive on such hosts and may report
  `AUTHORITATIVE PERFORMANCE INSUFFICIENT` (wall-clock only, functionally correct); it reproduces on a
  pristine baseline and is **not** a functional regression. No functional failure is waived.
- Requires `bash`, `git`, `jq`, and a working `python3`/`python` on PATH for install/verify.

## Verifying the artifact

The prerelease attaches a self-contained installation artifact, its SHA-256 checksum, an artifact
manifest, and these notes. Verify the checksum before installing:

```bash
sha256sum -c preflight-user-v0.10.0-rc.3.tar.gz.sha256
```

The installed runtime carries a per-generation `RUNTIME_MANIFEST.json`; `verify --user` re-checks every
artifact's SHA-256 and the settings registration.

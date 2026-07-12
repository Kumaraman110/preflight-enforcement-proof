# Preflight user-level installation (v0.10.0-rc.1)

A **user-level** Preflight install registers one PreToolUse Bash hook in `~/.claude/settings.json` that
is **opt-in per repository**, immutable, versioned, reversible, and independently verifiable. It does
not change the behavior of any repository that has not explicitly opted in, and it cannot corrupt your
existing Claude Code settings.

> **Release candidate.** This is `v0.10.0-rc.1`, not GA. The local user-level gate is
> **advisory / agent-resistant** — a determined local actor with filesystem access can alter it.
> The **final authority** for whether a change may merge is the **remote required-check** (the remote
> decision gate), which this installer does **not** configure. See "Trust boundary" below.

## Model

```
~/.claude/
  settings.json                     ← one PreToolUse "Bash" hook → the stable dispatcher (union-merged, dedup)
  preflight/
    dispatcher.cmd                  ← STABLE path (never changes across upgrades); reads ACTIVE, execs the gen
    ACTIVE                          ← the live <commit-sha>
    PREVIOUS                        ← the prior <commit-sha> (rollback target)
    runtime/<commit-sha>/           ← IMMUTABLE generation, one dir per installed source commit
      hooks/ lib/ verifier/ protocol/ gate/
      VERSION  RELEASE_VERSION  SOURCE_COMMIT
      RUNTIME_MANIFEST.json         ← sha256 of every artifact in the generation
    settings-backup/<timestamp>/    ← a copy of settings.json (or an ABSENT marker) before each edit
```

Upgrading = staging a new immutable generation, validating its checksums, then an **atomic pointer
swap** of `ACTIVE` (and `PREVIOUS` ← old `ACTIVE`). The dispatcher path is constant, so
`settings.json` is written exactly once at first install and never rewritten on upgrade. There is
**no dependency on the source checkout** after installation — everything is copied in.

## Opt-in

A repository is governed only when it contains a valid activation file at its root:
`.preflight/config.json` (or `.cpsl/config.json` / `.forge.json`). With no such file, the hook
**exits immediately** (allow) — ordinary work in un-opted-in repositories pays only a handful of
filesystem stats, no process spawn.

If a repository already carries a **project-level** Preflight registration, the user-level hook
**yields** to it (no double execution).

## Commands

```bash
tools/preflight-user.sh install  --user --ref <tag|sha> [--from-artifact <tarball>] [--source <code-forge-dir>]
tools/preflight-user.sh verify   --user      # manifest + registration + version integrity → exit 0/1
tools/preflight-user.sh status   --user      # ACTIVE/PREVIOUS, registration, generation count, version
tools/preflight-user.sh version              # prints v0.10.0-rc.1
tools/preflight-user.sh rollback --user      # atomic swap ACTIVE ↔ PREVIOUS (verifies target first)
tools/preflight-user.sh uninstall --user     # remove ONLY Preflight-owned data; restore prior settings
tools/preflight-user.sh doctor   --user      # environment + integrity diagnostics
```

Install guarantees:
- installs **only** from committed git objects of the ref, or a release artifact tarball — never the working tree;
- rejects an unresolvable/dirty/ambiguous ref;
- validates the staged generation's SHA-256 checksums **before** activation;
- backs up `settings.json` (or records its absence) before any modification;
- preserves all unrelated settings, and **merges** the hook registration without duplicate entries (dedup by command identity);
- is **idempotent** (re-installing the active version is a no-op);
- leaves the previous generation in place for rollback;
- on **any** failure, restores the prior settings and pointers exactly (no partial state).

Uninstall removes only `~/.claude/preflight/` and the Preflight-owned hook entry, and restores your
prior `settings.json` (including removing a `settings.json` that the installer itself created).

## Decision contract

The PreToolUse Bash hook exits `0` (allow) for ordinary commands and for un-opted-in repositories.
For an opted-in repository, an **in-scope consequential** command (e.g. `git push`, `gh pr create/merge`)
is routed to the local engine, which returns `ALLOW` (exit 0), `REQUIRE_APPROVAL`/CONFIRM (a
`permissionDecision` JSON, or exit non-zero), or `BLOCK` (exit 2). Missing engine / missing evidence
for a candidate **fails closed** (non-success) — but only for that candidate, never for ordinary work.

## Trust boundary (read this)

- The user-level gate runs on **your machine**, in your Claude Code session. It is **advisory and
  agent-resistant**: it raises the cost of an unreviewed consequential action and keeps the reversible
  fast path friction-free. It is **not** a server-side control.
- The **authoritative** enforcement is the **remote required-check** (the two-stage remote decision
  gate): a trusted default-branch workflow that independently re-resolves identity and signs the
  decision, gating merge. **This installer does not deploy or configure the remote gate.**
- Never treat a local `ALLOW` as final authority for a push to a shared/protected branch — the remote
  required check is what actually enforces it.

## Known limitations

- Release candidate, not GA.
- The local gate is advisory/agent-resistant, not a server-side control (above).
- On Windows/Git-Bash with on-access AV, per-spawn latency is variable (the `ir-push-perf` host
  matrix is timing-sensitive on such hosts — see the release notes).
- Requires `bash`, `git`, `jq`, and a working `python3`/`python` on PATH for install/verify.

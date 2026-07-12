# Preflight v0.10.0-rc.1 — Release notes

## This is a release candidate

`v0.10.0-rc.1` is a **release candidate**, published as a GitHub **prerelease** — it is **not** GA and
is **not** marked `latest`/`stable`. Evaluate it; do not treat it as a stable release.

## What this release is

The first **user-level** Preflight installation: a single, opt-in PreToolUse Bash hook registered in
`~/.claude/settings.json`, backed by an immutable, versioned runtime under `~/.claude/preflight/`. It
governs only repositories that explicitly opt in, is fast when inactive, and is fully reversible.

- **Source commit:** the `release/v0.10.0-rc.1` head. Its product content is the completed **PR #13**
  tree (`d7ba8ee`), a linear descendant of **PR #12**'s router/engine split (`dac97e8`).
- **Stacked-PR dependency:** PR #13 is stacked on PR #12. Both remain **open**; neither was merged to
  cut this release. A consumer adopting the product line should land PR #12 then PR #13 upstream.

## Trust boundary (important)

- The **local user-level gate is advisory / agent-resistant.** It runs in your Claude Code session and
  raises the cost of an unreviewed consequential action while keeping ordinary work friction-free. A
  local actor with filesystem access can alter it — it is not a server-side control.
- The **remote required-check enforcement remains the final authority.** The two-stage remote decision
  gate (trusted default-branch workflow, independent identity re-resolution, signed attestation,
  required status check) is what actually gates merges.
- **The remote gate is not automatically configured by this release.** Deploying it (secrets,
  workflows, branch protection / required check) is a separate, documented operator step.

## Install / upgrade / rollback / uninstall

```bash
# install this exact version (from the immutable tag or the published artifact)
tools/preflight-user.sh install --user --ref v0.10.0-rc.1
# or from the downloaded self-contained artifact:
tools/preflight-user.sh install --user --ref v0.10.0-rc.1 --from-artifact preflight-user-v0.10.0-rc.1.tar.gz

tools/preflight-user.sh verify   --user     # integrity: manifest + registration + version
tools/preflight-user.sh status   --user     # ACTIVE / PREVIOUS / registration / version
tools/preflight-user.sh rollback --user     # revert to the PREVIOUS generation (atomic)
tools/preflight-user.sh uninstall --user    # remove only Preflight-owned data; restore prior settings
```

**Upgrade notes.** Installing a newer ref stages a new immutable generation, validates it, then swaps
`ACTIVE` (old `ACTIVE` → `PREVIOUS`). The dispatcher path and `settings.json` registration do not
change. The previous generation stays on disk for rollback.

**Rollback instructions.** `tools/preflight-user.sh rollback --user` swaps `ACTIVE` ↔ `PREVIOUS`
(after integrity-checking the target). Re-installing the current version restores it.

**Uninstall.** `tools/preflight-user.sh uninstall --user` removes `~/.claude/preflight/` and the
Preflight-owned hook entry, and restores your prior `settings.json` exactly (including removing a
`settings.json` the installer itself created).

## Known limitations

- Release candidate, not GA.
- Local gate is advisory/agent-resistant; the remote required-check is the final authority (above).
- Remote-gate deployment is not automatically configured.
- **Host-performance:** on Windows/Git-Bash with on-access antivirus, per-spawn latency is variable.
  The `ir-push-perf` authoritative-performance matrix is timing-sensitive on such hosts and may report
  `AUTHORITATIVE PERFORMANCE INSUFFICIENT` (wall-clock only, functionally correct); it reproduces on a
  pristine baseline and is **not** a functional regression. No functional failure is waived.
- Requires `bash`, `git`, `jq`, and a working `python3`/`python` on PATH for install/verify.

## Verifying the artifact

The prerelease attaches a self-contained installation artifact, its SHA-256 checksum, an artifact
manifest, and these notes. Verify the checksum before installing:

```bash
sha256sum -c preflight-user-v0.10.0-rc.1.tar.gz.sha256
```

The installed runtime carries a per-generation `RUNTIME_MANIFEST.json`; `verify --user` re-checks every
artifact's SHA-256 and the settings registration.

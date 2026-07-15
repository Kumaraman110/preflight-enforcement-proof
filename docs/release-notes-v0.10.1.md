# Preflight v0.10.1 — Release notes (patch)

> **Patch release.** A linear descendant of the `v0.10.0` commit (`173bccd`). The `v0.10.0` tag, its
> published artifact (`preflight-user-v0.10.0.tar.gz`, sha256 `a30df67c…`), and its checksum are
> **immutable and unchanged** by this release. v0.10.1 fixes a single packaging defect and adds its
> regression test; there is no behavioral change to the push-safety guard itself.

## The defect — the artifact did not carry the management CLI

Preflight installs as two cooperating surfaces: an **immutable per-generation runtime**
(`~/.claude/preflight/runtime/<sha>/`, the hooks/lib the gate actually runs) and a **stable on-PATH CLI**
(`preflight` → `~/.claude/preflight/cli/preflight-user.sh`, the management command). Upgrading is an atomic
swap of the `ACTIVE` pointer to a new generation; the CLI is a separate stable copy.

In v0.10.0 the two could drift:

- `tools/user/build-artifact.sh` packed only the runtime closure into the release artifact — it **never
  packed the management CLI** (`tools/preflight-user.sh`).
- `cmd_install` sourced a fresh CLI **only on the git-object install path** (`[ -z "$ARTIFACT" ]`). On a
  **from-artifact** install there was no CLI to stage; the self-copy guard correctly skipped the copy.

Net effect: a from-artifact install/upgrade swapped the runtime generation but left the on-PATH CLI at its
previously-installed version. After the v0.10.0 stable install, `preflight version` printed:

```
v0.10.0 (active runtime; CLI v0.10.0-rc.4)
```

The **runtime** was genuinely v0.10.0 (integrity-verified), but the CLI *label* lagged at rc.4. The gate
behaved correctly throughout — this was a management-CLI version-reporting lag, not a safety regression.

The published **v0.10.0 artifact (`a30df67…`) contains no management CLI**, so it cannot itself refresh the
CLI. The immediate v0.10.0 CLI was resynchronized out-of-band from the immutable `v0.10.0` git object; this
release fixes the packaging contract so it can never recur.

## The fix — the CLI ships inside every generation and syncs in lockstep

- **`build-artifact.sh`** bundles `cli/preflight-user.sh` into the artifact. It is covered by both
  `RUNTIME_MANIFEST.json` and `ARTIFACT_MANIFEST.json` (each walks the whole stage) and is listed as a
  dedicated **SBOM component** (`preflight-user-cli`). A missing CLI is **fatal at build time**.
- **`_stage_from_git`** stages the same `cli/preflight-user.sh` into a git-sourced generation, so **both**
  install paths carry the CLI inside the immutable generation.
- The stable on-PATH CLI is now **synced from the ACTIVE generation** (atomic stage-beside + `mv`) on
  **install and on rollback**. The CLI therefore matches `ACTIVE` after fresh install, upgrade, rollback,
  and roll-forward.
- The CLI sync is part of the **atomic install transaction**: any failure trips the ERR trap, which now
  also restores the prior CLI bytes — a runtime/CLI half-swap cannot occur.
- **`verify`** reports CLI/runtime lockstep and **FAILs on drift** (mismatch detection). The idempotent
  install short-circuit now requires lockstep, so re-installing the active ref **repairs** a stale CLI
  instead of no-opping.

## Certification

The full framework test suite — now **110 shards** (103 behavioral + 7 in-file suites) — certifies on the
quiet ephemeral `windows-latest` runner (independent per-shard re-derivation), against the immutable
`v0.10.1` tag this release is cut from. The new `artifact-cli-packaging-test.sh` (10 assertions) proves the
contract end to end in isolated HOME dirs: artifact-contains-CLI, artifact-only fresh install, artifact-only
upgrade, interrupted-staging rollback, CLI/runtime mismatch detection + repair, rollback restores both
runtime and CLI, and self-contained operation after the source checkout is deleted.

## Known boundary (bootstrapping)

An in-place upgrade **driven by a pre-v0.10.1 launcher** cannot self-heal the CLI: the launcher execs the
OLD installed CLI, whose `cmd_install` predates this fix, so that upgrade still leaves the CLI stale (the
new generation bundles the correct CLI, and `verify` reports the drift so it is visible, not silent). Once a
v0.10.1+ CLI drives an install — or a one-time manual CLI refresh is performed — every subsequent
install / upgrade / rollback keeps the CLI in lockstep. This is the same boundary as any installer that
updates itself.

## Install

```sh
# from the published artifact (recommended):
#   download preflight-user-v0.10.1.tar.gz + .sha256, verify, then:
preflight install --user --ref v0.10.1 --from-artifact preflight-user-v0.10.1.tar.gz
preflight status && preflight verify   # verify reports "CLI in lockstep with active generation"
```

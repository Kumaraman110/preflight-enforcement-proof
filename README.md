# preflight-enforcement-proof

A **public, disposable proof harness** demonstrating a two-stage, fork-safe remote decision gate on
real GitHub infrastructure. It shows that an untrusted pull request can propose a change and emit
hints, but only an **independent, trusted, default-branch workflow** decides whether the change may
merge — and that a required status check makes GitHub refuse to merge a failing PR.

This repository is a self-contained demonstration. It contains **no** proprietary code, no
organization identifiers, and no production configuration. All keys used here are throwaway
test-only keys stored as GitHub Actions secrets/environments.

## What it proves

1. an untrusted (fork) PR **cannot access secrets** — Stage 1 runs in the PR context with none;
2. the trusted default-branch **Stage 2 uses its own pinned verifier and policy** (never the PR's);
3. valid evidence → **ALLOW**;
4. forged local ALLOW, a modified judge/policy, tamper, replay, wrong commit, and self-approval → **BLOCK**;
5. a missing secret, a timeout, or an internal failure → **non-success** (never ALLOW);
6. the independent decision check is a **required** status check;
7. **GitHub refuses to merge a failing PR**.

## Architecture

```
untrusted PR (pull_request)                trusted default branch (workflow_run)
──────────────────────────                 ─────────────────────────────────────────────
collect.yaml (NO secrets):        ┌──────▶ decide.yaml — three isolated jobs:
  record head/base SHA as data    │          A generate  (no signing key): fetch commit as DATA,
  (PR .gate/artifacts/* are       │                      independently DERIVE tier + tests
   untrusted HINTS, ignored)      │          B seal      (bundle key only): HMAC-sign the bundle
        │ artifact ───────────────┘          C decide    (attest key only + Ed25519 approval PUBLIC
        ▼                                                 key): run TRUSTED verifier+policy, post a
                                                          commit status on the PR head (the required check)

approve.yaml (workflow_dispatch, holds the Ed25519 PRIVATE key in a protected environment):
  mints a scoped approval that upgrades REQUIRE_APPROVAL → ALLOW. The judge holds ONLY the public
  key → it can verify but never mint → no self-approval.
```

## Tier model (demonstration only)

`gate/classify-tier.sh` derives the reversibility tier from the files a PR actually changed
(diffed against the **trusted default-branch tip**, not the PR's claimed base — unforgeable), using a
fail-closed **allowlist**:
- a changed path under `verifier/ protocol/ gate/ .github/ app/protected/` → **BLOCK**;
- else a changed path under `app/review/` → **CONFIRM** (needs a distinct approval);
- **AUTO only when every changed path is on the safe allowlist** (`app/safe/**`, `docs/**`, a few root docs);
- any unknown/unlisted path, or no resolvable diff → **BLOCK** (fail-closed).

The diff uses `--no-renames` and `core.quotePath=false` so a rename of a protected file into a safe
path, or a non-ASCII protected path, cannot launder a protected change into AUTO.

## Not production-ready

HMAC is symmetric (not public non-repudiation); the approval path uses Ed25519 key separation; there
is no persistent nonce ledger; the tier classifier is a path-based demonstration. See `docs/PROOF.md`.

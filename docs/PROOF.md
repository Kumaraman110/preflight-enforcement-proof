# Design & proof harness

This repository proves a two-stage, fork-safe remote decision gate on real GitHub. It is a
self-contained demonstration with new git history and no proprietary content.

## Platform facts the design rests on

- **A `workflow_run` workflow runs only from the default branch.** So the privileged Stage 2
  cannot be introduced or altered by a PR — it is defined once, on `main`, in the trusted context.
- **Fork PRs receive no secrets** (only a read-only `GITHUB_TOKEN`). So Stage 1 (`pull_request`)
  is structurally unable to read signing keys; it also references none, so same-repo PRs can't either.
- **A `workflow_run` job's own check attaches to the default-branch commit, not the PR head.** So the
  decision is published back onto the PR head as a **commit status** (`preflight-remote-decision-gate`)
  by the trusted default-branch workflow; branch protection requires that status context.

## Trust roles (least privilege, disjoint secrets)

| Role | Trigger / context | Holds | Trusted for |
|---|---|---|---|
| Untrusted PR | `pull_request` | nothing | proposing a commit + raw hint files |
| A — generate | `workflow_run`, default branch | no signing key | independently deriving tier + tests from the commit |
| B — seal | `workflow_run`, default branch | bundle key only | authenticating the derived evidence (HMAC) |
| C — decide | `workflow_run`, default branch | attest key + approval PUBLIC key | the decision, the attestation, the required commit status |
| approver | `workflow_dispatch`, protected env | approval PRIVATE key | minting a scoped approval (distinct authority) |

No single job both signs evidence and issues the decision. The evidence generator — the only job
that ingests the untrusted subject — holds no signing key.

## Why forged clearance cannot pass

- **Independent tier derivation.** The tier comes from `git diff base..head` (the files the PR
  actually changed — unforgeable), not from any PR-authored `tier.txt`. A protected-path change that
  lies `AUTO` is still `BLOCK`.
- **Independent identity re-resolution.** The verifier re-derives repo + commit from the fetched
  subject checkout. A forged `subject.head` → `identity.commit-mismatch` → BLOCK.
- **Trusted judge code.** The verifier + policy are checked out from the default branch
  (`--pkg-root`), never the PR tree. A PR that rewrites the verifier/policy is ignored (and touching
  `verifier/`/`protocol/` classifies BLOCK anyway).
- **Evidence authenticity.** The bundle is HMAC-signed by the sealer; an unsigned/forged bundle is
  rejected (`--require-bundle-attestation`).
- **No self-approval.** The judge holds only the Ed25519 **public** key; only the separate approve
  workflow (protected environment, distinct required reviewer) holds the private key. The approval is
  scoped to `repo|pr|commit|actionDigest|evidenceDigest|policyVersion|decisionDigest|expiry|nonce`,
  so it cannot be replayed onto another commit/action/evidence, or reused past expiry.

## Exit-code → status contract

`0` ALLOW → commit status `success`. `10` REQUIRE_APPROVAL, `20` BLOCK, `30` fail-closed
(missing key/artifact/identity), any other → commit status `failure`. A timed-out or cancelled job
is a GitHub non-success and can never be read as ALLOW.

## Known limitations (not production-ready)

- HMAC is symmetric (the sealer and judge share the bundle key; the attest key signs decisions).
  True non-repudiation / fully-disjoint sign-vs-verify custody needs asymmetric signing (Ed25519 /
  OIDC→KMS). The approval path already uses Ed25519 key separation.
- No persistent nonce ledger; within-window replay onto the *same* commit is bounded by expiry.
- The tier classifier is a path-based demonstration, not a real risk model.
- The evidence generator's `tests-pass` check is illustrative; a production generator would
  re-execute the test suite rather than attest its presence.

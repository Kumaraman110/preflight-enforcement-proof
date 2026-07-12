# Enforcement proof — live GitHub evidence

This records the executable evidence produced on real GitHub for this public proof repo. All keys are
throwaway test-only keys; no production system, secret, or organization identifier is involved.

- **Repository:** https://github.com/Kumaraman110/preflight-enforcement-proof (public)
- **Trusted workflow commit (default branch `main`):** see `git log main` — the gate machinery, verifier,
  and policy that decide runs execute are pinned to `main` (not the PR tree).

## Required-check merge prevention (headline)

Branch protection on `main`: `required_status_checks` = `["preflight-remote-decision-gate"]`,
`strict: true`, `enforce_admins: true` (no admin bypass).

| PR | change | decision | commit status | mergeStateStatus | merge attempt |
|----|--------|----------|---------------|------------------|---------------|
| #1 `pr-valid` | `app/safe/**` | ALLOW | `success` | CLEAN / MERGEABLE | eligible |
| #2 `pr-blocked` | `app/protected/**` (lies AUTO) | BLOCK | `failure` | BLOCKED | **refused** |
| #3 `pr-confirm` | `app/review/**` | REQUIRE_APPROVAL | `failure` | BLOCKED | needs approval |
| #4 `pr-judge-replace` | rewrites verifier+policy | BLOCK | `failure` | BLOCKED | refused |
| #5 `pr-forge-clearance` | protected + smuggled ALLOW `decision.json` | BLOCK | `failure` | BLOCKED | refused |

`gh pr merge 2 --merge` → *"not mergeable: the base branch policy prohibits the merge"* (no `--admin`).
A PR with no decision status yet is also `BLOCKED` (the required context is "expected") — a skipped,
cancelled, or never-run decide cannot make a PR mergeable.

## What each case proves

- **valid → ALLOW** (#1): independent verification + a signed decision attestation bound to the commit.
- **forged tier / protected change → BLOCK** (#2): the trusted classifier derives the tier from the
  files actually changed; the PR's `tier.txt` hint is ignored.
- **judge replacement → BLOCK** (#4): the verifier + policy run from the default branch (`--pkg-root`);
  the PR's rewritten verifier/policy are never executed.
- **forged local clearance → BLOCK** (#5): a PR-committed `decision.json` claiming ALLOW is ignored;
  the decision is re-derived independently.
- **REQUIRE_APPROVAL → gated** (#3): upgraded only by a distinct Ed25519 approval minted in the
  protected `preflight-approval-authority` environment; the judge holds only the public key.

## Secret isolation

- Stage 1 (`collect`, `pull_request`) references no secrets and grants only `contents: read`; fork PRs
  receive no secrets. The untrusted stage cannot read signing keys.
- Stage 2 jobs have disjoint secret scope: `generate` (none), `seal` (bundle key), `decide` (attest +
  bundle + approval public key). The Ed25519 approval **private** key exists only as an
  environment-scoped secret in `preflight-approval-authority`.

## Approval authority (environment protection)

`preflight-approval-authority`: `can_admins_bypass: false`, a `required_reviewers` rule with
`prevent_self_review: true`. A dispatched approve run enters `waiting`; the initiator's
`current_user_can_approve` is `false` (self-approval refused). The valid-approval → ALLOW upgrade was
demonstrated end-to-end with a distinct Ed25519 signature verifying under the committed public key.

## Fixes surfaced by live execution (this repo + the design's evolution)

- `actions: read` needed for cross-run artifact download.
- private-repo git fetch must be authenticated (automatic per-run token via `http.extraheader`).
- absolute paths for intent/bundle/out-dir (the entrypoint `cd`s into `--pkg-root`).
- deterministic `producedAt` (commit committer-date) + stable decision digest so the out-of-band
  approval binding is reproducible across a decide re-run.
- decision published as a commit status on the PR head (a `workflow_run` job's own check does not
  attach to the PR head commit).

## Honest limitations

- HMAC is symmetric (the bundle key is shared sign/verify; the attest key signs decisions). The
  approval path uses Ed25519 key separation; full non-repudiation / disjoint sign-vs-verify custody
  needs asymmetric signing everywhere (Ed25519 / OIDC→KMS).
- The required reviewer is a single account, so human dual-control cannot complete here; the mechanism
  (env required-reviewer + `prevent_self_review` + `can_admins_bypass: false` + env-only private key) is
  correctly configured and enforced, but true dual-control needs a second distinct reviewer.
- The tier classifier is a path-based demonstration, not a production risk model.
- The evidence generator's `tests-pass` check is illustrative (it attests the presence of a test log);
  a production generator would re-execute the suite.
- No persistent nonce ledger; within-window replay onto the *same* commit is bounded by expiry.
- A commit-status required check can also be satisfied by any human with repo write + `repo:status`
  scope posting the context manually — a general GitHub property, mitigated by restricting write access.

**This is a sandbox demonstration. Passing here does not establish production readiness.**

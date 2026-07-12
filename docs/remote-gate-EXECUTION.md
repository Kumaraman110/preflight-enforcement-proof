# Execution readiness — smallest human authorization steps (v0.2)

The remote gate branch is **complete, tested, and local**. Nothing below has been performed —
each step is a human decision because it is outward-facing or irreversible. Commands are exact
and copy-pasteable. Branch: `feature/preflight-remote-decision-gate-v0.1` @ `96c9ad0`
(7 commits on base `dac97e8`), worktree `C:/Users/v173617/Source_Code/code-forge-rdg`,
remote `origin = https://github.com/United-Airlines-Org/preflight.git`.

> NOTE ON SCOPE: `origin` is the canonical/shared remote. Pushing a NEW feature branch to it is
> a normal, reversible operation (an unprotected branch), but it IS an outward-facing publish and
> so requires explicit human authorization here. Do NOT push to `main`/`master`, do NOT force-push,
> do NOT open the PR against a protected base, and do NOT alter branch protection without a
> separate, explicit decision.

## Step 1 — Push the feature branch (reversible; publishes the branch)

Smallest human action: publish the local branch to origin (a new, unprotected branch — no history
rewrite, no protected-branch write).

```bash
cd C:/Users/v173617/Source_Code/code-forge-rdg
# Review first:
git log --oneline dac97e8..HEAD
git diff --stat dac97e8..HEAD
# Publish (sets upstream). This is the outward-facing action requiring authorization:
git push -u origin feature/preflight-remote-decision-gate-v0.1
```
Rollback: `git push origin --delete feature/preflight-remote-decision-gate-v0.1` (the branch is
new; deleting it removes nothing else).

## Step 2 — Open the PR (reversible; against a NON-protected integration base)

Open against the integration branch (`feature/preflight-framework`), **not** a protected release
branch. Use the prepared body in `docs/remote-gate-PR.md`.

```bash
gh pr create \
  --repo United-Airlines-Org/preflight \
  --base feature/preflight-framework \
  --head feature/preflight-remote-decision-gate-v0.1 \
  --title "feat(remote-gate): independently-enforceable remote/CI decision gate on Protocol v0.1" \
  --body-file docs/remote-gate-PR.md
```
(The kernel's own push/PR gate governs `gh pr create` — confirm the base/repo are the intended,
non-forbidden targets. This is a draft-quality PR; mark ready only after review.)
Rollback: `gh pr close <n>` (no code impact).

## Step 3 — Provision a TEST signing secret or OIDC identity (reversible)

For a real workflow run the trusted Stage 2 needs `PREFLIGHT_ATTEST_KEY` (and, for approvals, the
distinct `PREFLIGHT_APPROVAL_KEY`). For a **test** run, use a throwaway HMAC secret; for production
prefer OIDC→KMS/Ed25519 (see docs/remote-gate.md).

```bash
# TEST secrets (random values — never production keys). BUNDLE key is required for fork-safety.
python -c "import secrets;print(secrets.token_hex(32))" | gh secret set PREFLIGHT_ATTEST_KEY   --repo United-Airlines-Org/preflight
python -c "import secrets;print(secrets.token_hex(32))" | gh secret set PREFLIGHT_BUNDLE_KEY   --repo United-Airlines-Org/preflight
python -c "import secrets;print(secrets.token_hex(32))" | gh secret set PREFLIGHT_APPROVAL_KEY --repo United-Airlines-Org/preflight
```
Note: the producer that assembles the evidence bundle must sign it with `PREFLIGHT_BUNDLE_KEY`
(via `seal_bundle.py --attestation-key-file`); a fork that lacks the key cannot self-classify.
Rollback: `gh secret delete PREFLIGHT_ATTEST_KEY --repo …` (and the approval key).

## Step 4 — Run the workflow (reversible; observation only)

The workflow triggers on `pull_request` (Stage 1) and then `workflow_run` (Stage 2). On a real PR
both run automatically. To exercise it, ensure the producer's `intent.json`/`bundle.json` exist at
`.preflight/protocol/` on the PR head (the claude-code adapter emits these), then push a commit to
the PR branch. Inspect the `preflight-remote-decision` artifact for `decision.json` +
`attestation.json`. Rollback: none needed — it only reads + decides; `contents: read` only.

## Step 5 — Configure the required status check on a NON-PRODUCTION test branch (protected-setting change)

This is the only step that touches branch protection, and ONLY on a throwaway test branch — never
the real protected branch without a separate decision.

```bash
# Create an isolated test branch to gate (does not affect main/release):
git push origin dac97e8:refs/heads/test/remote-gate-trial
```
Then in the GitHub UI (Settings → Branches → branch protection rule for `test/remote-gate-trial`),
add the **Stage-2** required check named **`Independent remote decision gate`**. Do NOT add the
Stage-1 `Collect claim …` check. Rollback: delete the protection rule and the test branch
(`git push origin --delete test/remote-gate-trial`).

## What must NOT be done without a separate explicit decision

- Any push to `main` / `master` / a release branch, any force-push, any tag move, any release.
- Adding the required check to a **production** protected branch.
- Merging this PR.
- Anything touching PR #12 (`pr/p0-router-engine-split`) or the dirty pilot.

## Current state (as delivered — nothing outward performed)

- Branch is LOCAL only (no upstream). No push, no PR, no secret, no workflow run, no
  branch-protection change has been performed by this work.
- PR #12 `pr/p0-router-engine-split` @ `dac97e8` (unchanged). Tags unchanged. Main worktree carries
  only the pre-existing ` M tests/run-all-tests.sh`.

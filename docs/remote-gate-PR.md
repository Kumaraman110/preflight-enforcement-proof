# PR package — Preflight Remote Decision Gate v0.2

This is the review/rollout package for the `feature/preflight-remote-decision-gate-v0.1`
branch. It is **not** an instruction to push or open a PR — see "Remaining human authorization
steps". Nothing here mutates branch protection, merges, releases, or touches PR #12 / the pilot.

## Proposed PR title

`feat(remote-gate): independently-enforceable remote/CI decision gate on Protocol v0.1`

## Proposed PR body (concise)

Turns Preflight Protocol v0.1 into an **independently enforceable** remote/CI decision gate.
A locally forged or self-issued clearance cannot make an independently executed verification
pass — the property the local trust kernel structurally cannot provide.

- **Independent verifier** re-resolves repository + commit identity **from the CI checkout**
  (not the claimed `subject`), recomputes artifact hashes, validates schema / provenance /
  freshness / consistency / policy, and returns `ALLOW` / `REQUIRE_APPROVAL` / `BLOCK`.
- **Signed attestation** (HMAC over a canonical payload bound to repo, commit, action digest,
  evidence digest, policy/verifier version, issued/expiry, run/nonce). Tamper / expiry / replay
  across commit·action·repo / wrong-key all fail closed.
- **Policy exception path**: `REQUIRE_APPROVAL` is upgraded only by a separate, attributable
  approval signed with a **distinct approver key** — a producer cannot self-approve.
- **Fork-safe CI**: a two-stage trusted split (untrusted `collect` with no secrets → trusted
  `decide` running the verifier + policy from the base ref against the PR commit as data-only),
  least-privilege, SHA-pinned actions, fail-closed on missing signing material. Evidence
  authenticity is enforced via a distinct `PREFLIGHT_BUNDLE_KEY` + `--require-bundle-attestation`
  so a fork cannot self-classify its own tier (identity re-resolution + evidence authentication
  together — see the "fork-safe" scope note in `docs/remote-gate.md`).
- Additive only. The local kernel and every existing test are unchanged (`local-advisory` mode
  is a byte-identical no-op). Stdlib-only Python; no third-party deps; no secrets in the repo.

## Architecture summary

Five separable layers (full detail: `docs/remote-gate.md`, `protocol/PROTOCOL.md`):
1. **Producer adapters** — emit an Action Intent + Evidence Bundle; cannot issue final clearance.
2. **Independent verifier** (`verifier/pfverify/`) — `--mode remote-authoritative` re-resolves
   identity from the checkout; fail-closed pipeline.
3. **Attestation** (`verifier/pfverify/attest.py` + `decision-attestation.v1` schema).
4. **CI/GitHub adapter** (`.github/workflows/preflight-remote-gate.yaml` + portable
   `verifier/ci/remote-gate.sh`) — two-stage trusted split; suitable as a required status check.
5. **Approval** (`verifier/pfverify/approval.py` + `approval.v1` schema) — distinct approver key.

## Threat-model summary (full: `protocol/threat-model.md`)

Defended (each with a fail-closed test): wrong repo / wrong commit / changed-files / forged-local
-ALLOW (identity re-resolution); modified / invalid-sig / expired / replay-across-commit·action·repo
(attestation); producer self-approve / missing / expired / mismatched approval; path-traversal +
symlink-escape (realpath confinement); malformed / missing / stale / contradictory / ambiguous-tier
/ dependency-missing / timeout (pipeline). **Fork forcing ALLOW by editing its own policy/verifier**
is defeated by the trusted `--pkg-root`.

Stated limitations (honest, not hidden): HMAC is symmetric (not public non-repudiation; OIDC/KMS/
Ed25519 is the hardened option); no persistent nonce ledger (within-window replay onto the same
commit bounded by expiry); repo identity compares the host-insensitive `owner/repo` slug; evidence
content is hash-bound, not re-executed, without a separate bundle-signing key.

## Exact test evidence (rerun on this branch)

- Protocol + remote-gate suites via runner: **`bash tests/run-all-tests.sh protocol` → all passed,
  exit 0** (10 suites: verifier-decision 29, schema-contract 7, adapter-and-failmode 11,
  identity-reresolution 18, attestation 12, approval 8, remote-gate-e2e 8, workflow-security 20,
  integration-fixture 9, learning-loop-demo 11).
- Full regression: **`bash tests/run-all-tests.sh` → all pass except the reproduced baseline
  performance failure** (`ir-push-perf`, host-thrash wall/timeout only — see disclosure below).
- Independent adversarial reviews (non-author agents): branch audit + CI-security + hardening
  review — no fail-open found; the fork/force-ALLOW and fail-open-on-missing-key gaps are closed.

## Baseline exception disclosure

The single non-green suite in the full run is **`ir-push-perf`** (the Phase-7 authoritative
performance matrix). Its failures are **wall-clock / timeout only** (`AUTHORITATIVE PERFORMANCE
INSUFFICIENT`), with functionally-correct verdicts, caused by this Windows/CrowdStrike host's
variable per-spawn scan tax (~2× baseline). It **reproduces identically on a pristine `dac97e8`
worktree with none of this branch's changes** — i.e. pre-existing and host-caused, not a
regression introduced here. The engine/router are byte-identical to base. On a settled host (or CI
Linux) it is expected to pass. This is the ONLY excepted failure.

## Rollout plan

1. Merge the branch (human) to the integration branch; no behavior changes to the local kernel.
2. Add org/repo secrets `PREFLIGHT_ATTEST_KEY` (decision), `PREFLIGHT_BUNDLE_KEY` (evidence
   authenticity — required for fork-safety), + distinct `PREFLIGHT_APPROVAL_KEY` (or wire OIDC→KMS).
3. Enable the workflow for the target branch(es).
4. Observe the Stage-2 `Independent remote decision gate` check on real PRs (advisory first).
5. Once trusted, add the **Stage-2** check as a required status check on a **non-production test
   branch** first; promote to the protected branch only after a soak period.

## Rollback plan

- The change is **additive**: reverting the merge (or disabling the workflow) fully restores prior
  behavior — the local kernel, router, engine, and all existing tests are untouched.
- Remove the required-status-check setting (branch-protection UI) to stop gating instantly; no code
  revert needed to un-gate.
- Rotate `PREFLIGHT_ATTEST_KEY` / `PREFLIGHT_APPROVAL_KEY` if key custody is ever in doubt; old
  attestations expire on their `expiresAt`.

## Operator steps — required status check (see docs/remote-gate.md)

1. Provision secrets `PREFLIGHT_ATTEST_KEY` + `PREFLIGHT_APPROVAL_KEY` (never commit them).
2. Enable the workflow.
3. Branch protection → add **`Independent remote decision gate`** (Stage 2) as a required check.
   Do NOT require the untrusted Stage-1 `Collect claim …` check.

## Operator steps — signing-key custody

- Keys live only in GitHub secrets (or a KMS via OIDC), never in the repo. The **approver key must
  not be held by any producer / authoring agent** — that separation is what prevents self-approval.
- Prefer OIDC→KMS/Ed25519 in production so no long-lived symmetric secret is stored.
- Rotate on schedule; attestations are short-lived (`expiresAt`), so rotation is low-risk.

## Known limitations

See the threat-model summary above and `protocol/threat-model.md` "Remaining production gaps".

## Reviewer checklist

- [ ] Diff is product-only (protocol/ verifier/ tests/ .github/workflows/ + additive run-all-tests.sh).
- [ ] `bash tests/run-all-tests.sh protocol` is all-green on your host/CI.
- [ ] Full suite green except the disclosed `ir-push-perf` host-perf exception.
- [ ] Workflow is `contents: read` only; actions SHA-pinned; two-stage split; `--require-attestation`.
- [ ] Signing keys come only from secrets in Stage 2; approver key is distinct and producer-inaccessible.
- [ ] `tests/protocol/integration-fixture-test.sh` case 7b (fork policy/verifier tamper) BLOCKs.
- [ ] No secrets / keys / machine-paths committed.
- [ ] PR #12, pilot, protected branches, tags, releases untouched.

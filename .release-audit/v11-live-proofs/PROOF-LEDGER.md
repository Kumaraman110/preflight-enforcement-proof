# v0.11 Live Enforcement Proof Ledger

Repo: **Kumaraman110/preflight-enforcement-proof** (PUBLIC, disposable). Default branch `main`,
protection: required status `preflight-remote-decision-gate`, `strict:true`, `enforce_admins:true`.
Deployed gate = logically identical to reconciled mainline `c47c1bb` (only CRLF + public-repo
sanitization: `producer-a/producer-test` issuers, `example.invalid` schema `$id`; full 11-stage
pipeline byte-identical).

Authority separation (verified in workflow source):
- **collect.yaml** (untrusted PR context): NO secrets.
- **decide→generate** (ingests untrusted subject as data): NO signing key.
- **decide→seal**: `PREFLIGHT_BUNDLE_KEY` only (HMAC the bundle).
- **decide→decide** (judge): `PREFLIGHT_ATTEST_KEY` + `PREFLIGHT_APPROVAL_KEY` (**public** verify) + bundle key (verify). Cannot mint approvals.
- **approve.yaml**: `PREFLIGHT_APPROVAL_ED25519_PRIV` — **environment-scoped** (`preflight-approval-authority`), never a repo secret; the judge never holds it.

## Live decisions (isolated variables — every case carries a valid tests-pass log so the BLOCK/decision is attributable to the tested variable, not a missing-evidence artifact)

| # | PR | scenario | derived tier | decision | commit status | run |
|---|----|----------|--------------|----------|---------------|-----|
| 1 | [#10](https://github.com/Kumaraman110/preflight-enforcement-proof/pull/10) | valid safe change (`app/safe`) | AUTO | **ALLOW** | SUCCESS | 29393751518 |
| 2 | [#13](https://github.com/Kumaraman110/preflight-enforcement-proof/pull/13) | forged local ALLOW (`.gate/decision.json`) + protected edit | BLOCK | **BLOCK** | FAILURE | 29393989874 |
| 3 | [#12](https://github.com/Kumaraman110/preflight-enforcement-proof/pull/12) | PR weakens the verifier (`engine.py`) | BLOCK | **BLOCK** | FAILURE | 29393979081 |
| 4 | [#11](https://github.com/Kumaraman110/preflight-enforcement-proof/pull/11) | protected-path edit (`app/protected`) | BLOCK | **BLOCK** | FAILURE | 29393965127 |
| 5 | [#14](https://github.com/Kumaraman110/preflight-enforcement-proof/pull/14) | review-tier change (`app/review`) | CONFIRM | **REQUIRE_APPROVAL** | FAILURE | 29394003048 |

### Key attributions proven
- **valid → ALLOW** (#10): all 15 checks passed; tier AUTO → ALLOW; the ONLY success status.
- **forged local ALLOW ignored** (#13): the PR shipped `.gate/artifacts/decision.json = {"decision":"ALLOW"}`; the trusted gate re-derived tier=BLOCK from the actual changed paths and blocked. Producer's clearance carries no weight.
- **modified verifier ignored** (#12): PR added `"attacker"` to `KNOWN_ISSUERS` in `verifier/pfverify/engine.py`. The judge ran the **trusted default-branch verifier** — `provenance.issuer` still passed only for `producer-a` (the trusted list), and blocked because `verifier/` is a protected path. The PR's tampered verifier had zero effect.
- **review → REQUIRE_APPROVAL** (#14): tier CONFIRM maps to REQUIRE_APPROVAL (rc=10, non-success).
- **merge-refusal** (#11): `gh pr merge 11 --merge` → `"the base branch policy prohibits the merge"`. GitHub refuses to merge the BLOCKed PR. `--admin` break-glass offered but NOT used (honest admin-bypass boundary).

Tier→decision mapping (from decision artifacts): AUTO→ALLOW · CONFIRM→REQUIRE_APPROVAL · BLOCK→BLOCK.
Every decision artifact (`gate-out/decision.json`) + sealed bundle downloaded under `.release-audit/v11-live-proofs/final-p<N>/`.

## Remaining cases (identity + attestation + approval layers)

| # | scenario | decision | how proven | evidence |
|---|----------|----------|-----------|----------|
| 6 | valid independent approval upgrades REQUIRE_APPROVAL → ALLOW | ALLOW | Ed25519: approver-signed scoped payload verifies under the judge's PUBLIC key | `v11-approval-harness` (a): exit 0 |
| 7 | PR-authored / self-approval ignored | REJECTED | approval signed by any non-approver key (a PR author cannot hold the env-scoped private key) fails signature verify; an unsigned ALLOW json also fails | harness (b) exit 20, (b2) exit 20; protocol `approval-test.sh` 8/0 |
| 8 | wrong commit → BLOCK | BLOCK | trusted remote re-resolution: `identity.commit-mismatch` | `identity-reresolution-test.sh` 18/0 |
| 8 | wrong repo → BLOCK | BLOCK | `identity.repo-mismatch` (forged origin AND expected-repo-disagrees) | same suite |
| 9 | tamper / replay → BLOCK | BLOCK | attestation digest/signature/expiry/wrong-key all fail-closed; approval replay onto a different commit fails payload-equality | `attestation-test.sh` 12/0; harness (c) exit 20 |
| 10 | forged local ALLOW dies remotely (core threat) | BLOCK | a bundle that ALLOWs locally with a forged head → BLOCK `identity.commit-mismatch` remotely | `identity-reresolution-test.sh` |
| 11 | missing secret → failed check (LIVE) | fail-closed rc=30 | deleted `PREFLIGHT_ATTEST_KEY`, re-ran decide → `final_rc=30`, decision BLOCK, commit-status FAILURE; restored key → ALLOW again | decide run **29394711281** (FAILURE) → **29395201817** (SUCCESS after restore) |

## Merge-refusal (DONE-WHEN #4)
`gh pr merge 11 --merge` → **"the base branch policy prohibits the merge"**. GitHub refuses to merge a BLOCKed PR. `--admin` break-glass offered but NOT used.

## Honest platform ceilings (re-confirmed live, not faked)
- **Human dual-control is deployed AND enforced but not completable with one human.** The `preflight-approval-authority` environment has `required_reviewers` + `prevent_self_review:true` + `can_admins_bypass:false`, reviewer=`Kumaraman110`. When `Kumaraman110` dispatched `approve.yaml`, the pending deployment reported **`current_user_can_approve:false`** — the initiator is genuinely blocked from self-releasing the signer. Completing it needs a DISTINCT second human.
- **A distinct second human is unavailable on these accounts.** Adding `v173617_ual` (the only other account) as a collaborator was refused by GitHub: **HTTP 422 "Enterprise Managed Users cannot be invited to this repository because this Enterprise uses personal accounts."** This is a concrete external-authorization boundary. The approval SEPARATION proven here is therefore **cryptographic** (the judge holds only the public key → can verify, never mint) plus **enforced-but-uncompletable human dual-control**; true two-human completion needs a Team/Enterprise org with two members, or OIDC→KMS. Documented, not smoothed over.
- **Commit status is forgeable by any `statuses:write` holder** (branch protection matches context+state, not poster identity). The unforgeable proof-of-record is the signed `gate-out/attestation.json`. A hardened deployment should use a GitHub-App check-run with a pinned app-id. (Documented in the workflow + ops docs.)
- **HMAC is symmetric**: seal (sign) and judge (verify) share `PREFLIGHT_BUNDLE_KEY`. Full disjoint custody needs asymmetric OIDC→KMS. The security-critical separation still holds: the evidence GENERATOR (which ingests the untrusted subject) holds NO key.

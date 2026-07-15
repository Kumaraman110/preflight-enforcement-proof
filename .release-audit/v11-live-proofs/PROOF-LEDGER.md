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

## Remaining cases — with an honest LIVE vs OFFLINE-SUITE label

An independent adversarial reviewer (byte-verified the deployed gate == live `main`, then probed each
claim; see `ADVERSARIAL-REVIEW-COREECTIONS` below) required these to be labeled by *evidence kind*.
"LIVE" = observed on real GitHub against the deployed gate. "OFFLINE-SUITE" = proven by a protocol test
on the byte-identical deployed module (stubbed git / matching keys) — a correct algorithm proof, NOT a
live GitHub enforcement observation.

| # | scenario | decision | evidence kind | how proven |
|---|----------|----------|---------------|-----------|
| 6 | wrong commit → BLOCK | BLOCK | **OFFLINE-SUITE** | `identity-reresolution-test.sh` 18/0 (`identity.commit-mismatch`); no live PR forced an identity mismatch |
| 7 | wrong repo → BLOCK | BLOCK | **OFFLINE-SUITE** | same suite (`identity.repo-mismatch`, forged origin AND expected-repo-disagrees) |
| 8 | tamper / replay → BLOCK | BLOCK | **OFFLINE-SUITE** | `attestation-test.sh` 12/0 (digest/signature/expiry/wrong-key fail-closed); approval replay onto a different commit fails payload-equality |
| 9 | forged local ALLOW dies remotely (core threat) | BLOCK | **OFFLINE-SUITE** + LIVE analog | `identity-reresolution-test.sh` (offline); the LIVE analog is PR#13 (forged `.gate` ALLOW → BLOCK) |
| 10 | PR-authored / foreign approval REJECTED by the DEPLOYED judge | REJECTED | **LIVE-KEY** | a Ed25519 approval signed by a NON-deployed key fails verification **under the deployed `gate/approval-pub.pem`** (`O86e…`): exit 20. A PR author cannot hold the env-scoped private key, so any approval they mint is rejected by the deployed public key. Positive control: it verifies under its own key (exit 0). |
| 11 | valid independent approval upgrades REQUIRE_APPROVAL → ALLOW | ALLOW | **OFFLINE-SUITE only — NOT proven live** | `approval-test.sh` 8/0 exercises the deployed `pfverify.approval` + `check-approval.sh` with MATCHING keys and REAL reconstructed digests. **No live REQUIRE_APPROVAL→ALLOW upgrade has occurred on this repo** — both `approve.yaml` runs were cancelled (single-operator `prevent_self_review` blocks the initiator; the deployed private key is correctly inaccessible). See ceilings. |
| 12 | missing secret → failed check | fail-closed rc=30 | **LIVE** | deleted `PREFLIGHT_ATTEST_KEY`, re-ran decide → `final_rc=30`, decision BLOCK (`attestation-key-unavailable`), commit-status FAILURE; restored → ALLOW. decide run **29394711281** (FAILURE) → **29395201817** (SUCCESS) |

> Note: an earlier `v11-approval-harness` "valid approval → ALLOW" step used a FRESHLY-GENERATED key
> (`WeOf1…`, not the deployed `O86e…`) with placeholder digests. That proved only the Ed25519
> algorithm, NOT the deployed judge. It is superseded by row 10 (deployed-key rejection, LIVE) + row 11
> (algorithm with matching keys/real digests, OFFLINE-SUITE, explicitly not-live). Corrected per review.

## Merge-refusal (DONE-WHEN #4) — CONFIRMED, and stronger than first stated
`gh pr merge 11 --merge` → **"the base branch policy prohibits the merge"**. GitHub refuses to merge a
BLOCKed PR. `--admin` break-glass offered but NOT used. **The required check is pinned to `app_id:15368`
(GitHub Actions):** an adversarial live test posted a forged `success` on the
`preflight-remote-decision-gate` context **as a user PAT** — the PR **stayed BLOCKED** (the non-Actions-app
status does not satisfy the app-id-pinned required check). Status restored to failure afterwards.

## Correction to Claim 3 (PR#12, PR-modified verifier)
CONFIRMED that the judge uses the TRUSTED default-branch verifier (workflow checks out `ref: main`,
`--pkg-root $PWD/gate`; offline `verifier-decision-test.sh` case4 proves an in-subject malicious
policy+verifier is ignored). BUT for **this** PR the `KNOWN_ISSUERS += "attacker"` edit was doubly
INERT — `verifier/` is a protected path (tier=BLOCK short-circuits) AND the bundle issuer `producer-a`
was already trusted. So PR#12's BLOCK is attributable to the protected-path rule, not to a live
demonstration of trusted-checkout beating a hostile verifier. The trusted-checkout guarantee rests on
the byte-identical workflow structure + the offline case4, not on this live PR. A live PR editing a
NON-protected verifier constant to attempt forced-ALLOW was not run.

## Honest platform ceilings (re-confirmed live; corrected per adversarial review)
- **Human dual-control is deployed AND enforced but not completable with one human.** The
  `preflight-approval-authority` environment has `required_reviewers` + `prevent_self_review:true` +
  `can_admins_bypass:false`, reviewer=`Kumaraman110`. When `Kumaraman110` dispatched `approve.yaml`, the
  pending deployment reported **`current_user_can_approve:false`** — the initiator is genuinely blocked.
  Completing an upgrade needs a DISTINCT second human, which is why **claim 11 is not proven live.**
- **A distinct second human is unavailable on these accounts.** Adding `v173617_ual` as a collaborator
  was refused: **HTTP 422 "Enterprise Managed Users cannot be invited to this repository because this
  Enterprise uses personal accounts."** The approval separation proven is therefore **cryptographic**
  (deployed judge holds only the public key → verifies, never mints; a foreign-key approval is rejected
  under the deployed key — row 10, LIVE) plus **enforced-but-uncompletable human dual-control**.
- **Commit status forgeability — CORRECTED (was overstated pessimistic).** The required check on this
  deployment is pinned to **`app_id:15368` (GitHub Actions)**, so a forged `success` from a user PAT /
  broad PAT does **not** satisfy the gate (verified live — the forged status left PR#11 BLOCKED). Only a
  status posted by the GitHub Actions app from the trusted default branch counts; a fork/PR `collect.yaml`
  has `contents:read` only and cannot post it. The signed `attestation.json` remains the proof-of-record
  for defense-in-depth, but the "any `statuses:write` holder can bypass the merge gate" framing is
  empirically FALSE on this deployment — the app-id pin strengthens the required-check guarantee.
- **HMAC is symmetric**: seal (sign) and judge (verify) share `PREFLIGHT_BUNDLE_KEY`. Full disjoint
  custody needs asymmetric OIDC→KMS. The security-critical separation still holds: the evidence
  GENERATOR (which ingests the untrusted subject) holds NO key.

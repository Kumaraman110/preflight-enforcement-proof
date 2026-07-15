# Preflight v0.11.0-rc.1 — Enterprise Pilot (release candidate)

**Release candidate.** Linear descendant of the `v0.10.1` commit (`c47c1bb`). The `v0.10.0` and
`v0.10.1` tags, artifacts, and checksums are immutable and unchanged. This RC **does not change the
local-core enforcement engine** — the certification proves `hooks/` and `lib/` are byte-identical to
v0.10.1. It consolidates the mainline and adds operational proof + docs for the independent remote
decision gate.

## Headline

1. **One authoritative mainline.** `feature/preflight-framework` now contains v0.10.1 and the full
   remote-gate protocol on one linear history. PRs #12/#13 and the release-only packaging branch are
   superseded. Future work builds on the dev line, not a release-only branch.
2. **The remote decision gate runs as a REQUIRED GitHub status check** on a non-production repo, with
   all nine enforcement behaviors proven live/deterministically and the producer/signer/judge/approver
   authorities separated.
3. **The self-improvement loop is closed once on real services** — a genuine historical defect became
   an approved rule that catches an equivalent defect in a second real service before delivery.

## Remote decision gate — proven enforcement (evidence: `.release-audit/v11-live-proofs/PROOF-LEDGER.md`)

Labeled by evidence kind (honesty over headline count; independently adversarially reviewed):

| case | result | evidence |
|---|---|---|
| valid evidence | **ALLOW** (only success status) | LIVE |
| forged local ALLOW | **BLOCK** (trusted gate re-derives; producer clearance ignored) | LIVE |
| protected-path change | **BLOCK** (tier→BLOCK) | LIVE |
| review-tier change | **REQUIRE_APPROVAL** | LIVE |
| missing secret / dependency | **fail-closed** (rc 30) — deleted + restored the attest key | LIVE |
| PR-authored / foreign-key approval | **REJECTED under the deployed judge public key** (a PR author cannot hold the env-scoped private key) | LIVE (deployed key) |
| failing required check | **GitHub refuses the merge**; the required check is app-id-pinned so a forged user-PAT status does NOT bypass it (verified adversarially) | LIVE |
| wrong commit / repo | **BLOCK** (`identity.commit-mismatch` / `identity.repo-mismatch`) | OFFLINE suite on byte-identical deployed module (`identity-reresolution` 18/0) |
| tamper / replay | **BLOCK** (attestation digest/signature/expiry + approval commit-binding) | OFFLINE suite (`attestation` 12/0) |
| PR-modified verifier | **BLOCK** | LIVE, but this PR's BLOCK is via the protected-path rule; trusted-checkout beating a hostile verifier is proven by the workflow structure + offline `verifier-decision` case4, not isolated by this live PR |
| valid independent approval → ALLOW upgrade | REQUIRE_APPROVAL→ALLOW | **NOT proven live** — deployed `prevent_self_review` blocks the single operator; proven at the algorithm layer (`approval` 8/0, matching keys + real digests). Needs a distinct second human or OIDC→KMS. |

Authority separation: `collect` (producer, no secrets) → `decide.generate` (ingests untrusted subject,
no key) → `decide.seal` (bundle key) → `decide.decide` (attest key + public approval key; cannot mint)
→ `approve` (Ed25519 private key, environment-scoped, required reviewer with `prevent_self_review`).

## First real learning loop (evidence: `.release-audit/v11-learning-loop/LEARNING-LOOP-RECORD.md`)

- **Service N** (genuine): CPSL SessionToken (PR-12) silently introduced result codes absent from the
  legacy wire contract (`S0000`, `W0024`) and dropped/substituted legacy codes (`W0011`, `E0002`); the
  code-quality reviewer had no wire-contract check, so it escaped review.
- **Rule** `R-RESULTCODE-PARITY`, adjudicated from that finding, promoted through the
  distinct-approver signed-approval path (the producer cannot self-promote).
- **Service N+1** (real sibling `CTI.MicroService.TokenManager`): on a disposable, never-merged branch,
  the equivalent drift is **caught before delivery** by the promoted rule; the corrected change passes.
- Protected against regression by `tests/behavioral/resultcode-parity-loop-test.sh` (suite 110 → 111).

## Operations

`docs/remote-gate-operations.md` covers installation, rollback, policy ownership, key
rotation/revocation, approval ownership, break-glass, audit retention, incident response, onboarding,
and limitations.

## Certification

`certify-v0.11.0-rc.1.yaml` on windows-latest: a diagnose job (proves the learning-loop rule/gate 5/5
+ descent from v0.10.1 with `hooks`/`lib` byte-identical) and a full-suite job (independently
re-derives **111/111 unique PASS**; a timeout/cancel is never a pass).

## Honest boundaries (unchanged from the gate's design)

- The required check is **app-id-pinned** (GitHub Actions), so a forged status from a user/broad PAT
  does **not** bypass the merge gate (verified adversarially live — a forged user-PAT `success` left the
  BLOCKed PR still BLOCKED). The **signed attestation** remains the proof-of-record for defense-in-depth.
- HMAC is symmetric (seal/judge share the bundle key); asymmetric OIDC→KMS is future work. The
  security-critical separation holds: the evidence generator holds no key.
- Human dual-control is enforced (`prevent_self_review`, `can_admins_bypass=false`) but requires two
  distinct humans; single-account / Enterprise-Managed-User setups cannot complete it (GitHub refuses a
  second EMU collaborator: HTTP 422). The separation proven is cryptographic.
- No persistent nonce ledger; the tier classifier is a path-based demonstration model.
- Admin break-glass (`gh pr merge --admin`) exists and is not preventable at the commit-status layer;
  every use is an audited, attributable admin action.

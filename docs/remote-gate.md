# Preflight Remote Decision Gate v0.1

An **independently enforceable** decision gate built on Preflight Protocol v0.1. It proves
that a locally forged or self-issued clearance **cannot** make an independently executed
verification pass — the property the local trust kernel structurally cannot provide.

## The problem it closes

The local kernel (and the local-advisory verifier) trusts `intent.subject.repo` and
`intent.subject.head` as **claimed** strings. It proves the evidence bundle is internally
self-consistent — not that it describes the tree the verifier is standing in. So a producer
can assert any repo/head, reseal the digest (the documented B2 boundary), and reach a local
`ALLOW`. `hooks/write-gate-evidence` even states it "enforces NO actor check — the
restriction is prompt-level." That is acceptable for a local self-discipline aid; it is not
an accountability guarantee an external party can rely on.

## Architecture (5 separable layers)

```
producer (any model/adapter)          INDEPENDENT execution environment (CI)
──────────────────────────            ─────────────────────────────────────────────────
1. adapter emits                        actions/checkout → real repo + real HEAD
   Action Intent + Evidence Bundle  ┌─▶ 3. verifier/ci/remote-gate.sh
   (CANNOT issue final clearance)   │      └─ pfverify --mode remote-authoritative
                                    │         2. re-resolves repo+commit FROM THE CHECKOUT
   ── artifacts ───────────────────┘            recomputes hashes, validates schema/
                                                 provenance/freshness/consistency/policy
                                                 → ALLOW / REQUIRE_APPROVAL / BLOCK
                                              4. signs a Decision Attestation (HMAC, key
                                                 only CI holds) bound to repo/commit/action/
                                                 evidence/policy/verifier/time/nonce
                                              5. REQUIRE_APPROVAL → needs a separate approval
                                                 artifact signed with a DISTINCT approver key
                                                 (producer cannot self-approve)
                                                 → exit 0/10/20 (usable as required check)
```

1. **Producer adapters** — the Claude Code adapter (`verifier/pfverify/adapters/claude_code_adapter.py`)
   remains one producer. It emits an Action Intent + Evidence Bundle. It **cannot** issue
   final clearance — only a *claim* to be checked.
2. **Independent verifier** — `pfverify --mode remote-authoritative --repo-root <checkout>`
   re-resolves identity from the checkout (`verifier/pfverify/identity.py`), recomputes
   artifact hashes, and runs the full pipeline. Fails closed on every error.
3. **Attestation** — `verifier/pfverify/attest.py` + `protocol/schemas/decision-attestation.v1.schema.json`.
   Deterministic canonical payload, HMAC-signed with a key only the independent environment
   holds. Tamper-evident and replay-resistant.
4. **CI/GitHub adapter** — `verifier/ci/remote-gate.sh` (portable, offline-testable) +
   `.github/workflows/preflight-remote-gate.yaml`. Runs the verifier against the checked-out
   commit, exits non-zero on BLOCK/failure, uploads an inspectable decision + attestation.
5. **Policy exception path** — `verifier/pfverify/approval.py` + `protocol/schemas/approval.v1.schema.json`.
   REQUIRE_APPROVAL is upgraded to a pass only by a separate approval artifact signed with a
   DISTINCT approver key, bound to the exact intent + commit.

## Protocol flow (remote decision)

1. A producer adapter emits `intent.json` + `bundle.json` (the bundle sealed: artifact
   sha256s + `bundleDigest`).
2. CI checks out the target commit and runs `remote-gate.sh`.
3. The verifier re-resolves `git rev-parse HEAD` (authoritative commit) and the canonical
   `origin` repo id, and compares them to the intent's *claimed* `subject.head`/`subject.repo`.
   Any disagreement → `identity.commit-mismatch` / `identity.repo-mismatch` → BLOCK.
4. It recomputes each artifact's sha256 against the **checkout** and checks the worktree is
   clean (`identity.worktree-dirty` if not) — so the evidence provably describes the commit
   under decision.
5. It runs schema/provenance/freshness/consistency/policy checks (unchanged from v0.1) and
   maps the *verified* tier through the policy → ALLOW / REQUIRE_APPROVAL / BLOCK.
6. On a passing decision, CI signs a Decision Attestation with `PREFLIGHT_ATTEST_KEY`.
7. REQUIRE_APPROVAL requires a matching approval signed with `PREFLIGHT_APPROVAL_KEY`.

## Trust boundaries

| Party / input | Trusted for | NOT trusted for |
|---|---|---|
| Producer / adapter | assembling a *claim* (intent + bundle) | `subject.repo`, `subject.head`, `subject.tree`, tier, pass/fail |
| CI checkout (`actions/checkout`) | authoritative repo id + commit SHA + tree bytes | — |
| `.git/config` origin in the checkout | repo id **iff** it matches `--expected-repo` | repo id alone (an attacker-written config is caught by the `$GITHUB_REPOSITORY` cross-check) |
| Evidence artifacts on disk | only as far as sha256 + checkout-confinement verify | anything unhashed / outside the checkout |
| Attestation key (`PREFLIGHT_ATTEST_KEY`) | authenticity of the decision | — (held only in CI, never in the repo) |
| Approver key (`PREFLIGHT_APPROVAL_KEY`) | authenticity of an approval | — (distinct from the attest key; producer never holds it) |
| The verifier + schemas + policy | the accountability root | — (must run where the producer cannot write) |

**Why a locally self-issued ALLOW cannot survive:** in remote-authoritative mode the
verifier re-derives the real `origin` and `HEAD`. A forged `subject.repo` →
`identity.repo-mismatch`; a forged `subject.head` → `identity.commit-mismatch`. If the
forger instead sets `subject.head` to the *real* CI HEAD to slip past, the bundle's
artifacts (whose `boundHead` must equal it) must exist and hash-match **in that checkout** —
evidence manufactured elsewhere won't (`hash.mismatch`/`evidence.missing`), and any
post-checkout tampering is `identity.worktree-dirty`. There is no assignment of the claimed
fields that is simultaneously internally consistent, equal to the re-resolved identity, and
backed by clean, present, hash-matching artifacts — unless the evidence genuinely describes
the commit under decision. (Demonstrated in `tests/protocol/identity-reresolution-test.sh`
case 9: a bundle that ALLOWs locally with a forged head BLOCKs remotely.)

## Threat model — what v0.1 defends (all with a fail-closed test)

| Threat | Mechanism | Code | Test |
|---|---|---|---|
| wrong repository | independent origin re-resolution | `identity.repo-mismatch` | identity #3/#4 |
| wrong commit | independent HEAD re-resolution | `identity.commit-mismatch` | identity #2 |
| changed files after evidence | worktree-clean + hash recompute vs checkout | `identity.worktree-dirty` / `hash.mismatch` | identity #5 |
| forged local ALLOW | re-resolution ignores the claim | `identity.commit-mismatch` | identity #9 |
| modified attestation | recompute payloadDigest | `attestation.forged` | attestation #4 |
| invalid signature | HMAC under CI key | `attestation.signature-invalid` | attestation #3 |
| expired attestation | expiresAt < now | `attestation.expired` | attestation #5 |
| replay across commit/action/repo | signed payload binds all four; binding check | `attestation.binding-mismatch` | attestation #6/#7/#8 |
| producer self-approve | distinct approver key | `approval.signature-invalid` | approval #3, e2e #5 |
| missing/expired/mismatched approval | fail-closed upgrade rule | `approval.*` | approval #2/#4/#5/#6 |
| path traversal / symlink escape | realpath confinement to evidence root + checkout | `artifact.path-escape` | verifier-decision #16 (+ remote confinement) |
| malformed/missing/stale/contradictory/ambiguous-tier/dep-missing/timeout | v0.1 pipeline (preserved) | various | verifier-decision suite |

## Signing / key-management limitations (honest)

- **HMAC is symmetric.** The CI verifier and the attestation signer share the key. This is
  sufficient for the v0.1 guarantee — *an independent execution environment the producer
  cannot access issued this decision* — because the producer never holds the key. It is
  **not** public non-repudiation. Asymmetric signing (Ed25519) is future work.
- **No persistent nonce store (v0.1).** Each attestation carries a `runId` + `nonce`, but
  there is no server-side used-nonce ledger. Within the validity window, an attestation
  could be re-presented for the **same** commit/action/repo. This is bounded by a short
  `expiresAt`, not eliminated. A nonce ledger is future work.
- **`.git/config` trust.** The origin URL in a checkout could be attacker-written. This is
  mitigated by `--expected-repo` (fed from `$GITHUB_REPOSITORY`, which the workflow controls),
  cross-checked against the re-resolved origin. Without `--expected-repo`, only the claim-vs-
  origin equality is checked.
- **Branch protection is NOT applied by this project.** Configuring the workflow as a
  *required status check* is an operator step (below), performed by a human with admin
  rights. Nothing here mutates real branch-protection settings.

## Local vs remote authority

- **local-advisory mode** (default; the local kernel and the plain `pfverify verify`): fast,
  in-process, trusts the claimed subject. A self-discipline aid. Retains the B2 boundary.
- **remote-authoritative mode** (this gate): independent, re-resolves identity, is the
  authority for whether an action may proceed. A local ALLOW is advisory input; the remote
  decision is what a required check enforces.

The two are complementary. The local kernel is unchanged; the remote gate adds an external
accountability layer on top.

## Configuring the required status check (operator step — not automated)

1. Add repository/organization secrets `PREFLIGHT_ATTEST_KEY` (and, if using approvals,
   `PREFLIGHT_APPROVAL_KEY`). Never commit these.
2. Enable the `Preflight Remote Decision Gate` workflow for the branches you want gated.
3. In branch protection for the protected branch, add
   `Independent remote decision gate` as a **required status check**.
4. (Optional) restrict who can add an approval artifact by controlling access to
   `PREFLIGHT_APPROVAL_KEY`.

This project does not perform steps 1–4 for you; they require repo-admin rights and are
outside the safety boundary of the framework build.

## Remaining production gaps

- Asymmetric signing (Ed25519) for non-repudiation.
- A persistent nonce/one-time-use ledger to eliminate within-window replay.
- Adapter registration + key distribution for a real multi-producer deployment (the
  known-issuer set is a hard-coded allow-list in the MVP).
- Binding evidence to a *reproducible* attestation (e.g. a signed CI test run) rather than
  trusting a `tests-pass` claim at face value (v0.1 checks the artifact hash + freshness,
  not re-execution).

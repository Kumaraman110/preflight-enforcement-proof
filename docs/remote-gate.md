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
- **Repo identity is host-insensitive by design.** The repo check compares the trailing
  `owner/repo` slug (not `host/owner/repo`) so it interoperates with `$GITHUB_REPOSITORY`,
  which carries no host. Consequence: the same `owner/repo` on a *different host* (e.g. a
  mirror) compares equal. This is NOT exploitable for repo substitution — the commit SHA and
  tree are still independently re-resolved from the actual checkout, and both
  `$GITHUB_REPOSITORY` and the checkout are workflow-controlled and cannot diverge. If
  host-exact identity is required, pass a fully host-qualified `--expected-repo` and extend
  the comparison to the full canonical slug (future option).
- **Evidence content is not re-executed.** In remote mode the verifier binds repo/commit/tree
  and recomputes artifact *hashes*, but does not re-run tests or re-derive an evidence claim's
  truth. Without a separate bundle-signing key (`--bundle-key-file` / `PREFLIGHT_BUNDLE_KEY`),
  a producer can fabricate a hash-consistent evidence artifact for the real commit. Requiring
  a bundle-signing key closes this; binding evidence to a reproducible attestation is future
  work (see B3 in `../protocol/threat-model.md`).
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

## CI hardening — the two-stage trusted split (fork-safe)

A pull request — especially from a **fork** — is *untrusted code*. If the gate ran its own
policy, verifier, or entrypoint out of the PR checkout, a PR author could edit them to force
`ALLOW`; the judge would be running the defendant's code. The workflow therefore uses a
**two-stage trusted split** (`.github/workflows/preflight-remote-gate.yaml`):

- **Stage 1 — `collect` (`on: pull_request`, untrusted context, NO secrets).** Checks out the
  **exact PR head commit** (`pull_request.head.sha`, not the moving merge ref), packages the
  producer's `intent.json` + `bundle.json` (+ optional `approval.json`) and the head SHA as an
  artifact, and runs **no** gate logic that can go green. It never sees a signing secret.
- **Stage 2 — `decide` (`on: workflow_run` after Stage 1, trusted base context, HAS secrets).**
  Checks out the **trusted gate machinery** (verifier + policy + entrypoint) from the base ref
  into `gate/`; downloads Stage 1's claim artifact; `git fetch`es the exact PR head commit into
  `subject/` as **data only** (never executed); and runs the trusted entrypoint
  `bash gate/verifier/ci/remote-gate.sh --pkg-root "$PWD/gate" --repo-root "$PWD/subject" …`.
  The verifier re-resolves identity against the untrusted subject tree, while **all code and
  policy come from the trusted checkout** (`--pkg-root`), and the signing key is injected here
  only, from a secret. Only **Stage 2's** check should be made required.

Enforced hardening (asserted by `tests/protocol/workflow-security-test.sh`):
- `permissions: contents: read` only, no write scope anywhere; concurrency + timeouts.
- Actions pinned by **immutable commit SHA** (not a mutable `@vN` tag).
- Signing keys come **only** from secrets in Stage 2; **never** from any repo-controlled input
  (no `--*-key-file` flag is wired from PR content, no key env is set from the repo).
- `--require-attestation`: a missing signing key (e.g. a fork without secrets) **fails closed**
  (exit 30) — a required check cannot go green without an independently signed attestation.
- Decision → check: `ALLOW`/approved → exit 0 (success); `REQUIRE_APPROVAL` without a valid
  approval → exit 10 (**non-success**, documented, blocks the check); `BLOCK`/unverifiable →
  exit 20; usage/fail-closed → exit 30. The uploaded `decision.json` disambiguates
  `REQUIRE_APPROVAL` from `BLOCK` at the artifact level.

## What "fork-safe" does and does NOT mean

The two-stage split stops a fork from **editing the judge's code or policy** to force ALLOW (the
verifier + policy run from the trusted base, not the PR). It does **not**, on its own, stop a fork
from **lying in the evidence it submits** — the reversibility `tier` is producer-*claimed*
evidence. If the deployment does not authenticate the evidence bundle, a fork can self-classify
`tier=AUTO` in its own `tier.txt` and get ALLOW for a change a real classifier would rate
CONFIRM/BLOCK. **Provisioning `PREFLIGHT_BUNDLE_KEY` closes this**: the trusted Stage 2 passes
`--require-bundle-attestation`, so a bundle not HMAC-signed under the trusted bundle key is
rejected (`integrity.signature-invalid` → BLOCK). The shipped workflow already wires this; the
operator step below is therefore **required**, not optional, for a genuinely fork-safe required check.

## Configuring the required status check (operator step — not automated)

1. Add repository/organization secrets:
   - `PREFLIGHT_ATTEST_KEY` — signs the decision (required; `--require-attestation`).
   - `PREFLIGHT_BUNDLE_KEY` — authenticates the producer's evidence, incl. the tier claim
     (**required** for fork-safety; `--require-bundle-attestation`). The producer that assembles
     the bundle must hold this key; a fork does not.
   - `PREFLIGHT_APPROVAL_KEY` — the **distinct** approver key (if using approvals).
   Never commit these. For a hardened deployment prefer an OIDC → KMS / Ed25519 signer so no
   long-lived symmetric secret is stored (future work; see "Remaining production gaps").
2. Enable the `Preflight Remote Decision Gate` workflow for the branches you want gated.
3. In branch protection for the protected branch, add the **Stage 2** check
   **`Independent remote decision gate`** as a required status check. Do **not** require the
   Stage 1 `Collect claim …` check (it is untrusted-context and carries no verdict).
4. (Optional) restrict who can add an approval artifact by controlling access to
   `PREFLIGHT_APPROVAL_KEY` (the approver key must not be held by any producer/authoring agent).

This project does not perform steps 1–4 for you; they require repo-admin rights and are
outside the safety boundary of the framework build.

## Remaining production gaps

- Asymmetric signing (OIDC → KMS / Ed25519) for true non-repudiation — the hardened alternative
  to the symmetric-HMAC secret. Recommended for production; keeps no long-lived shared secret.
- A persistent nonce/one-time-use ledger to eliminate within-window replay.
- Adapter registration + key distribution for a real multi-producer deployment (the
  known-issuer set is a hard-coded allow-list in the MVP).
- Binding evidence to a *reproducible* attestation (e.g. a signed CI test run) rather than
  trusting a `tests-pass` claim at face value (v0.1 checks the artifact hash + freshness,
  not re-execution).
- The Stage-2 subject fetch uses the runner-provided `workflow_run.head_sha`, cross-checked
  against the Stage-1-recorded head SHA; a production deployment should additionally verify the
  PR head is an ancestor of / belongs to the expected repo via the API before fetching.

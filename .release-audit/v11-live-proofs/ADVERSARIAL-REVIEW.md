# Adversarial review of the v0.11 live-enforcement proofs (independent, non-author)

An independent reviewer byte-verified the deployed sandbox gate == live mainline (blob-by-blob for
decide/collect/approve workflows, engine.py, identity.py, remote-gate.sh, classify-tier.sh,
check-approval.sh, attest.py, approval.py, canonical.py), reproduced the three cited offline suites
(identity 18/0, attestation 12/0, approval 8/0), and performed ONE live adversarial mutation (a forged
`success` status on PR#11 as a user PAT), then restored it.

## Findings acted on (the ledger was corrected accordingly)

- **HIGH — approval "valid upgrade" was overstated.** The original harness signed with a FRESHLY
  GENERATED key (`WeOf1…`, not the deployed `O86e…`) and placeholder digests → proved only the Ed25519
  algorithm, not the deployed judge. CORRECTED: (a) a new LIVE-KEY test shows a foreign-key approval is
  REJECTED under the deployed `gate/approval-pub.pem` (exit 20) — the anti-self-approval property
  against the real deployment; (b) the "valid approval → ALLOW upgrade" is re-labeled OFFLINE-SUITE
  (`approval-test.sh` 8/0, matching keys + real digests) and explicitly NOT proven live (single-operator
  `prevent_self_review`; EMU 422 blocks a second human).
- **MEDIUM — wrong-commit/repo and tamper/replay are OFFLINE-SUITE**, now labeled as such (byte-identical
  deployed modules, stubbed git) rather than reading as live GitHub observations.
- **LOW — PR#12 (modified verifier) BLOCK is via the protected-path rule** for that PR (the KNOWN_ISSUERS
  edit was doubly inert). Trusted-checkout beating a hostile verifier is proven by the workflow structure
  + offline `verifier-decision` case4, not isolated by this live PR. Clarified in the ledger.
- **CORRECTION (strengthens claim 9) — the required check is app-id-pinned (`app_id:15368`).** The
  reviewer's live forged-status test left PR#11 BLOCKED. The "commit status forgeable by any
  statuses:write holder" ceiling was too pessimistic and is corrected across ledger/CHANGELOG/notes/ops.

## Net verdict
Claims 1,2,6(protected),9(merge-refusal),12(missing-secret) CONFIRMED LIVE; forged-local-ALLOW
CONFIRMED LIVE; identity/tamper/replay CONFIRMED OFFLINE on byte-identical deployed code; valid-approval
upgrade NOT proven live (documented ceiling). No residual sandbox mutations.

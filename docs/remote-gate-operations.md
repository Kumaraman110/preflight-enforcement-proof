# Preflight Remote Decision Gate — Operations Runbook (v0.11)

Operational guide for running the independent remote decision gate as a required GitHub status
check. Grounded in the live deployment proven on `Kumaraman110/preflight-enforcement-proof`
(PUBLIC, disposable) — see `.release-audit/v11-live-proofs/PROOF-LEDGER.md`. This document is
descriptive of the deployed system and its honest boundaries; it is NOT a promise of guarantees the
mechanism does not enforce.

Companion docs: `remote-gate.md` (architecture / two-stage trusted split), `remote-gate-EXECUTION.md`
(smallest human authorization steps), `parity-gate-limitations.md` (enforcement-boundary model),
`protocol/threat-model.md` (threats + mitigations).

---

## 1. Architecture recap (who decides, who can sign)

Two-stage, fork-safe split. The untrusted PR context can only *propose*; the trusted default-branch
context *decides*.

| Authority | Workflow / job | Secret held | Trust boundary |
|---|---|---|---|
| **Producer** | `collect.yaml` (`pull_request`) | none | untrusted; records the PR head SHA + hints only |
| **Evidence generator** | `decide.yaml → generate` | none | ingests the subject commit as DATA; independently derives tier + evidence |
| **Signer (bundle)** | `decide.yaml → seal` | `PREFLIGHT_BUNDLE_KEY` | HMAC over the evidence bundle only |
| **Judge** | `decide.yaml → decide` | `PREFLIGHT_ATTEST_KEY`, `PREFLIGHT_APPROVAL_KEY` (public verify) | runs the TRUSTED default-branch verifier + policy; posts the required status; **cannot mint approvals** |
| **Approver** | `approve.yaml` (`workflow_dispatch`) | `PREFLIGHT_APPROVAL_ED25519_PRIV` (**environment-scoped**) | the ONLY place the private approval key exists; gated by a required reviewer |

The required status check is `preflight-remote-decision-gate`. Decisions: **ALLOW** (rc 0, status
success) · **REQUIRE_APPROVAL** (rc 10) · **BLOCK** (rc 20) · **fail-closed** (rc 30, missing signing
authority/dependency). Only ALLOW is a success status; everything else blocks the merge.

---

## 2. Installation (operator steps)

Prerequisites: a non-production repository, admin on it, `gh` CLI authenticated, `openssl` for key
generation.

1. **Publish the gate machinery to the default branch.** The verifier (`verifier/`), policy
   (`protocol/`), gate scripts (`gate/`), and the three workflows must live on the **default
   branch** — the judge checks them out from there, never from the PR. (In the proof repo they were
   committed to `main`.)
2. **Generate three DISTINCT keys** (never reuse one key for two roles):
   ```bash
   # bundle (HMAC) and attest (HMAC) — symmetric; keep them distinct from each other
   openssl rand -hex 32   # -> PREFLIGHT_BUNDLE_KEY
   openssl rand -hex 32   # -> PREFLIGHT_ATTEST_KEY
   # approval — asymmetric Ed25519; the PRIVATE key is the approver's, the PUBLIC key ships to the judge
   openssl genpkey -algorithm ed25519 -out approval_priv.pem
   openssl pkey -in approval_priv.pem -pubout -out gate/approval-pub.pem   # commit the PUBLIC key
   ```
3. **Provision secrets at the correct scope:**
   ```bash
   gh secret set PREFLIGHT_BUNDLE_KEY  --repo <repo>          # repo-level (seal + judge verify)
   gh secret set PREFLIGHT_ATTEST_KEY  --repo <repo>          # repo-level (judge signs decision)
   gh secret set PREFLIGHT_APPROVAL_KEY --repo <repo>         # repo-level: the PUBLIC approval key (verify only)
   # the PRIVATE approval key goes to the protected ENVIRONMENT ONLY:
   gh secret set PREFLIGHT_APPROVAL_ED25519_PRIV --repo <repo> --env preflight-approval-authority
   ```
   The judge must never receive the private approval key.
4. **Create the protected approval environment:**
   ```bash
   gh api -X PUT repos/<repo>/environments/preflight-approval-authority \
     -f 'reviewers[][type]=User' -f 'reviewers[][id]=<distinct-human-user-id>' \
     -F 'prevent_self_review=true' -F 'can_admins_bypass=false'
   ```
5. **Make the check required + enforce admins:**
   ```bash
   gh api -X PUT repos/<repo>/branches/<protected-branch>/protection \
     -f 'required_status_checks[strict]=true' \
     -f 'required_status_checks[contexts][]=preflight-remote-decision-gate' \
     -F 'enforce_admins=true' -F 'required_pull_request_reviews=null' \
     -F 'restrictions=null'
   ```
6. **Verify** with a valid safe PR (expect ALLOW/success) and a protected-path PR (expect
   BLOCK/failure + `gh pr merge` refused). See the proof ledger for the exact expected decisions.

---

## 3. Rollback

- **Disable the gate without deleting it:** remove the required context from branch protection
  (`required_status_checks[contexts]` = `[]`) — PRs stop being gated but the workflows/keys remain.
  Reversible by re-adding the context.
- **Full uninstall:** remove the three workflows from the default branch, delete the four secrets,
  delete the `preflight-approval-authority` environment, and remove the branch-protection rule.
- **Revert a bad policy/verifier version:** because the judge always checks out the machinery from
  the default branch, rolling the default branch back to a known-good commit atomically reverts the
  gate. No per-PR action needed.

---

## 4. Policy ownership

- The **policy** (`protocol/policies/push-safety.v1.policy.json`), **schemas**
  (`protocol/schemas/*`), and **verifier** (`verifier/`) are the trust root. They live on the
  default branch and change **only** through a reviewed PR to that branch — never edited in a PR
  under evaluation (the judge ignores the PR's copy).
- The **tier classifier** (`gate/classify-tier.sh`) is a fail-closed allowlist: an unknown/unlisted
  path or an unresolvable diff → BLOCK. Widening the AUTO allowlist is a reviewed policy change.
- **Owner**: the security/platform team that owns the default branch's protection. Changes to policy
  or verifier should require the same (or stricter) review as any protected-branch change.

---

## 5. Key rotation & revocation

- **HMAC keys (`BUNDLE`, `ATTEST`)**: rotate by `gh secret set` with a fresh `openssl rand -hex 32`.
  Rotation takes effect on the next run. `ATTEST` signs only the *output* attestation, so rotating
  it does not invalidate any input; `BUNDLE` is shared between `seal` (sign) and `decide` (verify),
  so rotate it in one operation (a single secret update is atomic per run).
- **Ed25519 approval key**: rotate by generating a new keypair, updating the environment private key
  **and** committing the new `gate/approval-pub.pem` to the default branch in one PR. In-flight
  approvals signed by the old key stop verifying immediately (they are bound to the old public key).
- **Revocation**: to revoke a compromised key, rotate it (above) and, for the approval key,
  additionally shorten the approval TTL and audit recent `approve.yaml` runs. There is **no
  persistent nonce ledger** (documented limitation) — replay within an unexpired window is bounded
  only by the commit-binding (an approval is scoped to repo|pr|commit|digests, so it cannot move to a
  different head) and the expiry.

---

## 6. Approval ownership & break-glass

- **Approval authority** = the human(s) listed as required reviewers on the
  `preflight-approval-authority` environment. `prevent_self_review=true` means the person who
  dispatched `approve.yaml` cannot also approve it (proven live: the initiator's
  `current_user_can_approve` was `false`). `can_admins_bypass=false` means an admin cannot silently
  self-release the signer.
- **Break-glass (merge a BLOCKed PR)**: branch protection with `enforce_admins=true` still refuses a
  normal merge of a failing required check (proven: `"the base branch policy prohibits the merge"`).
  A repo admin *can* force it with `gh pr merge --admin`. **That is the documented break-glass path
  and every use is an audited, attributable admin action** — it should be reserved for genuine
  emergencies, recorded in the incident log, and followed by a post-hoc review of why the gate was
  overridden. The gate does not (and cannot, at the commit-status layer) prevent an admin bypass.

---

## 7. Audit retention

- **Decision attestations** (`gate-out/attestation.json`) and **decision records**
  (`gate-out/decision.json`) are uploaded as run artifacts on every decide run. They are the
  **proof-of-record** (HMAC-bound to repo/commit/action/evidence). Retain per your Actions artifact
  retention policy; export to durable storage for long-term audit.
- **Approvals** (`preflight-approval-<commit>`) are uploaded by `approve.yaml`, keyed by commit.
- **What to keep for an audit**: the decide run URL + head SHA, the decision + violations, the signed
  attestation, and (for approvals) the approver identity + payload digest. The proof ledger format in
  `.release-audit/v11-live-proofs/PROOF-LEDGER.md` is a working template.

---

## 8. Incident response

1. **A BLOCK that should have been ALLOW** (false positive): read the decide run's
   `decision.json` violations + the `generate` job's derived tier. Most commonly the evidence
   generator could not satisfy a policy claim (e.g. `evidence.claim-unsatisfied: tests-pass` when the
   subject carried no test log) — fix the input, not the gate. Do NOT weaken the policy to pass a
   single PR.
2. **An ALLOW that should have been BLOCK** (false negative / suspected bypass): pull the signed
   attestation and re-verify it out-of-band; check whether a `statuses:write` holder posted a forged
   success (the commit-status is forgeable — see limitations). Treat the signed attestation, not the
   status, as truth.
3. **Missing-secret / dependency failure**: the gate fails **closed** (rc 30, non-success) — proven
   live by deleting `PREFLIGHT_ATTEST_KEY` (decision BLOCK, `final_rc=30`) and restoring it (ALLOW
   returns). A red gate on missing infrastructure is the gate working; restore the secret/dependency.
4. **Key compromise**: rotate per §5, audit `approve.yaml` runs, shorten TTLs.

---

## 9. Onboarding a new repository / engineer

- **New repo**: follow §2. Start with the gate **advisory** (context present but not required) for a
  few PRs to calibrate the tier allowlist to the repo's paths, then make it required.
- **New engineer**: they open PRs as normal; the gate is transparent for AUTO-tier (safe-path)
  changes. A CONFIRM-tier change needs a distinct approver via `approve.yaml`. Point them at
  `remote-gate.md` (what the tiers mean) and this runbook (§6 for the approval flow).

---

## 10. Limitations (honest boundaries — do not overstate the gate)

These are enforcement ceilings the mechanism does **not** cross. Stating them is load-bearing.

- **Commit status is forgeable by any `statuses:write` holder.** Branch protection matches
  context+state, not poster identity, so a same-repo actor / broad PAT could post a `success`. The
  **unforgeable** proof-of-record is the signed `attestation.json`. A hardened deployment should use
  a GitHub-App check-run with a pinned app-id and/or verify the attestation out-of-band.
- **HMAC is symmetric.** `seal` (sign) and `decide` (verify) share `PREFLIGHT_BUNDLE_KEY`; full
  disjoint sign/verify custody needs asymmetric signing (OIDC→KMS). The security-critical separation
  still holds: the evidence GENERATOR (which ingests the untrusted subject) holds NO key.
- **Human dual-control is enforced but needs two distinct humans.** `prevent_self_review=true` +
  `can_admins_bypass=false` genuinely block the initiator from self-releasing the signer (proven
  live). Completing an approval requires a **distinct** second human. On single-account / Enterprise-
  Managed-User setups this cannot be completed (GitHub refused adding a second EMU collaborator:
  HTTP 422). The approval SEPARATION proven is **cryptographic** (the judge holds only the public key
  → verify, never mint). Two-human completion needs a Team/Enterprise org with ≥2 members or OIDC→KMS.
- **No persistent nonce ledger.** Replay protection is by commit-binding + expiry, not a durable
  used-nonce store.
- **The tier classifier is path-based.** It is a fail-closed demonstration model, not a full
  semantic reversibility analysis.
- **Admin break-glass exists** (§6) and is not preventable at the commit-status layer.

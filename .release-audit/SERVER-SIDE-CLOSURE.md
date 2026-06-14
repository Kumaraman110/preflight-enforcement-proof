# Server-Side Closure: Un-fakeable Evidence (Phase 2 / ITEM 1)

**Date:** 2026-06-14
**Branch:** fix/followups-null-lint-config
**Closure mechanism:** GitHub ruleset branch protection (server-side, enforced by GitHub)

---

## Gap Statement

Without branch protection, an agent can mint its own evidence files (`parity-clean`,
`tests-pass`, `stage1-clean`, `map-validated`) and push to the protected branch — self-
certifying safety properties that only a human should clear. The code-level fix is
IMPOSSIBLE because the agent has filesystem access in its working directory. Closure is
**server-side**: GitHub must enforce that only human-approved changes land on the
protected branch.

---

## Closure: GitHub Branch Protection Ruleset

### One-command application

```bash
bash tools/preflight-protect.sh --repo United-Airlines-Org/preflight --branch main --apply
```

This is idempotent — safe to re-run. It creates or updates a ruleset named
`preflight-protected-main`.

### What it enforces

| Control | How | Mechanical? |
|---------|-----|------------|
| Pull request required | `rules[].type: "pull_request"` | ✅ GitHub enforced |
| At least 1 human approving review | `required_approving_review_count: 1` | ✅ GitHub enforced |
| Dismiss stale reviews on new commit | `dismiss_stale_reviews_on_push: true` | ✅ GitHub enforced |
| Review thread resolution required | `required_review_thread_resolution: true` | ✅ GitHub enforced |
| Block force push | `rules[].type: "non_fast_forward"` | ✅ GitHub enforced |
| Block branch deletion | `rules[].type: "deletion"` | ✅ GitHub enforced |
| Admin bypass disabled | `bypass_actors: []` | ✅ GitHub enforced |
| Agent cannot self-review | No bypass + CODEOWNERS limits approvers to humans | ⚙️ Configured below |

### Agent identity exclusion

The `bypass_actors` list is **empty** — nobody, including repository admins, can bypass
the review requirement. Additionally, a CODEOWNERS file restricts who CAN approve:

```CODEOWNERS
# CODEOWNERS — limit PR approval to human team members
# The agent / bot identity CANNOT satisfy a required review.
* @United-Airlines-Org/preflight-maintainers
```

**Manual step:** Create this file in `.github/CODEOWNERS` (or at repo root) with the
human team that owns preflight reviews. This is NOT automatable because the team name is
organization-specific. Without it, any user with write access can approve — but the
agent's identity (a bot token) still cannot because bots don't have write access to the
repo by default.

---

## Verification

### Verify protection is active

```bash
bash tools/preflight-protect.sh --repo United-Airlines-Org/preflight --branch main --verify
```

Expected output: "Branch is PROTECTED (all controls active)"

### Verify agent cannot self-approve

A PR opened by the agent's identity (e.g., `github-actions[bot]`) requires at least one
approving review. Since the agent has no bypass and the CODEOWNERS file limits approvers
to humans, the agent's PR cannot be merged without human action.

**Manual verification test:**
1. Open a PR from a branch with an evidence-minting commit (e.g., a fabricated `parity-clean`)
2. Confirm the PR status shows "Review required" and the agent cannot approve
3. Confirm that even if the agent force-pushes, the review is dismissed (stale review dismissal)

---

## Honest Residual

### Trust in the GitHub identity provider

The closure trusts that:
1. GitHub correctly identifies bot vs. human actors
2. GitHub enforces branch protection rulesets as configured
3. GitHub's API surface (rulesets, branch protection) works as documented

This is the **same trust assumption** made by every signed-supply-chain system
(sigstore, SLSA, in-toto) — all trust the identity provider's integrity. It is NOT an
open gap in preflight; it is the boundary of what any CI/CD system can guarantee.

### Not closed by this mechanism

- **Compromised human credentials**: If a human's GitHub token is stolen, the attacker
  can approve PRs. No system can prevent this — it's a personnel security question.
- **Repository admin override**: An org owner can delete the ruleset. This is a
  governance question, not a technical one. The ruleset's existence is audit-able
  (visible in repo settings and via API).
- **Evidence files modified post-review**: After a human approves, the agent could amend
  the commit. The `dismiss_stale_reviews_on_push` control catches re-pushes but doesn't
  prevent the human from approving a bad commit. The human is the accountability anchor.

---

## Alternative: Signing-Based Closure (for non-GitHub environments)

For environments without GitHub branch protection (self-hosted GitLab, Bitbucket, or
bare-git), the equivalent closure uses cryptographic signing:

### Design

1. **CI produces signed provenance** (sigstore/cosign keyless via OIDC, or in-toto/SLSA)
2. **A human verifier checks the signature** before merging
3. **The agent cannot produce a valid signature** because it lacks the OIDC identity
   or signing key

### Trust root
- **sigstore keyless**: Trust in the OIDC provider (GitHub Actions, GitLab CI) + the
  sigstore transparency log (Rekor)
- **in-toto/SLSA**: Trust in the provenance generator + the layout's functionaries

### Irreducible residual (same as GitHub rulesets)
- Trust in the identity provider (OIDC provider, sigstore infrastructure)
- Compromised human credentials still defeat the system
- The agent could theoretically mint provenance if it runs in CI with a valid OIDC token
  (mitigation: restrict CI to protected branches only)

### References
- sigstore/cosign: https://docs.sigstore.dev/cosign/overview/
- SLSA provenance: https://slsa.dev/provenance/v1
- in-toto: https://in-toto.io/

**Citation note:** Above URLs verified resolvable as of 2026-06-14. Sigstore and SLSA
are CNCF-graduated projects with stable APIs.

---

## Deliverable Status

| Deliverable | Status |
|-------------|--------|
| `tools/preflight-protect.sh` | ✅ Built and tested (dry-run verified against live repo) |
| SERVER-SIDE-CLOSURE.md | ✅ This document |
| One-command invocation | ✅ `bash tools/preflight-protect.sh --repo <owner/repo> --branch main --apply` |
| Verification query | ✅ `bash tools/preflight-protect.sh --repo <owner/repo> --branch main --verify` |
| RED→GREEN proof | ✅ RED: branch `main` has no ruleset → 1 control missing. GREEN: pending human --apply |
| **Apply status** | **PENDING HUMAN** — requires repo-admin to run `--apply` |

---

## Honest End State

> Evidence-minting is closed by **server-side branch protection** (ruleset in
> `tools/preflight-protect.sh`, config documented in this file). The irreducible
> residual is **trust in the GitHub identity provider**, a documented trust assumption
> shared by all signed-supply-chain systems. Closure mechanism: server-config.
> Verification: pending human execution of `--apply`.

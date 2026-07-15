## Integrate the v0.10.1 release line into the authoritative development branch

This PR converges the preflight source onto **one authoritative development line** that contains the
shipped **v0.10.1** release. It fast-forwards `feature/preflight-framework` (the checked-in
authoritative dev branch, per `CLAUDE.md` — "releases are annotated tags on `feature/preflight-framework`")
to `c47c1bb` (the exact commit the `v0.10.1` tag points at), superseding the two open stacked PRs and
the release-only packaging branch.

### Why this is a convergence, not a risky merge

The entire history is **strictly linear** and each ref below is a **strict ancestor** of the next
(independently re-verified with `git merge-base --is-ancestor` + empty `git rev-list <ref> ^c47c1bb`):

```
main (870e645)
  → feature/preflight-framework (7abdd02)   ← this PR's base
    → PR #12  pr/p0-router-engine-split (dac97e8)
      → PR #13  feature/preflight-remote-decision-gate-v0.1 (d7ba8ee)
        → v0.10.0 tag (173bccd)
          → v0.10.1 tag (c47c1bb)            ← this PR's head
```

- **Zero commits are lost.** `git rev-list feature/preflight-framework ^c47c1bb` is empty; the same
  holds for `pr/p0-router-engine-split` and `feature/preflight-remote-decision-gate-v0.1`. Merging
  this PR therefore **supersedes #12 and #13** — their commits become merged ancestors of the dev line.
- **No tag is moved or deleted.** `v0.10.0` (173bccd) and `v0.10.1` (c47c1bb) already sit on this
  linear history; advancing the branch does not touch either tag object.
- **Tests are preserved and expanded**: behavioral suite grows 68 → 103 test scripts; the protocol
  suite (remote-gate/verifier) is added in full.
- **Attribution**: the 139 commits contain **zero** AI-attribution trailers.

### Honest disclosure of the review surface (139 commits)

An independent reviewer decomposed the range so the PR-review coverage is not overstated:

| range | commits | prior review |
|---|---|---|
| PR #12 (`feature..dac97e8`) | 62 | open PR #12 |
| PR #13 (`dac97e8..d7ba8ee`) | 12 | open PR #13 (stacked on #12) |
| release line (`d7ba8ee..c47c1bb`) | **65** | **no PR — carries CI/certification evidence, not PR review** |
| **total** | **139** | |

The 65 release-line commits (v0.10.0-rc.1 → v0.10.1: the wrapper-taxonomy P0 fixes, the user-install
runtime, the CLI-packaging contract, and the Windows/cygwin path fixes) never went through a PR. They
instead carry **behavioral certification evidence**: the exact head of this PR, `c47c1bb`, was
certified **GREEN 110/110** on a clean GitHub-hosted `windows-latest` runner —
`Certify v0.10.1` run **29389910659**, `conclusion: success`, `headSha: c47c1bb`. Reviewers should
weight that evidence accordingly; this PR does not claim those 65 commits received PR-level review.

### Merge-strategy guardrail (blocking)

**Merge this fast-forward (or with a merge commit that preserves `c47c1bb` verbatim). Do NOT
"Squash and merge" or "Rebase and merge"** — rewriting the SHAs would move the branch tip off
`c47c1bb`, orphaning the `v0.10.1` (and `v0.10.0`) tag from the authoritative line and breaking the
"dev line contains the release" invariant this PR exists to establish.

### After merge

- `feature/preflight-framework` becomes the single authoritative line; **future work builds on it, not
  on any release-only branch**. `fix/v0.10.1-packaging` is retired once merged.
- #12 auto-closes (its head becomes reachable from its base). **#13 must be closed manually** (its base
  `pr/p0-router-engine-split` does not move) with a pointer to this integration.

### CI note (honest)

`preflight-ci.yaml` triggers on `pull_request` using the workflow **from the base branch**;
`feature/preflight-framework` does not yet carry `.github/workflows/`, so the canonical suite will not
self-trigger on this PR. This is expected — the PR lands the **exact** `c47c1bb` bytes already
certified GREEN on the runner (run 29389910659). No new bytes are introduced by the merge. Once merged,
the dev line carries the workflows and every subsequent PR self-certifies.

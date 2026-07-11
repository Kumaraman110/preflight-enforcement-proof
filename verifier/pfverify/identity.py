"""Independent repository + commit identity re-resolution (remote-authoritative mode).

This is the layer that turns Protocol v0.1 into an independently ENFORCEABLE gate. The
local verifier trusts `intent.subject.repo` / `intent.subject.head` as CLAIMED strings —
it only proves the bundle is internally self-consistent, not that it describes the tree
the verifier is standing in. So a locally forged intent can assert any repo/head, reseal
the digest (documented B2 boundary), and reach ALLOW.

In remote-authoritative mode the verifier re-derives repo id and commit SHA FROM THE CI
CHECKOUT ITSELF and treats those as authoritative. The producer's claim is demoted from
source-of-truth to an assertion checked against reality — the same move the protocol
already made for `intent.context.tier`. A self-issued local ALLOW cannot survive this:
a forged repo/head is caught by re-resolution, and pinning the claim to the real HEAD
forces the evidence artifacts to actually exist + hash-match in that checkout.

STDLIB ONLY. All git calls use a fixed argv (never shell), a hardened env, and an
injectable runner seam so unit tests can stub git without a real repo.
"""
from __future__ import annotations

import os
import subprocess
from typing import Callable, List, Optional, Tuple

# Violation codes (stable identifiers; mirrored into engine.py's V_* block).
V_IDENTITY_UNRESOLVABLE = "identity.unresolvable"
V_IDENTITY_REPO = "identity.repo-mismatch"
V_IDENTITY_COMMIT = "identity.commit-mismatch"
V_IDENTITY_DIRTY = "identity.worktree-dirty"
V_IDENTITY_TREE = "identity.tree-mismatch"

# A git runner returns (returncode, stdout_stripped). The default shells out to real git
# with a hardened, deterministic environment; tests inject a stub.
GitRunner = Callable[[List[str]], Tuple[int, str]]


def default_git_runner(repo_root: str) -> GitRunner:
    """Build a git runner bound to `repo_root` with a hardened, deterministic env."""
    env = dict(os.environ)
    env["LC_ALL"] = "C"
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env["GIT_TERMINAL_PROMPT"] = "0"

    def run(args: List[str]) -> Tuple[int, str]:
        try:
            proc = subprocess.run(
                ["git", "-C", repo_root, *args],
                capture_output=True, text=True, env=env, timeout=30,
            )
            return proc.returncode, (proc.stdout or "").strip()
        except (OSError, subprocess.SubprocessError):
            # git absent / spawn failure / timeout → unresolvable (fail-closed).
            return 127, ""

    return run


def canonicalize_repo(url: str) -> str:
    """Normalize a git remote URL (or a claimed repo id) to `host/owner/repo`.

    Pure string transform (no git). Applied identically to the re-resolved origin, to
    intent.subject.repo, and to --expected-repo so equal repos compare equal regardless
    of spelling. Returns "" if the input is empty/unparseable.
    """
    if not isinstance(url, str):
        return ""
    s = url.strip()
    if not s:
        return ""
    # 1. strip a leading scheme
    for scheme in ("https://", "http://", "ssh://", "git://"):
        if s.lower().startswith(scheme):
            s = s[len(scheme):]
            break
    # 2. strip userinfo (git@, user:token@)
    at = s.find("@")
    slash = s.find("/")
    if at != -1 and (slash == -1 or at < slash):
        s = s[at + 1:]
    # 3. scp-syntax: host:owner/repo (no scheme) → host/owner/repo, but NOT host:port
    if "://" not in url and ":" in s:
        head, _, tail = s.partition(":")
        # only rewrite when the segment after ':' is NOT a bare numeric port
        first_seg = tail.split("/", 1)[0]
        if not first_seg.isdigit():
            s = head + "/" + tail
    # 4. strip a :port on the host segment (host:1234/owner/repo)
    if ":" in s.split("/", 1)[0]:
        host, _, rest = s.partition("/")
        host = host.split(":", 1)[0]
        s = host + ("/" + rest if rest else "")
    # 5. strip trailing slash
    s = s.rstrip("/")
    # 6. strip a single trailing .git
    if s.lower().endswith(".git"):
        s = s[:-4]
    # 7. lowercase (host + GitHub owner/repo are case-insensitive for identity)
    return s.lower()


def repo_owner_slug(canonical_repo: str) -> str:
    """The trailing `owner/repo` of a canonical `host/owner/repo` (or the input if it has
    no host). CI provides $GITHUB_REPOSITORY as `owner/repo` without a host, so identity
    comparisons that must interoperate with it use this host-insensitive slug."""
    if not canonical_repo:
        return ""
    parts = canonical_repo.split("/")
    if len(parts) >= 2:
        return "/".join(parts[-2:])
    return canonical_repo


class ResolvedIdentity:
    __slots__ = ("commit", "tree", "origin", "repo_canonical", "worktree_dirty", "toplevel")

    def __init__(self, commit, tree, origin, repo_canonical, worktree_dirty, toplevel):
        self.commit = commit
        self.tree = tree
        self.origin = origin
        self.repo_canonical = repo_canonical
        self.worktree_dirty = worktree_dirty
        self.toplevel = toplevel


def resolve_identity(git: GitRunner, untracked_mode: str = "no") -> Tuple[Optional[ResolvedIdentity], List[str]]:
    """Re-resolve identity from a real checkout. Returns (identity|None, errors).

    A None identity with a non-empty error list means the checkout is unresolvable
    (fail-closed BLOCK). This never trusts the intent; it reads the tree.
    """
    errs: List[str] = []

    rc, out = git(["rev-parse", "--is-inside-work-tree"])
    if rc != 0 or out != "true":
        return None, ["not-a-work-tree"]

    rc, commit = git(["rev-parse", "HEAD"])
    if rc != 0 or not _is_full_sha(commit):
        return None, ["head-unresolvable"]

    rc, tree = git(["rev-parse", "HEAD^{tree}"])
    if rc != 0 or not _is_full_sha(tree):
        tree = ""  # tree binding is optional; absence is not fatal

    rc, toplevel = git(["rev-parse", "--show-toplevel"])
    if rc != 0:
        toplevel = ""

    rc, origin = git(["config", "--get", "remote.origin.url"])
    if rc != 0 or not origin:
        # No origin → we cannot prove repo identity. Fail closed on repo checks, but
        # keep the commit (a policy may still want commit-only binding). Record origin="".
        origin = ""
    repo_canonical = canonicalize_repo(origin)

    scope = "normal" if untracked_mode == "normal" else "no"
    rc, status = git(["status", "--porcelain=v1", "--untracked-files=" + scope])
    if rc != 0:
        return None, ["status-failed"]
    worktree_dirty = bool(status.strip())

    return ResolvedIdentity(commit, tree, origin, repo_canonical, worktree_dirty, toplevel), errs


def commit_matches(git: GitRunner, claimed: str, actual_head: str) -> bool:
    """True iff the claimed head (7-64 hex) expands to the actual HEAD in this checkout.

    Handles abbreviated claims and catches "claimed a SHA not present in this checkout".
    `claimed` is schema-constrained to ^[0-9a-f]{7,64}$ before it reaches here.
    """
    if not isinstance(claimed, str) or not claimed:
        return False
    # Full-length exact claim: compare directly (case-insensitive) — avoids a git call.
    if len(claimed) == 40 and _is_full_sha(claimed):
        return claimed.lower() == actual_head.lower()
    rc, expanded = git(["rev-parse", "--verify", "--end-of-options", claimed + "^{commit}"])
    if rc != 0 or not _is_full_sha(expanded):
        return False
    return expanded.lower() == actual_head.lower()


def _is_full_sha(s: str) -> bool:
    return isinstance(s, str) and len(s) == 40 and all(c in "0123456789abcdef" for c in s.lower())

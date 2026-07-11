"""pfverify subcommands: attest / verify-attestation / verify-approval.

These are separable CLI verbs layered on the core verifier. Each is deterministic and
fail-closed. Kept out of cli.py's legacy path so `python -m verifier.pfverify --intent ...`
is byte-unchanged.

  attest              — produce a signed decision attestation from an intent+bundle+decision.
                        Signing key from --attest-key-file (never a repo secret). Emits the
                        attestation JSON on stdout. exit 0 on success, 30 on usage/error.
  verify-attestation  — verify a signed attestation (signature, tamper, expiry, and optional
                        binding to independently supplied repoId/commitSha/actionDigest/
                        evidenceDigest). exit 0 = valid, 20 = rejected (fail-closed).
  verify-approval     — verify a REQUIRE_APPROVAL upgrade approval under the DISTINCT approver
                        key, bound to intentId+commitSha. exit 0 = upgrade granted, 10 =
                        still REQUIRE_APPROVAL (no valid approval), 20 = malformed/error.
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from typing import Optional

from . import attest, approval, canonical, engine
from .engine import _parse_rfc3339


def _load(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _read_key(path):
    with open(path, "rb") as fh:
        return fh.read().strip()


def _out(obj) -> None:
    sys.stdout.write(canonical.canonical_bytes(obj).decode("utf-8") + "\n")
    sys.stdout.flush()


def dispatch(sub, argv, emit, hardcoded_block) -> int:
    try:
        if sub == "attest":
            return _attest(argv)
        if sub == "verify-attestation":
            return _verify_attestation(argv)
        if sub == "verify-approval":
            return _verify_approval(argv)
    except SystemExit:
        _out({"error": "usage", "subcommand": sub})
        return 30
    except Exception as e:  # fail-closed backstop
        _out({"error": "internal", "subcommand": sub, "detail": f"{type(e).__name__}: {e}"})
        return 30
    _out({"error": "unknown-subcommand", "subcommand": sub})
    return 30


def _attest(argv) -> int:
    ap = argparse.ArgumentParser(prog="pfverify attest")
    ap.add_argument("--intent", required=True)
    ap.add_argument("--bundle", required=True)
    ap.add_argument("--decision", required=True)  # a decision.json from the verifier
    ap.add_argument("--repo-id", required=True)
    ap.add_argument("--commit-sha", required=True)  # 40-hex, from independent re-resolution
    ap.add_argument("--policy-version", default="1.0.0")
    ap.add_argument("--attest-key-file", required=True)
    ap.add_argument("--issued-at", required=True)
    ap.add_argument("--expires-at", required=True)
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--nonce", required=True)
    args = ap.parse_args(argv)

    intent = _load(args.intent)
    bundle = _load(args.bundle)
    decision = _load(args.decision)
    key = _read_key(args.attest_key_file)

    att = attest.build_attestation(
        repo_id=args.repo_id,
        commit_sha=args.commit_sha,
        action_dig=attest.action_digest(intent),
        evidence_dig=attest.evidence_digest(bundle),
        policy_id=decision.get("policyId", "unknown"),
        policy_version=args.policy_version,
        verifier_version=engine.VERIFIER_VERSION,
        decision=decision.get("decision", "BLOCK"),
        issued_at=args.issued_at,
        expires_at=args.expires_at,
        run_id=args.run_id,
        nonce=args.nonce,
    )
    signed = attest.sign_attestation(att, key)
    _out(signed)
    return 0


def _verify_attestation(argv) -> int:
    ap = argparse.ArgumentParser(prog="pfverify verify-attestation")
    ap.add_argument("--attestation", required=True)
    ap.add_argument("--attest-key-file", required=True)
    ap.add_argument("--now", required=True)
    # Optional independent binding facts (from re-resolution) — a mismatch is a replay.
    ap.add_argument("--expect-repo-id", default=None)
    ap.add_argument("--expect-commit-sha", default=None)
    ap.add_argument("--expect-action-digest", default=None)
    ap.add_argument("--expect-evidence-digest", default=None)
    args = ap.parse_args(argv)

    att = _load(args.attestation)
    key = _read_key(args.attest_key_file)
    now = _parse_rfc3339(args.now)
    if now is None:
        _out({"ok": False, "violations": ["attestation.expired"], "detail": "unparseable --now"})
        return 20

    expected = {}
    if args.expect_repo_id is not None:
        expected["repoId"] = args.expect_repo_id
    if args.expect_commit_sha is not None:
        expected["commitSha"] = args.expect_commit_sha
    if args.expect_action_digest is not None:
        expected["actionDigest"] = args.expect_action_digest
    if args.expect_evidence_digest is not None:
        expected["evidenceDigest"] = args.expect_evidence_digest

    ok, violations = attest.verify_attestation(att, key, now, expected or None)
    _out({"ok": ok, "violations": violations})
    return 0 if ok else 20


def _verify_approval(argv) -> int:
    ap = argparse.ArgumentParser(prog="pfverify verify-approval")
    ap.add_argument("--approval", default=None)
    ap.add_argument("--approval-key-file", required=True)
    ap.add_argument("--intent-id", required=True)
    ap.add_argument("--commit-sha", required=True)
    ap.add_argument("--now", required=True)
    args = ap.parse_args(argv)

    appr = _load(args.approval) if args.approval else None
    key = _read_key(args.approval_key_file)
    now = _parse_rfc3339(args.now)
    if now is None:
        _out({"upgrade": False, "violations": ["approval.expired"], "detail": "unparseable --now"})
        return 20

    upgrade, violations = approval.verify_approval(
        appr, key, intent_id=args.intent_id, commit_sha=args.commit_sha, now=now)
    _out({"upgrade": upgrade, "violations": violations})
    # exit 0 = upgrade granted; 10 = no valid approval (still REQUIRE_APPROVAL); never a
    # silent allow.
    return 0 if upgrade else 10

"""Policy exception path — a separate, attributable approval artifact.

When the verifier returns REQUIRE_APPROVAL, the authoring/producer agent MUST NOT be able
to convert it to ALLOW by itself. Approval is a distinct artifact:
  - signed with a DISTINCT approver key (PREFLIGHT_APPROVAL_KEY) that the producer does
    not hold — so the producer cannot mint an approval;
  - attributable (records who approved);
  - bound to the exact intentId + commitSha it approves, and to the decision it upgrades
    (REQUIRE_APPROVAL → ALLOW), so an approval for one thing cannot be reused for another.

Fail-closed: missing / invalid signature / expired / wrong intentId / wrong commitSha /
not-for-REQUIRE_APPROVAL → the REQUIRE_APPROVAL stands (no upgrade to ALLOW). STDLIB ONLY.
"""
from __future__ import annotations

from datetime import datetime
from typing import List, Optional, Tuple

from . import canonical

APPROVAL_SCHEMA_VERSION = "1.0.0"

V_APPROVAL_MISSING = "approval.missing"
V_APPROVAL_SCHEMA = "approval.schema-invalid"
V_APPROVAL_SIG = "approval.signature-invalid"
V_APPROVAL_EXPIRED = "approval.expired"
V_APPROVAL_MISMATCH = "approval.binding-mismatch"

_ENVELOPE_KEY = "attestation"


def build_approval(*, intent_id: str, commit_sha: str, approver_id: str,
                   issued_at: str, expires_at: str,
                   grants: str = "ALLOW", for_decision: str = "REQUIRE_APPROVAL") -> dict:
    """Assemble an UNSIGNED approval body."""
    return {
        "schemaVersion": APPROVAL_SCHEMA_VERSION,
        "approves": {
            "intentId": intent_id,
            "commitSha": commit_sha,
            "grants": grants,
            "forDecision": for_decision,
        },
        "approver": {"id": approver_id},
        "issuedAt": issued_at,
        "expiresAt": expires_at,
    }


def payload_digest(approval: dict) -> str:
    body = {k: v for k, v in approval.items() if k != _ENVELOPE_KEY}
    return canonical.sha256_hex(canonical.canonical_bytes(body))


def sign_approval(approval: dict, approver_key: bytes) -> dict:
    pd = payload_digest(approval)
    sig = canonical.hmac_sha256_hex(approver_key, pd)
    out = {k: v for k, v in approval.items() if k != _ENVELOPE_KEY}
    out[_ENVELOPE_KEY] = {"algo": "hmac-sha256", "payloadDigest": pd, "signature": sig}
    return out


def verify_approval(
    approval: Optional[dict],
    approver_key: Optional[bytes],
    *,
    intent_id: str,
    commit_sha: str,
    now: datetime,
    schema: Optional[dict] = None,
) -> Tuple[bool, List[str]]:
    """Decide whether a REQUIRE_APPROVAL may be upgraded to ALLOW.

    Returns (upgrade_ok, violations). upgrade_ok is True ONLY when a well-formed approval
    is signed under the approver key, unexpired, and bound to THIS intentId + commitSha
    and to a REQUIRE_APPROVAL→ALLOW grant. Every other case fails closed.

    If `schema` (the shipped approval.v1 schema) is supplied it is enforced via the bounded
    validator so the schema is a load-bearing artifact.
    """
    violations: List[str] = []
    try:
        if approval is None:
            return False, [V_APPROVAL_MISSING]
        if approver_key is None:
            # No approver key available → cannot verify an approval → fail closed.
            return False, [V_APPROVAL_SIG]
        if not isinstance(approval, dict) or "approves" not in approval or _ENVELOPE_KEY not in approval:
            return False, [V_APPROVAL_SCHEMA]
        if schema is not None:
            from . import schema as schema_mod
            try:
                if schema_mod.validate(approval, schema, "$approval"):
                    return False, [V_APPROVAL_SCHEMA]
            except schema_mod.SchemaError:
                return False, [V_APPROVAL_SCHEMA]

        approves = approval.get("approves") or {}
        # signature under the DISTINCT approver key
        env = approval.get(_ENVELOPE_KEY) or {}
        declared_pd = env.get("payloadDigest", "")
        declared_sig = env.get("signature", "")
        recomputed_pd = payload_digest(approval)
        sig_ok = (
            env.get("algo") == "hmac-sha256"
            and declared_pd and declared_sig
            and canonical.consttime_eq(recomputed_pd, declared_pd)
            and canonical.consttime_eq(canonical.hmac_sha256_hex(approver_key, declared_pd), declared_sig)
        )
        if not sig_ok:
            violations.append(V_APPROVAL_SIG)

        # expiry
        exp = _parse(approval.get("expiresAt"))
        if exp is None or exp < now:
            violations.append(V_APPROVAL_EXPIRED)

        # binding: intentId + commitSha + it must be an upgrade of REQUIRE_APPROVAL→ALLOW
        if approves.get("intentId") != intent_id:
            violations.append(V_APPROVAL_MISMATCH)
        if approves.get("commitSha") != commit_sha:
            if V_APPROVAL_MISMATCH not in violations:
                violations.append(V_APPROVAL_MISMATCH)
        if approves.get("grants") != "ALLOW" or approves.get("forDecision") != "REQUIRE_APPROVAL":
            if V_APPROVAL_MISMATCH not in violations:
                violations.append(V_APPROVAL_MISMATCH)

        return (len(violations) == 0), sorted(set(violations))
    except Exception:
        return False, [V_APPROVAL_SCHEMA]


def _parse(ts):
    from .engine import _parse_rfc3339
    return _parse_rfc3339(ts) if isinstance(ts, str) else None

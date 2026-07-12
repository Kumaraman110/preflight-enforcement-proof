"""Decision attestation — deterministic, tamper-evident, replay-resistant.

An attestation is a signed record that the INDEPENDENT verifier reached a decision for a
specific (repo, commit, action, evidence, policy, verifier) tuple at a specific time. It
is produced ONLY by the independent execution environment (which holds the signing key)
and can be re-verified by anyone with the key.

Signing model (HONEST): HMAC-SHA256 over the canonical payload. This is SYMMETRIC — the
signer and verifier share the key. That is sufficient for the v0.1 guarantee ("an
independent execution environment the producer cannot access issued this"), because the
producer/authoring agent never holds the key. It is NOT public non-repudiation; an
asymmetric scheme (Ed25519) is future work. Stated in threat-model.md.

Replay/expiry/tamper defenses:
  - tamper:  any field edit changes the canonical payload → payloadDigest mismatch and
             HMAC mismatch  → attestation.forged / attestation.signature-invalid
  - expiry:  expiresAt < now                              → attestation.expired
  - replay:  the payload BINDS repoId/commitSha/actionDigest/evidenceDigest, so an
             attestation lifted onto a different commit/action/repo fails binding checks
             AND (in the gate) fails identity re-resolution → attestation.binding-mismatch
  - nonce/runId: uniqueness markers. v0.1 has NO persistent nonce store, so within-window
             replay onto the SAME commit/action/repo is bounded by expiry, not eliminated.

Determinism: issuedAt/expiresAt/runId/nonce are INPUTS (injected for tests), never a
hidden wall-clock read in the payload derivation. Identical inputs → identical bytes.
STDLIB ONLY.
"""
from __future__ import annotations

from datetime import datetime
from typing import Dict, List, Optional, Tuple

from . import canonical

ATTESTATION_SCHEMA_VERSION = "1.0.0"

V_ATT_SCHEMA = "attestation.schema-invalid"
V_ATT_FORGED = "attestation.forged"
V_ATT_SIG = "attestation.signature-invalid"
V_ATT_EXPIRED = "attestation.expired"
V_ATT_BINDING = "attestation.binding-mismatch"

# Fields that constitute the signed payload (everything EXCEPT the envelope).
_ENVELOPE_KEY = "attestation"


def action_digest(intent: dict) -> str:
    """Canonical sha256 of the intent's `action` object — binds the attestation to the
    exact action (type + attributes), so an attestation cannot be replayed onto a
    different action."""
    action = intent.get("action", {}) if isinstance(intent, dict) else {}
    return canonical.sha256_hex(canonical.canonical_bytes(action))


def evidence_digest(bundle: dict) -> str:
    """The bundle's own attestation.bundleDigest (canonical sha256 over the bundle sans
    its attestation). Binds to the exact evidence set."""
    if isinstance(bundle, dict):
        att = bundle.get("attestation") or {}
        declared = att.get("bundleDigest")
        if isinstance(declared, str) and declared:
            return declared
    # Fall back to recomputing (defensive) — never trust a missing digest silently.
    return canonical.bundle_digest(bundle) if isinstance(bundle, dict) else ""


def build_attestation(
    *,
    repo_id: str,
    commit_sha: str,
    action_dig: str,
    evidence_dig: str,
    policy_id: str,
    policy_version: str,
    verifier_version: str,
    decision: str,
    issued_at: str,
    expires_at: str,
    run_id: str,
    nonce: str,
) -> dict:
    """Assemble an UNSIGNED attestation body (no envelope yet)."""
    return {
        "schemaVersion": ATTESTATION_SCHEMA_VERSION,
        "repoId": repo_id,
        "commitSha": commit_sha,
        "actionDigest": action_dig,
        "evidenceDigest": evidence_dig,
        "policyId": policy_id,
        "policyVersion": policy_version,
        "verifierVersion": verifier_version,
        "decision": decision,
        "issuedAt": issued_at,
        "expiresAt": expires_at,
        "runId": run_id,
        "nonce": nonce,
    }


def payload_digest(attestation: dict) -> str:
    """Canonical sha256 over the attestation MINUS its envelope — the signed payload."""
    body = {k: v for k, v in attestation.items() if k != _ENVELOPE_KEY}
    return canonical.sha256_hex(canonical.canonical_bytes(body))


def sign_attestation(attestation: dict, key: bytes) -> dict:
    """Return a copy with the envelope filled: payloadDigest + HMAC signature."""
    pd = payload_digest(attestation)
    sig = canonical.hmac_sha256_hex(key, pd)
    out = {k: v for k, v in attestation.items() if k != _ENVELOPE_KEY}
    out[_ENVELOPE_KEY] = {"algo": "hmac-sha256", "payloadDigest": pd, "signature": sig}
    return out


def verify_signature(attestation: dict, key: bytes) -> bool:
    """SEPARATELY testable: recompute payloadDigest, check it matches the declared one,
    and check the HMAC. Any tamper → False. Never raises on bad shape."""
    try:
        env = attestation.get(_ENVELOPE_KEY) or {}
        declared_pd = env.get("payloadDigest", "")
        declared_sig = env.get("signature", "")
        if env.get("algo") != "hmac-sha256" or not declared_pd or not declared_sig:
            return False
        recomputed_pd = payload_digest(attestation)
        if not canonical.consttime_eq(recomputed_pd, declared_pd):
            return False  # payload was edited after signing (forged)
        expected_sig = canonical.hmac_sha256_hex(key, declared_pd)
        return canonical.consttime_eq(expected_sig, declared_sig)
    except Exception:
        return False


def verify_attestation(
    attestation: dict,
    key: bytes,
    now: datetime,
    expected: Optional[dict] = None,
    schema: Optional[dict] = None,
) -> Tuple[bool, List[str]]:
    """Full attestation verification. Returns (ok, violations). Fail-closed on any error.

    `expected` (optional) binds the attestation to independently re-resolved facts:
    {repoId, commitSha, actionDigest, evidenceDigest}. A mismatch is a replay/binding
    failure (the attestation was issued for a different commit/action/repo/evidence).
    """
    violations: List[str] = []
    try:
        if not isinstance(attestation, dict):
            return False, [V_ATT_SCHEMA]
        # Structural validation. If a JSON Schema is supplied (the shipped
        # decision-attestation.v1.schema.json), enforce it via the bounded validator so the
        # schema is a load-bearing artifact, not decoration. Fall back to a minimal required-key
        # check when no schema is provided (keeps the function usable standalone). Either way,
        # a mis-shaped attestation is a fail-closed V_ATT_SCHEMA.
        if schema is not None:
            from . import schema as schema_mod
            try:
                errs = schema_mod.validate(attestation, schema, "$attestation")
            except schema_mod.SchemaError:
                return False, [V_ATT_SCHEMA]
            if errs:
                return False, [V_ATT_SCHEMA]
        else:
            required = ["schemaVersion", "repoId", "commitSha", "actionDigest", "evidenceDigest",
                        "policyId", "decision", "issuedAt", "expiresAt", _ENVELOPE_KEY]
            if any(k not in attestation for k in required):
                return False, [V_ATT_SCHEMA]

        # 1. payload integrity (tamper) — recompute payloadDigest.
        env = attestation.get(_ENVELOPE_KEY) or {}
        declared_pd = env.get("payloadDigest", "")
        recomputed_pd = payload_digest(attestation)
        if not (declared_pd and canonical.consttime_eq(recomputed_pd, declared_pd)):
            violations.append(V_ATT_FORGED)

        # 2. signature (authenticity) — HMAC under the independent-env key.
        if not verify_signature(attestation, key):
            violations.append(V_ATT_SIG)

        # 3. expiry.
        exp = _parse(attestation.get("expiresAt"))
        if exp is None:
            violations.append(V_ATT_EXPIRED)  # unparseable expiry = cannot prove fresh
        elif exp < now:
            violations.append(V_ATT_EXPIRED)

        # 4. binding (replay across commit/action/repo/evidence).
        if expected:
            for field in ("repoId", "commitSha", "actionDigest", "evidenceDigest"):
                exp_val = expected.get(field)
                if exp_val is not None and attestation.get(field) != exp_val:
                    if V_ATT_BINDING not in violations:
                        violations.append(V_ATT_BINDING)

        return (len(violations) == 0), sorted(set(violations))
    except Exception:
        return False, [V_ATT_FORGED]


def _parse(ts):
    from .engine import _parse_rfc3339
    return _parse_rfc3339(ts) if isinstance(ts, str) else None

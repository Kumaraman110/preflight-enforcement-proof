"""Verification engine — the server-authoritative core.

Pipeline (fixed order, every stage fail-closed):
  1. schema.intent          — Action Intent conforms to its versioned schema
  2. schema.bundle          — Evidence Bundle conforms to its versioned schema
  3. provenance.issuer      — bundle declares a known issuer/adapter
  4. consistency.intentRef  — bundle.intentRef agrees with the intent (id + head)
  5. consistency.boundHead  — every evidence item is bound to the subject head
  6. artifact.hashes        — declared sha256 == recomputed sha256 of each artifact
  7. attestation.digest     — declared bundleDigest == recomputed canonical digest
  8. attestation.signature  — HMAC verified IFF a key is supplied (else 'unauthenticated')
  9. freshness              — required evidence within window AND head-fresh
 10. policy.evidence        — all policy-required evidence present + claims satisfied
 11. policy.decision        — map the verified tier through the policy tier->decision map

Any failed check that a policy depends on drives BLOCK. The engine NEVER returns
ALLOW unless every relevant check passed. Determinism: freshness uses an INJECTED
reference time; no wall-clock is read inside the decision path.
"""
from __future__ import annotations

import os
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

from . import canonical, schema as schema_mod

DECISION_SCHEMA_VERSION = "1.0.0"

# Machine violation codes (stable identifiers for tests + callers).
V_SCHEMA_INTENT = "schema.intent.invalid"
V_SCHEMA_BUNDLE = "schema.bundle.invalid"
V_PROVENANCE = "provenance.unknown-issuer"
V_INTENTREF = "contradiction.intentRef"
V_BOUNDHEAD = "contradiction.boundHead"
V_HASH = "hash.mismatch"
V_PATH_ESCAPE = "artifact.path-escape"
V_DIGEST = "integrity.digest-mismatch"
V_SIGNATURE = "integrity.signature-invalid"
V_FRESH_STALE = "freshness.stale"
V_FRESH_UNPROVABLE = "freshness.unprovable"
V_FUTURE = "contradiction.future-evidence"
V_EVIDENCE_MISSING = "evidence.missing"
V_EVIDENCE_CLAIM = "evidence.claim-unsatisfied"
V_TIER_UNRESOLVED = "policy.tier-unresolved"
V_DEPENDENCY = "dependency.unavailable"
V_INTERNAL = "internal.error"

# Known/trusted issuer adapters for the MVP. Provenance is an allow-list: an unknown
# producer is not automatically trusted. (A real deployment keys this to registered
# adapters; the MVP hard-codes the shipped one.)
KNOWN_ISSUERS = {"claude-code", "preflight-test"}


class Check:
    __slots__ = ("name", "passed", "detail")

    def __init__(self, name: str, passed: bool, detail: str = ""):
        self.name = name
        self.passed = passed
        self.detail = detail

    def as_dict(self) -> Dict[str, Any]:
        d = {"name": self.name, "passed": self.passed}
        if self.detail:
            d["detail"] = self.detail
        return d


def _parse_rfc3339(ts: str) -> Optional[datetime]:
    """Parse an RFC3339/ISO-8601 UTC timestamp. Returns None if unparseable."""
    if not isinstance(ts, str) or not ts:
        return None
    s = ts.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


class Verifier:
    def __init__(
        self,
        intent_schema: dict,
        bundle_schema: dict,
        policy: dict,
        evidence_root: str,
        now: datetime,
        attestation_key: Optional[bytes] = None,
    ):
        self.intent_schema = intent_schema
        self.bundle_schema = bundle_schema
        self.policy = policy
        self.evidence_root = evidence_root
        self.now = now
        self.attestation_key = attestation_key

    # ---- the pipeline -------------------------------------------------------
    def verify(self, intent: Any, bundle: Any) -> Dict[str, Any]:
        checks: List[Check] = []
        violations: List[str] = []
        reasons: List[str] = []

        policy_id = self.policy.get("policyId", "unknown")
        intent_id = "unknown"

        def fail_closed(decision_note: str) -> Dict[str, Any]:
            return self._decision(
                "BLOCK", policy_id, intent_id, reasons, violations, checks
            )

        # 1 + 2: schema validation. Unparseable/mis-shaped -> BLOCK immediately.
        try:
            ie = schema_mod.validate(intent, self.intent_schema, "$intent")
        except schema_mod.SchemaError as e:  # our own schema is broken
            violations.append(V_INTERNAL)
            checks.append(Check("schema.intent", False, f"schema fault: {e}"))
            reasons.append("internal:schema-fault")
            return fail_closed("schema-fault")
        if ie:
            violations.append(V_SCHEMA_INTENT)
            checks.append(Check("schema.intent", False, "; ".join(ie[:5])))
            reasons.append("intent:schema-invalid")
        else:
            checks.append(Check("schema.intent", True))
            intent_id = intent.get("intentId", "unknown")

        try:
            be = schema_mod.validate(bundle, self.bundle_schema, "$bundle")
        except schema_mod.SchemaError as e:
            violations.append(V_INTERNAL)
            checks.append(Check("schema.bundle", False, f"schema fault: {e}"))
            reasons.append("internal:schema-fault")
            return fail_closed("schema-fault")
        if be:
            violations.append(V_SCHEMA_BUNDLE)
            checks.append(Check("schema.bundle", False, "; ".join(be[:5])))
            reasons.append("bundle:schema-invalid")

        # If either core document is structurally invalid, stop: subsequent checks
        # would dereference fields that may not exist. Fail closed.
        if violations:
            return fail_closed("schema-invalid")
        checks.append(Check("schema.bundle", True))

        # 3: provenance — known issuer/adapter.
        issuer = bundle["issuer"]["adapter"]
        if issuer in KNOWN_ISSUERS:
            checks.append(Check("provenance.issuer", True, issuer))
            reasons.append(f"provenance:issuer:{issuer}")
        else:
            checks.append(Check("provenance.issuer", False, f"unknown issuer {issuer!r}"))
            violations.append(V_PROVENANCE)
            reasons.append("provenance:unknown-issuer")

        # 4: intentRef consistency (id + head agree between intent and bundle).
        subj_head = intent["subject"]["head"]
        ref = bundle["intentRef"]
        ref_ok = True
        if ref["intentId"] != intent_id:
            ref_ok = False
            violations.append(V_INTENTREF)
            reasons.append("contradiction:intentRef-id")
        if ref["subjectHead"] != subj_head:
            ref_ok = False
            violations.append(V_INTENTREF)
            reasons.append("contradiction:intentRef-head")
        checks.append(Check("consistency.intentRef", ref_ok,
                            "" if ref_ok else "intentRef disagrees with intent"))

        # 5: every evidence item bound to the subject head; none from the future.
        boundhead_ok = True
        future_ok = True
        for i, ev in enumerate(bundle["evidence"]):
            if ev["boundHead"] != subj_head:
                boundhead_ok = False
                violations.append(V_BOUNDHEAD)
                reasons.append(f"contradiction:boundHead:evidence[{i}]:{ev['type']}")
            produced = _parse_rfc3339(ev["producedAt"])
            if produced is None:
                boundhead_ok = False  # unparseable timestamp is a structural defect
                violations.append(V_BOUNDHEAD)
                reasons.append(f"contradiction:producedAt-unparseable:evidence[{i}]")
            elif produced > self.now:
                future_ok = False
                violations.append(V_FUTURE)
                reasons.append(f"contradiction:future-evidence:evidence[{i}]")
        checks.append(Check("consistency.boundHead", boundhead_ok and future_ok))

        # 6: artifact hashes — recompute and compare. Missing file / mismatch -> forgery/tamper.
        # Artifact paths are CONFINED to the evidence root: a `../` traversal or an absolute
        # path that resolves outside the root is rejected BEFORE any filesystem access, so a
        # bundle can never make the verifier hash arbitrary files on the host (defense-in-depth
        # beyond the B2 boundary — an escape is a violation even under an unauthenticated run).
        hashes_ok = True
        root_real = os.path.realpath(self.evidence_root)
        for i, ev in enumerate(bundle["evidence"]):
            art = ev["artifact"]
            apath = os.path.join(self.evidence_root, art["path"])
            art_real = os.path.realpath(apath)
            if art_real != root_real and not art_real.startswith(root_real + os.sep):
                hashes_ok = False
                violations.append(V_PATH_ESCAPE)
                reasons.append(f"integrity:path-escape:evidence[{i}]:{art['path']}")
                continue
            try:
                actual = canonical.sha256_file(apath)
            except OSError:
                hashes_ok = False
                violations.append(V_EVIDENCE_MISSING)
                reasons.append(f"evidence:artifact-missing:evidence[{i}]:{art['path']}")
                continue
            if not canonical.consttime_eq(actual, art["sha256"]):
                hashes_ok = False
                violations.append(V_HASH)
                reasons.append(f"integrity:hash-mismatch:evidence[{i}]:{art['path']}")
        checks.append(Check("artifact.hashes", hashes_ok))

        # 7: attestation digest — recompute canonical digest sans attestation.
        recomputed = canonical.bundle_digest(bundle)
        declared = bundle["attestation"]["bundleDigest"]
        digest_ok = canonical.consttime_eq(recomputed, declared)
        if digest_ok:
            checks.append(Check("attestation.digest", True))
        else:
            violations.append(V_DIGEST)
            reasons.append("integrity:digest-mismatch")
            checks.append(Check("attestation.digest", False,
                                f"declared!=recomputed"))

        # 8: signature — verified only if a key is present. Otherwise unauthenticated
        #    (documented reduced guarantee), which is NOT itself a violation but IS
        #    surfaced so callers can require authentication if they choose.
        sig = bundle["attestation"].get("signature")
        algo = bundle["attestation"]["algo"]
        if self.attestation_key is not None:
            if algo != "hmac-sha256" or not sig:
                violations.append(V_SIGNATURE)
                reasons.append("integrity:signature-missing-under-key")
                checks.append(Check("attestation.signature", False, "key supplied but no hmac signature"))
            else:
                expected = canonical.hmac_sha256_hex(self.attestation_key, declared)
                if canonical.consttime_eq(expected, sig):
                    checks.append(Check("attestation.signature", True))
                    reasons.append("integrity:authenticated")
                else:
                    violations.append(V_SIGNATURE)
                    reasons.append("integrity:signature-invalid")
                    checks.append(Check("attestation.signature", False, "hmac mismatch"))
        else:
            checks.append(Check("attestation.signature", True,
                                "unauthenticated: no key supplied (MVP boundary)"))
            reasons.append("integrity:unauthenticated")

        # 9: freshness — window + head-fresh per policy freshness mode.
        window = self.policy.get("freshnessWindowSeconds")
        fresh_ok = True
        for req in self.policy.get("requiredEvidence", []):
            mode = req.get("freshness", "bound-head")
            match = _find_evidence(bundle, req["type"])
            if match is None:
                continue  # missing-evidence is handled by policy.evidence (10)
            produced = _parse_rfc3339(match["producedAt"])
            if produced is None:
                fresh_ok = False
                continue
            if window is not None:
                age = (self.now - produced).total_seconds()
                if age < 0 or age > window:
                    fresh_ok = False
                    violations.append(V_FRESH_STALE)
                    reasons.append(f"freshness:stale:{req['type']}:age={int(age)}s>window={window}s")
            if mode == "bound-head" and match["boundHead"] != subj_head:
                fresh_ok = False
                violations.append(V_FRESH_STALE)
                reasons.append(f"freshness:head-stale:{req['type']}")
        checks.append(Check("freshness", fresh_ok))

        # 10: policy evidence — required types present, claims satisfied.
        evidence_ok = True
        for req in self.policy.get("requiredEvidence", []):
            match = _find_evidence(bundle, req["type"])
            if match is None:
                evidence_ok = False
                violations.append(V_EVIDENCE_MISSING)
                reasons.append(f"evidence:missing:{req['type']}")
                continue
            for ck, cv in (req.get("mustClaim") or {}).items():
                if match.get("claims", {}).get(ck) != cv:
                    evidence_ok = False
                    violations.append(V_EVIDENCE_CLAIM)
                    reasons.append(f"evidence:claim-unsatisfied:{req['type']}:{ck}")
        checks.append(Check("policy.evidence", evidence_ok))

        # 11: decision — map the VERIFIED tier through the policy map. The tier comes
        #     from hash-checked, fresh, consistent evidence, NEVER from intent.context.
        tier = _resolve_tier(bundle, self.policy)
        tier_map = self.policy.get("tierDecisionMap", {})
        gate_passed = (
            not violations  # every prior check clean
            and ref_ok and boundhead_ok and future_ok and hashes_ok
            and digest_ok and fresh_ok and evidence_ok
        )

        if not gate_passed:
            checks.append(Check("policy.decision", False, "prior checks failed -> fail-closed BLOCK"))
            reasons.append("decision:fail-closed")
            return self._decision("BLOCK", policy_id, intent_id, reasons, violations, checks)

        if tier is None or tier not in tier_map:
            violations.append(V_TIER_UNRESOLVED)
            reasons.append("policy:tier-unresolved")
            checks.append(Check("policy.decision", False, "no resolvable tier -> BLOCK"))
            return self._decision("BLOCK", policy_id, intent_id, reasons, violations, checks)

        decision = tier_map[tier]
        if decision not in ("ALLOW", "REQUIRE_APPROVAL", "BLOCK"):
            violations.append(V_INTERNAL)
            reasons.append("policy:invalid-decision-mapping")
            checks.append(Check("policy.decision", False, f"bad mapping {tier}->{decision}"))
            return self._decision("BLOCK", policy_id, intent_id, reasons, violations, checks)

        checks.append(Check("policy.decision", True, f"tier {tier} -> {decision}"))
        reasons.append(f"decision:tier:{tier}->{decision}")
        return self._decision(decision, policy_id, intent_id, reasons, violations, checks)

    def _decision(self, decision, policy_id, intent_id, reasons, violations, checks) -> Dict[str, Any]:
        return {
            "schemaVersion": DECISION_SCHEMA_VERSION,
            "decision": decision,
            "policyId": policy_id,
            "intentId": intent_id,
            "evaluatedAt": self.now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "reasons": sorted(set(reasons)),
            "violations": sorted(set(violations)),
            "checks": [c.as_dict() for c in checks],
        }


def _find_evidence(bundle: dict, etype: str) -> Optional[dict]:
    for ev in bundle.get("evidence", []):
        if ev.get("type") == etype:
            return ev
    return None


def _resolve_tier(bundle: dict, policy: dict) -> Optional[str]:
    """Read the reversibility tier from the policy-designated evidence type/claim.

    The tier is taken ONLY from verified evidence — never from intent.context.tier.
    If MULTIPLE tier-evidence items disagree on the tier, that ambiguity is itself a
    contradiction: we return the sentinel "__ambiguous__" so the caller fails closed
    (an attacker must not pick the most permissive of several tiers).
    """
    etype = policy.get("tierEvidenceType")
    ckey = policy.get("tierClaimKey")
    if not etype or not ckey:
        return None
    tiers = [ev.get("claims", {}).get(ckey)
             for ev in bundle.get("evidence", []) if ev.get("type") == etype]
    tiers = [t for t in tiers if t is not None]
    if not tiers:
        return None
    if len(set(tiers)) > 1:
        return "__ambiguous__"   # not in any tierDecisionMap -> BLOCK
    return tiers[0]

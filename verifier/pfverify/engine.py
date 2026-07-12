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
from . import identity as identity_mod

DECISION_SCHEMA_VERSION = "1.0.0"
VERIFIER_VERSION = "0.1.0"

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
# Remote-authoritative identity re-resolution (fire only in remote mode).
V_IDENTITY_UNRESOLVABLE = identity_mod.V_IDENTITY_UNRESOLVABLE
V_IDENTITY_REPO = identity_mod.V_IDENTITY_REPO
V_IDENTITY_COMMIT = identity_mod.V_IDENTITY_COMMIT
V_IDENTITY_DIRTY = identity_mod.V_IDENTITY_DIRTY
V_IDENTITY_TREE = identity_mod.V_IDENTITY_TREE
V_IDENTITY_MODE = "identity.mode-misconfigured"

# Known/trusted issuer adapters for the MVP. Provenance is an allow-list: an unknown
# producer is not automatically trusted. (A real deployment keys this to registered
# adapters; the MVP hard-codes the shipped one.)
KNOWN_ISSUERS = {"producer-a", "producer-test"}


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
        mode: str = "local-advisory",
        repo_root: Optional[str] = None,
        git_runner=None,
        expected_repo: Optional[str] = None,
        untracked_mode: str = "no",
    ):
        self.intent_schema = intent_schema
        self.bundle_schema = bundle_schema
        self.policy = policy
        self.evidence_root = evidence_root
        self.now = now
        self.attestation_key = attestation_key
        # Remote-authoritative identity re-resolution. Defaults preserve the exact
        # local-advisory behavior every existing test relies on (identity stage OFF).
        self.mode = mode
        self.repo_root = repo_root
        self.git_runner = git_runner
        self.expected_repo = expected_repo
        self.untracked_mode = untracked_mode
        # Populated by the identity stage in remote mode; consumed by callers (CLI/CI)
        # that build an attestation from the independently re-resolved facts.
        self.resolved = None

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

        # IDENTITY RE-RESOLUTION (remote-authoritative mode only). Appends NOTHING in
        # local-advisory mode, so the emitted decision is byte-identical to the local
        # verifier for every existing test. In remote mode this re-derives repo + commit
        # FROM THE CHECKOUT and blocks when the producer's claim disagrees — the core of
        # the enforceable gate.
        identity_ok = True
        if self.mode == "remote-authoritative":
            identity_ok = self._reresolve_identity(intent, checks, violations, reasons)
            if not identity_ok:
                # A failed identity re-resolution is decisive: report it and fail closed
                # without letting downstream checks misattribute the cause.
                checks.append(Check("policy.decision", False, "identity re-resolution failed -> BLOCK"))
                reasons.append("decision:fail-closed")
                return self._decision("BLOCK", policy_id, intent_id, reasons, violations, checks)

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
        # Artifacts must resolve inside the evidence root ALWAYS. In remote-authoritative
        # mode they must ADDITIONALLY resolve inside the actual git checkout — a bundle
        # cannot point the verifier at files outside the tree under decision. `realpath`
        # collapses symlinks, so a symlink whose target escapes a confinement is caught
        # here too (symlink-escape defense).
        def _within(p, base):
            return p == base or p.startswith(base + os.sep)
        repo_real = (os.path.realpath(self.repo_root)
                     if self.mode == "remote-authoritative" and self.repo_root else None)
        for i, ev in enumerate(bundle["evidence"]):
            art = ev["artifact"]
            apath = os.path.join(self.evidence_root, art["path"])
            art_real = os.path.realpath(apath)
            contained = _within(art_real, root_real) and (repo_real is None or _within(art_real, repo_real))
            if not contained:
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
            and identity_ok  # remote-mode identity re-resolution (True in local-advisory)
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

    def _reresolve_identity(self, intent, checks, violations, reasons) -> bool:
        """Independently re-resolve repo + commit from the checkout and compare to the
        intent's CLAIMED subject. Returns False (→ BLOCK) on any disagreement or when the
        checkout cannot be resolved. Appends checks/violations/reasons. Remote mode only.
        """
        # A repo_root is mandatory in remote mode (the CLI enforces this too).
        if not self.repo_root:
            checks.append(Check("identity.resolve", False, "no --repo-root in remote-authoritative mode"))
            violations.append(V_IDENTITY_UNRESOLVABLE)
            reasons.append("identity:unresolvable:no-repo-root")
            return False

        git = self.git_runner or identity_mod.default_git_runner(self.repo_root)
        resolved, errs = identity_mod.resolve_identity(git, self.untracked_mode)
        if resolved is None:
            checks.append(Check("identity.resolve", False, "; ".join(errs) or "unresolvable"))
            violations.append(V_IDENTITY_UNRESOLVABLE)
            reasons.append("identity:unresolvable:" + (errs[0] if errs else "unknown"))
            return False
        self.resolved = resolved
        checks.append(Check("identity.resolve", True, resolved.commit[:12]))

        ok = True
        subject = intent.get("subject", {})

        # repo identity: compare on the host-insensitive `owner/repo` slug so a claim or a
        # CI-provided $GITHUB_REPOSITORY ("owner/repo", no host) interoperates with a
        # host-qualified origin ("host/owner/repo"). The re-resolved origin is authoritative;
        # the claim and --expected-repo are checked against it. An attacker-written
        # .git/config is defended by --expected-repo (fed from the CI env, not the checkout).
        resolved_slug = identity_mod.repo_owner_slug(resolved.repo_canonical)
        claimed_slug = identity_mod.repo_owner_slug(
            identity_mod.canonicalize_repo(subject.get("repo", "")))
        repo_match = bool(resolved_slug) and resolved_slug == claimed_slug
        if self.expected_repo is not None:
            expected_slug = identity_mod.repo_owner_slug(
                identity_mod.canonicalize_repo(self.expected_repo))
            if resolved_slug != expected_slug:
                repo_match = False
        if repo_match:
            checks.append(Check("identity.repo", True, resolved.repo_canonical))
        else:
            ok = False
            checks.append(Check("identity.repo", False,
                                f"claimed={claimed_slug!r} resolved={resolved_slug!r}"))
            violations.append(V_IDENTITY_REPO)
            reasons.append("identity:repo-mismatch")

        # commit identity: claimed head (7-64 hex) must expand to the re-resolved HEAD.
        if identity_mod.commit_matches(git, subject.get("head", ""), resolved.commit):
            checks.append(Check("identity.commit", True, resolved.commit[:12]))
        else:
            ok = False
            checks.append(Check("identity.commit", False,
                                f"claimed={subject.get('head','')!r} resolvedHEAD={resolved.commit[:12]}"))
            violations.append(V_IDENTITY_COMMIT)
            reasons.append("identity:commit-mismatch")

        # worktree cleanliness: on-disk tracked bytes must equal committed HEAD, else the
        # evidence no longer describes the commit under decision.
        if resolved.worktree_dirty:
            ok = False
            checks.append(Check("identity.worktree", False, "tracked worktree dirty"))
            violations.append(V_IDENTITY_DIRTY)
            reasons.append("identity:worktree-dirty")
        else:
            checks.append(Check("identity.worktree", True))

        # optional tree binding: if the intent recorded subject.tree, it must equal the
        # re-derived HEAD tree object.
        claimed_tree = subject.get("tree")
        if claimed_tree:
            if resolved.tree and claimed_tree.lower() == resolved.tree.lower():
                checks.append(Check("identity.tree", True, resolved.tree[:12]))
            else:
                ok = False
                checks.append(Check("identity.tree", False,
                                    f"claimed={claimed_tree!r} resolved={resolved.tree!r}"))
                violations.append(V_IDENTITY_TREE)
                reasons.append("identity:tree-mismatch")

        return ok


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

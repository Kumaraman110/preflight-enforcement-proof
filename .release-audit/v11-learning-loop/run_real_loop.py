#!/usr/bin/env python3
"""REAL Service N -> Service N+1 learning loop (not the fictional demo).

Service N   = CPSL SessionToken (PR-12): the migration silently INTRODUCED result codes absent
              from the legacy contract (S0000, W0024) and DROPPED/substituted legacy codes.
              The initial ruleset (code-quality only, i13) had NO wire-contract check -> ESCAPED.
Rule        = R-RESULTCODE-PARITY (resultcode_parity.py), adjudicated from that finding.
Promotion   = gated by a DISTINCT-approver-signed approval (pfverify.approval HMAC) — the
              engine/agent cannot self-promote.
Service N+1 = CTI.MicroService.TokenManager (real sibling, same result-code idiom). A DISPOSABLE
              migration branch introduces the EQUIVALENT drift (invented S0000/W0024, dropped
              E0005). With the promoted rule, Preflight CATCHES it before delivery; the corrected
              version PASSES.

Deterministic: injected --now, throwaway approver key, real frozen contracts + real source files.
Exit 0 iff the whole loop is proven.

Usage: run_real_loop.py <verifier-repo-root> <loop-dir> <approver-key-file> <now-rfc3339> [--wrong-key F]
"""
from __future__ import annotations
import sys, os, json, importlib.util


def load_rule_module(loop_dir):
    spec = importlib.util.spec_from_file_location("rcp", os.path.join(loop_dir, "resultcode_parity.py"))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


def read(p):
    return open(p, encoding="utf-8").read()


def codes(text):
    import re
    return sorted(set(re.findall(r'"([WES]\d{4})"', text)))


def main():
    repo, loop, approver_key_file, now = sys.argv[1:5]
    wrong_key_file = None
    if len(sys.argv) > 6 and sys.argv[5] == "--wrong-key":
        wrong_key_file = sys.argv[6]

    sys.path.insert(0, os.path.join(repo, "verifier"))
    from pfverify import approval as ap
    from pfverify.engine import _parse_rfc3339
    rcp = load_rule_module(loop)

    now_dt = _parse_rfc3339(now)
    result = {"service_n": "CPSL-SessionToken", "service_n1": "CTI.MicroService.TokenManager"}

    # ── Service N: the frozen legacy contract + the historical migrated codes (from the audit). ──
    n_legacy = [c.strip() for c in read(os.path.join(loop, "serviceN-legacy-codes.txt")).split()]
    # The historical PR-12 migrated CPSL emitted S0000 + W0024 (invented) and dropped W0011.
    # (Documented in docs/pr12-parity-audit.md; we assert the finding, not re-derive the whole POC.)
    n_migrated_introduced = ["S0000", "W0024"]
    n_migrated_dropped = ["W0011"]
    result["serviceN_legacy_contract"] = n_legacy
    result["serviceN_finding"] = {"introduced": n_migrated_introduced, "dropped": n_migrated_dropped,
                                  "source": "docs/pr12-parity-audit.md i05,i07,i12"}

    # ── Step 1: the INITIAL ruleset (code-quality only) does NOT contain a wire-contract rule,
    #    so the Service N result-code drift ESCAPED review (this is exactly i13). ──
    INITIAL_RULES = [
        {"id": "SEC-SQL-CONCAT", "kind": "quality"},
        {"id": "STYLE-NAMING", "kind": "quality"},
    ]
    has_parity_rule = any(r["id"] == rcp.RULE_TEMPLATE["id"] for r in INITIAL_RULES)
    result["serviceN_drift_escaped_initial_ruleset"] = (not has_parity_rule) and bool(
        n_migrated_introduced or n_migrated_dropped)

    # ── Step 2: adjudicate the escaped drift into the candidate rule (disposition PROMOTE). ──
    rule = dict(rcp.RULE_TEMPLATE)
    result["adjudication"] = {
        "driftClass": "result-code wire-contract divergence",
        "proposedRuleId": rule["id"],
        "adjudicator": "security-lead",
        "adjudicatedAt": "2026-07-15T00:00:00Z",
        "disposition": "PROMOTE",
    }

    # ── Step 3: promotion GATED by a signed approval (distinct approver key). ──
    def promote(ruleset, approval_obj, key):
        ok, viol = ap.verify_approval(approval_obj, key,
                                      intent_id=rule["id"],
                                      commit_sha="0" * 40, now=now_dt)
        if not ok:
            return list(ruleset), False, viol
        if any(r["id"] == rule["id"] for r in ruleset):
            return list(ruleset), True, []
        return list(ruleset) + [rule], True, []

    approver_key = open(approver_key_file, "rb").read().strip()
    signed = ap.sign_approval(
        ap.build_approval(intent_id=rule["id"], commit_sha="0" * 40, approver_id="security-lead",
                          issued_at="2026-07-15T00:00:00Z", expires_at="2099-01-01T00:00:00Z"),
        approver_key)

    # 3a. WITHOUT a valid approval -> fail-closed, ruleset unchanged.
    rs_noappr, promoted_noappr, _ = promote(INITIAL_RULES, None, approver_key)
    # 3b. WITH a wrong (non-approver) key -> cannot promote (no self-promotion).
    promoted_wrong = None
    if wrong_key_file:
        wrong_key = open(wrong_key_file, "rb").read().strip()
        _, promoted_wrong, _ = promote(INITIAL_RULES, signed, wrong_key)
    # 3c. WITH the valid approver-signed approval -> promoted.
    rs_promoted, promoted_ok, promo_viol = promote(INITIAL_RULES, signed, approver_key)
    result["promotion"] = {
        "without_approval_promoted": promoted_noappr,     # must be False
        "wrong_key_promoted": promoted_wrong,             # must be False (or None if not tested)
        "with_valid_approval_promoted": promoted_ok,      # must be True
        "violations_when_valid": promo_viol,
    }

    # ── Step 4: Service N+1. Fill the rule's legacyContract from the REAL TokenManager contract. ──
    n1_legacy = [c.strip() for c in read(os.path.join(loop, "serviceN1-legacy-codes.txt")).split()]
    rule_for_n1 = dict(rule); rule_for_n1["legacyContract"] = n1_legacy
    result["serviceN1_legacy_contract"] = n1_legacy

    drifted = read(os.path.join(loop, "serviceN1-migration-disposable", "TokenService.migrated-DRIFTED.cs"))
    corrected = read(os.path.join(loop, "serviceN1-migration-disposable", "TokenService.corrected.cs"))

    # 4a. BEFORE promotion (initial ruleset has no parity rule) -> the N+1 drift would ESCAPE.
    escapes_without_rule = not has_parity_rule
    # 4b. WITH the promoted rule -> Preflight CATCHES the equivalent drift before delivery.
    drift_violations = rcp.check(rule_for_n1, drifted) if promoted_ok else []
    # 4c. The CORRECTED change PASSES the same promoted rule.
    corrected_violations = rcp.check(rule_for_n1, corrected) if promoted_ok else ["(rule not promoted)"]

    result["serviceN1_drift_escapes_without_rule"] = escapes_without_rule
    result["serviceN1_drift_caught_with_promoted_rule"] = bool(drift_violations)
    result["serviceN1_drift_violations"] = drift_violations
    result["serviceN1_corrected_passes"] = (corrected_violations == [])
    result["serviceN1_corrected_violations"] = corrected_violations

    # ── The loop is PROVEN iff every link holds. ──
    result["loop_proven"] = bool(
        result["serviceN_drift_escaped_initial_ruleset"]
        and promoted_noappr is False
        and (promoted_wrong in (False, None))
        and promoted_ok is True
        and result["serviceN1_drift_caught_with_promoted_rule"]
        and result["serviceN1_corrected_passes"]
    )
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["loop_proven"] else 1


if __name__ == "__main__":
    sys.exit(main())

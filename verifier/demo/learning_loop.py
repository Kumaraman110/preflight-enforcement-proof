"""Two-service learning-loop demo (deterministic, isolated, stdlib only).

Demonstrates the accountability platform's *learning* property end to end:

  1. A minimal rule engine scans a "service" source for behavioral-drift patterns.
  2. ServiceN contains a drift the INITIAL ruleset does NOT catch (escapes review).
  3. The escaped finding is CAPTURED and ADJUDICATED (a structured record of what the
     drift was and the rule that would catch it).
  4. Promotion of that adjudicated finding into the ruleset is GATED by a human approval
     — a separate, attributable, signed artifact (the same approval mechanism the remote
     gate uses, `pfverify.approval`). The engine/agent cannot self-promote.
  5. ServiceN+1 contains an EQUIVALENT drift. With the promoted rule in place, the engine
     now catches it LOCALLY, before shipping.

Everything is deterministic: no wall-clock in the decision path (times are injected), no
network, fixed inputs → fixed outputs. Run `demo_run(...)` or the CLI to see the loop.
"""
from __future__ import annotations

import json
import re
from datetime import datetime
from typing import Dict, List, Optional, Tuple

from ..pfverify import approval as approval_mod  # pfverify.approval
from ..pfverify.engine import _parse_rfc3339


# ── The minimal rule engine ──────────────────────────────────────────────────────────
# A rule is {id, pattern (regex), description}. Scanning a service = finding rule matches
# in its source lines. A "drift" is a source line matching a KNOWN-BAD pattern that the
# current ruleset does not yet encode.

def scan(source: str, rules: List[dict]) -> List[dict]:
    """Return findings: each {ruleId, line, text} for every rule that matches a line.
    Deterministic: rules applied in order, lines in order."""
    findings = []
    for lineno, line in enumerate(source.splitlines(), start=1):
        for rule in rules:
            if re.search(rule["pattern"], line):
                findings.append({"ruleId": rule["id"], "line": lineno, "text": line.strip()})
    return findings


# ── Adjudication of an escaped drift ─────────────────────────────────────────────────
def adjudicate(drift_text: str, proposed_rule: dict, adjudicator: str, at: str) -> dict:
    """Produce a structured adjudication record for a drift that escaped the ruleset.
    This is the 'capture + adjudicate' step — it does NOT itself change the ruleset."""
    return {
        "adjudication": {
            "driftText": drift_text,
            "proposedRule": proposed_rule,   # {id, pattern, description}
            "adjudicator": adjudicator,
            "adjudicatedAt": at,
            "disposition": "PROMOTE",        # a human decided this should become a rule
        }
    }


# ── Promotion gated by a signed human approval ───────────────────────────────────────
def promote_rule(
    ruleset: List[dict],
    adjudication: dict,
    approval: Optional[dict],
    approver_key: Optional[bytes],
    now: datetime,
) -> Tuple[List[dict], bool, List[str]]:
    """Attempt to add the adjudicated rule to the ruleset. Gated by a valid approval
    signed with the approver key. Returns (new_ruleset, promoted, violations).

    Fail-closed: without a valid, matching, unexpired approval the ruleset is UNCHANGED.
    The approval binds to the proposed rule id (as the 'intentId') and a fixed commit
    placeholder, mirroring the remote-gate approval contract — so an engine/agent that
    lacks the approver key cannot self-promote a rule.
    """
    rule = adjudication["adjudication"]["proposedRule"]
    rule_id = rule["id"]
    # We reuse the approval verifier: the approval must be for this rule id, unexpired,
    # signed by the approver. commitSha is a fixed demo placeholder (the "state" promoted).
    upgrade_ok, violations = approval_mod.verify_approval(
        approval, approver_key,
        intent_id=rule_id,
        commit_sha="0000000000000000000000000000000000000000",
        now=now,
    )
    if not upgrade_ok:
        return list(ruleset), False, violations
    # Idempotent: don't double-add.
    if any(r["id"] == rule_id for r in ruleset):
        return list(ruleset), True, []
    return list(ruleset) + [rule], True, []


# ── The end-to-end demo ──────────────────────────────────────────────────────────────
# ServiceN and ServiceN+1 both contain an "insecure deserialization" drift (the escaped
# class), spelled slightly differently. The INITIAL ruleset only catches a known SQL
# pattern, so the deserialization drift escapes ServiceN. After adjudication + approved
# promotion, the new rule catches the EQUIVALENT drift in ServiceN+1.

SERVICE_N = """\
public void Handler(Request r) {
    var q = "SELECT * FROM t WHERE id = " + r.id;   // caught by initial SQL rule
    var obj = BinaryFormatter.Deserialize(r.payload); // DRIFT: insecure deserialization (escapes)
}
"""

SERVICE_N_PLUS_1 = """\
public void Process(Message m) {
    var data = new BinaryFormatter().Deserialize(m.body); // EQUIVALENT drift
}
"""

INITIAL_RULES = [
    {"id": "SQL-CONCAT", "pattern": r'"SELECT .*"\s*\+', "description": "SQL built by string concat"},
]

# The rule an adjudicator proposes for the escaped deserialization drift.
PROPOSED_RULE = {
    "id": "INSECURE-DESERIALIZE",
    "pattern": r"BinaryFormatter[^;]*\.Deserialize\(",
    "description": "Insecure deserialization via BinaryFormatter.Deserialize",
}


def demo_run(approval: Optional[dict], approver_key: Optional[bytes], now: datetime) -> dict:
    """Run the full loop. Returns a structured, deterministic result dict."""
    result = {}

    # Step 1: ServiceN scanned with the INITIAL ruleset — the deserialization drift escapes.
    n_findings_initial = scan(SERVICE_N, INITIAL_RULES)
    escaped = "BinaryFormatter" in SERVICE_N and not any(
        f["ruleId"] == PROPOSED_RULE["id"] for f in n_findings_initial)
    result["serviceN_initial_findings"] = n_findings_initial
    result["serviceN_drift_escaped"] = escaped

    # Step 2: adjudicate the escaped drift.
    adj = adjudicate(
        drift_text="var obj = BinaryFormatter.Deserialize(r.payload);",
        proposed_rule=PROPOSED_RULE,
        adjudicator="security-reviewer",
        at="2026-07-11T09:00:00Z",
    )
    result["adjudication"] = adj["adjudication"]

    # Step 3: promotion gated by the signed approval.
    new_rules, promoted, violations = promote_rule(
        INITIAL_RULES, adj, approval, approver_key, now)
    result["promoted"] = promoted
    result["promotion_violations"] = violations

    # Step 4: ServiceN+1 scanned. With the promoted rule it's caught; without, it escapes.
    n1_findings = scan(SERVICE_N_PLUS_1, new_rules)
    caught_n1 = any(f["ruleId"] == PROPOSED_RULE["id"] for f in n1_findings)
    result["serviceN1_findings"] = n1_findings
    result["serviceN1_equivalent_drift_caught"] = caught_n1

    # The loop is proven when: drift escaped initially, promotion required a valid approval,
    # and (only) after an approved promotion the equivalent drift is caught.
    result["loop_proven"] = bool(escaped and promoted and caught_n1)
    return result


def _main(argv=None):
    import argparse, sys
    ap = argparse.ArgumentParser(prog="learning-loop-demo")
    ap.add_argument("--approval", default=None)
    ap.add_argument("--approval-key-file", default=None)
    ap.add_argument("--now", required=True)
    args = ap.parse_args(argv)
    appr = json.load(open(args.approval, encoding="utf-8")) if args.approval else None
    key = open(args.approval_key_file, "rb").read().strip() if args.approval_key_file else None
    now = _parse_rfc3339(args.now)
    out = demo_run(appr, key, now)
    sys.stdout.write(json.dumps(out, sort_keys=True, separators=(",", ":")) + "\n")
    return 0 if out.get("loop_proven") else 1


if __name__ == "__main__":
    import sys
    sys.exit(_main())

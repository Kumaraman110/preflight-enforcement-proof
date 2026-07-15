#!/usr/bin/env python3
"""Result-code wire-contract parity rule (candidate rule R-RESULTCODE-PARITY).

REAL Service N finding (PR-12 CPSL SessionToken migration, docs/pr12-parity-audit.md,
inventory i05/i07/i08/i12): the migration silently INTRODUCED result codes absent from the
legacy contract (S0000, W0024), DROPPED legacy codes (W0011), and SUBSTITUTED wrong codes
(E0002->W0024). The Stage-1 code-reviewer checked code quality but had NO wire-contract parity
mechanism (i13) — so the drift ESCAPED review. Callers that branch on the legacy codes break.

This rule generalizes that finding: given the legacy result-code contract (the authoritative set
of codes the service is allowed to emit) and a migrated service's source, it flags
  - INTRODUCED codes: emitted by the migration but absent from the legacy contract, and
  - DROPPED codes:    present in the legacy contract but never emitted by the migration.
Either is a wire-contract divergence a caller can observe. Deterministic; stdlib only; no network.

The rule is a structured object {id, description, legacyContract, severity}. `check()` returns a
list of violation dicts. This is the object the learning loop PROMOTES (gated by a signed
approval) so that an EQUIVALENT drift in Service N+1 is caught before delivery.
"""
from __future__ import annotations
import re
import sys
import json

CODE_RE = re.compile(r'"([WES]\d{4})"')


def emitted_codes(source: str) -> set:
    """The set of result codes a service source assigns/emits (string literals like "W0011")."""
    return set(CODE_RE.findall(source))


def check(rule: dict, migrated_source: str) -> list:
    """Apply R-RESULTCODE-PARITY. Returns a list of violation dicts (empty == parity holds)."""
    legacy = set(rule["legacyContract"])
    emitted = emitted_codes(migrated_source)
    violations = []
    for c in sorted(emitted - legacy):
        violations.append({"ruleId": rule["id"], "kind": "introduced-code", "code": c,
                           "detail": f"result code {c} is emitted by the migration but is NOT in the legacy contract"})
    for c in sorted(legacy - emitted):
        violations.append({"ruleId": rule["id"], "kind": "dropped-code", "code": c,
                           "detail": f"legacy result code {c} is NEVER emitted by the migration (dropped)"})
    return violations


# The candidate rule an adjudicator proposes for the escaped Service N drift. legacyContract is
# filled at loop time from the frozen Service N / Service N+1 legacy source (never invented).
RULE_TEMPLATE = {
    "id": "R-RESULTCODE-PARITY",
    "description": "A migrated service must not emit result codes absent from the legacy wire "
                   "contract, nor drop legacy result codes (PR-12 CPSL i05/i07/i12).",
    "severity": "BLOCK",
    "origin": "adjudicated:pr12-cpsl-sessiontoken:i05,i07,i12",
    "legacyContract": [],
}


def _main(argv=None):
    ap_rule = argv[0]      # path to a rule json (with legacyContract filled)
    ap_source = argv[1]    # path to the migrated source to check
    rule = json.load(open(ap_rule, encoding="utf-8"))
    src = open(ap_source, encoding="utf-8").read()
    v = check(rule, src)
    print(json.dumps({"ruleId": rule["id"], "violations": v, "clean": not v},
                     sort_keys=True, indent=2))
    return 1 if v else 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))

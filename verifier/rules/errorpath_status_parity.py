#!/usr/bin/env python3
"""Error-path HTTP-status parity rule (candidate rule R-ERRORPATH-STATUS-PARITY).

REAL Service N finding (PR-12 CPSL SessionToken migration, docs/pr12-parity-audit.md §4.4 +
audit rows #11/#12/#13; summary line 215 "Error HTTP status (400->500 for operational failures)"):
the legacy service returned HTTP **400** for ALL downstream/operational failures (the WebException
catch assigned `HttpStatus = BadRequest` unconditionally). The migration mapped result codes
starting with 'E' to **500** via a global exception handler, with NO non-2xx override — so a DB
connection failure (#12) and a timeout (#13) that legacy surfaced as 400 now surface as 500.

Impact (audit line 148/194): operational dashboards, alerting, circuit-breakers and bot retry
logic that distinguish 400 (client error, do NOT retry) from 500 (server error, retry) behave
differently — a transient DB issue legacy returned as 400 (no retry) now returns 500 (caller
retries, amplifying load during an outage). This is a DISTINCT wire-contract dimension from
result-code parity (the HTTP status line, not the ResultCode field), and it escaped the Stage-1
code-quality review by the same mechanism (i13): no HTTP-status parity check existed.

This rule generalizes that finding: given the legacy error-path HTTP-status contract (the
authoritative set of status codes the service is allowed to return on non-success paths) and a
migrated service's source, it flags
  - INTRODUCED statuses: returned by the migration but absent from the legacy contract, and
  - DROPPED statuses:    present in the legacy contract but never returned by the migration.
Either is an observable HTTP-status divergence a caller's retry/alerting logic depends on.
Deterministic; stdlib only; no network.

The rule is a structured object {id, description, legacyContract, severity}. `check()` returns a
list of violation dicts. This is the object the learning loop PROMOTES (gated by a signed
approval) so that an EQUIVALENT status drift in Service N+1 is caught before delivery.

Extraction is language-parametric: `statusPattern` (a regex whose first group is the numeric
status) defaults to the .NET idiom set (Ok/BadRequest/NotFound/StatusCode(nnn)/Unauthorized/...)
but can be supplied per-stack in the rule object so the SAME guarantee applies to other stacks
(the G3 seam). If a rule sets `statusPattern`, it is used verbatim; otherwise the default below.
"""
from __future__ import annotations
import re
import sys
import json

# Default .NET/ASP.NET error-path status idioms. Maps a source construct to the HTTP status it
# returns. First capture group (when present) is an explicit numeric status; the keyword forms map
# to their canonical status via _KEYWORD_STATUS. A rule may override via rule["statusPattern"] +
# rule["keywordStatus"] for another stack (G3), keeping the set-diff guarantee identical.
_DEFAULT_STATUS_RE = (
    r'\bStatusCode\(\s*(\d{3})\s*\)'          # StatusCode(500)
    r'|\bStatus\s*=\s*(\d{3})\b'              # Status = 400
    r'|\b(BadRequest)\b'                      # -> 400
    r'|\b(Unauthorized)\b'                    # -> 401
    r'|\b(Forbid(?:den)?)\b'                  # -> 403
    r'|\b(NotFound)\b'                        # -> 404
    r'|\b(Conflict)\b'                        # -> 409
    r'|\b(UnprocessableEntity)\b'             # -> 422
    r'|\b(InternalServerError)\b'             # -> 500
)
_DEFAULT_KEYWORD_STATUS = {
    "BadRequest": "400", "Unauthorized": "401", "Forbid": "403", "Forbidden": "403",
    "NotFound": "404", "Conflict": "409", "UnprocessableEntity": "422",
    "InternalServerError": "500",
}

# Success/2xx constructs are NOT error-path statuses; the rule governs the ERROR/non-success
# contract only, so success returns (Ok/200/201/202/204) are deliberately excluded from the set.


def returned_statuses(source: str, status_re: str = _DEFAULT_STATUS_RE,
                      keyword_status: dict | None = None) -> set:
    """The set of ERROR-path HTTP statuses a service source returns (as numeric strings, e.g. '400')."""
    kw = keyword_status if keyword_status is not None else _DEFAULT_KEYWORD_STATUS
    out = set()
    for m in re.finditer(status_re, source):
        # Prefer an explicit numeric group; else map the matched keyword.
        num = next((g for g in m.groups() if g and g.isdigit()), None)
        if num is not None:
            out.add(num)
            continue
        kwmatch = next((g for g in m.groups() if g and not g.isdigit()), None)
        if kwmatch is not None and kwmatch in kw:
            out.add(kw[kwmatch])
    return out


def check(rule: dict, migrated_source: str) -> list:
    """Apply R-ERRORPATH-STATUS-PARITY. Returns a list of violation dicts (empty == parity holds)."""
    legacy = set(rule["legacyContract"])
    returned = returned_statuses(source=migrated_source,
                                 status_re=rule.get("statusPattern", _DEFAULT_STATUS_RE),
                                 keyword_status=rule.get("keywordStatus"))
    violations = []
    for s in sorted(returned - legacy):
        violations.append({"ruleId": rule["id"], "kind": "introduced-status", "status": s,
                           "detail": f"error-path HTTP status {s} is returned by the migration but is NOT in the legacy contract"})
    for s in sorted(legacy - returned):
        violations.append({"ruleId": rule["id"], "kind": "dropped-status", "status": s,
                           "detail": f"legacy error-path HTTP status {s} is NEVER returned by the migration (dropped)"})
    return violations


# The candidate rule an adjudicator proposes for the escaped Service N HTTP-status drift.
# legacyContract is filled at loop time from the frozen legacy contract (never invented).
RULE_TEMPLATE = {
    "id": "R-ERRORPATH-STATUS-PARITY",
    "description": "A migrated service must not return error-path HTTP status codes absent from "
                   "the legacy wire contract, nor drop legacy error-path statuses (PR-12 CPSL "
                   "audit #11/#12/#13 §4.4: legacy 400 for downstream failures -> migration 500).",
    "severity": "BLOCK",
    "origin": "adjudicated:pr12-cpsl-sessiontoken:audit-4.4,rows-11-12-13",
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

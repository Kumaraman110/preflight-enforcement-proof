# Governance POC — Shared Base Rubric

<!-- Section ID prefix: §B
     The SHARED BASE: the detection floor every team inherits. A team overlay may ADD rules or RAISE
     a base rule's severity, but may NEVER weaken a base rule (remove it, lower its severity, or
     redefine its Detect). Enforced by lib/rubric-overlay-check.sh. Base changes are governed
     separately (base-owners CODEOWNERS) — see .release-audit/RUBRIC-GOVERNANCE.md. -->

This is a thin POC fixture, not an operative rubric. It proves the no-weakening property.

---

## §B1 Security

### §B1.1 Log injection (CWE-117)
**Detect:** Logger call where an argument is user-controlled and not wrapped in a structured logging placeholder or sanitizer.
**Severity:** major
**Fix:** Use structured logging placeholders or a sanitizer.

---

## §B2 Input Validation

### §B2.1 Missing input validation on public API
**Detect:** Public API endpoint that accepts user input without validation attributes.
**Severity:** major
**Fix:** Add data-annotation validation matching the domain constraints.

# Governance POC — Team Overlay (INVALID: silently weakens the base)

<!-- An INVALID team overlay: it LOWERS a base rule's severity (§B2.1 major -> minor), which silently
     lowers the detection bar another team's service depends on. lib/rubric-overlay-check.sh must
     BLOCK it (exit 1, naming §B2.1). This is the RED case — the prime-requirement proof. -->

This overlay looks like a routine local tweak but degrades the shared floor.

---

## §B2 Input Validation

### §B2.1 Missing input validation on public API
**Detect:** Public API endpoint that accepts user input without validation attributes.
**Severity:** minor
**Fix:** Add data-annotation validation matching the domain constraints.

<!-- ^ LOWERED from major to minor — WEAKENING the base. Must be BLOCKED. -->

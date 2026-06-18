# Governance POC — Team Overlay (VALID: only tightens)

<!-- A VALID team overlay. It may ADD a new rule (new §ID) and RAISE a base rule's severity. It does
     NOT remove any base rule, lower any base severity, or redefine a base rule's Detect — so
     lib/rubric-overlay-check.sh ALLOWS it (exit 0). This is the GREEN case. -->

This overlay inherits the base and strengthens it for this team's services.

---

## §B1 Security

### §B1.1 Log injection (CWE-117)
**Detect:** Logger call where an argument is user-controlled and not wrapped in a structured logging placeholder or sanitizer.
**Severity:** blocker
**Fix:** Use structured logging placeholders or a sanitizer.

<!-- ^ RAISED from major to blocker — tightening, allowed. Base Detect text unchanged. -->

---

## §T1 Team-Specific: PII Handling

### §T1.1 PII in URL query string
**Detect:** A user identifier or token placed in a URL query string (logged by proxies/browsers).
**Severity:** blocker
**Fix:** Move the identifier to the request body or a header; never the query string.

<!-- ^ NEW rule (new §ID §T1.1, not in base) — adding detection, allowed. -->

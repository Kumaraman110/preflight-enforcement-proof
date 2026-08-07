# Preflight Base Rubric (stack-neutral)

<!-- Section ID prefix: §BASE
     The zero-config DETECTION FLOOR shipped with every install. It is deliberately STACK-NEUTRAL:
     every rule keys off a cross-cutting defect class (secrets, injection, swallowed errors, untested
     new surface) whose Detect signal is phrased WITHOUT language-specific tokens, so it fires on any
     stack (.NET, Python, Node, Go, ...). This is the "useful on day 0" fallback the code-reviewer and
     self-review skill load when a consumer has NOT configured a rubric of their own.

     HONEST CEILING (do not overstate): a stack-neutral floor catches a DEFINED class of cross-cutting
     issues; it is NOT a deep, stack-tuned review. Teams layer depth via a configured rubric + overlays
     (lib/rubric-resolve.sh). A clean diff may legitimately produce zero findings — that is correct, not
     a failure. The claim this rubric supports is "a working guardrail on any stack out of the box,"
     never "deep stack-specific review out of the box."

     Every rule carries a structured **Source:** provenance line (enforced by lib/rubric-source-check.sh):
       **Source:** <origin> | <ref> | <YYYY-MM-DD> | <op>
-->

This is the shipped stack-neutral base. It is loaded automatically when no project rubric is configured
so a freshly installed repo has a working Stage-1 review on day 0, on any stack.

---

## §BASE1 Secrets

### §BASE1.1 Hardcoded secret or credential in source
**Detect:** A string literal in tracked source that matches a credential shape — an API key/token
(e.g. an `AKIA…` AWS key id, a long random token), a password assigned to a variable/field named like
`password`/`secret`/`apikey`/`token`, or a private-key/connection-string literal — rather than being
read from configuration, an environment variable, or a secret store.
**Severity:** critical
**Fix:** Move the value to configuration / an environment variable / a secret manager and reference it;
rotate the exposed credential.
**Source:** preflight-base 2026-08-07 | cross-cutting-floor | 2026-08-07 | add

---

## §BASE2 Injection

### §BASE2.1 Untrusted input concatenated into a query, command, or log
**Detect:** User-controlled input is string-concatenated or interpolated into a SQL/NoSQL query, an OS
command / shell invocation, or a log line, instead of using a parameterized query, an argument vector,
or a structured-logging placeholder.
**Severity:** critical
**Fix:** Use parameterized queries / prepared statements, pass command arguments as a vector (no shell
string), and use structured logging placeholders for user data.
**Source:** preflight-base 2026-08-07 | cross-cutting-floor | 2026-08-07 | add

---

## §BASE3 Error Handling

### §BASE3.1 Swallowed error / empty catch
**Detect:** A caught exception or checked error that is discarded — an empty catch/except block, a
catch that only logs and continues where the caller cannot observe the failure, or an ignored error
return — so a real failure is silently dropped.
**Severity:** major
**Fix:** Handle the error, propagate it, or fail closed; if intentionally ignored, document why in code.
**Source:** preflight-base 2026-08-07 | cross-cutting-floor | 2026-08-07 | add

---

## §BASE4 Test Coverage

### §BASE4.1 New public surface without a test
**Detect:** A newly added public function / endpoint / exported symbol in the diff has no accompanying
test exercising it (no new or changed test references the new surface).
**Severity:** major
**Fix:** Add a test covering the new public behavior, including at least one failure/edge path.
**Source:** preflight-base 2026-08-07 | cross-cutting-floor | 2026-08-07 | add

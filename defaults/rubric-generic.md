# Generic Code Review Rubric (Default)

<!-- Section ID prefix: §G
     All section IDs in this rubric use the §G prefix to
     enable unambiguous cross-rubric reference. -->

This rubric is used when no project-specific rubric exists. It covers cross-cutting concerns that apply to any .NET project.

---

## §G1 Async Correctness

### §G1.1 Synchronous blocking in async context
**Detect:** `.Result`, `.Wait()`, `.GetAwaiter().GetResult()` called inside an `async` method or on a hot path.
**Severity:** major
**Fix:** Replace with `await`. Propagate async up the call chain.

### §G1.2 Missing CancellationToken propagation
**Detect:** Async method accepts `CancellationToken` parameter but does not pass it to downstream async calls (`HttpClient`, database, etc.).
**Severity:** major
**Fix:** Pass the token to every downstream awaitable.

### §G1.3 Fire-and-forget without observation
**Detect:** `Task` returned from an async call that is neither `await`ed, stored, nor observed (no `_ = Task.Run(...)`).
**Severity:** major
**Fix:** Await it, or if intentionally fire-and-forget, assign to `_ =` with a comment explaining why.

---

## §G2 Security

### §G2.1 Log injection (CWE-117)
**Detect:** Logger call (`_logger.Log*()`, `Log.*()`) where an argument is user-controlled (method parameter, HTTP context value, request body property) and NOT wrapped in structured logging placeholder (`{@name}`) or a sanitizer.
**Severity:** blocker
**Fix:** Use structured logging placeholders or wrap in a sanitization method.

### §G2.2 SSRF risk (CWE-918)
**Detect:** URL constructed by concatenating a user-controlled value without validation against an allowlist.
**Severity:** blocker
**Fix:** Validate the URL against a configured allowlist of permitted hosts/paths. Use `Uri.TryCreate` + scheme/host check.

### §G2.3 Hardcoded secrets
**Detect:** String literals that look like secrets (API keys, connection strings with passwords, tokens) in source code.
**Severity:** blocker
**Fix:** Move to configuration (secrets manager, environment variable) and reference by key.

### §G2.4 Missing input validation
**Detect:** Public API endpoint that accepts user input without `[MaxLength]`, `[Range]`, or equivalent validation attributes.
**Severity:** major
**Fix:** Add data annotation attributes matching the domain constraints.

---

## §G3 Error Handling

### §G3.1 Empty catch blocks
**Detect:** `catch` block with no body, or body that only re-throws the same exception.
**Severity:** major
**Fix:** Log the exception with context, or remove the try/catch if the exception should propagate.

### §G3.2 Catching System.Exception broadly
**Detect:** `catch (Exception ex)` at a non-boundary layer (not a top-level middleware or background service).
**Severity:** minor
**Fix:** Catch specific exception types relevant to the operation.

---

## §G4 HTTP Client Patterns

### §G4.1 HttpClient instantiation without factory
**Detect:** `new HttpClient()` in application code (not in tests).
**Severity:** major
**Fix:** Use `IHttpClientFactory` with typed or named clients.

### §G4.2 Missing resilience (Polly)
**Detect:** Typed HttpClient registered without a resilience handler (no `AddStandardResilienceHandler()` or explicit Polly policy).
**Severity:** minor
**Fix:** Add `AddStandardResilienceHandler()` or explicit retry/circuit-breaker policy.

---

## §G5 Dependency Injection

### §G5.1 Service lifetime mismatch
**Detect:** Singleton service that depends on (injects) a Scoped or Transient service.
**Severity:** major
**Fix:** Align lifetimes or use `IServiceScopeFactory` to resolve the shorter-lived dependency.

### §G5.2 Disposable registered without interface
**Detect:** Concrete class implementing `IDisposable` registered in DI without an interface, making it hard to mock and potentially leaking resources.
**Severity:** minor
**Fix:** Register via interface. Ensure DI container manages disposal.

---

## §G6 Configuration

### §G6.1 Missing options validation
**Detect:** `services.Configure<T>(...)` without `.ValidateDataAnnotations().ValidateOnStart()`.
**Severity:** minor
**Fix:** Use `services.AddOptions<T>().Bind(...).ValidateDataAnnotations().ValidateOnStart()`.

### §G6.2 Magic strings for config keys
**Detect:** Configuration section name as a literal string in multiple places.
**Severity:** info
**Fix:** Use a constant or the options pattern.

---

## §G7 Testing

### §G7.1 Test coverage regression
**Detect:** New code without corresponding test coverage (heuristic: new public method with no test referencing it).
**Severity:** major
**Fix:** Add tests covering the new code path.

### §G7.2 Test without assertion
**Detect:** Test method that calls code but never asserts on the result or verifies mock interactions.
**Severity:** major
**Fix:** Add meaningful assertions.

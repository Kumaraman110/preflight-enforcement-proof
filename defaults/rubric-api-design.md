# API Design Review Rubric (Net-New Development)

This rubric is used for net-new API projects. It covers API design, contract consistency, and operational readiness in addition to the generic code quality rules.

When reviewing net-new API code, apply BOTH this rubric AND the generic rubric. This rubric adds API-specific categories; it does not replace the generic rules.

---

## §A1 API Contract Design

### §A1.1 Inconsistent response envelope
**Detect:** Different endpoints return different response shapes for success/error cases. One returns `{data: T}`, another returns the raw object, another returns `{result: T, status: "ok"}`.
**Severity:** major
**Fix:** Standardize on one envelope: `{success: bool, data: T?, errors: [{code, message, field?}]?}`. All endpoints use the same shape.

### §A1.2 Missing error contract
**Detect:** Endpoint that can fail (database lookup, downstream call) but only returns 200 or 500 with no structured error body.
**Severity:** major
**Fix:** Define error response shape with problem details (RFC 7807) or consistent error envelope. Map known failures to appropriate HTTP status codes (404 not found, 422 validation, 503 downstream unavailable).

### §A1.3 Missing versioning strategy
**Detect:** API endpoint with no version indicator (no `/v1/` path prefix, no `api-version` header, no query param).
**Severity:** minor
**Fix:** Add path-prefix versioning (`/v1/resource`) unless the team has a documented alternative.

---

## §A2 Pagination and Limits

### §A2.1 Unbounded collection endpoint
**Detect:** GET endpoint that returns a list without pagination parameters (no `page`/`pageSize`, no `limit`/`offset`, no cursor).
**Severity:** major
**Fix:** Add pagination. Default page size ≤ 100. Include total count or next-page cursor in response.

### §A2.2 No maximum page size enforcement
**Detect:** Pagination accepts `pageSize` from user input without capping it.
**Severity:** major
**Fix:** Enforce max (e.g., 100). Silently cap or return 400 if exceeded.

---

## §A3 Authentication and Authorization

### §A3.1 Endpoint missing auth requirement
**Detect:** Controller/endpoint without `[Authorize]` attribute or explicit `[AllowAnonymous]` (ambiguous — is it intentionally open or accidentally unprotected?).
**Severity:** major
**Fix:** Add explicit `[Authorize]` or `[AllowAnonymous]` — make the intent clear.

### §A3.2 Token caching without stampede prevention
**Detect:** OAuth token cached with `IMemoryCache.GetOrCreateAsync` or `GetOrCreate` without a lock/semaphore. Under concurrent requests, all threads simultaneously request new tokens.
**Severity:** blocker
**Fix:** Use `static SemaphoreSlim` + double-checked lock pattern. Or use a dedicated token lifecycle manager.

---

## §A4 Observability

### §A4.1 Missing health endpoints
**Detect:** Service has no `/health` (liveness) or `/ready` (readiness) endpoint.
**Severity:** major
**Fix:** Add both. Liveness = service is running (always 200). Readiness = dependencies are reachable (checks downstream connectivity).

### §A4.2 No structured logging on error paths
**Detect:** Catch block that returns an error response without logging the exception with structured context.
**Severity:** minor
**Fix:** Log with `_logger.LogError(ex, "Operation {Op} failed for {Context}", ...)`.

### §A4.3 Missing request correlation
**Detect:** No correlation ID propagation (no `Activity.Current`, no `X-Correlation-Id` header forwarding).
**Severity:** minor
**Fix:** Ensure OpenTelemetry auto-instrumentation is configured, or manually propagate correlation IDs.

---

## §A5 Operational Readiness

### §A5.1 Dockerfile without non-root user
**Detect:** Dockerfile that runs as root (no `USER` directive after the final `FROM`).
**Severity:** blocker
**Fix:** Add `RUN groupadd -r appuser && useradd -r -g appuser -u 1000 appuser` + `USER appuser`.

### §A5.2 Health check in Dockerfile instead of orchestrator
**Detect:** `HEALTHCHECK` directive in Dockerfile (conflicts with ECS/K8s health check configuration).
**Severity:** minor
**Fix:** Remove from Dockerfile. Define health checks in the orchestrator's task/deployment definition only.

### §A5.3 Secrets as plaintext environment variables
**Detect:** Sensitive values (passwords, tokens, API keys) passed as plaintext `ENV` or `-e` in docker-compose / task definition. Look for: key names containing "secret", "password", "token", "key", "credential".
**Severity:** blocker
**Fix:** Use secrets manager ARN references (ECS `secrets` input) or mounted secret files.

---

## §A6 Idempotency and Safety

### §A6.1 Non-idempotent PUT
**Detect:** PUT endpoint that creates a new resource on every call rather than upserting (checking existence first).
**Severity:** major
**Fix:** PUT should be idempotent — same request produces same result regardless of repetition.

### §A6.2 Destructive GET
**Detect:** GET endpoint that modifies state (deletes, updates, triggers side effects beyond logging).
**Severity:** blocker
**Fix:** GET must be safe (no side effects). Move mutations to POST/PUT/DELETE.

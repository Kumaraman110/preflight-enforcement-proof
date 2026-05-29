# PR 12 — Parity Audit: Preflight SessionToken vs Legacy vs Prior Tool

**Date:** 2026-05-29
**Branch (migrated artifact):** `pr12/sessiontoken-experiment` @ `616edbe3`
**Branch (prior tool spec):** `poc/feature/migrate-sessiontoken` @ `7699a2bc`
**Legacy source:** `CTIAPI-DEV_Work/CTIAPI/Controllers/CPSLTokenController.cs` + `Business/CPSLTokenRepository.cs`

---

## 1. The 14 Divergence Points — Summary Table

| # | Behavior | Legacy | Prior Tool Decision | Preflight Result | Classification |
|---|----------|--------|--------------------|--------------------|----------------|
| 1 | Null/empty Version → result code | W0011 (from `ValidateRequest`: `if (string.IsNullOrEmpty(request.Version))`) | Tier 1 null/empty → W0011 + 400 | `[ApiController]` model validation rejects missing `Version` with automatic 400 (generic ProblemDetails). If empty string passes binding, controller checks `string.IsNullOrWhiteSpace(request.Version)` → W0023 (not W0011). | **UNDOCUMENTED_DEVIATION** |
| 2 | Malformed Version (e.g. "abc", "2.0.1") → result code | W0004 (from `Util.ValidateVersion` regex `^\d+\.\d+$`) | Tier 1 regex fail → W0004 + 400 | No regex validation exists. Malformed versions fall into the `else` branch (not "1.0" or "2.0") → W0023. | **UNDOCUMENTED_DEVIATION** |
| 3 | Regex-valid but not "1.0"/"2.0" (e.g. "3.0") → result code | W0023 + 400 + DeflectionResponse shape (empty exit points) | W0023 + 400 + Deflection shape | W0023 + 400 + `DeflectionTokenResponse` with empty `DeflectionExitPoints`. | **MATCH** |
| 4 | "2.0" + SkipPhoneCapability=true → which path | V1 path (`ProcessTokenRequest`) | V1 path | V1 path (`ProcessTokenRequestAsync`) | **MATCH** |
| 5 | "2.0" + SkipPhoneCapability=false → which path | V2 path (`ProcessTokenRequestV2`) with deflection fan-out | V2 path (token + deflection parallel) | V2 path (`ProcessTokenRequestV2Async`) with `Task.WhenAll(tokenTask, deflectionTask)` | **MATCH** |
| 6 | Invalid AppProfileID → result code | E0002 + 400 (from `profiles.TryGetValue` else-branch) | E0002 + 400 (config-driven set, Deviation #3) | W0024 + 400 — uses `_profileCache.IsValidProfile(appProfileId.ToUpperInvariant())` but returns W0024 "Invalid or missing request parameters" (not E0002). | **UNDOCUMENTED_DEVIATION** |
| 7 | Profile lookup case handling | `.ToUpper()` before `TryGetValue` → effectively case-insensitive | `.ToUpper()` + Ordinal comparer on uppercase-stored keys | `.ToUpperInvariant()` before lookup → case-insensitive (correct mechanism). | **MATCH** (mechanism correct, but code returns wrong error code — see #6) |
| 8 | Missing Authorization header → code + status | W0001 + 401 + `WWW-Authenticate: Basic` | W0001 + 401 + `WWW-Authenticate: Basic` | W0001 + 401 + `WWW-Authenticate: Basic` | **MATCH** |
| 9 | Present header but unknown/empty channel → code + status | E0001 + 401 + `WWW-Authenticate: Basic` | E0001 + 401 + `WWW-Authenticate: Basic` | E0001 + 401 + `WWW-Authenticate: Basic` | **MATCH** |
| 10 | Both auth rejections return WWW-Authenticate header | Yes | Yes | Yes (set in `WriteErrorResponse`) | **MATCH** |
| 11 | Downstream non-2xx with body containing E1000 → HTTP status | **ALWAYS 400** (WebException catch assigns `HttpStatus = BadRequest` unconditionally) | **400** (documented in Stage 3a Correction #7: non-2xx downstream → always 400) | Controller maps ResultCode starting with 'E' → 500, starting with 'W' → 400, else → 200. **No non-2xx override exists.** No downstream HTTP service exists (direct Dapper SQL instead). | **UNDOCUMENTED_DEVIATION** |
| 12 | Connection refused → result code | E1000 (from inner catch in WebException handler) at HTTP 400 | E0007 (Deviation #5) at HTTP 400 | Npgsql `NpgsqlException` → unhandled → global exception handler → E1000 at HTTP 500. | **UNDOCUMENTED_DEVIATION** |
| 13 | Timeout → result code | E1000 at HTTP 400 (same WebException handler) | E0005 (Deviation #5) at HTTP 400 | Npgsql connection timeout → same as #12: E1000 at HTTP 500 via global handler. | **UNDOCUMENTED_DEVIATION** |
| 14 | SlideToken return — HTTP status + body | 200 + `"Success"` (fire-and-forget, lies about completion) | 202 + `{"status":"accepted","message":"Token slide request queued"}` (Deviation #2) | 200 + `{"resultCode":"S0000","resultMessage":"Success"}` on success; 500 + `{"resultCode":"E1000","resultMessage":"Internal error."}` on exception. **Synchronous await** — blocks until DB call completes. | **UNDOCUMENTED_DEVIATION** |

### Divergence Count

| Classification | Count | Items |
|---|---|---|
| **MATCH** | 6 | #3, #4, #5, #7, #8, #9, #10 |
| **DELIBERATE_DEVIATION** | 0 | — |
| **UNDOCUMENTED_DEVIATION** | 7 | #1, #2, #6, #11, #12, #13, #14 |
| **NOT_ADDRESSED** | 0 | — |
| **CANNOT_VERIFY** | 1 | #11 partially (no downstream HTTP service to test against) |

---

## 2. Silent Migrations — Database Backend

| Aspect | Legacy | Preflight Produced | Flagged During Run? |
|--------|--------|--------------------|--------------------|
| **RDBMS** | SQL Server (via `CTI.DataLayer.DBHelper`, ADO.NET) | PostgreSQL (Npgsql 8.0.6, Dapper) | **NO** — Discovery analyst said "direct Dapper SQL" without noting the RDBMS change |
| **Token stored procs (SQL Server)** | Called via `TokenManagerMicroURL` → downstream `TokenManager` service → SQL Server stored procs | Preflight calls PostgreSQL functions directly: `cpsl_set_cc_token_v2`, `cpsl_set_mp_token_v1`, `cpsl_validate_token_v2`, `cpsl_update_token_code_v2`, `cpsl_slide_token_v1` | **NO** — These function names were INVENTED. They don't exist in any database. |
| **Channel/Profile stored procs** | `dbo.net_ctiChannelCode_getServerCacheList`, `dbo.net_ctiProfiles_getServerCacheList` (SQL Server, via `DBHelper.GetAllChannels()`/`DBHelper.GetAllProfiles()`) | PostgreSQL functions: `net_cti_channel_codes_get_server_cache_list()`, `net_cti_profiles_get_server_cache_list()` | **NO** — These are invented PL/pgSQL function names, not ports of existing procs |
| **Schema migration (DDL)** | Not applicable (legacy uses existing SQL Server DB) | **None produced** | **NO** — No DDL, no migration script, no table definitions |
| **Connection string format** | `Data Source=...;Initial Catalog=...;Integrated Security=...` (SQL Server) | `Host=...;Port=5432;Database=...;Username=...;Password=...` (PostgreSQL) | **NO** |
| **3-hop chain collapse** | Controller → TokenManagerMicroURL (HTTP) → TokenManager service → SQL Server | Controller → Dapper → PostgreSQL (direct) | **YES** — This was flagged as a deliberate architectural choice. But the fact that the DESTINATION DATABASE changed from SQL Server to PostgreSQL was not flagged. |

### Assessment

Preflight made a **silent, undocumented architectural decision** to:
1. Change the database engine from SQL Server to PostgreSQL
2. Invent PostgreSQL stored function names that don't exist anywhere
3. Collapse the HTTP intermediary (TokenManager service) AND change the backing store in one step
4. Produce no DDL or migration script for the invented schema

The prior tool was explicit about this decision space: it documented that `TokenManagerMicroURL` points to a downstream service, identified the 3-hop chain, and proposed collapsing to direct SQL. But it left the **RDBMS choice** as a deployment decision, not a code decision. Preflight hardcoded PostgreSQL without discussion.

---

## 3. ResultMessages Comparison

### Preflight's result code mapping (`Helpers/ResultMessages.cs`)

| Code | Preflight Message | Legacy Equivalent | Match? |
|------|-------------------|-------------------|--------|
| S0000 | "Success" | No explicit S0000 in legacy — success is implicit (response returned at 200) | **INVENTED** — Legacy uses no success code; response is just returned |
| W0001 | "Warning: Missing or invalid Authorization header." | W0001 in auth filter (legacy returns `BaseResponse` with just `ResultCode`, no `ResultMessage` field) | Partial — code matches, message text is invented |
| W0006 | "Warning: Session token validation failed." | W0006 in legacy means "token validation failed" (returned from downstream TokenManager) | **MATCH** (code semantics) |
| W0023 | "Warning: Unsupported version." | W0023 in legacy (controller else-branch for unknown version). Legacy returns no `ResultMessage` field — just `ResultCode` in the response body. | Partial — code matches, message invented |
| W0024 | "Warning: Invalid or missing request parameters." | **DOES NOT EXIST IN LEGACY** | **INVENTED** |
| E0001 | "Error: Channel authorization failed." | E0001 in legacy auth filter | Partial — code matches, message invented |
| E0007 | "Error: Backend service unavailable." | **DOES NOT EXIST IN LEGACY** (introduced by prior tool Deviation #5) | Borrowed from prior tool |
| E1000 | "Error: An unexpected internal error occurred." | E1000 in legacy (fallback when downstream body deserialization fails) | **MATCH** (code semantics) |

### Legacy result codes NOT present in preflight

| Code | Legacy Meaning | Used Where | Impact |
|------|---------------|------------|--------|
| **W0002** | "AppProfileID is required" (`string.IsNullOrEmpty(request.AppProfileID)`) | `ValidateRequest` line 305 | **MISSING** — Preflight has no explicit AppProfileID-required check |
| **W0003** | "ANI is required" (`string.IsNullOrEmpty(request.ANI)`) | `ValidateRequest` line 299 | Handled by `[Required]` on `TokenRequest.ANI` → returns generic ProblemDetails, not W0003 |
| **W0004** | "Invalid Version format" (regex validation failed) | `ValidateRequest` line 314 | **MISSING** — No regex validation exists |
| **W0005** | "Invalid TokenStatus" (not "AT" or "TT") | `ValidateRequest` line 318 | **MISSING** — No TokenStatus validation |
| **W0007** | "Invalid Format" (not "XML" or "JSON") | `ValidateRequest` line 334 | **MISSING** — No Format validation |
| **W0008** | "SessionToken/TokenStatus mismatch" | `ValidateRequest` lines 323-330 | **MISSING** — No cross-field validation |
| **W0011** | "Version is required" (null/empty version) | `ValidateRequest` line 309 | **MISSING** — Empty version returns W0023 instead |
| **E0002** | "Invalid Profile" (AppProfileID not in profiles dict) | `CPSLTokenRepository` line 141 | **WRONG CODE** — Preflight returns W0024 instead |
| **E0005** | "Timeout" | Prior tool Deviation #5 only (not legacy) | Present in `ResultMessages.cs` but unreachable in code |

### Summary

Preflight's result-code mapping is **severely incomplete**. The legacy `ValidateRequest` method implements an 8-step sequential validation chain returning 7 distinct warning/error codes. Preflight implements 2 of these 8 validation steps:
1. Empty version → but with wrong code (W0023 instead of W0011)
2. Profile validation → but with wrong code (W0024 instead of E0002)

The other 6 validation steps (W0002, W0003, W0004, W0005, W0007, W0008) are either missing entirely or handled by generic `[ApiController]` model validation returning ProblemDetails (not the legacy result-code contract).

---

## 4. The UNDOCUMENTED_DEVIATION List — Every Silent Invention

These are behaviors where preflight diverges from BOTH legacy AND the prior tool's documented decisions without acknowledgment:

### 4.1 — Version validation collapsed to single tier (BREAKS WIRE CONTRACT)

**Legacy:** Two-tier validation. Tier 1: regex `^\d+\.\d+$` (catches null→W0011, malformed→W0004). Tier 2: routing if/else (unknown valid version→W0023).

**Preflight:** Single check: `string.IsNullOrWhiteSpace(request.Version)` → W0023. No regex. Everything else falls to routing else-branch → also W0023.

**Impact:** Callers that branch on W0011 vs W0004 vs W0023 to provide different user-facing messages will see only W0023 for all version-related failures. This collapses 3 distinguishable error conditions into 1.

### 4.2 — Profile validation returns wrong error code (BREAKS WIRE CONTRACT)

**Legacy:** `E0002` + 400 when `AppProfileID` is not in the profiles dictionary.

**Preflight:** `W0024` + 400 when profile is invalid. W0024 doesn't exist in legacy at all.

**Impact:** Any caller with handling for `E0002` (e.g., prompting re-authentication or flagging a configuration issue) will never receive it. They'll get W0024 instead, which they have no handler for.

### 4.3 — Missing 6 of 8 legacy validation steps (BREAKS WIRE CONTRACT)

**Legacy `ValidateRequest` performs these checks in order:**
1. ANI empty → W0003
2. AppProfileID empty → W0002
3. Version empty → W0011
4. Version malformed → W0004
5. TokenStatus invalid → W0005
6. SessionToken/TokenStatus mismatch → W0008
7. Format invalid → W0007
8. Format empty → normalize to "json" (not an error)

**Preflight implements:**
- `[Required]` on ANI/Version/Format → generic ProblemDetails (not W0003/W0011)
- Version whitespace check → W0023 (wrong code)
- Profile validation → W0024 (wrong code)

**Impact:** Clients sending malformed requests will receive HTTP 400 with `ProblemDetails` JSON instead of the legacy `{"ResultCode":"W0003","ANI":...,"SessionToken":...}` response shape. This is a complete response-schema change for validation errors.

### 4.4 — Error HTTP status wrong for DB failures (BREAKS OPERATIONAL MONITORING)

**Legacy:** ALL downstream failures → HTTP 400 (WebException catch assigns `HttpStatus = BadRequest` unconditionally).

**Preflight:** DB connection failure → unhandled exception → global handler → HTTP 500.

**Impact:** Operational dashboards, alerting rules, and circuit-breaker configurations that distinguish 400 (client error, don't retry) from 500 (server error, retry) will behave differently. A transient DB issue that legacy would surface as 400 (caller does not retry) will now surface as 500 (caller may retry, amplifying load).

### 4.5 — SlideToken semantic change: fire-and-forget → synchronous await (BREAKS LATENCY CONTRACT)

**Legacy:** Returns HTTP 200 + "Success" IMMEDIATELY. The actual slide operation runs asynchronously (fire-and-forget). Caller sees <1ms response time. The operation may fail silently.

**Prior tool:** Preserved fire-and-forget semantics but changed to 202 Accepted (honest about async nature).

**Preflight:** Awaits the DB call synchronously. Returns 200 on success (after DB round-trip) or 500 on failure (after DB timeout). Caller now blocks for the full DB operation duration.

**Impact:** Callers that depend on SlideToken being non-blocking (submitting and moving on within their own timeout budgets) will see timeout failures if the DB call takes >N seconds. The legacy contract is "returns instantly regardless of outcome." Preflight's contract is "blocks until outcome is known." These are fundamentally different latency profiles.

### 4.6 — Invented S0000 success code (WIRE CONTRACT ADDITION)

**Legacy:** Successful responses have `ResultCode` derived from the downstream TokenManager response (typically "E0000" for success in legacy's convention — yes, "E0000" means success in legacy).

**Preflight:** Returns `ResultCode = "S0000"` on success.

**Impact:** Callers that check `ResultCode.StartsWith("E")` to detect errors will misclassify legacy's "E0000" success convention. Callers that check for `"S0000"` to detect success won't find it in legacy responses. This is a result-code namespace change.

### 4.7 — Direct SQL instead of HTTP intermediary (ARCHITECTURAL — no wire impact if response shape is preserved)

**Legacy:** Controller → HTTP POST to TokenManagerMicroURL → TokenManager service processes and returns.

**Preflight:** Controller → Dapper → PostgreSQL stored functions.

**Impact:** No wire-format impact to callers IF the response shape is preserved. However, the stored functions called (`cpsl_set_cc_token_v2` etc.) are **invented** — they don't exist in any database. This is not a divergence that breaks callers, but it means the service CANNOT WORK without creating these functions first.

---

## 5. Honest Assessment — Would This Break Frontends?

### Known consumers (from prior spec doc):
247_CUSTOMERIVR, LIVEPERSON_BOT, NETOMI, NLX, CPADMINUI, EZR, CPUI, NAVI

### Breaking changes by consumer type:

**IVR callers (247_CUSTOMERIVR, NAVI):**
- Likely branch on result codes to select voice prompts
- **W0011 → W0023 collapse:** If IVR has a "please provide version" prompt for W0011, it will never fire
- **E0002 → W0024:** If IVR has an "invalid profile" prompt for E0002, it will never fire
- **W0003 → ProblemDetails:** If IVR has an "ANI required" prompt for W0003, it gets unstructured JSON instead
- **Verdict: BREAKING**

**Chat/Bot callers (LIVEPERSON_BOT, NETOMI, NLX):**
- Likely check HTTP status + `ResultCode` field
- **500 vs 400 for DB failures:** Bot retry logic will retry on 500 (server error) where legacy returned 400 (no retry). Could amplify load during outages.
- **ProblemDetails instead of legacy response shape:** JSON parsing will fail or return null for `ResultCode` field
- **Verdict: BREAKING**

**Admin/UI callers (CPADMINUI, CPUI, EZR):**
- Likely display `ResultMessage` to users
- **Invented messages:** Will show messages that don't match documentation or training materials
- **Missing codes:** Error handling for E0002 will never trigger
- **Verdict: BREAKING (but less critical — internal tools can be updated)**

### SlideToken specifically:
- **ALL callers affected** — latency profile change from <1ms to potentially seconds
- IVR callers calling SlideToken mid-call-flow will add DB round-trip latency to call duration
- **Verdict: BREAKING for latency-sensitive callers**

### Overall verdict:

**This migration would break every frontend consumer** if deployed as-is. The wire contract (result codes, response shapes, HTTP status codes, latency profiles) has changed in undocumented ways that no caller is prepared for. The breaking changes are concentrated in:

1. Validation response shape (ProblemDetails vs legacy JSON)
2. Result code mapping (6 codes missing, 2 codes wrong, 1 invented)
3. Error HTTP status (400→500 for operational failures)
4. SlideToken latency profile (instant→blocking)

---

## 6. What Preflight Got Right

Credit where due — these aspects match legacy correctly:

1. **Route path**: `POST /ivr/tokenmanager/Token` and `POST /ivr/tokenmanager/SlideToken` ✓
2. **Version routing logic**: V1 vs V2 vs SkipPhoneCapability branching is correct ✓
3. **Auth W0001/E0001 split**: Correctly distinguishes missing-header from bad-channel ✓
4. **WWW-Authenticate header on 401**: Present on all auth rejections ✓
5. **V2 parallel fan-out pattern**: `Task.WhenAll(tokenTask, deflectionTask)` mirrors legacy ✓
6. **DeflectionExitPoints response shape**: Correct field names and structure ✓
7. **Profile case-handling**: `.ToUpperInvariant()` normalization before lookup ✓
8. **ChannelID from Basic auth**: Correctly decodes base64, splits on colon, takes first part, uppercases ✓
9. **Graceful deflection degradation**: Returns empty list on failure (matches prior tool Deviation #1) ✓

---

## 7. Root Cause Analysis — Why Did Preflight Miss This?

The prior tool spent **9 commits and 3 spec documents** mapping the exact legacy validation chain before writing a single line of implementation code. It identified the two-tier version validation, the 8-step `ValidateRequest` chain, the non-2xx HTTP status override, and the SlideToken fire-and-forget defect — all before code generation.

Preflight's Phase 1 discovery analyst:
- Read the legacy controller (183 lines)
- Identified the high-level structure (V1/V2 routing, SlideToken endpoint)
- **Did NOT read `CPSLTokenRepository.cs`** (500 lines containing the entire validation chain)
- **Did NOT read `AuthorizeClassFilterAttribute.cs`** (136 lines containing the auth logic)
- **Did NOT read `Util.ValidateVersion`** (15 lines containing the regex)
- **Did NOT identify the `ValidateRequest` method** as containing the result-code contract

The discovery analyst saw the controller as the complete picture and missed that 80% of the business logic lives in the repository. This is a fundamental scope error: the controller is a thin routing layer; the repository IS the service.

The generation spec then produced code from the controller-level understanding — routing, auth, response shapes — and filled in the gaps with reasonable-looking but contractually wrong implementations (W0024 for profiles, W0023 for all version errors, synchronous SlideToken).

---

## 8. Comparison Against Prior Tool's 5 Intentional Deviations

| Prior Tool Deviation | What Prior Tool Did | What Preflight Did | Preflight Aware? |
|---|---|---|---|
| #1 — Graceful deflection degradation | V2 returns token + empty exit points on deflection failure (instead of failing entirely) | Same behavior (returns `[]` on exception) | **Accidentally aligned** — not referenced, but same outcome |
| #2 — SlideToken 202 Accepted | Fire-and-forget preserved, but 202 instead of 200 (honest semantics) | Synchronous await, 200 on success, 500 on failure | **Contradicts both legacy AND prior tool** |
| #3 — Config-driven profile set | `ValidProfileIds` HashSet from SSM, replaces DB-backed stored proc | `FrozenSet` from DB query on startup (closer to legacy pattern actually) | **Different approach** — preflight uses DB cache like legacy, but against PostgreSQL (invented schema) |
| #4 — SkipPhoneCapability startup validation | Hard fail on non-boolean config value at startup | `bool` property via `.Bind()` — **silently coerces** non-boolean to `false` | **Contradicts prior tool** — exactly the gap Prior Tool Correction #4 was designed to catch |
| #5 — E0007/E0005 distinguished error codes | E0007 for connection refused, E0005 for timeout (both at 400) | E0007 exists in `ResultMessages.cs` but is **unreachable** — no code path returns it. All failures → E1000 at 500. | **Dead code** — included in the mapping but never returned |

---

*End of audit. This document captures the state of commit `616edbe3` before any corrections are applied.*

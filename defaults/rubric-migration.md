# Migration Review Rubric (Default)

This rubric is used for framework migration projects when no project-specific rubric exists. It covers the common classes of issues found when migrating .NET Framework services to modern .NET.

Projects with their own rubric (e.g., the CPSL migration rubric at `docs/cpsl-migration/migration-review-rubric.md`) should use that instead — it will be richer and calibrated to the specific codebase.

---

## §M1 Project Structure

### §M1.1 Non-SDK-style project file
**Detect:** `.csproj` using `<Project ToolsVersion=...>` or `<Import Project="$(MSBuildToolsPath)...">` (legacy format).
**Severity:** blocker
**Fix:** Convert to SDK-style format: `<Project Sdk="Microsoft.NET.Sdk.Web">`.

### §M1.2 Wrong target framework
**Detect:** `<TargetFramework>` still set to `net48`, `net472`, `netstandard2.0`, or any non-modern TFM when the migration target is specified.
**Severity:** blocker
**Fix:** Update to the target framework specified in project config.

---

## §M2 Dependency Injection

### §M2.1 Unity container references remain
**Detect:** References to `Unity`, `IUnityContainer`, `UnityContainerExtensions`, `RegisterType<>`.
**Severity:** blocker
**Fix:** Replace with `Microsoft.Extensions.DependencyInjection`. Constructor injection, `IServiceCollection` registration.

### §M2.2 Service Locator anti-pattern
**Detect:** `IServiceProvider.GetService<T>()` or `GetRequiredService<T>()` called outside of factory registrations or middleware.
**Severity:** major
**Fix:** Use constructor injection. Service locator is only acceptable in factory lambdas within `Program.cs`.

---

## §M3 Configuration

### §M3.1 ConfigurationManager static access
**Detect:** `ConfigurationManager.AppSettings[...]` or `ConfigurationManager.ConnectionStrings[...]`.
**Severity:** blocker
**Fix:** Use `IOptions<T>` pattern with `builder.Configuration.GetSection(...)`.

### §M3.2 Web.config/App.config remnants
**Detect:** `Web.config` or `App.config` files present in a modern .NET project.
**Severity:** major
**Fix:** Migrate settings to `appsettings.json` + environment-specific overrides.

---

## §M4 HTTP and Networking

### §M4.1 WebClient or HttpWebRequest usage
**Detect:** `WebClient`, `HttpWebRequest`, `WebRequest` in application code.
**Severity:** major
**Fix:** Replace with `HttpClient` via `IHttpClientFactory`.

### §M4.2 System.Web dependencies
**Detect:** `using System.Web`, `HttpContext.Current`, `HttpRequest`, `HttpResponse` from System.Web namespace.
**Severity:** blocker
**Fix:** Replace with ASP.NET Core equivalents (`Microsoft.AspNetCore.Http`).

---

## §M5 Serialization

### §M5.1 Newtonsoft.Json without justification
**Detect:** `Newtonsoft.Json` references in new code where `System.Text.Json` would work.
**Severity:** minor
**Fix:** Prefer `System.Text.Json`. Only use Newtonsoft when STJ lacks a required feature (e.g., complex polymorphic deserialization, `JsonPath`).

### §M5.2 Wire format breaking change
**Detect:** Property naming, casing, or structure differs from the legacy service's response format (when backward compatibility is required).
**Severity:** blocker
**Fix:** Add `[JsonPropertyName("...")]` or custom converters to match the exact legacy wire format.

---

## §M6 Async Migration

### §M6.1 Sync-over-async wrapper
**Detect:** Method that wraps an async call in `.Result` or `.Wait()` to present a synchronous interface.
**Severity:** major
**Fix:** Make the method async end-to-end. Propagate async up to the controller/handler.

### §M6.2 Missing async suffix removed
**Detect:** Method that IS async but lacks the `Async` suffix when the project convention uses it (or vice versa).
**Severity:** info
**Fix:** Follow the project's naming convention consistently.

---

## §M7 Authentication

### §M7.1 Legacy auth middleware carried forward
**Detect:** OWIN middleware, `[System.Web.Http.Authorize]`, custom `AuthorizationFilterAttribute` from legacy framework.
**Severity:** blocker
**Fix:** Replace with ASP.NET Core auth middleware (`AddAuthentication`, `AddAuthorization`, `[Authorize]`).

### §M7.2 Token validation bypass in non-development
**Detect:** Token validation that can be disabled via configuration in non-Development environments (missing environment guard).
**Severity:** blocker
**Fix:** Validation bypass must be gated by `IHostEnvironment.IsDevelopment()`. If the validation URL is empty in non-dev, fail at startup.

---

## §M8 Container and Deployment

### §M8.1 Running as root in container
**Detect:** Dockerfile with no `USER` directive, or `USER root` without switching back.
**Severity:** blocker
**Fix:** Add non-root user (uid 1000) with `groupadd`/`useradd`.

### §M8.2 HEALTHCHECK in Dockerfile
**Detect:** `HEALTHCHECK` directive in Dockerfile (conflicts with orchestrator health checks).
**Severity:** minor
**Fix:** Remove from Dockerfile. Define in ECS task definition or K8s deployment spec only.

### §M8.3 Immutable tag violation
**Detect:** Docker push with `:latest` tag when the registry enforces immutable tags.
**Severity:** blocker
**Fix:** Use SHA-based tags only. Remove `:latest` from build/push scripts.

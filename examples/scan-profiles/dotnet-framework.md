---
name: dotnet-framework
description: Technical debt patterns for .NET Framework 4.x → .NET 10 migration
stack: dotnet
version: 1
---

# .NET Framework Migration Scan Profile

This profile covers the seven canonical technical debt categories encountered when migrating from .NET Framework 4.5–4.8 to .NET 10. Used by the discovery-analyst during Phase 1.

---

## §D1 Legacy DI Container (Unity)

**What:** Unity container registrations indicating legacy dependency injection that must be replaced with the built-in DI container.
**Why:** Unity is unmaintained and incompatible with .NET 10. The native `Microsoft.Extensions.DependencyInjection` container is the standard.
**Severity:** required
**Glob:** *.cs
**Signal:** `unity\.RegisterType|unity\.RegisterInstance|container\.Resolve<|IUnityContainer|UnityContainer`
**Replacement:** Constructor injection via `Microsoft.Extensions.DependencyInjection`. Register in `Program.cs` using `builder.Services.AddTransient/Scoped/Singleton<T>()`.

---

## §D2 System.Web Dependencies

**What:** Usage of `System.Web` types (`HttpContext.Current`, `HttpRequest`, `HttpResponse`, `HttpApplication`) that do not exist in .NET 10.
**Why:** `System.Web` is the core of ASP.NET classic. It has no equivalent in ASP.NET Core — the entire request pipeline is different.
**Severity:** required
**Glob:** *.cs
**Signal:** `System\.Web|HttpContext\.Current|HttpApplication|System\.Web\.Http`
**Replacement:** ASP.NET Core equivalents — `IHttpContextAccessor` for context access, `HttpContext` via controller/middleware injection, `IApplicationBuilder` for pipeline configuration.

---

## §D3 ConfigurationManager Static Calls

**What:** Static access to configuration via `ConfigurationManager.AppSettings` or `ConfigurationManager.ConnectionStrings`.
**Why:** Static configuration access is incompatible with .NET 10's `IConfiguration` + options pattern and prevents testability.
**Severity:** required
**Glob:** *.cs
**Signal:** `ConfigurationManager\.AppSettings|ConfigurationManager\.ConnectionStrings|System\.Configuration\.ConfigurationManager`
**Replacement:** `IConfiguration` injection + `IOptions<T>` pattern with `AddOptions<T>().Bind().ValidateDataAnnotations().ValidateOnStart()`.

---

## §D4 Synchronous Database/HTTP Calls

**What:** Blocking I/O calls — synchronous database operations (`ExecuteReader`, `ExecuteNonQuery`, `.Result`, `.Wait()`) or synchronous HTTP calls (`WebClient`, `HttpWebRequest`).
**Why:** Synchronous I/O blocks threads and prevents efficient scaling under load. .NET 10 services should be async end-to-end.
**Severity:** recommended
**Glob:** *.cs
**Signal:** `\.ExecuteReader\(|\.ExecuteNonQuery\(|\.GetResponse\(|WebClient|HttpWebRequest|\.Result(?!s)|\.Wait\(\)|\.GetAwaiter\(\)\.GetResult\(\)`
**Replacement:** `async/await` end-to-end with `CancellationToken` propagation. Use `IHttpClientFactory` for HTTP, async ADO.NET methods or Dapper async for database.

---

## §D5 WCF/SOAP Service References

**What:** WCF client proxies, SOAP service references, or `System.ServiceModel` usage indicating RPC-style service dependencies.
**Why:** WCF client is partially available on .NET 10 but the server-side model is gone. SOAP references are fragile and should be replaced with typed HTTP clients.
**Severity:** recommended
**Glob:** *.cs, *.config, *.svc
**Signal:** `System\.ServiceModel|ServiceReference|BasicHttpBinding|ChannelFactory<|\.svc`
**Replacement:** Typed `HttpClient` via `IHttpClientFactory` calling REST/JSON endpoints. If the downstream is still SOAP-only, use `System.ServiceModel` client package with async patterns.

---

## §D6 Legacy Authentication Patterns

**What:** OWIN middleware, ASP.NET Identity, FormsAuthentication, or custom auth modules from the classic ASP.NET pipeline.
**Why:** ASP.NET Core has its own authentication/authorization middleware stack. Classic auth patterns are incompatible.
**Severity:** recommended
**Glob:** *.cs, web.config, *.config
**Signal:** `Microsoft\.Owin|Owin\.Security|FormsAuthentication|System\.Web\.Security|AspNet\.Identity|IAuthenticationManager`
**Replacement:** ASP.NET Core authentication middleware (`AddAuthentication`, `AddJwtBearer`, `AddOAuth`). For OAuth2 client_credentials flows, use token lifecycle with `IMemoryCache` + stampede prevention.

---

## §D7 Newtonsoft.Json Usage

**What:** Direct `Newtonsoft.Json` usage (`JsonConvert`, `JObject`, `JArray`, `[JsonProperty]` attributes) that can migrate to `System.Text.Json`.
**Why:** `System.Text.Json` is the .NET native serializer — faster, lower allocation, built-in source generation support. Reduces a dependency.
**Severity:** informational
**Glob:** *.cs, *.csproj
**Signal:** `Newtonsoft\.Json|JsonConvert\.|JObject|JArray|JToken|\[JsonProperty|JsonSerializerSettings`
**Replacement:** `System.Text.Json` with `JsonSerializer`, `[JsonPropertyName]` attributes, custom converters where wire-format parity requires it. Note: migration must preserve exact wire format — test byte-for-byte output parity before removing Newtonsoft.

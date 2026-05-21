# Generation Spec: .NET Service Patterns

These are complete, copy-pasteable code patterns with placeholders. When generating a service (Phase 3 of migration, or scaffold-api), use these patterns EXACTLY. Do not improvise variations.

Each pattern maps to a detection rule in the rubric. If you use the pattern correctly, the corresponding rubric section will never flag it. This is by design — the generation spec and detection spec are two sides of the same coin.

---

## Token Caching (prevents §G4.2, §M4.3 findings)

```csharp
public class {ServiceName}TokenProvider : I{ServiceName}TokenProvider
{
    private static readonly SemaphoreSlim _semaphore = new(1, 1);
    private readonly IMemoryCache _cache;
    private readonly {ServiceName}Options _options;
    private readonly HttpClient _httpClient;
    private readonly ILogger<{ServiceName}TokenProvider> _logger;
    private const string CacheKey = "{service-kebab}-oauth-token";

    public {ServiceName}TokenProvider(
        IMemoryCache cache,
        {ServiceName}Options options,
        HttpClient httpClient,
        ILogger<{ServiceName}TokenProvider> logger)
    {
        _cache = cache;
        _options = options;
        _httpClient = httpClient;
        _logger = logger;
    }

    public async Task<string> GetTokenAsync(CancellationToken ct = default)
    {
        if (_cache.TryGetValue(CacheKey, out string? cached))
            return cached!;

        await _semaphore.WaitAsync(ct);
        try
        {
            if (_cache.TryGetValue(CacheKey, out cached))
                return cached!;

            var token = await RequestTokenAsync(ct);
            var lifetime = TimeSpan.FromMinutes(_options.TokenLifetimeMinutes - 1);
            _cache.Set(CacheKey, token, lifetime);
            _logger.LogDebug("Token cached for {Lifetime}m", lifetime.TotalMinutes);
            return token;
        }
        finally
        {
            _semaphore.Release();
        }
    }

    private async Task<string> RequestTokenAsync(CancellationToken ct)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, _options.TokenUrl);
        /* ADAPT: Token request body — grant_type and fields vary per IdP */
        request.Content = new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["grant_type"] = "client_credentials",
            ["client_id"] = _options.ClientId,
            ["client_secret"] = _options.ClientSecret,
            ["scope"] = _options.Scope
        });

        var response = await _httpClient.SendAsync(request, ct);
        response.EnsureSuccessStatusCode();

        var json = await response.Content.ReadFromJsonAsync<JsonElement>(ct);
        return json.GetProperty("access_token").GetString()!; /* ADAPT: OAuth response property — verify against actual IdP */
    }
}
```

**Placeholders:** `{ServiceName}` (PascalCase), `{service-kebab}` (lowercase-hyphenated)
**When to apply:** Service needs OAuth2 client_credentials token

---

## Options Pattern with Validation (prevents §G6.1 findings)

```csharp
public class {ServiceName}Options
{
    public const string SectionName = "{ServiceName}";

    [Required]
    public string BaseUrl { get; set; } = string.Empty;

    [Required]
    public string TokenUrl { get; set; } = string.Empty;

    [Required]
    public string ClientId { get; set; } = string.Empty;

    [Required]
    public string ClientSecret { get; set; } = string.Empty;

    [Required]
    public string Scope { get; set; } = string.Empty;

    [Range(1, 60)]
    public int TokenLifetimeMinutes { get; set; } = 55;

    [Range(1, 30)]
    public int TimeoutSeconds { get; set; } = 15;

    /* ADAPT: Add service-specific properties with [Required]/[Range] annotations */
}
```

**Registration in Program.cs:**
```csharp
builder.Services
    .AddOptions<{ServiceName}Options>()
    .Bind(builder.Configuration.GetSection({ServiceName}Options.SectionName))
    .ValidateDataAnnotations()
    .ValidateOnStart();
```

---

## Typed HttpClient with Resilience (prevents §G4.1, §G4.2 findings)

```csharp
// Registration in Program.cs
builder.Services
    .AddHttpClient<I{ServiceName}Client, {ServiceName}Client>(client =>
    {
        client.BaseAddress = new Uri(builder.Configuration[$"{ServiceName}:BaseUrl"]!);
        client.Timeout = TimeSpan.FromSeconds(
            builder.Configuration.GetValue<int>($"{ServiceName}:TimeoutSeconds", 15));
    })
    .AddStandardResilienceHandler();
```

---

## Log Sanitization (prevents §G2.1 / CWE-117 findings)

```csharp
public static class LogSanitizer
{
    public static string Sanitize(string? input)
    {
        if (string.IsNullOrEmpty(input))
            return string.Empty;

        return input
            .Replace("\n", "_")
            .Replace("\r", "_")
            .Replace("\t", "_");
    }
}
```

**Usage pattern (every time user input is logged):**
```csharp
_logger.LogInformation("Looking up account for {MileagePlus}",
    LogSanitizer.Sanitize(request.MileagePlusNumber));
```

**NEVER do this:**
```csharp
_logger.LogInformation("Looking up account for {MileagePlus}", request.MileagePlusNumber);
```

---

## Health Endpoints (prevents §A4.1 findings)

```csharp
// In Program.cs
builder.Services.AddHealthChecks()
    .AddCheck<{ServiceName}HealthCheck>("downstream", tags: new[] { "ready" }); /* ADAPT: one AddCheck per critical dependency */

// After app = builder.Build():
app.MapHealthChecks("/health", new HealthCheckOptions
{
    Predicate = _ => false // Liveness: always 200
});
app.MapHealthChecks("/ready", new HealthCheckOptions
{
    Predicate = check => check.Tags.Contains("ready")
});
```

---

## Dockerfile (prevents §G2.2, §M8.1, §A5.1 findings)

```dockerfile
FROM mcr.microsoft.com/dotnet/aspnet:{version} AS base
WORKDIR /app
EXPOSE 8080

RUN groupadd -r appuser && useradd -r -g appuser -u 1000 appuser

FROM mcr.microsoft.com/dotnet/sdk:{version} AS build
WORKDIR /src
COPY ["{ServiceName}/{ServiceName}.csproj", "{ServiceName}/"]
RUN dotnet restore "{ServiceName}/{ServiceName}.csproj"
COPY . .
WORKDIR "/src/{ServiceName}"
RUN dotnet publish -c Release -o /app/publish /p:UseAppHost=false

FROM base AS final
WORKDIR /app
COPY --from=build /app/publish .
USER appuser
ENTRYPOINT ["dotnet", "{ServiceName}.dll"]
```

**NEVER include:** `HEALTHCHECK` directive (use orchestrator), `USER root` without switching back, `EXPOSE 80` (use 8080).

---

## Input Validation on Models (prevents §G2.4 / CWE-1174 findings)

```csharp
public class {RequestName}
{
    [Required]
    [MaxLength(25)]
    public string MileagePlusNumber { get; set; } = string.Empty;

    [Required]
    [MaxLength(100)]
    public string SessionToken { get; set; } = string.Empty;

    [MaxLength(10)]
    public string? Version { get; set; }
}
```

**Rule:** Every `string` property on a public request model MUST have `[MaxLength(N)]`. Every required field MUST have `[Required]`. No exceptions.

---

## Adaptation Points

Patterns above are used EXACTLY — except at marked `/* ADAPT */` points. These are the ONLY places where per-service customization is expected:

### Token Caching
- `/* ADAPT: OAuth response property */` — The token response JSON property name. Default is `"access_token"`. Some identity providers use `"token"`, `"id_token"`, or a nested path. Verify against the actual IdP response.
- `/* ADAPT: Token lifetime source */` — Default uses `_options.TokenLifetimeMinutes`. If the IdP returns `expires_in` in the response, prefer computing from that (subtract buffer) over config.
- `/* ADAPT: Token request body */` — The `grant_type` and fields vary. `client_credentials` is default. Service accounts may need `urn:ietf:params:oauth:grant-type:jwt-bearer` with assertion.

### Options Pattern
- `/* ADAPT: Add service-specific properties */` — Beyond BaseUrl/TokenUrl/ClientId/ClientSecret/Scope, each service has unique config (e.g., `RetryCount`, `CircuitBreakerThreshold`, downstream-specific paths). Add properties with `[Required]` or `[Range]` annotations as appropriate.

### Typed HttpClient
- `/* ADAPT: Base address source */` — Default reads from `Configuration[$"{ServiceName}:BaseUrl"]`. If the URL is constructed from multiple parts (region, version, tenant), adapt the address construction.

### Dockerfile
- `/* ADAPT: Additional COPY layers */` — If the service has native dependencies, additional runtime packages, or config files that must be copied separately.
- `/* ADAPT: Multi-project COPY */` — If the `.csproj` references other projects in the solution, COPY their project files for proper restore layer caching.

### Health Endpoints
- `/* ADAPT: Readiness dependencies */` — The downstream health check class name and what it probes. Each service has different backends (DB, HTTP, queue). Add one `AddCheck<>()` per critical dependency.

## Using This Spec

**The verb is PASTE, not "use."** Interpretation and reconstruction from memory degrade at high context utilization. Verbatim paste does not.

1. When generating Phase 3 code (migration) or scaffold code (net-new), identify each pattern above that applies to the service
2. For each applicable pattern: copy the code block CHARACTER FOR CHARACTER into the target file. Replace `{Placeholders}` with the service's values. Change nothing else.
3. At `/* ADAPT */` points ONLY: customize for the service's specific requirements. Document WHY in a comment at that point.
4. If you're unsure whether a pattern applies → paste it (it's cheaper to have an unused pattern than to get flagged for its absence)
5. After pasting all applicable patterns, the remaining work is service-specific business logic — that's the part that requires LLM reasoning, not templates
6. The rule is: **PASTE verbatim, then ADAPT at marked points only.** If you find yourself typing code that looks similar-but-not-identical to a spec pattern, stop — you're reconstructing, not pasting. Go back and copy.

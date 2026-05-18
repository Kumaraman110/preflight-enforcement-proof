# Generation Spec: .NET Service Patterns

These are complete, copy-pasteable code patterns with placeholders. When generating a service (Phase 3 of migration, or scaffold-api), use these patterns EXACTLY. Do not improvise variations.

Each pattern maps to a detection rule in the rubric. If you use the pattern correctly, the corresponding rubric section will never flag it. This is by design — the generation spec and detection spec are two sides of the same coin.

---

## Token Caching (prevents §4.2–4.4 findings)

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
        return json.GetProperty("access_token").GetString()!;
    }
}
```

**Placeholders:** `{ServiceName}` (PascalCase), `{service-kebab}` (lowercase-hyphenated)
**When to apply:** Service needs OAuth2 client_credentials token

---

## Options Pattern with Validation (prevents §6.1 findings)

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

## Typed HttpClient with Resilience (prevents §4.1, §4.2 findings)

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

## Log Sanitization (prevents §5.1 / CWE-117 findings)

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
    .AddCheck<{ServiceName}HealthCheck>("downstream", tags: new[] { "ready" });

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

## Dockerfile (prevents §2.2, §M8.1, §A5.1 findings)

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

## Input Validation on Models (prevents §2.4 / CWE-1174 findings)

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

## Using This Spec

1. When generating Phase 3 code (migration) or scaffold code (net-new), check each pattern above
2. If the service needs the pattern → instantiate with correct placeholder values → paste
3. If you're unsure whether to use a pattern → use it (it's cheaper to have an unused pattern than to get flagged for its absence)
4. After pasting all applicable patterns, the remaining work is service-specific business logic — that's the part that requires LLM reasoning, not templates

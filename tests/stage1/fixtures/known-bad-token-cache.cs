// Fixture: triggers §M4.3 (IMemoryCache.GetOrCreateAsync for tokens — thundering herd)
// Expected findings: 1 major-severity on line 18

using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Logging;

namespace TestService.Services;

public class TokenProvider
{
    private readonly IMemoryCache _cache;
    private readonly HttpClient _httpClient;
    private readonly ILogger<TokenProvider> _logger;

    public async Task<string> GetTokenAsync(CancellationToken ct)
    {
        return await _cache.GetOrCreateAsync("oauth_token", async entry =>
        {
            entry.AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(55);
            var response = await _httpClient.PostAsync("/oauth/token", null, ct);
            var payload = await response.Content.ReadFromJsonAsync<TokenResponse>(ct);
            return payload.AccessToken;
        });
        // ↑ §M4.3: GetOrCreateAsync is NOT single-flight. Under concurrent requests,
        //   multiple callers enter the factory simultaneously → thundering herd on
        //   the token endpoint. Must use SemaphoreSlim + double-checked lock.
    }
}

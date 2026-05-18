// DI-coupled: TokenProvider is injected into AccountClient
// These MUST be in the same coupling group

using Microsoft.Extensions.Logging;

namespace TestService.Services;

public class TokenProvider : ITokenProvider
{
    private readonly HttpClient _httpClient;

    public async Task<string> GetTokenAsync(CancellationToken ct)
    {
        var response = await _httpClient.PostAsync("/oauth/token", null, ct);
        return await response.Content.ReadAsStringAsync(ct);
    }
}

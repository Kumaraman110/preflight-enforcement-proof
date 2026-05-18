// DI-coupled: AccountClient depends on ITokenProvider via constructor injection
// These MUST be in the same coupling group

using Microsoft.Extensions.Logging;

namespace TestService.Clients;

public class AccountClient : IAccountClient
{
    private readonly HttpClient _httpClient;
    private readonly ITokenProvider _tokenProvider;
    private readonly ILogger<AccountClient> _logger;

    public AccountClient(HttpClient httpClient, ITokenProvider tokenProvider, ILogger<AccountClient> logger)
    {
        _httpClient = httpClient;
        _tokenProvider = tokenProvider;
        _logger = logger;
    }

    public async Task<AccountResponse> LookupAsync(string id, CancellationToken ct)
    {
        var token = await _tokenProvider.GetTokenAsync(ct);
        _httpClient.DefaultRequestHeaders.Authorization = new("Bearer", token);
        var response = await _httpClient.GetAsync($"/accounts/{id}", ct);
        return await response.Content.ReadFromJsonAsync<AccountResponse>(ct);
    }
}

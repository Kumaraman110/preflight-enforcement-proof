// Fixture: code that should trigger the operative rule below
// The rule (simulated from capture file):
//   Flag as major if: HttpClient.DefaultRequestHeaders is set inside a request method
//   BAD: _httpClient.DefaultRequestHeaders.Authorization = new(...)
//   GOOD: Use HttpRequestMessage with per-request headers
//
// Expected: rule fires (info-level because Survived: 0)

using System.Net.Http.Headers;

namespace TestService.Clients;

public class DownstreamClient
{
    private readonly HttpClient _httpClient;

    public async Task<string> CallApiAsync(string token, CancellationToken ct)
    {
        _httpClient.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", token);
        // ↑ Operative rule fires: mutating shared DefaultRequestHeaders is thread-unsafe

        var response = await _httpClient.GetAsync("/api/data", ct);
        return await response.Content.ReadAsStringAsync(ct);
    }
}

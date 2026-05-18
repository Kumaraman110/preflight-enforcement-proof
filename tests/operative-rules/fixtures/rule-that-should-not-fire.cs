// Fixture: code that should NOT trigger the operative rule
// The rule: Flag if DefaultRequestHeaders is set inside a request method
// This code uses per-request HttpRequestMessage headers — the GOOD pattern
//
// Expected: rule does NOT fire

using System.Net.Http.Headers;

namespace TestService.Clients;

public class DownstreamClient
{
    private readonly HttpClient _httpClient;

    public async Task<string> CallApiAsync(string token, CancellationToken ct)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, "/api/data");
        request.Headers.Authorization =
            new AuthenticationHeaderValue("Bearer", token);
        // ↑ Correct: per-request headers on HttpRequestMessage, not shared DefaultRequestHeaders

        var response = await _httpClient.SendAsync(request, ct);
        return await response.Content.ReadAsStringAsync(ct);
    }
}

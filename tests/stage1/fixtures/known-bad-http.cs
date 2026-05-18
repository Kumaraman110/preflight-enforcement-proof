// Fixture: triggers §M4.1 (WebClient) and §M4.2 (System.Web dependency)
// Expected findings: 1 major on line 13, 1 blocker on line 20

using System.Net;
using System.Web;

namespace TestService.Clients;

public class LegacyApiClient
{
    public string FetchData(string endpoint)
    {
        using var client = new WebClient();
        // ↑ §M4.1: WebClient usage — must use HttpClient via IHttpClientFactory
        return client.DownloadString(endpoint);
    }

    public string GetCurrentUser()
    {
        return HttpContext.Current.User.Identity.Name;
        // ↑ §M4.2: System.Web HttpContext.Current — not available in ASP.NET Core
    }
}

// Fixture: triggers §M3.1 (ConfigurationManager) and §M2.2 (Service Locator)
// Expected findings: 1 blocker on line 15, 1 major on line 22

using System.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace TestService.Services;

public class LegacySettingsReader
{
    private readonly IServiceProvider _serviceProvider;

    public string GetEndpointUrl()
    {
        var url = ConfigurationManager.AppSettings["ServiceEndpoint"];
        // ↑ §M3.1: static ConfigurationManager access — must use IOptions<T>
        return url ?? "http://fallback";
    }

    public IAccountRepository GetRepository()
    {
        return _serviceProvider.GetRequiredService<IAccountRepository>();
        // ↑ §M2.2: Service Locator anti-pattern outside factory registration
    }
}

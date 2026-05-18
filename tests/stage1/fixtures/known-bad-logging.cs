// Fixture: triggers §M9.1 (unsanitized logging) and §M9.2 (credentials in logs)
// Expected findings: 2 major-severity on lines 14, 22

using Microsoft.Extensions.Logging;

namespace TestService.Services;

public class AccountService
{
    private readonly ILogger<AccountService> _logger;

    public async Task<Account> LookupAsync(string userInput, string sessionToken)
    {
        _logger.LogInformation("Looking up account for: {Input}", userInput);
        // ↑ §M9.1: user-controlled value logged without sanitization

        var account = await _repository.GetByIdAsync(userInput);

        if (account == null)
        {
            _logger.LogWarning("Failed lookup. Session: {Token}, Input: {Input}",
                sessionToken, userInput);
            // ↑ §M9.2: session token (credential) logged directly
            return null;
        }

        return account;
    }
}

// GOOD: correctly guarded - should NOT be flagged
public class WellGuardedService {
    private bool _dbConfigured = false;

    public bool IsValidChannel(string channelId) {
        // Null check FIRST, then empty check - correct order
        if (string.IsNullOrEmpty(channelId)) {  // Has null check
            return false;
        }
        if (!_dbConfigured) {
            return false;  // Fail-CLOSED, not fail-open
        }
        return CheckCache(channelId);
    }

    public bool IsValidProfile(string profileId) {
        // Using != null check
        if (profileId != null && profileId.Length == 0) {
            return false;
        }
        if (!_dbConfigured) {
            return false;  // Fail-CLOSED
        }
        return CheckCache(profileId);
    }

    public ValidationResult Validate(TokenRequest request) {
        // Null check before empty check
        if (request.TokenStatus == null || request.TokenStatus == "") {
            return ValidationResult.Fail("W0008");
        }
        return ValidationResult.Pass();
    }

    // Non-boundary internal method - should not be flagged even if it has patterns
    internal void InternalHelper(string data) {
        if (data == "") {  // Internal, not a boundary
            // This is fine - not externally reachable
        }
    }

    private bool CheckCache(string id) { return true; }
}

public class TokenRequest {
    public string TokenStatus { get; set; }
}

public class ValidationResult {
    public static ValidationResult Fail(string code) => new ValidationResult { Code = code };
    public static ValidationResult Pass() => new ValidationResult { Code = "OK" };
    public string Code { get; set; }
}
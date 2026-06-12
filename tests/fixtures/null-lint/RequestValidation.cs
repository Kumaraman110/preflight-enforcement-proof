// BAD: W0008 guard - TokenStatus == "" misses null
public class RequestValidation {
    public ValidationResult Validate(TokenRequest request) {
        // W0008_STYLE_GUARD - null TokenStatus slips through
        if (request.TokenStatus == "") {
            return ValidationResult.Fail("W0008");
        }
        // The LIVE PR #95 shape (RequestValidation.cs:44): a null check of a
        // DIFFERENT variable (SessionToken) on the same line must NOT suppress
        // the W0008 finding on TokenStatus == "".
        if ((!string.IsNullOrEmpty(request.SessionToken)) && request.TokenStatus == "") {
            return ValidationResult.Fail("W0008");
        }
        return ValidationResult.Pass();
    }
}

public class TokenRequest {
    public string TokenStatus { get; set; }  // Can be null (JSON omitted)
    public string SessionToken { get; set; }
}

public class ValidationResult {
    public static ValidationResult Fail(string code) => new ValidationResult { Code = code };
    public static ValidationResult Pass() => new ValidationResult { Code = "OK" };
    public string Code { get; set; }
}

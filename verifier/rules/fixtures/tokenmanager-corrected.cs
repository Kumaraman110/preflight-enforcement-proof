// Service N+1: migrated CTI.MicroService.TokenManager (CORRECTED — wire-contract parity restored).
// Emits ONLY the legacy contract: E0005 (timeout), E0007 (connect-failure/404), E1000 (internal).
public class TokenService {
    public TokenManagerModel GetTokenDetails(TokenRequest req) {
        var result = new TokenManagerModel();
        try {
            result = _repository.TokenManager(req);   // success: response returned at 200, no invented code
            return Ok(result);
        } catch (ConnectFailure) {
            result.ResultCode = "E0007";
        } catch (TimeoutException) {
            result.ResultCode = "E0005";              // corrected: timeout maps to the legacy code
        } catch (Exception) {
            result.ResultCode = "E1000";
        }
        return BadRequest(result);
    }
}

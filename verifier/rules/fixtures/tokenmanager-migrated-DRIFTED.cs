// Service N+1: migrated CTI.MicroService.TokenManager (DISPOSABLE branch — equivalent PR-12 drift).
// Legacy contract: E0005 (timeout), E0007 (connect-failure/404), E1000 (internal).
public class TokenService {
    public TokenManagerModel GetTokenDetails(TokenRequest req) {
        var result = new TokenManagerModel();
        try {
            result = _repository.TokenManager(req);
            result.ResultCode = "S0000";              // DRIFT: invented success code (not in legacy)
            return Ok(result);
        } catch (ConnectFailure) {
            result.ResultCode = "E0007";              // preserved
        } catch (TimeoutException) {
            result.ResultCode = "W0024";              // DRIFT: wrong/invented code; legacy uses E0005
        } catch (Exception) {
            result.ResultCode = "E1000";              // preserved
        }
        return BadRequest(result);
    }
}

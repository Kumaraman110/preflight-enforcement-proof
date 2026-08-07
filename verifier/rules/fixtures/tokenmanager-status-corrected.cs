// Service N+1: migrated CTI.MicroService.TokenManager (CORRECTED — error-path HTTP-status parity restored).
// Returns ONLY the legacy error-path contract: 400 (ALL downstream/operational failures) + 401 (auth).
// The global-handler 500 override is removed; downstream failures map back to the legacy 400.
public class TokenService {
    public IActionResult GetTokenDetails(TokenRequest req) {
        if (!_auth.HasValidChannel(req)) {
            return Unauthorized();                        // 401 — legacy auth path
        }
        try {
            var result = _repository.TokenManager(req);   // success path: 200 (not an error-path status)
            return Ok(result);
        } catch (ConnectFailure) {
            return BadRequest();                           // corrected: downstream failure -> legacy 400
        } catch (TimeoutException) {
            return BadRequest();                           // corrected: timeout -> legacy 400
        } catch (Exception) {
            return BadRequest();                           // 400
        }
    }
}

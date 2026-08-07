// Service N+1: migrated CTI.MicroService.TokenManager (DISPOSABLE branch — equivalent PR-12 §4.4 drift).
// Legacy error-path HTTP-status contract: 400 (ALL downstream/operational failures, WebException catch
// assigns HttpStatus=BadRequest unconditionally) + 401 (missing/invalid auth, WWW-Authenticate: Basic).
// DRIFT: the migration maps result codes starting with 'E' to 500 via a global exception handler with
// NO non-2xx override, so a DB connection failure / timeout that legacy surfaced as 400 now surfaces
// as 500 — breaking retry/circuit-breaker logic (audit rows #11/#12/#13, §4.4).
public class TokenService {
    public IActionResult GetTokenDetails(TokenRequest req) {
        if (!_auth.HasValidChannel(req)) {
            return Unauthorized();                        // 401 — preserved (legacy auth path)
        }
        try {
            var result = _repository.TokenManager(req);   // success path: 200 (not an error-path status)
            return Ok(result);
        } catch (ConnectFailure) {
            return StatusCode(500);                        // DRIFT: legacy returned 400 for this downstream failure
        } catch (TimeoutException) {
            return StatusCode(500);                        // DRIFT: legacy returned 400 for a timeout
        } catch (Exception) {
            return BadRequest();                           // 400 — preserved
        }
    }
}

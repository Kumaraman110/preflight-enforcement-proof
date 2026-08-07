# Service N+1 (non-.NET / Python): migrated token service — CLEAN, wire-contract parity holds.
# Legacy result-code contract: E0005 (timeout), E0007 (connect-failure/404), E1000 (internal).
# NOTE single-quoted string literals — the pre-G3 rule regex matched ONLY double quotes and would
# have FAILED OPEN here (seen nothing, passed green). The quote-agnostic rule detects these.
class TokenService:
    def get_token_details(self, req):
        result = {}
        try:
            result = self._repository.token_manager(req)
            return result
        except ConnectFailure:
            result['result_code'] = 'E0007'      # preserved
        except TimeoutError:
            result['result_code'] = 'E0005'      # preserved (maps timeout to the legacy code)
        except Exception:
            result['result_code'] = 'E1000'      # preserved
        return result

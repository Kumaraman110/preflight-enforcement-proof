# Service N+1 (non-.NET / Python): migrated token service — DRIFTED, equivalent PR-12 result-code drift.
# Legacy contract: E0005 (timeout), E0007 (connect-failure/404), E1000 (internal).
# DRIFT (same class as the .NET fixture): invents S0000 (success code not in legacy), substitutes
# W0024 for the legacy E0005 (so E0005 is DROPPED). Single-quoted literals — proves the quote-agnostic
# fix closes the fail-open (the old double-quote-only regex would have passed this green).
class TokenService:
    def get_token_details(self, req):
        result = {}
        try:
            result = self._repository.token_manager(req)
            result['result_code'] = 'S0000'      # DRIFT: invented success code (not in legacy)
            return result
        except ConnectFailure:
            result['result_code'] = 'E0007'      # preserved
        except TimeoutError:
            result['result_code'] = 'W0024'      # DRIFT: wrong/invented code; legacy uses E0005 (dropped)
        except Exception:
            result['result_code'] = 'E1000'      # preserved
        return result

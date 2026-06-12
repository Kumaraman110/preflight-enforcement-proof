// BAD: same shape as ChannelCacheService
public class ProfileCacheService {
    private bool _dbConfigured = false;

    public bool IsValidProfile(string profileId) {
        if (profileId == string.Empty) {  // EMPTY_GUARD_WITHOUT_NULL_CHECK
            return false;
        }
        if (!_dbConfigured) {
            return true;  // PERMISSIVE_DEFAULT_UNCONFIGURED
        }
        return CheckCache(profileId);
    }

    private bool CheckCache(string id) { return true; }
}
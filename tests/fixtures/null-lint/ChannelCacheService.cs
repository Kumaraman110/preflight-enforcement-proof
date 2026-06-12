// BAD: fail-open auth - returns !_dbConfigured when cache empty
public class ChannelCacheService {
    private bool _dbConfigured = false;

    public bool IsValidChannel(string channelId) {
        if (channelId == "") {  // EMPTY_GUARD_WITHOUT_NULL_CHECK - null slips through
            return false;
        }
        if (!_dbConfigured) {
            return true;  // PERMISSIVE_DEFAULT_UNCONFIGURED - fail-open!
        }
        return CheckCache(channelId);
    }

    private bool CheckCache(string id) { return true; }
}
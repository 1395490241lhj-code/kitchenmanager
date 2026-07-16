const { SUPABASE_URL, SUPABASE_ANON_KEY } = require('../config');

// Freezes /api/sync/* for a user whose account deletion is underway. This
// lives at the Express middleware layer — the same layer as the existing
// version-gate and rate-limit middleware — rather than inside the large
// apply_sync_mutation/pull_sync_changes/get_sync_bootstrap SQL functions,
// which stay untouched. A lightweight, RLS-scoped read (anon key + the
// caller's own bearer token, exactly like every other read in this
// codebase) is enough: account_deletion_requests_select_self already
// restricts a user to seeing only their own row.
function createAccountDeletionSyncGuard({
  supabaseUrl = SUPABASE_URL,
  anonKey = SUPABASE_ANON_KEY,
  fetchImpl = globalThis.fetch
} = {}) {
  return async function accountDeletionSyncGuard(req, res, next) {
    if (!supabaseUrl || !anonKey || typeof fetchImpl !== 'function') {
      // Fail open only for "not configured" (matches every other Supabase-
      // backed check in this codebase — the RPC calls themselves would
      // already fail closed downstream if truly misconfigured); this guard
      // existing or not never changes what apply_sync_mutation itself
      // enforces.
      return next();
    }
    let response;
    try {
      response = await fetchImpl(
        `${supabaseUrl}/rest/v1/account_deletion_requests?select=status&user_id=eq.${encodeURIComponent(req.auth.userId)}`,
        {
          headers: {
            apikey: anonKey,
            Authorization: `Bearer ${req.auth.accessToken}`,
            Accept: 'application/json'
          }
        }
      );
    } catch {
      // A transient network failure here must not block ordinary sync for
      // every other user — only an explicit, confirmed in-progress deletion
      // does that.
      return next();
    }
    if (!response.ok) return next();
    let rows;
    try { rows = await response.json(); } catch { return next(); }
    const status = Array.isArray(rows) && rows[0] ? rows[0].status : null;
    if (status === 'requested' || status === 'business_data_cleaned' || status === 'auth_deletion_pending') {
      return res.status(423).json({
        error: { code: 'ACCOUNT_DELETION_IN_PROGRESS', message: '账号删除正在进行中，暂时无法同步。' }
      });
    }
    return next();
  };
}

module.exports = { createAccountDeletionSyncGuard };

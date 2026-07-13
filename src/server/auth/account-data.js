const {
  SUPABASE_ANON_KEY,
  SUPABASE_URL
} = require('../config');

class AccountDataError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'AccountDataError';
    this.code = code;
  }
}

function createSupabaseAccountDataSource({
  supabaseUrl = SUPABASE_URL,
  anonKey = SUPABASE_ANON_KEY,
  fetchImpl = globalThis.fetch
} = {}) {
  async function request(path, accessToken) {
    if (!supabaseUrl || !anonKey || typeof fetchImpl !== 'function') {
      throw new AccountDataError('not_configured', 'Supabase account data is not configured');
    }
    const response = await fetchImpl(`${supabaseUrl}/rest/v1/${path}`, {
      headers: {
        apikey: anonKey,
        Authorization: `Bearer ${accessToken}`,
        Accept: 'application/json'
      }
    });
    if (!response.ok) {
      throw new AccountDataError('query_failed', `Supabase account query failed (${response.status})`);
    }
    const value = await response.json();
    if (!Array.isArray(value)) {
      throw new AccountDataError('invalid_response', 'Supabase account query returned an invalid shape');
    }
    return value;
  }

  return {
    async getAccount({ userId, accessToken }) {
      const encodedUserId = encodeURIComponent(userId);
      const profiles = await request(
        `profiles?select=id,email,display_name&id=eq.${encodedUserId}&limit=1`,
        accessToken
      );
      if (!profiles[0]) return null;
      if (profiles[0].id !== userId) {
        throw new AccountDataError('identity_mismatch', 'Supabase profile did not match the verified subject');
      }

      const memberships = await request(
        `household_members?select=role,households!inner(id,name)&user_id=eq.${encodedUserId}`,
        accessToken
      );
      return {
        profile: profiles[0],
        households: memberships.map(item => ({
          id: item.households?.id,
          name: item.households?.name,
          role: item.role
        })).filter(item => item.id && item.name && item.role)
      };
    }
  };
}

module.exports = {
  AccountDataError,
  createSupabaseAccountDataSource
};

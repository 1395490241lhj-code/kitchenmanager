const { SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY } = require('../config');
const { AccountDeletionError } = require('./errors');

// User-scoped RPC calls: anon key + the caller's own bearer token, exactly
// like src/server/sync/repository.js — never the service-role key. RLS and
// the functions' own auth.uid()-derived checks are what keep these safe;
// this repository does not add its own authorization logic on top.
function createSupabaseAccountDeletionRepository({
  supabaseUrl = SUPABASE_URL,
  anonKey = SUPABASE_ANON_KEY,
  fetchImpl = globalThis.fetch
} = {}) {
  async function rpc(functionName, parameters, accessToken) {
    if (!supabaseUrl || !anonKey || typeof fetchImpl !== 'function') {
      throw new AccountDeletionError('account_deletion_not_configured', 'Account deletion is not configured', 503);
    }
    let response;
    try {
      response = await fetchImpl(`${supabaseUrl}/rest/v1/rpc/${functionName}`, {
        method: 'POST',
        headers: {
          apikey: anonKey,
          Authorization: `Bearer ${accessToken}`,
          Accept: 'application/json',
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(parameters || {})
      });
    } catch (error) {
      throw new AccountDeletionError('account_deletion_network_error', 'Account deletion request failed', 503, { cause: error });
    }
    if (!response.ok) {
      throw new AccountDeletionError('account_deletion_rpc_failed', `Account deletion RPC failed (${response.status})`, 502);
    }
    let payload;
    try { payload = await response.json(); } catch (error) {
      throw new AccountDeletionError('account_deletion_invalid_response', 'Account deletion RPC returned invalid JSON', 502, { cause: error });
    }
    if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
      throw new AccountDeletionError('account_deletion_invalid_response', 'Account deletion RPC returned an invalid shape', 502);
    }
    return payload;
  }

  return {
    async getPreview({ accessToken }) {
      return rpc('get_account_deletion_preview', {}, accessToken);
    },
    async requestDeletion({ accessToken, idempotencyKey, previewFingerprint }) {
      return rpc('request_account_deletion', {
        p_idempotency_key: idempotencyKey,
        p_preview_fingerprint: previewFingerprint
      }, accessToken);
    },
    async transferOwnership({ accessToken, householdId, newOwnerUserId }) {
      return rpc('transfer_household_ownership', {
        p_household_id: householdId,
        p_new_owner_user_id: newOwnerUserId
      }, accessToken);
    },
    async listMembersForTransfer({ accessToken, householdId }) {
      return rpc('list_household_members_for_transfer', { p_household_id: householdId }, accessToken);
    }
  };
}

// Privileged, backend-only operations: the Supabase Auth Admin API and the
// service_role-only finalize RPC. Never reachable from iOS, never triggered
// by anything other than this module's own confirm handler after the
// user-scoped RPC above has already reported business_data_cleaned.
function createSupabaseAccountDeletionAdmin({
  supabaseUrl = SUPABASE_URL,
  serviceRoleKey = SUPABASE_SERVICE_ROLE_KEY,
  fetchImpl = globalThis.fetch
} = {}) {
  function assertConfigured() {
    if (!supabaseUrl || !serviceRoleKey || typeof fetchImpl !== 'function') {
      throw new AccountDeletionError('account_deletion_admin_not_configured', 'Account deletion admin operations are not configured', 503);
    }
  }

  return {
    // Deleting the Auth user cannot be done via plain SQL (GoTrue owns
    // session/identity/refresh-token cleanup) — this is the one operation
    // in this codebase that legitimately needs the service-role key, used
    // only for exactly this one admin endpoint, never for ordinary reads.
    async deleteAuthUser({ userId }) {
      assertConfigured();
      let response;
      try {
        response = await fetchImpl(`${supabaseUrl}/auth/v1/admin/users/${encodeURIComponent(userId)}`, {
          method: 'DELETE',
          headers: {
            apikey: serviceRoleKey,
            Authorization: `Bearer ${serviceRoleKey}`,
            Accept: 'application/json'
          }
        });
      } catch (error) {
        return { deleted: false, alreadyGone: false, cause: error };
      }
      // A retried finalize step may find the user already gone (a prior
      // attempt's Admin API call succeeded but the response was lost, or a
      // network blip happened after deletion but before this function
      // returned) — Supabase returns 404 for that, which must be treated
      // as an idempotent success, not a failure to keep retrying forever.
      if (response.status === 404) return { deleted: true, alreadyGone: true };
      if (!response.ok) return { deleted: false, alreadyGone: false };
      return { deleted: true, alreadyGone: false };
    },

    async markFinalized({ userId, idempotencyKey, authDeleted, failureCode = null }) {
      assertConfigured();
      let response;
      try {
        response = await fetchImpl(`${supabaseUrl}/rest/v1/rpc/mark_account_deletion_finalized`, {
          method: 'POST',
          headers: {
            apikey: serviceRoleKey,
            Authorization: `Bearer ${serviceRoleKey}`,
            Accept: 'application/json',
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({
            p_user_id: userId,
            p_idempotency_key: idempotencyKey,
            p_auth_deleted: authDeleted,
            p_failure_code: failureCode
          })
        });
      } catch (error) {
        throw new AccountDeletionError('account_deletion_finalize_network_error', 'Finalize step failed', 503, { cause: error });
      }
      if (!response.ok) {
        throw new AccountDeletionError('account_deletion_finalize_failed', `Finalize RPC failed (${response.status})`, 502);
      }
      try { return await response.json(); } catch (error) {
        throw new AccountDeletionError('account_deletion_finalize_invalid_response', 'Finalize RPC returned invalid JSON', 502, { cause: error });
      }
    }
  };
}

module.exports = { createSupabaseAccountDeletionRepository, createSupabaseAccountDeletionAdmin };

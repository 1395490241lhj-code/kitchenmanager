const { SUPABASE_ANON_KEY, SUPABASE_URL } = require('../config');
const { SyncRepositoryError } = require('./errors');
const { toDatabaseData } = require('./entities');

function createSupabaseSyncRepository({
  supabaseUrl = SUPABASE_URL,
  anonKey = SUPABASE_ANON_KEY,
  fetchImpl = globalThis.fetch
} = {}) {
  async function rpc(functionName, parameters, accessToken) {
    if (!supabaseUrl || !anonKey || typeof fetchImpl !== 'function') {
      throw new SyncRepositoryError('sync_not_configured', 'Supabase sync repository is not configured');
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
      throw new SyncRepositoryError('sync_network_error', 'Supabase sync request failed', { cause: error });
    }
    if (!response.ok) {
      throw new SyncRepositoryError('sync_rpc_failed', `Supabase sync RPC failed (${response.status})`);
    }
    let payload;
    try { payload = await response.json(); } catch (error) {
      throw new SyncRepositoryError('sync_invalid_response', 'Supabase sync RPC returned invalid JSON', { cause: error });
    }
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
      throw new SyncRepositoryError('sync_invalid_response', 'Supabase sync RPC returned an invalid shape');
    }
    return payload;
  }

  return {
    async bootstrap({ accessToken }) {
      return rpc('get_sync_bootstrap', {}, accessToken);
    },

    async pullChanges({ accessToken, scopeType, scopeId, cursor, limit, entityTypes }) {
      return rpc('pull_sync_changes', {
        p_scope_type: scopeType,
        p_scope_id: scopeId,
        p_cursor: cursor,
        p_limit: limit,
        p_entity_types: entityTypes.length ? entityTypes : null
      }, accessToken);
    },

    async applyMutation({ accessToken, scopeType, scopeId, mutation }) {
      return rpc('apply_sync_mutation', {
        p_scope_type: scopeType,
        p_scope_id: scopeId,
        p_mutation_id: mutation.mutationId,
        p_entity_type: mutation.entityType,
        p_entity_id: mutation.entityId,
        p_operation: mutation.operation,
        p_base_version: mutation.baseVersion,
        p_client_updated_at: mutation.clientUpdatedAt,
        p_data: toDatabaseData(mutation.entityType, mutation.data)
      }, accessToken);
    }
  };
}

module.exports = { createSupabaseSyncRepository };

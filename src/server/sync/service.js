const { SyncError, toSyncError } = require('./errors');
const { fromDatabaseRecord } = require('./entities');
const { serializeCursor } = require('./cursor');
const { MAX_BATCH_SIZE } = require('./validation');
const { createSupabaseSyncRepository } = require('./repository');

function requireAuth(auth) {
  if (!auth?.userId || !auth?.accessToken) throw new SyncError('auth_required', '需要登录后才能同步。', 401);
}

function verifyBootstrapIdentity(auth, bootstrap) {
  if (!bootstrap?.user
    || bootstrap.user.id !== auth.userId
    || !Array.isArray(bootstrap.households)
    || !Array.isArray(bootstrap.syncScopes)) {
    throw new SyncError('sync_identity_mismatch', '同步账户信息不一致。', 503);
  }
  const expectedScopes = new Set([
    `user:${auth.userId}`,
    ...bootstrap.households.map(item => `household:${item.id}`)
  ]);
  const actualScopes = new Set(bootstrap.syncScopes.map(item => `${item?.type}:${item?.id}`));
  if (expectedScopes.size !== actualScopes.size
    || [...expectedScopes].some(scope => !actualScopes.has(scope))) {
    throw new SyncError('sync_scope_mismatch', '同步范围信息不一致。', 503);
  }
}

function requireScopeAccess(bootstrap, auth, scopeType, scopeId) {
  if (scopeType === 'user') {
    if (scopeId !== auth.userId) throw new SyncError('scope_forbidden', '不能访问其他用户的同步范围。', 403);
    return { type: 'user', id: scopeId };
  }
  const membership = bootstrap.households.find(item => item?.id === scopeId);
  if (!membership) throw new SyncError('household_forbidden', '当前账户不是该厨房的成员。', 403);
  return { type: 'household', id: scopeId, role: membership.role };
}

function maxCursor(values, fallback = '0') {
  let maximum = BigInt(serializeCursor(fallback));
  for (const value of values) {
    if (value === null || value === undefined) continue;
    const parsed = BigInt(serializeCursor(value));
    if (parsed > maximum) maximum = parsed;
  }
  return maximum.toString();
}

function normalizeMutationResult(mutation, result) {
  const normalized = {
    mutationId: result.mutationId || mutation.mutationId,
    entityId: result.entityId || mutation.entityId,
    status: result.status,
    version: result.version === null || result.version === undefined ? null : String(result.version),
    sequence: result.sequence === null || result.sequence === undefined ? null : String(result.sequence)
  };
  if (result.errorCode) normalized.errorCode = result.errorCode;
  if (result.originalStatus) normalized.originalStatus = result.originalStatus;
  if (result.serverRecord) normalized.serverRecord = fromDatabaseRecord(mutation.entityType, result.serverRecord);
  return normalized;
}

function createSyncService({ repository = createSupabaseSyncRepository(), maxBatchSize = MAX_BATCH_SIZE } = {}) {
  async function loadBootstrap(auth) {
    requireAuth(auth);
    const bootstrap = await repository.bootstrap({ accessToken: auth.accessToken });
    verifyBootstrapIdentity(auth, bootstrap);
    return bootstrap;
  }

  return {
    async bootstrap({ auth }) {
      try {
        const value = await loadBootstrap(auth);
        return {
          schemaVersion: 1,
          user: { id: value.user.id, email: value.user.email || auth.email || null },
          households: value.households.map(item => ({ id: item.id, role: item.role })),
          defaultHouseholdId: value.defaultHouseholdId || value.households[0]?.id || null,
          syncScopes: value.syncScopes.map(scope => ({
            type: scope.type,
            id: scope.id,
            cursor: String(scope.cursor || '0')
          })),
          serverTime: value.serverTime,
          capabilities: { push: true, pull: true, maxBatchSize }
        };
      } catch (error) { throw toSyncError(error); }
    },

    async pullChanges({ auth, input }) {
      try {
        const bootstrap = await loadBootstrap(auth);
        requireScopeAccess(bootstrap, auth, input.scopeType, input.scopeId);
        const page = await repository.pullChanges({ accessToken: auth.accessToken, ...input });
        const changes = Array.isArray(page.changes) ? page.changes.map(change => ({
          sequence: String(change.sequence),
          entityType: change.entityType,
          entityId: change.entityId,
          operation: change.operation,
          version: String(change.version),
          changedAt: change.changedAt,
          data: fromDatabaseRecord(change.entityType, change.data)
        })) : [];
        return {
          scopeType: input.scopeType,
          scopeId: input.scopeId,
          cursor: String(page.cursor || input.cursor),
          hasMore: !!page.hasMore,
          changes
        };
      } catch (error) { throw toSyncError(error); }
    },

    async applyMutations({ auth, input }) {
      try {
        const bootstrap = await loadBootstrap(auth);
        requireScopeAccess(bootstrap, auth, input.scopeType, input.scopeId);
        if (input.mutations.length > maxBatchSize) throw new SyncError('batch_too_large', '同步批次过大。', 413);
        const results = [];
        for (const mutation of input.mutations) {
          // Each RPC call is its own atomic transaction. If the network fails
          // after an earlier item commits, retrying the same mutation IDs is safe.
          const result = await repository.applyMutation({
            accessToken: auth.accessToken,
            scopeType: input.scopeType,
            scopeId: input.scopeId,
            mutation
          });
          results.push(normalizeMutationResult(mutation, result));
        }
        return {
          results,
          cursor: maxCursor(results.map(item => item.sequence), '0')
        };
      } catch (error) { throw toSyncError(error); }
    }
  };
}

module.exports = { createSyncService, maxCursor, normalizeMutationResult, requireScopeAccess };

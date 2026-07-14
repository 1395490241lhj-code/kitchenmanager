import assert from 'node:assert/strict';
import test from 'node:test';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { MAX_POSTGRES_BIGINT, parseCursor, parseVersion, serializeCursor } = require('../src/server/sync/cursor');
const { deterministicSyncEntityId, isUuid } = require('../src/server/sync/stable-id');
const { validateChangesQuery, validateEntityData, validateMutation, validateMutationsRequest } = require('../src/server/sync/validation');
const { createSyncService } = require('../src/server/sync/service');
const { createSupabaseSyncRepository } = require('../src/server/sync/repository');
const { createSyncHandlers, registerSyncRoutes } = require('../src/server/sync/routes');
const { SyncError } = require('../src/server/sync/errors');

const userA = '11111111-1111-4111-8111-111111111111';
const userB = '22222222-2222-4222-8222-222222222222';
const householdA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const householdB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const mutationId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const entityId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const auth = { userId: userA, email: 'a@example.com', accessToken: 'opaque-test-token' };

function inventoryMutation(overrides = {}) {
  return {
    mutationId,
    entityType: 'inventory_item',
    entityId,
    operation: 'upsert',
    baseVersion: 0,
    clientUpdatedAt: '2026-07-13T12:00:00Z',
    data: { name: '鸡蛋', normalizedName: '鸡蛋', quantity: 6, unit: '个' },
    ...overrides
  };
}

function bootstrapFor(userId = userA) {
  return {
    user: { id: userId, email: 'a@example.com' },
    households: [{ id: householdA, role: 'owner' }],
    defaultHouseholdId: householdA,
    syncScopes: [
      { type: 'household', id: householdA, cursor: '7' },
      { type: 'user', id: userId, cursor: '9' }
    ],
    serverTime: '2026-07-13T12:00:00Z'
  };
}

function createResponse() {
  return {
    statusCode: 200, body: null,
    status(code) { this.statusCode = code; return this; },
    json(value) { this.body = value; return this; }
  };
}

test('cursor keeps full PostgreSQL BIGINT precision as a decimal string', () => {
  assert.equal(parseCursor('9007199254740993'), 9007199254740993n);
  assert.equal(serializeCursor(MAX_POSTGRES_BIGINT), '9223372036854775807');
  assert.equal(parseVersion(4), 4n);
  assert.equal(parseVersion('9007199254740993'), 9007199254740993n);
});

test('cursor rejects negative, float, scientific, padded, and out-of-range values', () => {
  for (const value of ['-1', '1.5', '1e6', '01', ' 1', '9223372036854775808']) {
    assert.throws(() => parseCursor(value));
  }
});

test('deterministic legacy mapping is stable and returns UUIDv5', () => {
  const input = { scopeType: 'household', scopeId: householdA, entityType: 'shopping_item', legacyKey: 'u-abc-123' };
  const first = deterministicSyncEntityId(input);
  assert.equal(first, deterministicSyncEntityId(input));
  assert.equal(first[14], '5');
  assert.equal(isUuid(first), true);
});

test('deterministic mapping separates entity type and household/user scope', () => {
  const base = { scopeType: 'household', scopeId: householdA, entityType: 'shopping_item', legacyKey: 'same-key' };
  const ids = new Set([
    deterministicSyncEntityId(base),
    deterministicSyncEntityId({ ...base, entityType: 'inventory_item' }),
    deterministicSyncEntityId({ ...base, scopeId: householdB }),
    deterministicSyncEntityId({ ...base, scopeType: 'user', scopeId: userA })
  ]);
  assert.equal(ids.size, 4);
});

test('deterministic mapping rejects invalid context and never needs a device name', () => {
  assert.throws(() => deterministicSyncEntityId({ scopeType: 'device', scopeId: householdA, entityType: 'inventory_item', legacyKey: 'x' }));
  assert.throws(() => deterministicSyncEntityId({ scopeType: 'household', scopeId: 'not-uuid', entityType: 'inventory_item', legacyKey: 'x' }));
});

test('mutation validation requires UUID mutation/entity IDs and allowlisted types/operations', () => {
  for (const mutation of [
    inventoryMutation({ mutationId: undefined }),
    inventoryMutation({ mutationId: 'bad' }),
    inventoryMutation({ entityId: 'bad' }),
    inventoryMutation({ entityType: 'profiles' }),
    inventoryMutation({ operation: 'truncate' })
  ]) assert.throws(() => validateMutation(mutation));
});

test('mutation validation rejects invalid baseVersion and protects server-owned fields', () => {
  for (const baseVersion of [-1, 1.5, '1e3', '9223372036854775808']) {
    assert.throws(() => validateMutation(inventoryMutation({ baseVersion })));
  }
  for (const injected of [{ userId: userB }, { householdId: householdB }, { version: 99 }, { created_by: userB }]) {
    assert.throws(() => validateMutation(inventoryMutation({ data: { ...inventoryMutation().data, ...injected } })));
  }
});

test('request validation rejects body userId, oversized batch, and oversized payload', () => {
  assert.throws(() => validateMutationsRequest({ scopeType: 'household', scopeId: householdA, userId: userB, mutations: [inventoryMutation()] }));
  assert.throws(() => validateMutationsRequest({ scopeType: 'household', scopeId: householdA, mutations: Array.from({ length: 101 }, inventoryMutation) }));
  assert.throws(() => validateMutationsRequest({
    scopeType: 'household', scopeId: householdA,
    mutations: [inventoryMutation({ data: { ...inventoryMutation().data, name: 'x'.repeat(1024 * 1024) } })]
  }));
});

test('request scope must match every entity ownership definition', () => {
  const favorite = inventoryMutation({
    entityType: 'recipe_favorite',
    data: { recipeId: 'sample-mapotofu' }
  });
  assert.equal(validateMutationsRequest({
    scopeType: 'user', scopeId: userA, mutations: [favorite]
  }).scopeType, 'user');
  assert.throws(() => validateMutationsRequest({
    scopeType: 'household', scopeId: householdA, mutations: [favorite]
  }));
  assert.throws(() => validateMutationsRequest({
    scopeType: 'user', scopeId: userA, mutations: [inventoryMutation()]
  }));
});

test('recipe and snapshot validation enforce item count, text, depth, and schema limits', () => {
  assert.throws(() => validateEntityData('user_recipe', {
    title: '过大菜谱', ingredients: Array.from({ length: 101 }, () => '鸡蛋')
  }));
  assert.throws(() => validateEntityData('user_recipe', { title: '长步骤', steps: ['x'.repeat(4001)] }));
  assert.throws(() => validateEntityData('weekly_meal_plan_item', {
    planId: entityId, dayIndex: 0, mealIndex: 0, recipeTitle: '测试',
    recipeSnapshot: { title: '测试', unexpected: 'not allowed' }
  }));
  assert.throws(() => validateEntityData('consumption_record', {
    occurredAt: '2026-07-13T12:00:00Z',
    items: [{ ingredientName: '鸡蛋', consumedQuantity: 1, previousQuantity: 6, resultingQuantity: 5, unit: '个', sql: 'drop' }]
  }));
});

test('delete accepts no business data and preserves BIGINT baseVersion as string', () => {
  const value = validateMutation(inventoryMutation({ operation: 'delete', data: {}, baseVersion: '9007199254740993' }));
  assert.equal(value.baseVersion, '9007199254740993');
  assert.deepEqual(value.data, {});
  assert.throws(() => validateMutation(inventoryMutation({ operation: 'delete', data: { name: '鸡蛋' } })));
});

test('changes query validates scope, allowlist, limit, and malformed cursor', () => {
  assert.deepEqual(validateChangesQuery({ scopeType: 'household', scopeId: householdA, cursor: '9007199254740993', limit: '25', entityTypes: 'inventory_item,user_recipe' }), {
    scopeType: 'household', scopeId: householdA, cursor: '9007199254740993', limit: 25, entityTypes: ['inventory_item', 'user_recipe']
  });
  for (const query of [
    { scopeType: 'household', scopeId: 'bad', cursor: '0' },
    { scopeType: 'device', scopeId: householdA, cursor: '0' },
    { scopeType: 'household', scopeId: householdA, cursor: '1e3' },
    { scopeType: 'household', scopeId: householdA, cursor: '0', limit: 101 },
    { scopeType: 'household', scopeId: householdA, cursor: '0', entityTypes: 'profiles' },
    { scopeType: 'household', scopeId: householdA, cursor: '0', entityTypes: 'recipe_favorite' }
  ]) assert.throws(() => validateChangesQuery(query));
});

test('bootstrap exposes only verified user summary, memberships, independent scope cursors, and capabilities', async () => {
  const service = createSyncService({ repository: { bootstrap: async () => bootstrapFor() } });
  const result = await service.bootstrap({ auth });
  assert.equal(result.user.id, userA);
  assert.deepEqual(result.households, [{ id: householdA, role: 'owner' }]);
  assert.deepEqual(result.syncScopes, [
    { type: 'household', id: householdA, cursor: '7' },
    { type: 'user', id: userA, cursor: '9' }
  ]);
  assert.equal(result.capabilities.maxBatchSize, 100);
  assert.doesNotMatch(JSON.stringify(result), /opaque-test-token|displayName|name/);
});

test('service rejects unauthenticated, identity mismatch, and non-member requests', async () => {
  const service = createSyncService({
    repository: {
      bootstrap: async () => bootstrapFor(),
      pullChanges: async () => assert.fail('must not pull')
    }
  });
  await assert.rejects(() => service.bootstrap({ auth: null }), error => error.status === 401);
  await assert.rejects(() => createSyncService({ repository: { bootstrap: async () => bootstrapFor(userB) } }).bootstrap({ auth }), error => error.status === 503);
  await assert.rejects(() => service.pullChanges({ auth, input: { scopeType: 'household', scopeId: householdB, cursor: '0', limit: 10, entityTypes: [] } }), error => error.status === 403);
  await assert.rejects(() => service.pullChanges({ auth, input: { scopeType: 'user', scopeId: userB, cursor: '0', limit: 10, entityTypes: [] } }), error => error.status === 403);
});

test('owner/member may pull their household and data snapshots are serialized', async () => {
  let received;
  const service = createSyncService({ repository: {
    bootstrap: async () => bootstrapFor(),
    pullChanges: async input => {
      received = input;
      return { cursor: '9007199254740994', hasMore: false, changes: [{
        sequence: '9007199254740994', entityType: 'inventory_item', entityId,
        operation: 'upsert', version: '2', changedAt: '2026-07-13T12:00:00Z',
        data: { id: entityId, household_id: householdA, name: '鸡蛋', normalized_name: '鸡蛋', version: 2 }
      }] };
    }
  } });
  const result = await service.pullChanges({ auth, input: { scopeType: 'household', scopeId: householdA, cursor: '0', limit: 10, entityTypes: [] } });
  assert.equal(received.accessToken, auth.accessToken);
  assert.equal(result.changes[0].data.normalizedName, '鸡蛋');
  assert.equal(result.changes[0].data.version, '2');
  assert.equal(result.changes[0].data.householdId, undefined);
});

test('mixed applied/conflict/duplicate batch returns independent results and max cursor', async () => {
  const statuses = [
    { status: 'applied', version: '1', sequence: '8', serverRecord: { id: entityId, version: 1, name: '鸡蛋', normalized_name: '鸡蛋' } },
    { status: 'conflict', version: '2', errorCode: 'stale_version', serverRecord: { id: entityId, version: 2, name: '鸡蛋', normalized_name: '鸡蛋' } },
    { status: 'duplicate', originalStatus: 'applied', version: '1', sequence: '8' }
  ];
  const service = createSyncService({ repository: {
    bootstrap: async () => bootstrapFor(),
    applyMutation: async () => statuses.shift()
  } });
  const mutations = [inventoryMutation(), inventoryMutation({ mutationId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee' }), inventoryMutation({ mutationId: 'ffffffff-ffff-4fff-8fff-ffffffffffff' })];
  const result = await service.applyMutations({ auth, input: { scopeType: 'household', scopeId: householdA, mutations } });
  assert.deepEqual(result.results.map(item => item.status), ['applied', 'conflict', 'duplicate']);
  assert.equal(result.cursor, '8');
});

test('repository failures become sanitized 503 errors without token or payload logging', async () => {
  const logs = [];
  const handlers = createSyncHandlers({
    service: createSyncService({ repository: { bootstrap: async () => { throw new Error(`db failed ${auth.accessToken}`); } } }),
    logger: { error: message => logs.push(message) }
  });
  const req = { auth, query: {}, body: {} };
  const res = createResponse();
  await handlers.bootstrap(req, res);
  assert.equal(res.statusCode, 503);
  assert.equal(res.body.error.code, 'sync_unavailable');
  assert.doesNotMatch(JSON.stringify({ logs, body: res.body }), /opaque-test-token/);
});

test('Supabase repository forwards public key + user JWT only to fixed RPC paths', async () => {
  const calls = [];
  const repository = createSupabaseSyncRepository({
    supabaseUrl: 'https://phase2a-test.supabase.co', anonKey: 'public-test-key',
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      return { ok: true, async json() { return { mutationId, entityId, status: 'applied', version: '1', sequence: '9' }; } };
    }
  });
  const mutation = validateMutation(inventoryMutation());
  await repository.applyMutation({ accessToken: auth.accessToken, scopeType: 'household', scopeId: householdA, mutation });
  assert.equal(calls[0].url, 'https://phase2a-test.supabase.co/rest/v1/rpc/apply_sync_mutation');
  assert.equal(calls[0].options.headers.apikey, 'public-test-key');
  assert.equal(calls[0].options.headers.Authorization, `Bearer ${auth.accessToken}`);
  const body = JSON.parse(calls[0].options.body);
  assert.equal(body.p_scope_type, 'household');
  assert.equal(body.p_scope_id, householdA);
  assert.equal(body.p_data.normalized_name, '鸡蛋');
  assert.equal(body.p_data.household_id, undefined);
  assert.equal(body.p_data.user_id, undefined);
});

test('route handlers map validation/auth/service failures to 400/401/403/503', async () => {
  const handlers = createSyncHandlers({ service: {
    bootstrap: async ({ auth: current }) => { if (!current) throw new SyncError('auth_required', '需要登录。', 401); return {}; },
    pullChanges: async () => { throw new SyncError('household_forbidden', '禁止访问。', 403); },
    applyMutations: async () => { throw new SyncError('sync_unavailable', '暂时不可用。', 503); }
  }, logger: { error() {} } });

  const malformed = createResponse();
  await handlers.changes({ auth, query: { scopeType: 'household', scopeId: 'bad' } }, malformed);
  assert.equal(malformed.statusCode, 400);

  const unauthorized = createResponse();
  await handlers.bootstrap({ auth: null }, unauthorized);
  assert.equal(unauthorized.statusCode, 401);

  const forbidden = createResponse();
  await handlers.changes({ auth, query: { scopeType: 'household', scopeId: householdA, cursor: '0' } }, forbidden);
  assert.equal(forbidden.statusCode, 403);

  const unavailable = createResponse();
  await handlers.mutations({ auth, body: { scopeType: 'household', scopeId: householdA, mutations: [inventoryMutation()] } }, unavailable);
  assert.equal(unavailable.statusCode, 503);
});

test('route handlers return 200 bootstrap/changes/mutations and ignore fake userId', async () => {
  const seen = [];
  const handlers = createSyncHandlers({ service: {
    bootstrap: async input => { seen.push(input); return { schemaVersion: 1 }; },
    pullChanges: async input => { seen.push(input); return { cursor: '0', hasMore: false, changes: [] }; },
    applyMutations: async input => { seen.push(input); return { cursor: '1', results: [] }; }
  } });
  for (const [handler, req] of [
    [handlers.bootstrap, { auth }],
    [handlers.changes, { auth, query: { scopeType: 'household', scopeId: householdA, cursor: '0' } }],
    [handlers.mutations, { auth, body: { scopeType: 'household', scopeId: householdA, mutations: [inventoryMutation()], userId: userB } }]
  ]) {
    const res = createResponse();
    await handler(req, res);
    if (handler === handlers.mutations) assert.equal(res.statusCode, 400);
    else assert.equal(res.statusCode, 200);
  }
  assert.equal(seen.every(item => item.auth.userId === userA), true);
});

test('route registration protects all sync endpoints without wrapping public APIs', async () => {
  const routes = [];
  const app = {
    get(path, handler) { routes.push({ method: 'GET', path, handler }); },
    post(path, handler) { routes.push({ method: 'POST', path, handler }); }
  };
  const events = [];
  const authenticate = async (req, _res, next) => {
    events.push('authenticate');
    if (!req.auth) throw new SyncError('auth_required', '需要登录。', 401);
    await next();
  };
  const requireRole = async (_req, _res, next) => {
    events.push('role');
    await next();
  };
  registerSyncRoutes(app, {
    authenticate,
    requireRole,
    service: {
      bootstrap: async () => { events.push('bootstrap'); return { schemaVersion: 1 }; },
      pullChanges: async () => ({ cursor: '0', hasMore: false, changes: [] }),
      applyMutations: async () => ({ cursor: '0', results: [] })
    }
  });

  assert.deepEqual(routes.map(({ method, path }) => `${method} ${path}`), [
    'GET /api/sync/bootstrap',
    'GET /api/sync/changes',
    'POST /api/sync/mutations'
  ]);
  const response = createResponse();
  await routes[0].handler({ auth, query: {}, body: {} }, response);
  assert.equal(response.statusCode, 200);
  assert.deepEqual(events, ['authenticate', 'role', 'bootstrap']);
});

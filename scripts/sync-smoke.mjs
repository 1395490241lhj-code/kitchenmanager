import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { ensureDevelopmentTarget, validateHttpUrl } from './verify-supabase-phase0.mjs';

const SECRET_NAMES = [
  'SUPABASE_ANON_KEY', 'SUPABASE_DB_PASSWORD', 'SUPABASE_SERVICE_ROLE_KEY',
  'TEST_USER_A_EMAIL', 'TEST_USER_A_PASSWORD', 'TEST_USER_B_EMAIL', 'TEST_USER_B_PASSWORD'
];

function required(env, name) {
  const value = String(env[name] || '').trim();
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function redact(message, env) {
  let result = String(message || 'unexpected failure')
    .replace(/Bearer\s+\S+/gi, 'Bearer [redacted]')
    .replace(/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+/g, '[redacted-jwt]');
  for (const name of SECRET_NAMES) {
    const value = String(env[name] || '');
    if (value.length >= 4) result = result.split(value).join('[redacted]');
  }
  return result;
}

async function readJson(response) {
  const text = await response.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch { /* shape assertions handle invalid JSON */ }
  return { response, body, text };
}

async function signIn(config, email, password) {
  const result = await readJson(await fetch(`${config.supabaseUrl}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: config.anonKey, Accept: 'application/json', 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password })
  }));
  assert.equal(result.response.status, 200, `development sign-in failed (${result.response.status})`);
  assert.ok(result.body?.access_token && result.body?.user?.id, 'development sign-in response is incomplete');
  return { token: result.body.access_token, userId: result.body.user.id };
}

async function supabaseRequest(config, session, pathValue, options = {}) {
  return readJson(await fetch(`${config.supabaseUrl}/rest/v1/${pathValue}`, {
    ...options,
    headers: {
      apikey: config.anonKey,
      Authorization: `Bearer ${session.token}`,
      Accept: 'application/json',
      'Content-Type': 'application/json',
      ...(options.headers || {})
    }
  }));
}

async function rpc(config, session, name, parameters) {
  return supabaseRequest(config, session, `rpc/${name}`, {
    method: 'POST', body: JSON.stringify(parameters)
  });
}

async function expressRequest(config, session, route, options = {}) {
  const headers = { Accept: 'application/json', ...(options.headers || {}) };
  if (session?.token) headers.Authorization = `Bearer ${session.token}`;
  if (options.body) headers['Content-Type'] = 'application/json';
  return readJson(await fetch(`${config.expressBase}${route}`, { ...options, headers }));
}

function mutation(entityType, entityId, operation, baseVersion, data = undefined, mutationId = randomUUID()) {
  const value = {
    mutationId, entityType, entityId, operation, baseVersion: String(baseVersion),
    clientUpdatedAt: new Date().toISOString()
  };
  if (operation === 'upsert') value.data = data;
  return value;
}

function rpcMutation(scopeType, scopeId, value) {
  return {
    p_scope_type: scopeType, p_scope_id: scopeId, p_mutation_id: value.mutationId,
    p_entity_type: value.entityType, p_entity_id: value.entityId,
    p_operation: value.operation, p_base_version: value.baseVersion,
    p_client_updated_at: value.clientUpdatedAt, p_data: value.data || {}
  };
}

function householdScope(bootstrap) {
  const scope = bootstrap.syncScopes?.find(item => item.type === 'household');
  assert.ok(scope?.id && /^\d+$/.test(scope.cursor), 'bootstrap is missing a household scope/cursor');
  return scope;
}

function personalScope(bootstrap, userId) {
  const scope = bootstrap.syncScopes?.find(item => item.type === 'user');
  assert.equal(scope?.id, userId, 'bootstrap personal scope does not match JWT subject');
  assert.match(scope.cursor, /^\d+$/);
  return scope;
}

async function bootstrap(config, session) {
  const result = await rpc(config, session, 'get_sync_bootstrap', {});
  assert.equal(result.response.status, 200, `bootstrap failed (${result.response.status})`);
  assert.equal(result.body?.user?.id, session.userId);
  assert.ok(Array.isArray(result.body?.households) && result.body.households.length >= 1);
  return result.body;
}

async function apply(config, session, scope, value, expectedStatus = 'applied') {
  const result = await rpc(config, session, 'apply_sync_mutation', rpcMutation(scope.type, scope.id, value));
  assert.equal(result.response.status, 200, `mutation RPC failed (${result.response.status})`);
  assert.equal(result.body?.status, expectedStatus, `unexpected mutation status for ${value.entityType}`);
  return result.body;
}

async function pull(config, session, scope, cursor, limit = 100, entityTypes = null) {
  const result = await rpc(config, session, 'pull_sync_changes', {
    p_scope_type: scope.type, p_scope_id: scope.id, p_cursor: String(cursor),
    p_limit: limit, p_entity_types: entityTypes
  });
  assert.equal(result.response.status, 200, `pull RPC failed (${result.response.status})`);
  assert.equal(result.body?.scopeType, scope.type);
  assert.equal(result.body?.scopeId, scope.id);
  assert.ok(Array.isArray(result.body?.changes));
  return result.body;
}

async function assertDirectDmlDenied(config, session, householdId) {
  const result = await supabaseRequest(config, session, 'inventory_items', {
    method: 'POST',
    headers: { Prefer: 'return=representation' },
    body: JSON.stringify({
      id: randomUUID(), household_id: householdId, name: 'must fail',
      normalized_name: 'must fail', unit: ''
    })
  });
  assert.ok([401, 403].includes(result.response.status), `direct DML unexpectedly returned ${result.response.status}`);
}

async function assertInventoryProtocol(config, a, scope, startCursor, cleanup) {
  const entityId = randomUUID();
  const mutationId = randomUUID();
  const baseData = { name: 'Phase 2A smoke egg', normalized_name: 'phase 2a smoke egg', quantity: 2, unit: '个' };
  const createMutation = rpcShape('inventory_item', entityId, 'upsert', 0, baseData, mutationId);
  const created = await apply(config, a, scope, createMutation);
  assert.equal(created.version, 1);
  cleanup.set(entityId, { entityType: 'inventory_item', version: 1, scope });

  const duplicate = await apply(config, a, scope, createMutation, 'duplicate');
  assert.equal(duplicate.originalStatus, 'applied');
  assert.equal(duplicate.sequence, created.sequence);

  const mismatch = await apply(
    config, a, scope,
    { ...createMutation, data: { ...baseData, quantity: 99 } },
    'rejected'
  );
  assert.equal(mismatch.errorCode, 'idempotency_mismatch');
  const ledger = await supabaseRequest(
    config, a,
    `sync_mutations?select=mutation_id,status,result_sequence&mutation_id=eq.${encodeURIComponent(mutationId)}`
  );
  assert.equal(ledger.response.status, 200);
  assert.equal(ledger.body?.length, 1, 'idempotent retry created more than one ledger row');

  const updated = await apply(config, a, scope, rpcShape(
    'inventory_item', entityId, 'upsert', 1, { ...baseData, quantity: 3 }
  ));
  assert.equal(updated.version, 2);
  cleanup.get(entityId).version = 2;

  const conflict = await apply(config, a, scope, rpcShape(
    'inventory_item', entityId, 'upsert', 1, { ...baseData, quantity: 4 }
  ), 'conflict');
  assert.equal(conflict.errorCode, 'stale_version');
  assert.equal(conflict.version, 2);

  const deleteMutation = rpcShape('inventory_item', entityId, 'delete', 2);
  const removed = await apply(config, a, scope, deleteMutation);
  assert.equal(removed.version, 3);
  assert.deepEqual(Object.keys(removed.serverRecord).sort(), ['deleted_at', 'id', 'version']);
  const duplicateDelete = await apply(config, a, scope, deleteMutation, 'duplicate');
  assert.equal(duplicateDelete.version, 3);
  assert.equal(duplicateDelete.sequence, removed.sequence);
  cleanup.delete(entityId);

  const feed = await pull(config, a, scope, startCursor, 100, ['inventory_item']);
  const entityChanges = feed.changes.filter(item => item.entityId === entityId);
  assert.deepEqual(entityChanges.map(item => item.operation), ['upsert', 'upsert', 'delete']);
  assert.deepEqual(entityChanges.map(item => item.version), ['1', '2', '3']);
  assert.ok(entityChanges.every((item, index, array) => index === 0 || BigInt(item.sequence) > BigInt(array[index - 1].sequence)));
  assert.deepEqual(Object.keys(entityChanges[2].data).sort(), ['deleted_at', 'id', 'version']);

  const firstPage = await pull(config, a, scope, startCursor, 1, ['inventory_item']);
  assert.equal(firstPage.changes.length, 1);
  assert.equal(firstPage.hasMore, true);
  const repeatedPage = await pull(config, a, scope, startCursor, 1, ['inventory_item']);
  assert.deepEqual(repeatedPage, firstPage, 'same cursor must return the same page');
  const secondPage = await pull(config, a, scope, firstPage.cursor, 1, ['inventory_item']);
  assert.equal(secondPage.changes.length, 1);
  assert.ok(BigInt(secondPage.cursor) > BigInt(firstPage.cursor));
  assert.notEqual(secondPage.changes[0].sequence, firstPage.changes[0].sequence);
  const emptyPage = await pull(config, a, scope, feed.cursor, 100, ['inventory_item']);
  assert.deepEqual(emptyPage.changes, []);
  assert.equal(emptyPage.cursor, feed.cursor, 'empty pull must preserve its input cursor');
  return { entityId, finalCursor: feed.cursor };
}

// Direct RPC payloads use database field names; Express payloads use client names.
function rpcShape(entityType, entityId, operation, baseVersion, data, mutationId) {
  return {
    mutationId: mutationId || randomUUID(), entityType, entityId, operation,
    baseVersion: String(baseVersion), clientUpdatedAt: new Date().toISOString(), data
  };
}

async function assertRepresentativeEntities(config, session, household, personal, cleanup) {
  const before = await bootstrap(config, session);
  const householdCursor = householdScope(before).cursor;
  const personalCursor = personalScope(before, session.userId).cursor;
  const now = new Date().toISOString();
  const today = now.slice(0, 10);
  const weeklyId = randomUUID();
  const preferenceRecipeId = `phase2a-smoke-${randomUUID()}`;
  const entries = [
    [household, 'shopping_item', randomUUID(), { name: 'smoke milk', normalized_name: 'smoke milk', quantity: 1, unit: '盒' }],
    [household, 'today_plan', randomUUID(), { recipe_name: 'smoke meal', planned_date: today }],
    [household, 'consumption_record', randomUUID(), { occurred_at: now, recipe_name: 'smoke meal', plan_ids: [], items: [] }],
    [household, 'weekly_meal_plan', weeklyId, { week_start: today, servings: 2 }],
    [household, 'weekly_meal_plan_item', randomUUID(), { plan_id: weeklyId, day_index: 0, meal_index: 0, recipe_title: 'smoke meal' }],
    [household, 'user_recipe', randomUUID(), { title: 'smoke recipe', ingredients: [], seasonings: [], steps: [] }],
    [personal, 'recipe_favorite', randomUUID(), { recipe_id: preferenceRecipeId }],
    [personal, 'frequent_recipe', randomUUID(), { recipe_id: preferenceRecipeId }]
  ];
  for (const [scope, entityType, entityId, data] of entries) {
    const result = await apply(config, session, scope, rpcShape(entityType, entityId, 'upsert', 0, data));
    cleanup.set(entityId, { entityType, version: Number(result.version), scope });
  }
  const householdFeed = await pull(config, session, household, householdCursor, 100, null);
  const personalFeed = await pull(config, session, personal, personalCursor, 100, null);
  const personalIds = new Set(entries.filter(([scope]) => scope.type === 'user').map(([, , id]) => id));
  assert.ok(!householdFeed.changes.some(item => personalIds.has(item.entityId)), 'household cursor leaked personal changes');
  assert.ok(personalFeed.changes.filter(item => personalIds.has(item.entityId)).length >= 2);
  const createdIds = new Set(entries.filter(([scope]) => scope.type === 'household').map(([, , id]) => id));
  const createdChanges = householdFeed.changes.filter(item => createdIds.has(item.entityId));
  assert.equal(createdChanges.length, 6);
  assert.ok(createdChanges.every((item, index) => index === 0
    || BigInt(item.sequence) > BigInt(createdChanges[index - 1].sequence)), 'cross-entity sequence is not strictly increasing');
  return entries.length;
}

async function assertIsolation(config, a, b, scopeA, scopeB) {
  const forbiddenPull = await rpc(config, a, 'pull_sync_changes', {
    p_scope_type: 'household', p_scope_id: scopeB.id, p_cursor: '0', p_limit: 10, p_entity_types: null
  });
  assert.ok([401, 403].includes(forbiddenPull.response.status));
  const forbiddenWrite = await rpc(config, a, 'apply_sync_mutation', rpcMutation(
    'household', scopeB.id,
    rpcShape('inventory_item', randomUUID(), 'upsert', 0, { name: 'forbidden', normalized_name: 'forbidden' })
  ));
  assert.ok([401, 403].includes(forbiddenWrite.response.status));
  const reversePull = await rpc(config, b, 'pull_sync_changes', {
    p_scope_type: 'household', p_scope_id: scopeA.id, p_cursor: '0', p_limit: 10, p_entity_types: null
  });
  assert.ok([401, 403].includes(reversePull.response.status));
}

async function assertExpressContract(config, a, b, scope, forbiddenScope) {
  const missing = await expressRequest(config, null, '/api/sync/bootstrap');
  assert.equal(missing.response.status, 401);
  const bootstrapResult = await expressRequest(config, a, '/api/sync/bootstrap');
  assert.equal(bootstrapResult.response.status, 200);
  const expressCursor = householdScope(bootstrapResult.body).cursor;
  const bootstrapB = await expressRequest(config, b, '/api/sync/bootstrap');
  assert.equal(bootstrapB.response.status, 200);
  const forbidden = await expressRequest(
    config, a,
    `/api/sync/changes?scopeType=household&scopeId=${forbiddenScope.id}&cursor=0&limit=10`
  );
  assert.equal(forbidden.response.status, 403);
  const entityId = randomUUID();
  const created = await expressRequest(config, a, '/api/sync/mutations', {
    method: 'POST',
    body: JSON.stringify({
      scopeType: scope.type, scopeId: scope.id,
      mutations: [mutation('inventory_item', entityId, 'upsert', 0, {
        name: 'Express smoke item', normalizedName: 'express smoke item', quantity: 1, unit: '个'
      })]
    })
  });
  assert.equal(created.response.status, 200);
  assert.equal(created.body?.results?.[0]?.status, 'applied');
  const version = created.body.results[0].version;
  const pulled = await expressRequest(
    config, a,
    `/api/sync/changes?scopeType=household&scopeId=${scope.id}&cursor=${expressCursor}&limit=100&entityTypes=inventory_item`
  );
  assert.equal(pulled.response.status, 200);
  assert.ok(pulled.body?.changes?.some(item => item.entityId === entityId));
  const removed = await expressRequest(config, a, '/api/sync/mutations', {
    method: 'POST',
    body: JSON.stringify({
      scopeType: scope.type, scopeId: scope.id,
      mutations: [mutation('inventory_item', entityId, 'delete', version)]
    })
  });
  assert.equal(removed.response.status, 200);
  assert.equal(removed.body?.results?.[0]?.status, 'applied');
  const forged = await expressRequest(config, a, '/api/sync/mutations', {
    method: 'POST', body: JSON.stringify({ scopeType: scope.type, scopeId: scope.id, userId: randomUUID(), mutations: [] })
  });
  assert.equal(forged.response.status, 400);
  const forgedScopeData = await expressRequest(config, a, '/api/sync/mutations', {
    method: 'POST',
    body: JSON.stringify({
      scopeType: scope.type, scopeId: scope.id,
      mutations: [mutation('inventory_item', randomUUID(), 'upsert', 0, {
        name: 'x', normalizedName: 'x', householdId: forbiddenScope.id
      })]
    })
  });
  assert.equal(forgedScopeData.response.status, 400);
  const oversized = Array.from({ length: 101 }, () => mutation(
    'inventory_item', randomUUID(), 'upsert', 0, { name: 'x', normalizedName: 'x' }
  ));
  const tooMany = await expressRequest(config, a, '/api/sync/mutations', {
    method: 'POST', body: JSON.stringify({ scopeType: scope.type, scopeId: scope.id, mutations: oversized })
  });
  assert.equal(tooMany.response.status, 413);
}

async function cleanupRecords(config, session, records) {
  const ordered = [...records.entries()].sort(([, a], [, b]) =>
    Number(a.entityType === 'weekly_meal_plan') - Number(b.entityType === 'weekly_meal_plan')
  );
  for (const [entityId, record] of ordered) {
    const result = await rpc(config, session, 'apply_sync_mutation', rpcMutation(
      record.scope.type, record.scope.id,
      rpcShape(record.entityType, entityId, 'delete', record.version)
    ));
    assert.equal(result.response.status, 200, `cleanup RPC failed for ${record.entityType}`);
    assert.equal(result.body?.status, 'applied', `cleanup mutation failed for ${record.entityType}`);
  }
  records.clear();
}

export async function runSyncSmoke({ env = process.env, logger = console } = {}) {
  const config = {
    supabaseUrl: validateHttpUrl(required(env, 'SUPABASE_URL'), 'SUPABASE_URL'),
    anonKey: required(env, 'SUPABASE_ANON_KEY'),
    expressBase: validateHttpUrl(env.EXPRESS_API_BASE || 'http://127.0.0.1:3000', 'EXPRESS_API_BASE'),
    userAEmail: required(env, 'TEST_USER_A_EMAIL'), userAPassword: required(env, 'TEST_USER_A_PASSWORD'),
    userBEmail: required(env, 'TEST_USER_B_EMAIL'), userBPassword: required(env, 'TEST_USER_B_PASSWORD')
  };
  ensureDevelopmentTarget(env, config.supabaseUrl);
  const a = await signIn(config, config.userAEmail, config.userAPassword);
  const b = await signIn(config, config.userBEmail, config.userBPassword);
  assert.notEqual(a.userId, b.userId, 'smoke users must be distinct');
  const cleanup = new Map();
  try {
    const bootstrapA = await bootstrap(config, a);
    const bootstrapB = await bootstrap(config, b);
    const householdA = householdScope(bootstrapA);
    const householdB = householdScope(bootstrapB);
    const personalA = personalScope(bootstrapA, a.userId);
    assert.notEqual(householdA.id, householdB.id, 'smoke users unexpectedly share a household');
    await assertDirectDmlDenied(config, a, householdA.id);
    await assertIsolation(config, a, b, householdA, householdB);
    await assertInventoryProtocol(config, a, householdA, householdA.cursor, cleanup);
    const entityCount = await assertRepresentativeEntities(config, a, householdA, personalA, cleanup);
    await assertExpressContract(config, a, b, householdA, householdB);
    await cleanupRecords(config, a, cleanup);
    logger.log('[sync-smoke] auth, direct-DML denial and A/B isolation: PASS');
    logger.log('[sync-smoke] create/update/conflict/delete/idempotency/feed/pagination: PASS');
    logger.log(`[sync-smoke] representative entity families: PASS (${entityCount})`);
    logger.log('[sync-smoke] real Express sync contract: PASS');
    return { entityCount };
  } finally {
    if (cleanup.size) await cleanupRecords(config, a, cleanup);
    a.token = '';
    b.token = '';
  }
}

async function main() {
  try { await runSyncSmoke(); }
  catch (error) {
    console.error(`[sync-smoke] failed: ${redact(error?.message, process.env)}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) await main();

export { redact };

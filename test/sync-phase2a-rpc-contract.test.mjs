import assert from 'node:assert/strict';
import test from 'node:test';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { createSyncService } = require('../src/server/sync/service');
const { validateChangesQuery, validateMutationsRequest } = require('../src/server/sync/validation');

const userA = '11111111-1111-4111-8111-111111111111';
const userB = '22222222-2222-4222-8222-222222222222';
const householdA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const householdB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const inventoryId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const shoppingId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';

const authA = { userId: userA, email: 'a@example.com', accessToken: 'token-a' };
const authB = { userId: userB, email: 'b@example.com', accessToken: 'token-b' };

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function createAtomicContractRepository() {
  const accounts = new Map([
    ['token-a', { user: { id: userA, email: 'a@example.com' }, households: [{ id: householdA, role: 'owner' }] }],
    ['token-b', { user: { id: userB, email: 'b@example.com' }, households: [{ id: householdB, role: 'owner' }] }]
  ]);
  const records = new Map();
  const ledger = new Map();
  const changes = [];
  let sequence = 0n;

  function account(accessToken) {
    const value = accounts.get(accessToken);
    if (!value) throw new Error('unknown test token');
    return value;
  }

  return {
    records,
    ledger,
    changes,
    async bootstrap({ accessToken }) {
      const value = account(accessToken);
      const syncScopes = [
        ...value.households.map(item => ({
          type: 'household', id: item.id,
          cursor: changes.filter(change => change.householdId === item.id)
            .reduce((maximum, change) => BigInt(change.sequence) > maximum ? BigInt(change.sequence) : maximum, 0n).toString()
        })),
        {
          type: 'user', id: value.user.id,
          cursor: changes.filter(change => change.userId === value.user.id)
            .reduce((maximum, change) => BigInt(change.sequence) > maximum ? BigInt(change.sequence) : maximum, 0n).toString()
        }
      ];
      return { ...value, defaultHouseholdId: value.households[0]?.id || null, syncScopes, serverTime: '2026-07-13T12:00:00Z' };
    },
    async applyMutation({ accessToken, scopeType, scopeId, mutation }) {
      const value = account(accessToken);
      if (scopeType === 'household' && !value.households.some(item => item.id === scopeId)) throw new Error('forbidden test household');
      if (scopeType === 'user' && value.user.id !== scopeId) throw new Error('forbidden test user');
      const ledgerKey = `${value.user.id}:${mutation.mutationId}`;
      const requestHash = stableJson({ scopeType, scopeId, ...mutation });
      const prior = ledger.get(ledgerKey);
      if (prior) {
        if (prior.requestHash !== requestHash) {
          return { mutationId: mutation.mutationId, entityId: mutation.entityId, status: 'rejected', errorCode: 'idempotency_mismatch' };
        }
        return {
          mutationId: prior.result.mutationId,
          entityId: prior.result.entityId,
          status: 'duplicate',
          originalStatus: prior.result.status,
          version: prior.result.version,
          sequence: prior.result.sequence,
          errorCode: prior.result.errorCode
        };
      }

      const recordKey = `${mutation.entityType}:${mutation.entityId}`;
      const current = records.get(recordKey);
      let result;
      if (!current && mutation.operation === 'delete') {
        result = { mutationId: mutation.mutationId, entityId: mutation.entityId, status: 'rejected', errorCode: 'not_found' };
      } else if (!current && BigInt(mutation.baseVersion || '0') !== 0n) {
        result = { mutationId: mutation.mutationId, entityId: mutation.entityId, status: 'rejected', errorCode: 'invalid_create_version' };
      } else if (current && (mutation.baseVersion === null || BigInt(mutation.baseVersion) !== BigInt(current.version))) {
        result = { mutationId: mutation.mutationId, entityId: mutation.entityId, status: 'conflict', version: current.version, errorCode: 'stale_version', serverRecord: current.data };
      } else {
        const version = current ? (BigInt(current.version) + 1n).toString() : '1';
        const operation = mutation.operation === 'delete' ? 'delete' : 'upsert';
        const data = operation === 'delete'
          ? { id: mutation.entityId, deleted_at: '2026-07-13T12:00:00Z', version }
          : { id: mutation.entityId, ...mutation.data, version };
        records.set(recordKey, { scopeType, scopeId, entityType: mutation.entityType, entityId: mutation.entityId, version, operation, data });
        sequence += 1n;
        changes.push({
          householdId: scopeType === 'household' ? scopeId : null,
          userId: scopeType === 'user' ? scopeId : null,
          sequence: sequence.toString(), entityType: mutation.entityType, entityId: mutation.entityId,
          operation, version, changedAt: '2026-07-13T12:00:00Z', data
        });
        result = { mutationId: mutation.mutationId, entityId: mutation.entityId, status: 'applied', version, sequence: sequence.toString(), serverRecord: data };
      }
      ledger.set(ledgerKey, { requestHash, result });
      return result;
    },
    async pullChanges({ accessToken, scopeType, scopeId, cursor, limit, entityTypes }) {
      account(accessToken);
      const candidates = changes.filter(change => (
        (scopeType === 'household' ? change.householdId === scopeId : change.userId === scopeId)
        && BigInt(change.sequence) > BigInt(cursor)
        && (!entityTypes.length || entityTypes.includes(change.entityType))
      ));
      const page = candidates.slice(0, limit);
      return {
        cursor: page.at(-1)?.sequence || cursor,
        hasMore: candidates.length > limit,
        changes: page.map(({ householdId: _household, userId: _user, ...change }) => change)
      };
    }
  };
}

function mutation({ mutationId, entityType = 'inventory_item', entityId = inventoryId, operation = 'upsert', baseVersion = '0', data } = {}) {
  return {
    mutationId,
    entityType,
    entityId,
    operation,
    baseVersion,
    clientUpdatedAt: '2026-07-13T12:00:00Z',
    data: data ?? { name: '鸡蛋', normalizedName: '鸡蛋', quantity: 6, unit: '个' }
  };
}

async function apply(service, auth, scopeId, mutations, scopeType = 'household') {
  const input = validateMutationsRequest({ scopeType, scopeId, mutations });
  return service.applyMutations({ auth, input });
}

test('create retry is idempotent and emits exactly one change', async () => {
  const repository = createAtomicContractRepository();
  const service = createSyncService({ repository });
  const request = mutation({ mutationId: '10000000-0000-4000-8000-000000000001' });
  const first = await apply(service, authA, householdA, [request]);
  const retry = await apply(service, authA, householdA, [request]);
  assert.equal(first.results[0].status, 'applied');
  assert.equal(first.results[0].version, '1');
  assert.equal(retry.results[0].status, 'duplicate');
  assert.equal(retry.results[0].originalStatus, 'applied');
  assert.equal(repository.changes.length, 1);
});

test('matching update succeeds, stale update conflicts, and neither conflict nor retry adds a change', async () => {
  const repository = createAtomicContractRepository();
  const service = createSyncService({ repository });
  await apply(service, authA, householdA, [mutation({ mutationId: '10000000-0000-4000-8000-000000000002' })]);
  const update = mutation({ mutationId: '10000000-0000-4000-8000-000000000003', baseVersion: '1', data: { name: '鸡蛋', normalizedName: '鸡蛋', quantity: 4, unit: '个' } });
  const applied = await apply(service, authA, householdA, [update]);
  const stale = mutation({ mutationId: '10000000-0000-4000-8000-000000000004', baseVersion: '1', data: { name: '鸡蛋', normalizedName: '鸡蛋', quantity: 2, unit: '个' } });
  const conflict = await apply(service, authA, householdA, [stale]);
  const conflictRetry = await apply(service, authA, householdA, [stale]);
  assert.equal(applied.results[0].version, '2');
  assert.equal(conflict.results[0].status, 'conflict');
  assert.equal(conflict.results[0].version, '2');
  assert.equal(conflictRetry.results[0].status, 'duplicate');
  assert.equal(conflictRetry.results[0].originalStatus, 'conflict');
  assert.equal(repository.changes.length, 2);
});

test('delete creates one tombstone and retry does not physically delete or append another change', async () => {
  const repository = createAtomicContractRepository();
  const service = createSyncService({ repository });
  await apply(service, authA, householdA, [mutation({ mutationId: '10000000-0000-4000-8000-000000000005' })]);
  const removal = mutation({ mutationId: '10000000-0000-4000-8000-000000000006', operation: 'delete', baseVersion: '1', data: {} });
  const first = await apply(service, authA, householdA, [removal]);
  const retry = await apply(service, authA, householdA, [removal]);
  assert.equal(first.results[0].status, 'applied');
  assert.equal(first.results[0].version, '2');
  assert.equal(retry.results[0].status, 'duplicate');
  assert.equal(repository.records.get(`inventory_item:${inventoryId}`).operation, 'delete');
  assert.equal(repository.changes.filter(change => change.operation === 'delete').length, 1);
});

test('reusing mutationId with a different canonical payload is rejected without another change', async () => {
  const repository = createAtomicContractRepository();
  const service = createSyncService({ repository });
  const mutationId = '10000000-0000-4000-8000-000000000007';
  await apply(service, authA, householdA, [mutation({ mutationId })]);
  const mismatch = await apply(service, authA, householdA, [mutation({ mutationId, data: { name: '鸡蛋', normalizedName: '鸡蛋', quantity: 99, unit: '个' } })]);
  assert.equal(mismatch.results[0].status, 'rejected');
  assert.equal(mismatch.results[0].errorCode, 'idempotency_mismatch');
  assert.equal(repository.changes.length, 1);
});

test('different entity types share one monotonic sequence space', async () => {
  const repository = createAtomicContractRepository();
  const service = createSyncService({ repository });
  await apply(service, authA, householdA, [mutation({ mutationId: '10000000-0000-4000-8000-000000000008' })]);
  await apply(service, authA, householdA, [mutation({
    mutationId: '10000000-0000-4000-8000-000000000009', entityType: 'shopping_item', entityId: shoppingId,
    data: { name: '牛奶', normalizedName: '牛奶', quantity: 1, unit: '盒' }
  })]);
  assert.deepEqual(repository.changes.map(change => change.sequence), ['1', '2']);
  assert.deepEqual(repository.changes.map(change => change.entityType), ['inventory_item', 'shopping_item']);
});

test('household and personal pulls use independent scope cursors without cross-scope leakage', async () => {
  const repository = createAtomicContractRepository();
  const service = createSyncService({ repository });
  await apply(service, authA, householdA, [mutation({ mutationId: '10000000-0000-4000-8000-000000000011' })]);
  await apply(service, authA, userA, [mutation({
    mutationId: '10000000-0000-4000-8000-000000000012',
    entityType: 'recipe_favorite',
    entityId: 'f0000000-0000-4000-8000-000000000001',
    data: { recipeId: 'sample-mapotofu' }
  })], 'user');

  const householdPage = await service.pullChanges({
    auth: authA,
    input: validateChangesQuery({ scopeType: 'household', scopeId: householdA, cursor: '0', limit: '100' })
  });
  const userPage = await service.pullChanges({
    auth: authA,
    input: validateChangesQuery({ scopeType: 'user', scopeId: userA, cursor: '0', limit: '100' })
  });
  assert.deepEqual(householdPage.changes.map(change => change.entityType), ['inventory_item']);
  assert.deepEqual(userPage.changes.map(change => change.entityType), ['recipe_favorite']);
  assert.equal(householdPage.cursor, '1');
  assert.equal(userPage.cursor, '2');
});

test('User B cannot pull User A household changes', async () => {
  const repository = createAtomicContractRepository();
  const service = createSyncService({ repository });
  await apply(service, authA, householdA, [mutation({ mutationId: '10000000-0000-4000-8000-000000000010' })]);
  const input = validateChangesQuery({ scopeType: 'household', scopeId: householdA, cursor: '0', limit: '100' });
  await assert.rejects(() => service.pullChanges({ auth: authB, input }), error => error.status === 403);
});

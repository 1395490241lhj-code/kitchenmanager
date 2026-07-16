import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const routesSource = fs.readFileSync(path.join(ROOT, 'src/server/sync/routes.js'), 'utf8');
const versionGateSource = fs.readFileSync(path.join(ROOT, 'src/server/sync/version-gate.js'), 'utf8');
const rateLimitSource = fs.readFileSync(path.join(ROOT, 'src/server/sync/rate-limit.js'), 'utf8');
const {
  parseSemVer,
  formatSemVer,
  compareSemVer,
  parseNonNegativeInteger,
  loadVersionEnforcementConfig,
  createVersionGateMiddleware,
  VERSION_HEADER,
  BUILD_HEADER,
  SCHEMA_HEADER
} = require('../src/server/sync/version-gate');
const {
  createMemoryWindowStore,
  createReadRateLimiter,
  createMutationRateLimiter
} = require('../src/server/sync/rate-limit');
const { registerSyncRoutes } = require('../src/server/sync/routes');
const { SyncError } = require('../src/server/sync/errors');

const userA = '11111111-1111-4111-8111-111111111111';
const userB = '22222222-2222-4222-8222-222222222222';
const householdA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const authA = { userId: userA, email: 'a@example.com', accessToken: 'opaque-test-token' };
const authB = { userId: userB, email: 'b@example.com', accessToken: 'opaque-test-token-b' };

function createResponse() {
  return {
    statusCode: 200, body: null, headers: {},
    status(code) { this.statusCode = code; return this; },
    json(value) { this.body = value; return this; },
    set(name, value) { this.headers[name] = value; return this; }
  };
}

function fakeReq({ auth = authA, headers = {}, body = {}, query = {}, path = '/api/sync/mutations' } = {}) {
  const normalized = {};
  for (const [key, value] of Object.entries(headers)) normalized[key.toLowerCase()] = value;
  return {
    auth,
    body,
    query,
    path,
    get(name) { return normalized[name.toLowerCase()]; }
  };
}

function currentVersionHeaders(overrides = {}) {
  return {
    [VERSION_HEADER]: '1.2.0',
    [BUILD_HEADER]: '5',
    [SCHEMA_HEADER]: '1',
    ...overrides
  };
}

// ── 1. Version comparator safety (section 八) ──────────────────────────────

test('parseSemVer/compareSemVer: numeric, not lexicographic, comparison', () => {
  assert.equal(compareSemVer(parseSemVer('1.0.0'), parseSemVer('1.0.0')), 0);
  assert.equal(compareSemVer(parseSemVer('1.0.1'), parseSemVer('1.0.0')), 1);
  assert.equal(compareSemVer(parseSemVer('1.10.0'), parseSemVer('1.9.0')), 1, '10 > 9 numerically, not "1" < "9" lexicographically');
  assert.equal(compareSemVer(parseSemVer('2.0'), parseSemVer('1.99.99')), 1, 'major version wins regardless of minor/patch digit count');
});

test('parseSemVer rejects malformed/empty version strings', () => {
  for (const bad of [undefined, null, '', '   ', 'abc', '1', '1.a.0', '1.0.0.0', '-1.0.0', '1.0.-1', 'v1.0.0']) {
    assert.equal(parseSemVer(bad), null, `expected null for ${JSON.stringify(bad)}`);
  }
});

test('parseNonNegativeInteger accepts leading zeros, rejects negative/overflow/malformed', () => {
  assert.equal(parseNonNegativeInteger('007'), 7, 'leading zeros parse to the equivalent integer');
  assert.equal(parseNonNegativeInteger('0'), 0);
  assert.equal(parseNonNegativeInteger('-1'), null, 'negative build numbers are rejected');
  assert.equal(parseNonNegativeInteger('1.5'), null);
  assert.equal(parseNonNegativeInteger(''), null);
  assert.equal(parseNonNegativeInteger(undefined), null);
  assert.equal(parseNonNegativeInteger('99999999999999999999'), null, 'integer overflow is rejected, never silently truncated');
  assert.equal(parseNonNegativeInteger('  12 '), 12, 'surrounding whitespace is trimmed');
});

test('formatSemVer round-trips a parsed version for the 426 response body', () => {
  assert.equal(formatSemVer(parseSemVer('1.2.3')), '1.2.3');
  assert.equal(formatSemVer(parseSemVer('2.0')), '2.0.0');
});

// ── 2. Version-enforcement config loading (fail-safe) ──────────────────────

test('enforcement config defaults to disabled when the flag is missing/malformed', () => {
  for (const raw of [undefined, '', 'not-a-boolean', '2']) {
    const config = loadVersionEnforcementConfig({ SYNC_VERSION_ENFORCEMENT_ENABLED: raw });
    assert.equal(config.enabled, false);
  }
});

test('enforcement enabled but thresholds missing/malformed is reported as misconfigured, never silently allowing every client', () => {
  const base = { SYNC_VERSION_ENFORCEMENT_ENABLED: 'true' };
  for (const env of [
    base,
    { ...base, MIN_IOS_APP_VERSION: '1.0.0' }, // build/schema missing
    { ...base, MIN_IOS_APP_VERSION: 'bad', MIN_IOS_BUILD: '1', MIN_IOS_CLIENT_SCHEMA: '1' },
    { ...base, MIN_IOS_APP_VERSION: '1.0.0', MIN_IOS_BUILD: '-1', MIN_IOS_CLIENT_SCHEMA: '1' }
  ]) {
    const config = loadVersionEnforcementConfig(env);
    assert.equal(config.enabled, true);
    assert.equal(config.misconfigured, true);
  }
});

test('enforcement enabled with fully valid thresholds is not misconfigured', () => {
  const config = loadVersionEnforcementConfig({
    SYNC_VERSION_ENFORCEMENT_ENABLED: 'true',
    MIN_IOS_APP_VERSION: '1.0.0', MIN_IOS_BUILD: '1', MIN_IOS_CLIENT_SCHEMA: '1'
  });
  assert.equal(config.enabled, true);
  assert.equal(config.misconfigured, false);
  assert.deepEqual(config.minVersion, [1, 0, 0]);
  assert.equal(config.minBuild, 1);
  assert.equal(config.minSchema, 1);
});

// ── 3. Version gate middleware (tests 1-14, section 十六) ──────────────────

function gateFor(env) {
  return createVersionGateMiddleware({ loadConfig: () => loadVersionEnforcementConfig(env) });
}

test('1. enforcement disabled allows a request with no version headers at all', async () => {
  const gate = gateFor({ SYNC_VERSION_ENFORCEMENT_ENABLED: 'false' });
  const res = createResponse();
  let calledNext = false;
  await gate(fakeReq({ headers: {} }), res, () => { calledNext = true; });
  assert.equal(calledNext, true);
  assert.equal(res.body, null);
});

test('2. valid current client is allowed', async () => {
  const gate = gateFor({
    SYNC_VERSION_ENFORCEMENT_ENABLED: 'true',
    MIN_IOS_APP_VERSION: '1.0.0', MIN_IOS_BUILD: '1', MIN_IOS_CLIENT_SCHEMA: '1'
  });
  const res = createResponse();
  let calledNext = false;
  await gate(fakeReq({ headers: currentVersionHeaders() }), res, () => { calledNext = true; });
  assert.equal(calledNext, true);
});

test('3. old semantic version is rejected with 426', async () => {
  const gate = gateFor({
    SYNC_VERSION_ENFORCEMENT_ENABLED: 'true',
    MIN_IOS_APP_VERSION: '2.0.0', MIN_IOS_BUILD: '1', MIN_IOS_CLIENT_SCHEMA: '1'
  });
  const res = createResponse();
  await gate(fakeReq({ headers: currentVersionHeaders({ [VERSION_HEADER]: '1.9.9' }) }), res, () => { throw new Error('must not call next'); });
  assert.equal(res.statusCode, 426);
});

test('4. old build is rejected with 426 even when the version string matches the minimum', async () => {
  const gate = gateFor({
    SYNC_VERSION_ENFORCEMENT_ENABLED: 'true',
    MIN_IOS_APP_VERSION: '1.2.0', MIN_IOS_BUILD: '10', MIN_IOS_CLIENT_SCHEMA: '1'
  });
  const res = createResponse();
  await gate(fakeReq({ headers: currentVersionHeaders({ [VERSION_HEADER]: '1.2.0', [BUILD_HEADER]: '5' }) }), res, () => { throw new Error('must not call next'); });
  assert.equal(res.statusCode, 426);
});

test('5. old schema is rejected with 426', async () => {
  const gate = gateFor({
    SYNC_VERSION_ENFORCEMENT_ENABLED: 'true',
    MIN_IOS_APP_VERSION: '1.0.0', MIN_IOS_BUILD: '1', MIN_IOS_CLIENT_SCHEMA: '2'
  });
  const res = createResponse();
  await gate(fakeReq({ headers: currentVersionHeaders({ [SCHEMA_HEADER]: '1' }) }), res, () => { throw new Error('must not call next'); });
  assert.equal(res.statusCode, 426);
});

test('6. missing version headers are rejected when enforcement is on — never treated as a legitimate up-to-date client', async () => {
  const gate = gateFor({
    SYNC_VERSION_ENFORCEMENT_ENABLED: 'true',
    MIN_IOS_APP_VERSION: '1.0.0', MIN_IOS_BUILD: '1', MIN_IOS_CLIENT_SCHEMA: '1'
  });
  const res = createResponse();
  await gate(fakeReq({ headers: {} }), res, () => { throw new Error('must not call next'); });
  assert.equal(res.statusCode, 426);
});

test('7. malformed version header is rejected with 426', async () => {
  const gate = gateFor({
    SYNC_VERSION_ENFORCEMENT_ENABLED: 'true',
    MIN_IOS_APP_VERSION: '1.0.0', MIN_IOS_BUILD: '1', MIN_IOS_CLIENT_SCHEMA: '1'
  });
  const res = createResponse();
  await gate(fakeReq({ headers: currentVersionHeaders({ [VERSION_HEADER]: 'not-a-version' }) }), res, () => { throw new Error('must not call next'); });
  assert.equal(res.statusCode, 426);
});

test('8. malformed build header is rejected with 426', async () => {
  const gate = gateFor({
    SYNC_VERSION_ENFORCEMENT_ENABLED: 'true',
    MIN_IOS_APP_VERSION: '1.0.0', MIN_IOS_BUILD: '1', MIN_IOS_CLIENT_SCHEMA: '1'
  });
  const res = createResponse();
  await gate(fakeReq({ headers: currentVersionHeaders({ [BUILD_HEADER]: '-5' }) }), res, () => { throw new Error('must not call next'); });
  assert.equal(res.statusCode, 426);
});

test('9. malformed schema header is rejected with 426', async () => {
  const gate = gateFor({
    SYNC_VERSION_ENFORCEMENT_ENABLED: 'true',
    MIN_IOS_APP_VERSION: '1.0.0', MIN_IOS_BUILD: '1', MIN_IOS_CLIENT_SCHEMA: '1'
  });
  const res = createResponse();
  await gate(fakeReq({ headers: currentVersionHeaders({ [SCHEMA_HEADER]: 'x' }) }), res, () => { throw new Error('must not call next'); });
  assert.equal(res.statusCode, 426);
});

test('10. 426 response format matches the documented contract and includes only safe fields', async () => {
  const gate = gateFor({
    SYNC_VERSION_ENFORCEMENT_ENABLED: 'true',
    MIN_IOS_APP_VERSION: '9.0.0', MIN_IOS_BUILD: '100', MIN_IOS_CLIENT_SCHEMA: '5'
  });
  const res = createResponse();
  await gate(fakeReq({ headers: currentVersionHeaders() }), res, () => { throw new Error('must not call next'); });
  assert.equal(res.statusCode, 426);
  assert.deepEqual(Object.keys(res.body).sort(), ['code', 'error', 'message', 'minimumBuild', 'minimumVersion'].sort());
  assert.equal(res.body.error, 'client_upgrade_required');
  assert.equal(res.body.code, 'CLIENT_UPGRADE_REQUIRED');
  assert.equal(res.body.minimumVersion, '9.0.0');
  assert.equal(res.body.minimumBuild, 100);
});

test('14. version-gate response never contains internal config, stack trace, token, user id, or household id', async () => {
  const gate = gateFor({
    SYNC_VERSION_ENFORCEMENT_ENABLED: 'true',
    MIN_IOS_APP_VERSION: '9.0.0', MIN_IOS_BUILD: '1', MIN_IOS_CLIENT_SCHEMA: '1'
  });
  const res = createResponse();
  await gate(fakeReq({ auth: authA, headers: currentVersionHeaders() }), res, () => { throw new Error('must not call next'); });
  const serialized = JSON.stringify(res.body);
  for (const forbidden of [userA, authA.accessToken, householdA, 'process.env', '/Users/', 'at ']) {
    assert.equal(serialized.includes(forbidden), false, `response leaked ${forbidden}`);
  }
});

test('misconfiguration (enforcement on, thresholds unusable) fails closed with a distinct 503, never crashes, never falls back to allowing everything', async () => {
  const gate = gateFor({ SYNC_VERSION_ENFORCEMENT_ENABLED: 'true' });
  const res = createResponse();
  await gate(fakeReq({ headers: currentVersionHeaders() }), res, () => { throw new Error('must not call next — a misconfigured server must not silently allow'); });
  assert.equal(res.statusCode, 503);
  assert.equal(res.body.code, 'SYNC_VERSION_ENFORCEMENT_MISCONFIGURED');
});

// ── 11-13. sync read/mutation blocked, unrelated route unaffected (integration via registerSyncRoutes) ──

function fakeApp() {
  const routes = new Map();
  return {
    app: {
      get(path, handler) { routes.set(`GET ${path}`, handler); },
      post(path, handler) { routes.set(`POST ${path}`, handler); }
    },
    routes
  };
}

async function passthroughAuthAndRole(req, _res, next) { await next(); }

test('11. sync read (bootstrap/changes) blocked by an old client', async () => {
  const { app, routes } = fakeApp();
  const seen = [];
  registerSyncRoutes(app, {
    authenticate: passthroughAuthAndRole,
    requireRole: passthroughAuthAndRole,
    versionGate: gateFor({ SYNC_VERSION_ENFORCEMENT_ENABLED: 'true', MIN_IOS_APP_VERSION: '9.0.0', MIN_IOS_BUILD: '1', MIN_IOS_CLIENT_SCHEMA: '1' }),
    service: {
      bootstrap: async () => { seen.push('bootstrap'); return { schemaVersion: 1 }; },
      pullChanges: async () => { seen.push('changes'); return { cursor: '0', hasMore: false, changes: [] }; },
      applyMutations: async () => { seen.push('mutations'); return { cursor: '0', results: [] }; }
    }
  });
  for (const path of ['GET /api/sync/bootstrap', 'GET /api/sync/changes']) {
    const res = createResponse();
    await routes.get(path)(fakeReq({ headers: {}, query: { scopeType: 'household', scopeId: householdA } }), res);
    assert.equal(res.statusCode, 426);
  }
  assert.deepEqual(seen, [], 'the service must never be reached for a rejected old client');
});

test('12. sync mutation write blocked by an old client', async () => {
  const { app, routes } = fakeApp();
  let mutationsCalled = false;
  registerSyncRoutes(app, {
    authenticate: passthroughAuthAndRole,
    requireRole: passthroughAuthAndRole,
    versionGate: gateFor({ SYNC_VERSION_ENFORCEMENT_ENABLED: 'true', MIN_IOS_APP_VERSION: '9.0.0', MIN_IOS_BUILD: '1', MIN_IOS_CLIENT_SCHEMA: '1' }),
    service: { applyMutations: async () => { mutationsCalled = true; return { cursor: '0', results: [] }; } }
  });
  const res = createResponse();
  await routes.get('POST /api/sync/mutations')(fakeReq({ headers: {}, body: { scopeType: 'household', scopeId: householdA, mutations: [] } }), res);
  assert.equal(res.statusCode, 426);
  assert.equal(mutationsCalled, false, 'no mutation must ever be applied for a rejected old client — the ledger must never be touched');
});

test('13. a non-sync route registered separately on the same app is never wrapped by the version gate', async () => {
  // registerSyncRoutes only ever registers the three documented sync paths —
  // confirmed structurally by the existing "route registration protects all
  // sync endpoints without wrapping public APIs" test in
  // sync-phase2a-api.test.mjs. Re-asserted here for this phase's routes.
  const { app, routes } = fakeApp();
  registerSyncRoutes(app, { authenticate: passthroughAuthAndRole, requireRole: passthroughAuthAndRole });
  assert.deepEqual([...routes.keys()].sort(), ['GET /api/sync/bootstrap', 'GET /api/sync/changes', 'POST /api/sync/mutations'].sort());
});

// ── Rate limiting (tests 15-30, section 十六) ──────────────────────────────

test('15. under the limit is allowed', () => {
  const store = createMemoryWindowStore();
  const limiter = createReadRateLimiter({ store, windowMs: 60000, maxRequests: 3 });
  let calls = 0;
  const next = () => { calls += 1; };
  for (let i = 0; i < 3; i += 1) limiter(fakeReq({ path: '/api/sync/bootstrap' }), createResponse(), next);
  assert.equal(calls, 3);
});

test('16. the exact boundary request is allowed, only the one after it is rejected', () => {
  const store = createMemoryWindowStore();
  const limiter = createReadRateLimiter({ store, windowMs: 60000, maxRequests: 3 });
  const results = [];
  for (let i = 0; i < 4; i += 1) {
    const res = createResponse();
    limiter(fakeReq({ path: '/api/sync/bootstrap' }), res, () => results.push('next'));
    if (res.statusCode === 429) results.push('429');
  }
  assert.deepEqual(results, ['next', 'next', 'next', '429']);
});

test('17. over the limit returns 429 with the documented body', () => {
  const store = createMemoryWindowStore();
  const limiter = createReadRateLimiter({ store, windowMs: 60000, maxRequests: 1 });
  limiter(fakeReq({ path: '/api/sync/bootstrap' }), createResponse(), () => {});
  const res = createResponse();
  limiter(fakeReq({ path: '/api/sync/bootstrap' }), res, () => { throw new Error('must not call next'); });
  assert.equal(res.statusCode, 429);
  assert.equal(res.body.error, 'rate_limited');
  assert.equal(res.body.code, 'SYNC_RATE_LIMITED');
  assert.equal(typeof res.body.retryAfterSeconds, 'number');
});

test('18. Retry-After header is present and matches the body field', () => {
  const store = createMemoryWindowStore();
  const limiter = createReadRateLimiter({ store, windowMs: 60000, maxRequests: 0 });
  const res = createResponse();
  limiter(fakeReq({ path: '/api/sync/bootstrap' }), res, () => { throw new Error('must not call next'); });
  assert.equal(res.statusCode, 429);
  assert.equal(res.headers['Retry-After'], String(res.body.retryAfterSeconds));
});

test('19. separate users have separate buckets', () => {
  const store = createMemoryWindowStore();
  const limiter = createReadRateLimiter({ store, windowMs: 60000, maxRequests: 1 });
  limiter(fakeReq({ auth: authA, path: '/api/sync/bootstrap' }), createResponse(), () => {});
  const res = createResponse();
  limiter(fakeReq({ auth: authB, path: '/api/sync/bootstrap' }), res, () => {});
  assert.equal(res.statusCode, 200, 'user B must not be affected by user A exhausting their own bucket');
});

test('20. separate routes have separate buckets for the same user', () => {
  const store = createMemoryWindowStore();
  const limiter = createReadRateLimiter({ store, windowMs: 60000, maxRequests: 1 });
  limiter(fakeReq({ auth: authA, path: '/api/sync/bootstrap' }), createResponse(), () => {});
  const res = createResponse();
  limiter(fakeReq({ auth: authA, path: '/api/sync/changes' }), res, () => {});
  assert.equal(res.statusCode, 200, 'exhausting the bootstrap bucket must not affect the changes bucket');
});

test('21. read and mutation limiters use independent buckets', () => {
  const store = createMemoryWindowStore();
  const readLimiter = createReadRateLimiter({ store, windowMs: 60000, maxRequests: 1 });
  const mutationLimiter = createMutationRateLimiter({ store, requestWindowMs: 60000, maxRequests: 1, operationWindowMs: 60000, maxOperations: 100 });
  readLimiter(fakeReq({ auth: authA, path: '/api/sync/bootstrap' }), createResponse(), () => {});
  const res = createResponse();
  mutationLimiter(fakeReq({ auth: authA, body: { mutations: [] } }), res, () => {});
  assert.equal(res.statusCode, 200);
});

test('22. mutation operation-count limit trips even under the per-request limit', () => {
  const store = createMemoryWindowStore();
  const limiter = createMutationRateLimiter({ store, requestWindowMs: 60000, maxRequests: 100, operationWindowMs: 60000, maxOperations: 5 });
  const bigBatch = Array.from({ length: 6 }, (_, i) => ({ mutationId: String(i) }));
  const res = createResponse();
  limiter(fakeReq({ auth: authA, body: { mutations: bigBatch } }), res, () => { throw new Error('must not call next'); });
  assert.equal(res.statusCode, 429);
});

test('23. mutation batch-size limit (100 per request, validation.js) remains enforced independently of rate limiting', () => {
  const { validateMutationsRequest } = require('../src/server/sync/validation');
  const mutations = Array.from({ length: 101 }, (_, i) => ({
    mutationId: `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`,
    entityType: 'inventory_item',
    entityId: `10000000-0000-4000-8000-${String(i).padStart(12, '0')}`,
    operation: 'upsert',
    baseVersion: 0,
    data: { name: 'x', normalizedName: 'x' }
  }));
  assert.throws(() => validateMutationsRequest({ scopeType: 'household', scopeId: householdA, mutations }), /SyncError|批/i);
});

test('24. a failed-auth request never reaches or consumes any per-user rate-limit bucket', () => {
  const store = createMemoryWindowStore();
  const limiter = createReadRateLimiter({ store, windowMs: 60000, maxRequests: 1 });
  // No req.auth at all — mirrors what the request looks like before/without
  // successful authentication (auth/role middleware would already have
  // rejected it with 401 long before reaching the rate limiter).
  const res = createResponse();
  let calledNext = false;
  limiter(fakeReq({ auth: null, path: '/api/sync/bootstrap' }), res, () => { calledNext = true; });
  assert.equal(calledNext, true, 'without an authenticated identity the limiter is a defensive no-op, not a rejection');
  assert.equal(store._size(), 0, 'no bucket was created for an unauthenticated request');
});

test('25. 426 and 429 never reach the handler, so a mutation ledger row is never written for a rejected request', async () => {
  const { app, routes } = fakeApp();
  let applyMutationsCalled = false;
  const store = createMemoryWindowStore();
  registerSyncRoutes(app, {
    authenticate: passthroughAuthAndRole,
    requireRole: passthroughAuthAndRole,
    mutationRateLimiter: createMutationRateLimiter({ store, requestWindowMs: 60000, maxRequests: 0 }),
    service: { applyMutations: async () => { applyMutationsCalled = true; return { cursor: '0', results: [] }; } }
  });
  const res = createResponse();
  await routes.get('POST /api/sync/mutations')(fakeReq({ headers: currentVersionHeaders(), body: { scopeType: 'household', scopeId: householdA, mutations: [] } }), res);
  assert.equal(res.statusCode, 429);
  assert.equal(applyMutationsCalled, false);
});

test('26. window reset works with a fake clock — no real sleep required', () => {
  const store = createMemoryWindowStore();
  let now = 1_000_000;
  const limiter = createReadRateLimiter({ store, windowMs: 10_000, maxRequests: 1, nowProvider: () => now });
  limiter(fakeReq({ path: '/api/sync/bootstrap' }), createResponse(), () => {});
  const blocked = createResponse();
  limiter(fakeReq({ path: '/api/sync/bootstrap' }), blocked, () => { throw new Error('must not call next'); });
  assert.equal(blocked.statusCode, 429);
  now += 10_001; // advance the fake clock past the window, no real waiting
  const afterReset = createResponse();
  let calledNext = false;
  limiter(fakeReq({ path: '/api/sync/bootstrap' }), afterReset, () => { calledNext = true; });
  assert.equal(calledNext, true);
});

test('27. limiter bucket keys never contain an email or the raw token/Authorization value', () => {
  const store = createMemoryWindowStore();
  const originalConsume = store.consume.bind(store);
  const seenKeys = [];
  store.consume = (key, ...rest) => { seenKeys.push(key); return originalConsume(key, ...rest); };
  const limiter = createReadRateLimiter({ store, windowMs: 60000, maxRequests: 10 });
  limiter(fakeReq({ auth: authA, path: '/api/sync/bootstrap' }), createResponse(), () => {});
  assert.equal(seenKeys.length, 1);
  for (const forbidden of [authA.email, authA.accessToken]) {
    assert.equal(seenKeys[0].includes(forbidden), false);
  }
  assert.equal(seenKeys[0].includes(userA), true, 'the key is keyed by the stable JWT subject UUID, not email/token');
});

test('28. the rollback/merge-confirm mutation path (same POST /api/sync/mutations endpoint) is protected by the mutation limiter', async () => {
  // The server has no field distinguishing "this batch is a rollback" vs
  // "this batch is an ordinary confirm/CRUD sync" — both travel through the
  // identical endpoint and payload shape, so there is exactly one mutation
  // limiter covering all of them uniformly (documented in
  // docs/SYNC_API_RATE_LIMITING.md).
  const { app, routes } = fakeApp();
  const store = createMemoryWindowStore();
  registerSyncRoutes(app, {
    authenticate: passthroughAuthAndRole,
    requireRole: passthroughAuthAndRole,
    mutationRateLimiter: createMutationRateLimiter({ store, requestWindowMs: 60000, maxRequests: 1 }),
    service: { applyMutations: async () => ({ cursor: '0', results: [] }) }
  });
  const rollbackLikeBody = {
    scopeType: 'household', scopeId: householdA,
    mutations: [{
      mutationId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', entityType: 'inventory_item',
      entityId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', operation: 'delete', baseVersion: 1
    }]
  };
  const first = createResponse();
  await routes.get('POST /api/sync/mutations')(fakeReq({ headers: currentVersionHeaders(), body: rollbackLikeBody }), first);
  assert.equal(first.statusCode, 200);
  const second = createResponse();
  await routes.get('POST /api/sync/mutations')(fakeReq({ headers: currentVersionHeaders(), body: rollbackLikeBody }), second);
  assert.equal(second.statusCode, 429);
});

test('29. merge-confirm-shaped requests (ordinary upserts) are protected by the same mutation limiter', async () => {
  const { app, routes } = fakeApp();
  const store = createMemoryWindowStore();
  registerSyncRoutes(app, {
    authenticate: passthroughAuthAndRole,
    requireRole: passthroughAuthAndRole,
    mutationRateLimiter: createMutationRateLimiter({ store, requestWindowMs: 60000, maxRequests: 1 }),
    service: { applyMutations: async () => ({ cursor: '0', results: [] }) }
  });
  const confirmLikeBody = {
    scopeType: 'household', scopeId: householdA,
    mutations: [{
      mutationId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', entityType: 'inventory_item',
      entityId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', operation: 'upsert', baseVersion: 0,
      data: { name: '鸡蛋', normalizedName: '鸡蛋', quantity: 6, unit: '个' }
    }]
  };
  const first = createResponse();
  await routes.get('POST /api/sync/mutations')(fakeReq({ headers: currentVersionHeaders(), body: confirmLikeBody }), first);
  assert.equal(first.statusCode, 200);
  const second = createResponse();
  await routes.get('POST /api/sync/mutations')(fakeReq({ headers: currentVersionHeaders(), body: confirmLikeBody }), second);
  assert.equal(second.statusCode, 429);
});

test('30. test environment is deterministic — no real timers, no flakiness across repeated runs', () => {
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const store = createMemoryWindowStore();
    let now = 0;
    const limiter = createReadRateLimiter({ store, windowMs: 1000, maxRequests: 2, nowProvider: () => now });
    const outcomes = [];
    for (let i = 0; i < 3; i += 1) {
      const res = createResponse();
      limiter(fakeReq({ path: '/api/sync/bootstrap' }), res, () => outcomes.push('ok'));
      if (res.statusCode === 429) outcomes.push('429');
    }
    assert.deepEqual(outcomes, ['ok', 'ok', '429']);
  }
});

test('mutation rate limiter operation-count math sums across multiple requests within the same window', () => {
  const store = createMemoryWindowStore();
  const limiter = createMutationRateLimiter({ store, requestWindowMs: 60000, maxRequests: 100, operationWindowMs: 60000, maxOperations: 10 });
  const fiveOps = Array.from({ length: 5 }, (_, i) => ({ mutationId: String(i) }));
  const first = createResponse();
  limiter(fakeReq({ auth: authA, body: { mutations: fiveOps } }), first, () => {});
  assert.equal(first.statusCode, 200);
  const second = createResponse();
  limiter(fakeReq({ auth: authA, body: { mutations: fiveOps } }), second, () => {});
  assert.equal(second.statusCode, 200, 'exactly 10 total, still within the boundary');
  const third = createResponse();
  limiter(fakeReq({ auth: authA, body: { mutations: [{ mutationId: 'extra' }] } }), third, () => { throw new Error('must not call next'); });
  assert.equal(third.statusCode, 429, 'the 11th operation must trip the quota');
});

// ── Node semantic guards (section 十八) ─────────────────────────────────────

test('semantic guard: every /api/sync/* route wires versionGate before its rate limiter', () => {
  const bootstrapLine = routesSource.match(/app\.get\('\/api\/sync\/bootstrap',\s*chain\(([^)]*)\)\)/)?.[1] || '';
  const changesLine = routesSource.match(/app\.get\('\/api\/sync\/changes',\s*chain\(([^)]*)\)\)/)?.[1] || '';
  const mutationsLine = routesSource.match(/app\.post\('\/api\/sync\/mutations',\s*chain\(([^)]*)\)\)/)?.[1] || '';
  for (const [name, line] of [['bootstrap', bootstrapLine], ['changes', changesLine], ['mutations', mutationsLine]]) {
    assert.ok(line.includes('versionGate'), `${name} route must include versionGate in its chain`);
  }
  assert.ok(bootstrapLine.includes('readRateLimiter'), 'bootstrap must use the read limiter');
  assert.ok(changesLine.includes('readRateLimiter'), 'changes must use the read limiter');
  assert.ok(mutationsLine.includes('mutationRateLimiter'), 'mutations must use the mutation limiter, not the read limiter');
});

test('semantic guard: versionGate is applied strictly before the rate limiter in every chain (order matters)', () => {
  for (const pattern of [
    /app\.get\('\/api\/sync\/bootstrap',\s*chain\(auth,\s*role,\s*versionGate,\s*readRateLimiter/,
    /app\.get\('\/api\/sync\/changes',\s*chain\(auth,\s*role,\s*versionGate,\s*readRateLimiter/,
    /app\.post\('\/api\/sync\/mutations',\s*chain\(auth,\s*role,\s*versionGate,\s*mutationRateLimiter/
  ]) {
    assert.ok(pattern.test(routesSource), `expected ${pattern} to match routes.js`);
  }
});

test('semantic guard: no service-role key material anywhere in the new version/rate-limit modules', () => {
  for (const source of [routesSource, versionGateSource, rateLimitSource]) {
    assert.equal(/service[_-]?role/i.test(source), false);
  }
});

test('semantic guard: no production feature flag is flipped to enabled by this phase\'s source changes', () => {
  for (const source of [versionGateSource, rateLimitSource]) {
    assert.equal(/=\s*(true|YES)\s*;?\s*$/m.test(source.replace(/\/\/.*$/gm, '')), false);
  }
});

test('semantic guard: rate-limit bucket keys are built only from req.auth.userId and route/path — never req.headers, req.ip, or req.auth.email', () => {
  const relevantLines = rateLimitSource.split('\n').filter(line => line.includes('const key') || line.includes('Key = '));
  assert.ok(relevantLines.length > 0, 'expected at least one key-construction line to inspect');
  for (const line of relevantLines) {
    assert.equal(/req\.ip|req\.headers|\.email|accessToken/i.test(line), false, `key construction line must not reference IP/headers/email/token: ${line}`);
  }
});

test('semantic guard: 426/429 error codes are stable string literals, not derived from request input', () => {
  assert.ok(versionGateSource.includes("code: 'CLIENT_UPGRADE_REQUIRED'"));
  assert.ok(versionGateSource.includes("code: 'SYNC_VERSION_ENFORCEMENT_MISCONFIGURED'"));
  assert.ok(rateLimitSource.includes("code: 'SYNC_RATE_LIMITED'"));
});

test('semantic guard: rate-limit thresholds are documented, named constants in config.js, not magic numbers scattered in routes.js', () => {
  const configSource = fs.readFileSync(path.join(ROOT, 'src/server/config.js'), 'utf8');
  for (const name of [
    'SYNC_READ_RATE_LIMIT_WINDOW_MS', 'SYNC_READ_RATE_LIMIT_MAX',
    'SYNC_MUTATION_RATE_LIMIT_WINDOW_MS', 'SYNC_MUTATION_RATE_LIMIT_MAX_REQUESTS',
    'SYNC_MUTATION_OPERATION_RATE_LIMIT_WINDOW_MS', 'SYNC_MUTATION_OPERATION_RATE_LIMIT_MAX'
  ]) {
    assert.ok(configSource.includes(name), `expected ${name} to be defined in config.js`);
    assert.ok(routesSource.includes(name), `expected routes.js to import/use ${name}`);
  }
});

test('semantic guard: no Shopping/Plan/Recipe entity type is referenced by the new version/rate-limit modules', () => {
  for (const source of [versionGateSource, rateLimitSource]) {
    for (const forbidden of ['shopping_item', 'today_plan', 'user_recipe', 'weekly_meal_plan']) {
      assert.equal(source.includes(forbidden), false, `${forbidden} must not appear — this phase never expands scope beyond sync infrastructure itself`);
    }
  }
});

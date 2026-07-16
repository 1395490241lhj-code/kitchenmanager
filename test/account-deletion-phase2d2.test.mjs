import assert from 'node:assert/strict';
import test from 'node:test';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { registerAccountDeletionRoutes, createNonceStore } = require('../src/server/account/deletion-routes');
const { createAccountDeletionSyncGuard } = require('../src/server/account/deletion-sync-guard');
const { AccountDeletionError } = require('../src/server/account/errors');

const userA = '11111111-1111-4111-8111-111111111111';
const userB = '22222222-2222-4222-8222-222222222222';
const authA = { userId: userA, email: 'a@example.com', accessToken: 'token-a' };

function createResponse() {
  return {
    statusCode: 200, body: null,
    status(code) { this.statusCode = code; return this; },
    json(value) { this.body = value; return this; }
  };
}

// Express-style variadic middleware composition, matching how registerSyncRoutes'
// own tests fake an app (test/sync-phase2a-api.test.mjs) but extended to accept
// >2 middleware args the way plain `app.post(path, mw1, mw2, handler)` does.
function createFakeApp() {
  const routes = new Map();
  return {
    routes,
    post(path, ...handlers) { routes.set(`POST ${path}`, handlers); },
    async call(method, path, req) {
      const handlers = routes.get(`${method} ${path}`);
      if (!handlers) throw new Error(`no route registered for ${method} ${path}`);
      const res = createResponse();
      let index = 0;
      const next = async () => {
        const handler = handlers[index++];
        if (!handler) return;
        await handler(req, res, next);
      };
      await next();
      return res;
    }
  };
}

function passthroughAuth(req, _res, next) { return next(); }
function passthroughRole(req, _res, next) { return next(); }

function baseDeps(overrides = {}) {
  return {
    authenticate: overrides.authenticate || passthroughAuth,
    requireRole: overrides.requireRole || passthroughRole,
    repository: overrides.repository,
    admin: overrides.admin,
    nonceStore: overrides.nonceStore || createNonceStore(),
    rateLimiter: overrides.rateLimiter || ((req, res, next) => next()),
    logger: overrides.logger
  };
}

function fakeRepository(overrides = {}) {
  return {
    async getPreview() {
      return { canDelete: true, blockingReason: null, householdCount: 1, ownedHouseholdCount: 0, requiresOwnershipTransfer: false, requiresHouseholdDeletion: false, pendingMutationCountBucket: '0', confirmationVersion: 'fp-1' };
    },
    async requestDeletion() { return { status: 'business_data_cleaned', errorCode: null }; },
    async transferOwnership() { return { status: 'transferred' }; },
    async listMembersForTransfer() { return []; },
    ...overrides
  };
}

function fakeAdmin(overrides = {}) {
  return {
    async deleteAuthUser() { return { deleted: true, alreadyGone: false }; },
    async markFinalized() { return { status: 'completed' }; },
    ...overrides
  };
}

// ── 1. unauthenticated delete denied ──────────────────────────────────────

test('confirm is denied when authentication middleware rejects the request', async () => {
  const app = createFakeApp();
  registerAccountDeletionRoutes(app, baseDeps({
    authenticate: (req, res) => res.status(401).json({ error: { code: 'auth_required' } }),
    repository: fakeRepository(),
    admin: fakeAdmin()
  }));
  const res = await app.call('POST', '/api/account/delete/confirm', { auth: null, body: {} });
  assert.equal(res.statusCode, 401);
});

// ── 2. invalid JWT denied (role middleware layer) ─────────────────────────

test('confirm is denied when the role middleware rejects the request', async () => {
  const app = createFakeApp();
  registerAccountDeletionRoutes(app, baseDeps({
    requireRole: (req, res) => res.status(403).json({ error: { code: 'forbidden' } }),
    repository: fakeRepository(),
    admin: fakeAdmin()
  }));
  const res = await app.call('POST', '/api/account/delete/confirm', { auth: authA, body: {} });
  assert.equal(res.statusCode, 403);
});

// ── 3/4. deletion preview safe, contains no names/email/UUID ──────────────

test('preview returns only the documented coarse fields and a nonce, never a household id/email', async () => {
  const app = createFakeApp();
  registerAccountDeletionRoutes(app, baseDeps({ repository: fakeRepository(), admin: fakeAdmin() }));
  const res = await app.call('POST', '/api/account/delete/preview', { auth: authA, body: {} });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(Object.keys(res.body).sort(), [
    'blockingReason', 'canDelete', 'confirmationVersion', 'deletionNonce', 'householdCount',
    'ownedHouseholdCount', 'pendingMutationCountBucket', 'requiresHouseholdDeletion', 'requiresOwnershipTransfer'
  ].sort());
  assert.equal(JSON.stringify(res.body).includes('@'), false, 'no email-shaped string in the response');
});

test('preview surfaces repository errors as a safe, generic message', async () => {
  const app = createFakeApp();
  registerAccountDeletionRoutes(app, baseDeps({
    repository: fakeRepository({ getPreview: async () => { throw new AccountDeletionError('account_deletion_rpc_failed', 'internal db detail', 502); } }),
    admin: fakeAdmin()
  }));
  const res = await app.call('POST', '/api/account/delete/preview', { auth: authA, body: {} });
  assert.equal(res.statusCode, 502);
  assert.equal(res.body.error.code, 'account_deletion_rpc_failed');
  assert.equal(res.body.error.message.includes('internal db detail'), false, 'internal error detail must never leak to the client');
});

// ── 5. non-owner member can leave / 6. sole owner deletion blocked / 7. owner-with-member transfer required ──

test('confirm surfaces OWNERSHIP_TRANSFER_REQUIRED as 409 without touching local state', async () => {
  const app = createFakeApp();
  const nonceStore = createNonceStore();
  const nonce = nonceStore.issue(userA);
  registerAccountDeletionRoutes(app, baseDeps({
    nonceStore,
    repository: fakeRepository({ requestDeletion: async () => ({ status: 'rejected', errorCode: 'OWNERSHIP_TRANSFER_REQUIRED' }) }),
    admin: fakeAdmin()
  }));
  const res = await app.call('POST', '/api/account/delete/confirm', {
    auth: authA, body: { idempotencyKey: 'k1', confirmationVersion: 'fp-1', deletionNonce: nonce }
  });
  assert.equal(res.statusCode, 409);
  assert.equal(res.body.error.code, 'OWNERSHIP_TRANSFER_REQUIRED');
});

test('leave/transfer-ownership request forwards to the repository and returns its result', async () => {
  const app = createFakeApp();
  let seenArgs;
  registerAccountDeletionRoutes(app, baseDeps({
    repository: fakeRepository({ transferOwnership: async (args) => { seenArgs = args; return { status: 'transferred' }; } }),
    admin: fakeAdmin()
  }));
  const res = await app.call('POST', '/api/account/transfer-ownership', {
    auth: authA, body: { householdId: 'hh-1', newOwnerUserId: userB }
  });
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.status, 'transferred');
  assert.equal(seenArgs.householdId, 'hh-1');
  assert.equal(seenArgs.newOwnerUserId, userB);
  assert.equal(seenArgs.accessToken, authA.accessToken);
});

test('transfer-ownership rejects a request missing required fields before calling the repository', async () => {
  const app = createFakeApp();
  let called = false;
  registerAccountDeletionRoutes(app, baseDeps({
    repository: fakeRepository({ transferOwnership: async () => { called = true; return {}; } }),
    admin: fakeAdmin()
  }));
  const res = await app.call('POST', '/api/account/transfer-ownership', { auth: authA, body: { householdId: 'hh-1' } });
  assert.equal(res.statusCode, 400);
  assert.equal(called, false);
});

// ── 8. ownership transfer atomic (delegated to the DB function; verified in pgTAP) ──
// Covered by supabase/tests/account_deletion_test.sql, not re-verified here.

// ── 9. stale preview rejected ──────────────────────────────────────────────

test('confirm surfaces STALE_DELETION_PREVIEW as 409', async () => {
  const app = createFakeApp();
  const nonceStore = createNonceStore();
  const nonce = nonceStore.issue(userA);
  registerAccountDeletionRoutes(app, baseDeps({
    nonceStore,
    repository: fakeRepository({ requestDeletion: async () => ({ status: 'rejected', errorCode: 'STALE_DELETION_PREVIEW' }) }),
    admin: fakeAdmin()
  }));
  const res = await app.call('POST', '/api/account/delete/confirm', {
    auth: authA, body: { idempotencyKey: 'k1', confirmationVersion: 'stale-fp', deletionNonce: nonce }
  });
  assert.equal(res.statusCode, 409);
  assert.equal(res.body.error.code, 'STALE_DELETION_PREVIEW');
});

// ── 10. duplicate confirm idempotent ───────────────────────────────────────

test('a duplicate confirm that the repository reports as already completed returns success without calling admin', async () => {
  const app = createFakeApp();
  const nonceStore = createNonceStore();
  const nonce = nonceStore.issue(userA);
  let adminCalled = false;
  registerAccountDeletionRoutes(app, baseDeps({
    nonceStore,
    repository: fakeRepository({ requestDeletion: async () => ({ status: 'completed', errorCode: null }) }),
    admin: fakeAdmin({ deleteAuthUser: async () => { adminCalled = true; return { deleted: true }; } })
  }));
  const res = await app.call('POST', '/api/account/delete/confirm', {
    auth: authA, body: { idempotencyKey: 'k1', confirmationVersion: 'fp-1', deletionNonce: nonce }
  });
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.status, 'completed');
  assert.equal(adminCalled, false, 'an already-completed deletion must not re-invoke the Auth admin API');
});

// ── 11. failed Auth deletion recoverable / 12. failed DB cleanup recoverable / 13. partial state detectable ──

test('a failed Auth admin delete returns 202 auth_deletion_pending, not a hard failure', async () => {
  const app = createFakeApp();
  const nonceStore = createNonceStore();
  const nonce = nonceStore.issue(userA);
  let markFinalizedArgs;
  registerAccountDeletionRoutes(app, baseDeps({
    nonceStore,
    repository: fakeRepository(),
    admin: fakeAdmin({
      deleteAuthUser: async () => ({ deleted: false, alreadyGone: false }),
      markFinalized: async (args) => { markFinalizedArgs = args; return { status: 'auth_deletion_pending' }; }
    })
  }));
  const res = await app.call('POST', '/api/account/delete/confirm', {
    auth: authA, body: { idempotencyKey: 'k1', confirmationVersion: 'fp-1', deletionNonce: nonce }
  });
  assert.equal(res.statusCode, 202);
  assert.equal(res.body.status, 'auth_deletion_pending');
  assert.equal(markFinalizedArgs.authDeleted, false);
});

test('a repository failure during business-data cleanup never calls the Auth admin API', async () => {
  const app = createFakeApp();
  const nonceStore = createNonceStore();
  const nonce = nonceStore.issue(userA);
  let adminCalled = false;
  registerAccountDeletionRoutes(app, baseDeps({
    nonceStore,
    repository: fakeRepository({ requestDeletion: async () => { throw new AccountDeletionError('account_deletion_rpc_failed', 'x', 502); } }),
    admin: fakeAdmin({ deleteAuthUser: async () => { adminCalled = true; return { deleted: true }; } })
  }));
  const res = await app.call('POST', '/api/account/delete/confirm', {
    auth: authA, body: { idempotencyKey: 'k1', confirmationVersion: 'fp-1', deletionNonce: nonce }
  });
  assert.equal(res.statusCode, 502);
  assert.equal(adminCalled, false, 'business-data cleanup must fully fail before any Auth admin call is attempted');
});

// ── 14. sync frozen during deletion ────────────────────────────────────────

test('the sync guard blocks requests while a deletion is requested/cleaning/pending, and allows otherwise', async () => {
  for (const status of ['requested', 'business_data_cleaned', 'auth_deletion_pending']) {
    const guard = createAccountDeletionSyncGuard({
      supabaseUrl: 'https://example.test',
      anonKey: 'anon',
      fetchImpl: async () => ({ ok: true, json: async () => [{ status }] })
    });
    const res = createResponse();
    let nextCalled = false;
    await guard({ auth: authA }, res, () => { nextCalled = true; });
    assert.equal(res.statusCode, 423, `status=${status} must block`);
    assert.equal(nextCalled, false);
  }

  for (const rows of [[], [{ status: 'completed' }]]) {
    const guard = createAccountDeletionSyncGuard({
      supabaseUrl: 'https://example.test',
      anonKey: 'anon',
      fetchImpl: async () => ({ ok: true, json: async () => rows })
    });
    const res = createResponse();
    let nextCalled = false;
    await guard({ auth: authA }, res, () => { nextCalled = true; });
    assert.equal(nextCalled, true, `rows=${JSON.stringify(rows)} must allow sync through`);
  }
});

test('the sync guard fails open (never blocks sync) on its own network/config errors', async () => {
  const guard = createAccountDeletionSyncGuard({
    supabaseUrl: 'https://example.test',
    anonKey: 'anon',
    fetchImpl: async () => { throw new Error('network blip'); }
  });
  const res = createResponse();
  let nextCalled = false;
  await guard({ auth: authA }, res, () => { nextCalled = true; });
  assert.equal(nextCalled, true);

  const unconfigured = createAccountDeletionSyncGuard({ supabaseUrl: '', anonKey: '', fetchImpl: async () => ({ ok: true, json: async () => [] }) });
  const res2 = createResponse();
  let nextCalled2 = false;
  await unconfigured({ auth: authA }, res2, () => { nextCalled2 = true; });
  assert.equal(nextCalled2, true);
});

// ── 15. pending mutation not applied ───────────────────────────────────────
// Enforced by the sync guard test above (423 before the sync handler ever runs).

// ── 16. old token rejected after completion ────────────────────────────────
// This is an Auth-provider-level guarantee (a deleted Supabase Auth user's
// existing JWT is rejected by Supabase's own token verification once the
// user record is gone) — not something this backend's own code re-implements
// or can meaningfully unit-test without a real Supabase Auth instance; see
// docs/PHASE2D2_VALIDATION.md for the hosted-development check of this.

// ── 17. no service-role leakage ────────────────────────────────────────────

test('the user-scoped repository never touches the service-role key, even if one is configured', () => {
  const { createSupabaseAccountDeletionRepository } = require('../src/server/account/deletion-repository');
  const seenHeaders = [];
  const repo = createSupabaseAccountDeletionRepository({
    supabaseUrl: 'https://example.test',
    anonKey: 'anon-key-value',
    fetchImpl: async (url, init) => { seenHeaders.push(init.headers); return { ok: true, json: async () => ({ canDelete: true }) }; }
  });
  return repo.getPreview({ accessToken: 'user-token' }).then(() => {
    assert.equal(seenHeaders[0].apikey, 'anon-key-value');
    assert.equal(seenHeaders[0].Authorization, 'Bearer user-token');
    assert.equal(JSON.stringify(seenHeaders).toLowerCase().includes('service_role'), false);
  });
});

test('the confirm route never accepts or forwards a client-supplied service-role-shaped value', async () => {
  const app = createFakeApp();
  const nonceStore = createNonceStore();
  const nonce = nonceStore.issue(userA);
  let seenRequestDeletionArgs;
  registerAccountDeletionRoutes(app, baseDeps({
    nonceStore,
    repository: fakeRepository({ requestDeletion: async (args) => { seenRequestDeletionArgs = args; return { status: 'business_data_cleaned' }; } }),
    admin: fakeAdmin()
  }));
  await app.call('POST', '/api/account/delete/confirm', {
    auth: authA,
    body: { idempotencyKey: 'k1', confirmationVersion: 'fp-1', deletionNonce: nonce, serviceRoleKey: 'sneaky-value' }
  });
  assert.equal(Object.keys(seenRequestDeletionArgs).includes('serviceRoleKey'), false);
});

// ── 18. structured logs redacted ───────────────────────────────────────────

test('security-event logging never includes the raw userId, access token, or nonce', async () => {
  const app = createFakeApp();
  const nonceStore = createNonceStore();
  const nonce = nonceStore.issue(userA);
  const logs = [];
  registerAccountDeletionRoutes(app, baseDeps({
    nonceStore,
    repository: fakeRepository(),
    admin: fakeAdmin(),
    logger: { info: (fields) => logs.push(fields) }
  }));
  await app.call('POST', '/api/account/delete/preview', { auth: authA, body: {} });
  await app.call('POST', '/api/account/delete/confirm', {
    auth: authA, body: { idempotencyKey: 'k1', confirmationVersion: 'fp-1', deletionNonce: nonce }
  });
  const serialized = JSON.stringify(logs);
  assert.equal(serialized.includes(userA), false, 'raw userId must never appear in a log field');
  assert.equal(serialized.includes(authA.accessToken), false);
  assert.equal(serialized.includes(nonce), false);
});

// ── 19. rate limit applied ──────────────────────────────────────────────────

test('the rate limiter middleware is consulted and can block preview/confirm', async () => {
  const app = createFakeApp();
  registerAccountDeletionRoutes(app, baseDeps({
    repository: fakeRepository(),
    admin: fakeAdmin(),
    rateLimiter: (req, res) => res.status(429).json({ error: { code: 'rate_limited' } })
  }));
  const res = await app.call('POST', '/api/account/delete/preview', { auth: authA, body: {} });
  assert.equal(res.statusCode, 429);
});

// ── 20. version gate applied ────────────────────────────────────────────────
// Account deletion is not a /api/sync/* route and is not subject to the
// minimum-app-version gate by design (deleting one's account should not be
// blockable by an outdated client) — documented in docs/ACCOUNT_DELETION_DESIGN.md,
// not applicable here.

// ── 21. user A cannot delete user B / 22. no cross-household deletion ─────
// Enforced entirely server-side by auth.uid()-derived scoping inside the
// privileged SQL functions (there is no userId/householdId parameter on
// request_account_deletion at all) — verified in supabase/tests/account_deletion_test.sql,
// not re-provable at the Express layer since Express never receives or
// forwards a target user id for this operation.

// ── 23. deletion request RLS ────────────────────────────────────────────────
// Verified in supabase/tests/account_deletion_test.sql (RLS select-self policy).

// ── 24. cleanup/anonymization correct ──────────────────────────────────────
// Verified in supabase/tests/account_deletion_test.sql.

// ── 25. retry safe (nonce single-use + idempotency key) ────────────────────

test('a nonce can only be consumed once, even for a legitimate immediate retry', () => {
  const nonceStore = createNonceStore();
  const nonce = nonceStore.issue(userA);
  assert.equal(nonceStore.consume(userA, nonce), true);
  assert.equal(nonceStore.consume(userA, nonce), false, 'the same nonce must not be usable twice');
});

test('an expired nonce is rejected', async () => {
  const nonceStore = createNonceStore();
  const originalNow = Date.now;
  const nonce = nonceStore.issue(userA);
  Date.now = () => originalNow() + 10 * 60 * 1000;
  try {
    assert.equal(nonceStore.consume(userA, nonce), false);
  } finally {
    Date.now = originalNow;
  }
});

test('confirm rejects a missing or wrong nonce with REAUTHENTICATION_REQUIRED, without calling the repository', async () => {
  const app = createFakeApp();
  let called = false;
  registerAccountDeletionRoutes(app, baseDeps({
    nonceStore: createNonceStore(),
    repository: fakeRepository({ requestDeletion: async () => { called = true; return { status: 'business_data_cleaned' }; } }),
    admin: fakeAdmin()
  }));
  const res = await app.call('POST', '/api/account/delete/confirm', {
    auth: authA, body: { idempotencyKey: 'k1', confirmationVersion: 'fp-1', deletionNonce: 'wrong-or-missing' }
  });
  assert.equal(res.statusCode, 401);
  assert.equal(res.body.error.code, 'REAUTHENTICATION_REQUIRED');
  assert.equal(called, false);
});

test('confirm rejects a request missing any of idempotencyKey/confirmationVersion/deletionNonce', async () => {
  const app = createFakeApp();
  registerAccountDeletionRoutes(app, baseDeps({ repository: fakeRepository(), admin: fakeAdmin() }));
  for (const body of [{}, { idempotencyKey: 'k1' }, { idempotencyKey: 'k1', confirmationVersion: 'fp-1' }]) {
    const res = await app.call('POST', '/api/account/delete/confirm', { auth: authA, body });
    assert.equal(res.statusCode, 400);
  }
});

import assert from 'node:assert/strict';
import test from 'node:test';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';

const require = createRequire(import.meta.url);
const {
  registerAccountDeletionRoutes,
  createDeletionReauthenticationStore,
  createAccountDeletionAvailabilityGuard
} = require('../src/server/account/deletion-routes');
const { createAccountDeletionSyncGuard } = require('../src/server/account/deletion-sync-guard');
const { AccountDeletionError } = require('../src/server/account/errors');
const { isAccountDeletionAdminConfigured } = require('../src/server/account/deletion-repository');
const { createReadyHandler } = require('../src/server/observability/health');
const serverSource = readFileSync(new URL('../server.js', import.meta.url), 'utf8');

const userA = '11111111-1111-4111-8111-111111111111';
const userB = '22222222-2222-4222-8222-222222222222';
const authA = {
  userId: userA,
  email: 'a@example.com',
  accessToken: 'token-a',
  authenticationMethods: [{ method: 'password', timestamp: Date.now() }]
};

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
    reauthenticationStore: overrides.reauthenticationStore || createDeletionReauthenticationStore(),
    rateLimiter: overrides.rateLimiter || ((req, res, next) => next()),
    isAdminConfigured: overrides.isAdminConfigured,
    logger: overrides.logger
  };
}

async function prepareReauthenticationProof(app, auth = authA, confirmationVersion = 'fp-1') {
  const preview = await app.call('POST', '/api/account/delete/preview', { auth, body: {} });
  assert.equal(preview.statusCode, 200);
  const reauthentication = await app.call('POST', '/api/account/delete/reauthenticate', {
    auth,
    body: { confirmationVersion }
  });
  assert.equal(reauthentication.statusCode, 200);
  return reauthentication.body.reauthenticationProof;
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

// ── 0. deployment capability gate ────────────────────────────────────────

test('account-deletion Admin capability requires server-only URL, service-role key, and fetch support', () => {
  assert.equal(isAccountDeletionAdminConfigured({ supabaseUrl: 'https://example.test', serviceRoleKey: '', fetchImpl: async () => {} }), false);
  assert.equal(isAccountDeletionAdminConfigured({ supabaseUrl: '', serviceRoleKey: 'server-only-key', fetchImpl: async () => {} }), false);
  assert.equal(isAccountDeletionAdminConfigured({ supabaseUrl: 'https://example.test', serviceRoleKey: 'server-only-key', fetchImpl: null }), false);
  assert.equal(isAccountDeletionAdminConfigured({ supabaseUrl: 'https://example.test', serviceRoleKey: 'server-only-key', fetchImpl: async () => {} }), true);
});

test('missing Admin capability fails closed before preview, transfer, or confirm can create deletion state', async () => {
  const app = createFakeApp();
  let available = false;
  let previewCalls = 0;
  let transferCalls = 0;
  let requestDeletionCalls = 0;
  let authAdminCalls = 0;

  registerAccountDeletionRoutes(app, baseDeps({
    isAdminConfigured: () => available,
    repository: fakeRepository({
      getPreview: async () => { previewCalls += 1; return fakeRepository().getPreview(); },
      transferOwnership: async () => { transferCalls += 1; return { status: 'transferred' }; },
      requestDeletion: async () => { requestDeletionCalls += 1; return { status: 'business_data_cleaned' }; }
    }),
    admin: fakeAdmin({ deleteAuthUser: async () => { authAdminCalls += 1; return { deleted: true, alreadyGone: false }; } })
  }));

  const preview = await app.call('POST', '/api/account/delete/preview', { auth: authA, body: {} });
  const transfer = await app.call('POST', '/api/account/transfer-ownership', {
    auth: authA, body: { householdId: 'hh-1', newOwnerUserId: userB }
  });
  const reauthentication = await app.call('POST', '/api/account/delete/reauthenticate', {
    auth: authA, body: { confirmationVersion: 'fp-1' }
  });
  const confirm = await app.call('POST', '/api/account/delete/confirm', {
    auth: authA, body: { idempotencyKey: 'k1', confirmationVersion: 'fp-1', reauthenticationProof: 'not-a-proof' }
  });

  for (const response of [preview, transfer, reauthentication, confirm]) {
    assert.equal(response.statusCode, 503);
    assert.equal(response.body.error.code, 'ACCOUNT_DELETION_UNAVAILABLE');
    assert.equal(response.body.error.message, '账号删除服务当前不可用，请稍后再试。');
    assert.doesNotMatch(JSON.stringify(response.body), /service.role|key|token|stack/i);
  }
  assert.equal(previewCalls, 0);
  assert.equal(transferCalls, 0);
  assert.equal(requestDeletionCalls, 0, 'no deletion request means no business-data cleanup and no sync freeze');
  assert.equal(authAdminCalls, 0);

  // Once deployment configuration is fixed, the user must receive a real
  // provider-backed proof before the saga can begin.
  available = true;
  const proof = await prepareReauthenticationProof(app);
  const recovered = await app.call('POST', '/api/account/delete/confirm', {
    auth: authA, body: { idempotencyKey: 'k1', confirmationVersion: 'fp-1', reauthenticationProof: proof }
  });
  assert.equal(recovered.statusCode, 200);
  assert.equal(requestDeletionCalls, 1);
  assert.equal(authAdminCalls, 1);
});

test('the readiness response exposes account-deletion capability without exposing a server-only credential', async () => {
  const handler = createReadyHandler({
    checks: [
      { name: 'ordinary_service_config', run: async () => true },
      { name: 'account_deletion_configured', run: async () => false }
    ]
  });
  const res = createResponse();
  await handler({}, res);
  assert.equal(res.statusCode, 503);
  assert.equal(res.body.checks.ordinary_service_config, true);
  assert.equal(res.body.checks.account_deletion_configured, false);
  assert.doesNotMatch(JSON.stringify(res.body), /server-only-key|service.role|token|stack/i);
  assert.match(serverSource, /name: 'account_deletion_configured'/);
  assert.match(serverSource, /isAccountDeletionAdminConfigured/);
});

test('the availability middleware allows the original configured flow unchanged', async () => {
  const guard = createAccountDeletionAvailabilityGuard(() => true);
  const res = createResponse();
  let nextCalled = false;
  await guard({}, res, () => { nextCalled = true; });
  assert.equal(nextCalled, true);
  assert.equal(res.body, null);
});

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

test('preview returns only documented coarse fields, never a household id/email or reauthentication proof', async () => {
  const app = createFakeApp();
  registerAccountDeletionRoutes(app, baseDeps({ repository: fakeRepository(), admin: fakeAdmin() }));
  const res = await app.call('POST', '/api/account/delete/preview', { auth: authA, body: {} });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(Object.keys(res.body).sort(), [
    'blockingReason', 'canDelete', 'confirmationVersion', 'householdCount',
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
  registerAccountDeletionRoutes(app, baseDeps({
    repository: fakeRepository({ requestDeletion: async () => ({ status: 'rejected', errorCode: 'OWNERSHIP_TRANSFER_REQUIRED' }) }),
    admin: fakeAdmin()
  }));
  const proof = await prepareReauthenticationProof(app);
  const res = await app.call('POST', '/api/account/delete/confirm', {
    auth: authA, body: { idempotencyKey: 'k1', confirmationVersion: 'fp-1', reauthenticationProof: proof }
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
  registerAccountDeletionRoutes(app, baseDeps({
    repository: fakeRepository({
      getPreview: async () => ({
        canDelete: true, blockingReason: null, householdCount: 1, ownedHouseholdCount: 0,
        requiresOwnershipTransfer: false, requiresHouseholdDeletion: false,
        pendingMutationCountBucket: '0', confirmationVersion: 'stale-fp'
      }),
      requestDeletion: async () => ({ status: 'rejected', errorCode: 'STALE_DELETION_PREVIEW' })
    }),
    admin: fakeAdmin()
  }));
  const proof = await prepareReauthenticationProof(app, authA, 'stale-fp');
  const res = await app.call('POST', '/api/account/delete/confirm', {
    auth: authA, body: { idempotencyKey: 'k1', confirmationVersion: 'stale-fp', reauthenticationProof: proof }
  });
  assert.equal(res.statusCode, 409);
  assert.equal(res.body.error.code, 'STALE_DELETION_PREVIEW');
});

// ── 10. duplicate confirm idempotent ───────────────────────────────────────

test('a duplicate confirm that the repository reports as already completed returns success without calling admin', async () => {
  const app = createFakeApp();
  let adminCalled = false;
  registerAccountDeletionRoutes(app, baseDeps({
    repository: fakeRepository({ requestDeletion: async () => ({ status: 'completed', errorCode: null }) }),
    admin: fakeAdmin({ deleteAuthUser: async () => { adminCalled = true; return { deleted: true }; } })
  }));
  const proof = await prepareReauthenticationProof(app);
  const res = await app.call('POST', '/api/account/delete/confirm', {
    auth: authA, body: { idempotencyKey: 'k1', confirmationVersion: 'fp-1', reauthenticationProof: proof }
  });
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.status, 'completed');
  assert.equal(adminCalled, false, 'an already-completed deletion must not re-invoke the Auth admin API');
});

// ── 11. failed Auth deletion recoverable / 12. failed DB cleanup recoverable / 13. partial state detectable ──

test('a failed Auth admin delete returns 202 auth_deletion_pending, not a hard failure', async () => {
  const app = createFakeApp();
  let markFinalizedArgs;
  registerAccountDeletionRoutes(app, baseDeps({
    repository: fakeRepository(),
    admin: fakeAdmin({
      deleteAuthUser: async () => ({ deleted: false, alreadyGone: false }),
      markFinalized: async (args) => { markFinalizedArgs = args; return { status: 'auth_deletion_pending' }; }
    })
  }));
  const proof = await prepareReauthenticationProof(app);
  const res = await app.call('POST', '/api/account/delete/confirm', {
    auth: authA, body: { idempotencyKey: 'k1', confirmationVersion: 'fp-1', reauthenticationProof: proof }
  });
  assert.equal(res.statusCode, 202);
  assert.equal(res.body.status, 'auth_deletion_pending');
  assert.equal(markFinalizedArgs.authDeleted, false);
});

test('a repository failure during business-data cleanup never calls the Auth admin API', async () => {
  const app = createFakeApp();
  let adminCalled = false;
  registerAccountDeletionRoutes(app, baseDeps({
    repository: fakeRepository({ requestDeletion: async () => { throw new AccountDeletionError('account_deletion_rpc_failed', 'x', 502); } }),
    admin: fakeAdmin({ deleteAuthUser: async () => { adminCalled = true; return { deleted: true }; } })
  }));
  const proof = await prepareReauthenticationProof(app);
  const res = await app.call('POST', '/api/account/delete/confirm', {
    auth: authA, body: { idempotencyKey: 'k1', confirmationVersion: 'fp-1', reauthenticationProof: proof }
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
  let seenRequestDeletionArgs;
  registerAccountDeletionRoutes(app, baseDeps({
    repository: fakeRepository({ requestDeletion: async (args) => { seenRequestDeletionArgs = args; return { status: 'business_data_cleaned' }; } }),
    admin: fakeAdmin()
  }));
  const proof = await prepareReauthenticationProof(app);
  await app.call('POST', '/api/account/delete/confirm', {
    auth: authA,
    body: { idempotencyKey: 'k1', confirmationVersion: 'fp-1', reauthenticationProof: proof, serviceRoleKey: 'sneaky-value' }
  });
  assert.equal(Object.keys(seenRequestDeletionArgs).includes('serviceRoleKey'), false);
});

// ── 18. structured logs redacted ───────────────────────────────────────────

test('security-event logging never includes the raw userId, access token, or reauthentication proof', async () => {
  const app = createFakeApp();
  const logs = [];
  registerAccountDeletionRoutes(app, baseDeps({
    repository: fakeRepository(),
    admin: fakeAdmin(),
    logger: { info: (fields) => logs.push(fields) }
  }));
  const proof = await prepareReauthenticationProof(app);
  await app.call('POST', '/api/account/delete/confirm', {
    auth: authA, body: { idempotencyKey: 'k1', confirmationVersion: 'fp-1', reauthenticationProof: proof }
  });
  const serialized = JSON.stringify(logs);
  assert.equal(serialized.includes(userA), false, 'raw userId must never appear in a log field');
  assert.equal(serialized.includes(authA.accessToken), false);
  assert.equal(serialized.includes(proof), false);
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

// ── 25. real reauthentication proof — single-use, bounded and side-effect safe ──

test('ordinary sessions and token refreshes cannot obtain a deletion proof', async () => {
  const app = createFakeApp();
  let called = false;
  registerAccountDeletionRoutes(app, baseDeps({
    repository: fakeRepository({ requestDeletion: async () => { called = true; return { status: 'business_data_cleaned' }; } }),
    admin: fakeAdmin()
  }));
  const oldPasswordSession = {
    ...authA,
    // A token refresh may have a new `iat`, but Supabase AMR retains this
    // original password-authentication time. It must not bypass reauth.
    issuedAt: Date.now(),
    authenticationMethods: [{ method: 'password', timestamp: Date.now() - 10 * 60 * 1000 }]
  };
  await app.call('POST', '/api/account/delete/preview', { auth: oldPasswordSession, body: {} });
  const reauth = await app.call('POST', '/api/account/delete/reauthenticate', {
    auth: oldPasswordSession, body: { confirmationVersion: 'fp-1' }
  });
  assert.equal(reauth.statusCode, 401);
  assert.equal(reauth.body.error.code, 'ACCOUNT_DELETION_REAUTH_FAILED');
  assert.equal(called, false);
});

test('proof is bound to the current user and fingerprint, expires, and is single-use', () => {
  let currentTime = 1_000_000_000_000;
  const store = createDeletionReauthenticationStore({ now: () => currentTime, ttlMs: 1_000 });
  store.issuePreview(userA, 'fp-1');
  const issued = store.issueProof({
    userId: userA,
    fingerprint: 'fp-1',
    authenticationMethods: [{ method: 'password', timestamp: currentTime / 1000 }]
  });
  assert.ok(issued.proof);
  assert.equal(store.consumeProof({ userId: userB, fingerprint: 'fp-1', proof: issued.proof }).valid, undefined);
  assert.equal(store.consumeProof({ userId: userA, fingerprint: 'fp-1', proof: issued.proof }).valid, true);
  assert.equal(store.consumeProof({ userId: userA, fingerprint: 'fp-1', proof: issued.proof }).error, 'required');

  store.issuePreview(userA, 'fp-1');
  const expiring = store.issueProof({ userId: userA, fingerprint: 'fp-1', authenticationMethods: [{ method: 'password', timestamp: currentTime / 1000 }] });
  currentTime += 1_001;
  assert.equal(store.consumeProof({ userId: userA, fingerprint: 'fp-1', proof: expiring.proof }).error, 'expired');
});

test('confirm rejects a missing or wrong reauthentication proof without calling the repository', async () => {
  const app = createFakeApp();
  let called = false;
  registerAccountDeletionRoutes(app, baseDeps({
    repository: fakeRepository({ requestDeletion: async () => { called = true; return { status: 'business_data_cleaned' }; } }),
    admin: fakeAdmin()
  }));
  const res = await app.call('POST', '/api/account/delete/confirm', {
    auth: authA, body: { idempotencyKey: 'k1', confirmationVersion: 'fp-1', reauthenticationProof: 'wrong-or-missing' }
  });
  assert.equal(res.statusCode, 401);
  assert.equal(res.body.error.code, 'ACCOUNT_DELETION_REAUTH_REQUIRED');
  assert.equal(called, false);
});

test('a proof cannot be used for a different preview fingerprint or replayed after a failed confirm', async () => {
  const app = createFakeApp();
  let deletionRequests = 0;
  registerAccountDeletionRoutes(app, baseDeps({
    repository: fakeRepository({ requestDeletion: async () => { deletionRequests += 1; return { status: 'business_data_cleaned' }; } }),
    admin: fakeAdmin()
  }));
  const proof = await prepareReauthenticationProof(app);
  const wrongFingerprint = await app.call('POST', '/api/account/delete/confirm', {
    auth: authA,
    body: { idempotencyKey: 'k1', confirmationVersion: 'other-preview', reauthenticationProof: proof }
  });
  assert.equal(wrongFingerprint.statusCode, 401);
  assert.equal(wrongFingerprint.body.error.code, 'ACCOUNT_DELETION_REAUTH_FAILED');
  const replay = await app.call('POST', '/api/account/delete/confirm', {
    auth: authA,
    body: { idempotencyKey: 'k1', confirmationVersion: 'fp-1', reauthenticationProof: proof }
  });
  assert.equal(replay.statusCode, 401);
  assert.equal(replay.body.error.code, 'ACCOUNT_DELETION_REAUTH_REQUIRED');
  assert.equal(deletionRequests, 0);
});

test('confirm rejects a request missing any of idempotencyKey/confirmationVersion/reauthenticationProof', async () => {
  const app = createFakeApp();
  registerAccountDeletionRoutes(app, baseDeps({ repository: fakeRepository(), admin: fakeAdmin() }));
  for (const body of [{}, { idempotencyKey: 'k1' }, { idempotencyKey: 'k1', confirmationVersion: 'fp-1' }]) {
    const res = await app.call('POST', '/api/account/delete/confirm', { auth: authA, body });
    assert.equal(res.statusCode, 400);
  }
});

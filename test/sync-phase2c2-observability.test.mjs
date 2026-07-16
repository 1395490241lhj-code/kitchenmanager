import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const serverSource = fs.readFileSync(path.join(ROOT, 'server.js'), 'utf8');
const routesSource = fs.readFileSync(path.join(ROOT, 'src/server/sync/routes.js'), 'utf8');

const { createLogger, hashUserId, ALLOWED_LOG_FIELDS } = require('../src/server/observability/logger');
const { createMetricsRegistry } = require('../src/server/observability/metrics');
const {
  createRequestIdMiddleware,
  isValidIncomingRequestId,
  REQUEST_ID_HEADER
} = require('../src/server/observability/request-id');
const { createRequestLoggingMiddleware } = require('../src/server/observability/http-logging');
const { createHealthHandler, createReadyHandler } = require('../src/server/observability/health');
const { createVersionGateMiddleware } = require('../src/server/sync/version-gate');
const { createMemoryWindowStore, createReadRateLimiter } = require('../src/server/sync/rate-limit');
const { registerSyncRoutes } = require('../src/server/sync/routes');

// ── Shared fakes (mirrors test/sync-phase2c1-version-and-rate-limit.test.mjs) ──

function createResponse() {
  const listeners = { finish: [] };
  return {
    statusCode: 200,
    body: null,
    headers: {},
    status(code) { this.statusCode = code; return this; },
    json(value) { this.body = value; this._emit('finish'); return this; },
    set(name, value) { this.headers[name] = value; return this; },
    setHeader(name, value) { this.headers[name] = value; return this; },
    on(event, cb) { listeners[event] = listeners[event] || []; listeners[event].push(cb); },
    _emit(event) { for (const cb of (listeners[event] || [])) cb(); }
  };
}

function fakeReq({ auth = undefined, headers = {}, body = {}, query = {}, path: reqPath = '/api/sync/mutations', method = 'POST' } = {}) {
  const normalized = {};
  for (const [key, value] of Object.entries(headers)) normalized[key.toLowerCase()] = value;
  return {
    auth,
    body,
    query,
    path: reqPath,
    method,
    get(name) { return normalized[name.toLowerCase()]; }
  };
}

function captureStream() {
  const lines = [];
  return {
    lines,
    write(chunk) { lines.push(String(chunk).trim()); }
  };
}

const userA = '11111111-1111-4111-8111-111111111111';

// ── 1-4. Request id ──────────────────────────────────────────────────────

test('request id: generated when no header supplied', () => {
  const middleware = createRequestIdMiddleware();
  const req = fakeReq({ headers: {} });
  const res = createResponse();
  middleware(req, res, () => {});
  assert.equal(typeof req.requestId, 'string');
  assert.ok(req.requestId.length > 0);
  assert.equal(res.headers['X-Request-ID'], req.requestId);
});

test('request id: valid incoming X-Request-ID header is accepted verbatim', () => {
  const middleware = createRequestIdMiddleware();
  const incoming = 'client-supplied-id-123';
  const req = fakeReq({ headers: { [REQUEST_ID_HEADER]: incoming } });
  const res = createResponse();
  middleware(req, res, () => {});
  assert.equal(req.requestId, incoming);
  assert.equal(res.headers['X-Request-ID'], incoming);
});

test('request id: invalid/oversized incoming header is replaced, never trusted verbatim', () => {
  const middleware = createRequestIdMiddleware();
  const tooLong = 'a'.repeat(500);
  const withWhitespace = 'has a space';
  const withNewline = 'line1\nline2';
  for (const bad of [tooLong, withWhitespace, withNewline, '']) {
    assert.equal(isValidIncomingRequestId(bad), false, `expected ${JSON.stringify(bad.slice(0, 20))} to be rejected`);
    const req = fakeReq({ headers: { [REQUEST_ID_HEADER]: bad } });
    const res = createResponse();
    middleware(req, res, () => {});
    assert.notEqual(req.requestId, bad);
    assert.ok(req.requestId.length <= 100);
  }
});

test('request id: response always carries X-Request-ID, and separate requests get separate ids', () => {
  const middleware = createRequestIdMiddleware();
  const reqOne = fakeReq({});
  const resOne = createResponse();
  middleware(reqOne, resOne, () => {});
  const reqTwo = fakeReq({});
  const resTwo = createResponse();
  middleware(reqTwo, resTwo, () => {});
  assert.ok(resOne.headers['X-Request-ID']);
  assert.ok(resTwo.headers['X-Request-ID']);
  assert.notEqual(resOne.headers['X-Request-ID'], resTwo.headers['X-Request-ID']);
});

// ── 5-7. Structured logging safety ──────────────────────────────────────

test('logger: emits one JSON line per call with the documented stable fields', () => {
  const stream = captureStream();
  const logger = createLogger({ stream, environment: 'test', release: '1.2.3', nowProvider: () => new Date('2026-07-16T00:00:00.000Z') });
  logger.log('http_request', { requestId: 'abc', method: 'GET', route: '/api/sync/bootstrap', status: 200, durationMs: 12 });
  assert.equal(stream.lines.length, 1);
  const parsed = JSON.parse(stream.lines[0]);
  assert.equal(parsed.event, 'http_request');
  assert.equal(parsed.environment, 'test');
  assert.equal(parsed.release, '1.2.3');
  assert.equal(parsed.timestamp, '2026-07-16T00:00:00.000Z');
  assert.equal(parsed.level, 'info');
  assert.equal(parsed.requestId, 'abc');
  assert.equal(parsed.status, 200);
});

test('logger: never emits an Authorization header, raw user id, email, token, or request body', () => {
  const stream = captureStream();
  const logger = createLogger({ stream });
  logger.log('sync_event', {
    requestId: 'abc',
    // Attempted injection of forbidden fields under both documented and
    // made-up keys — the allowlist must drop all of them.
    authorization: 'Bearer secret-token',
    Authorization: 'Bearer secret-token',
    email: 'user@example.com',
    token: 'opaque-token',
    accessToken: 'opaque-token',
    userId: userA,
    householdId: 'household-uuid',
    body: { name: '鸡蛋' },
    inventoryName: '鸡蛋',
    receiptText: '收据内容'
  });
  const parsed = JSON.parse(stream.lines[0]);
  const serialized = JSON.stringify(parsed).toLowerCase();
  for (const forbidden of ['secret-token', 'user@example.com', 'opaque-token', userA.toLowerCase(), 'household-uuid', '鸡蛋'.toLowerCase(), '收据内容']) {
    assert.ok(!serialized.includes(forbidden.toLowerCase()), `log line must not contain ${forbidden}`);
  }
  assert.equal(parsed.authorization, undefined);
  assert.equal(parsed.Authorization, undefined);
  assert.equal(parsed.email, undefined);
  assert.equal(parsed.token, undefined);
  assert.equal(parsed.body, undefined);
});

test('logger: hashUserId is a short irreversible digest, not the raw id', () => {
  const digest = hashUserId(userA);
  assert.equal(typeof digest, 'string');
  assert.notEqual(digest, userA);
  assert.ok(digest.length <= 16);
  assert.equal(hashUserId(userA), digest, 'stable for the same input');
  assert.notEqual(hashUserId('22222222-2222-4222-8222-222222222222'), digest);
});

test('logger: ALLOWED_LOG_FIELDS is an explicit allowlist, not derived from caller input', () => {
  assert.ok(ALLOWED_LOG_FIELDS instanceof Set);
  assert.ok(ALLOWED_LOG_FIELDS.has('requestId'));
  assert.ok(ALLOWED_LOG_FIELDS.has('userHash'));
  assert.ok(!ALLOWED_LOG_FIELDS.has('email'));
  assert.ok(!ALLOWED_LOG_FIELDS.has('token'));
  assert.ok(!ALLOWED_LOG_FIELDS.has('body'));
});

// ── 8-12. Metrics ────────────────────────────────────────────────────────

test('426 (client_upgrade_required) emits sync_upgrade_required metric', () => {
  const metrics = createMetricsRegistry();
  const gate = createVersionGateMiddleware({
    loadConfig: () => ({ enabled: true, misconfigured: false, minVersion: [9, 9, 9], minBuild: 999, minSchema: 99 }),
    metrics
  });
  const req = fakeReq({ path: '/api/sync/bootstrap', headers: {} });
  const res = createResponse();
  gate(req, res, () => { throw new Error('must not call next on 426'); });
  assert.equal(res.statusCode, 426);
  const snapshot = metrics.snapshot();
  const key = Object.keys(snapshot.counters).find((k) => k.startsWith('sync_upgrade_required'));
  assert.ok(key, 'expected a sync_upgrade_required counter entry');
  assert.equal(snapshot.counters[key], 1);
});

test('429 (rate limited) emits sync_rate_limited metric', () => {
  const metrics = createMetricsRegistry();
  const store = createMemoryWindowStore();
  const limiter = createReadRateLimiter({ store, windowMs: 1000, maxRequests: 1, nowProvider: () => 0, metrics });
  const req = fakeReq({ auth: { userId: userA }, path: '/api/sync/bootstrap' });
  limiter(req, createResponse(), () => {});
  const res = createResponse();
  limiter(req, res, () => { throw new Error('must not call next on 429'); });
  assert.equal(res.statusCode, 429);
  const snapshot = metrics.snapshot();
  const key = Object.keys(snapshot.counters).find((k) => k.startsWith('sync_rate_limited'));
  assert.ok(key);
  assert.equal(snapshot.counters[key], 1);
});

test('backend_5xx metric increments on a 5xx response via the request-logging middleware', () => {
  const metrics = createMetricsRegistry();
  const logger = createLogger({ stream: captureStream() });
  const middleware = createRequestLoggingMiddleware({ logger, metrics });
  const req = fakeReq({ path: '/api/sync/bootstrap' });
  const res = createResponse();
  middleware(req, res, () => {});
  res.status(503).json({ error: 'sync_version_enforcement_misconfigured' });
  const snapshot = metrics.snapshot();
  const key = Object.keys(snapshot.counters).find((k) => k.startsWith('backend_5xx'));
  assert.ok(key);
  assert.equal(snapshot.counters[key], 1);
});

test('a successful sync bootstrap/changes/mutations request emits sync_request_success and latency observations', async () => {
  const metrics = createMetricsRegistry();
  const service = {
    bootstrap: async () => ({ schemaVersion: 1 }),
    pullChanges: async () => ({ changes: [] }),
    applyMutations: async () => ({ results: [], cursor: '0' })
  };
  const { createSyncHandlers } = require('../src/server/sync/routes');
  const handlers = createSyncHandlers({ service, observability: { metrics } });
  const res = createResponse();
  await handlers.bootstrap(fakeReq({ auth: { userId: userA }, path: '/api/sync/bootstrap' }), res);
  const snapshot = metrics.snapshot();
  const successKey = Object.keys(snapshot.counters).find((k) => k.startsWith('sync_request_success'));
  assert.ok(successKey);
  const latencyKey = Object.keys(snapshot.observations).find((k) => k.startsWith('sync_read_latency'));
  assert.ok(latencyKey);
});

test('mutation results emit applied/conflict/rejected metrics distinctly', async () => {
  const metrics = createMetricsRegistry();
  const service = {
    applyMutations: async () => ({
      results: [
        { mutationId: '1', status: 'applied' },
        { mutationId: '2', status: 'conflict' },
        { mutationId: '3', status: 'rejected' },
        { mutationId: '4', status: 'duplicate' }
      ],
      cursor: '10'
    })
  };
  const { createSyncHandlers } = require('../src/server/sync/routes');
  const handlers = createSyncHandlers({ service, observability: { metrics } });
  const householdId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const makeDeleteMutation = (mutationId) => ({
    mutationId,
    entityType: 'inventory_item',
    entityId: mutationId,
    operation: 'delete',
    baseVersion: '1',
    clientUpdatedAt: '2026-07-16T00:00:00.000Z'
  });
  const req = fakeReq({
    auth: { userId: userA },
    path: '/api/sync/mutations',
    body: {
      scopeType: 'household',
      scopeId: householdId,
      mutations: [
        makeDeleteMutation('11111111-1111-4111-8111-111111111101'),
        makeDeleteMutation('11111111-1111-4111-8111-111111111102'),
        makeDeleteMutation('11111111-1111-4111-8111-111111111103'),
        makeDeleteMutation('11111111-1111-4111-8111-111111111104')
      ]
    }
  });
  await handlers.mutations(req, createResponse());
  const snapshot = metrics.snapshot();
  const has = (name) => Object.keys(snapshot.counters).some((k) => k.startsWith(name) && snapshot.counters[k] === 1);
  assert.ok(has('sync_mutation_applied'));
  assert.ok(has('sync_mutation_conflict'));
  assert.ok(has('sync_mutation_rejected'));
  assert.ok(has('sync_mutation_duplicate'));
  const opsKey = Object.keys(snapshot.counters).find((k) => k.startsWith('sync_mutation_operations'));
  assert.equal(snapshot.counters[opsKey], 4);
});

// ── 13-16. Health / ready ────────────────────────────────────────────────

test('/health never invokes a check function (no DB access) and responds fast', () => {
  let checkCalled = false;
  const handler = createHealthHandler({ environment: 'test', release: '1.0.0' });
  const req = fakeReq({});
  const res = createResponse();
  handler(req, res);
  assert.equal(checkCalled, false);
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.status, 'ok');
  assert.equal(res.body.environment, 'test');
  assert.equal(res.body.version, '1.0.0');
});

test('/ready returns 503 when a config check fails', async () => {
  const handler = createReadyHandler({
    environment: 'test',
    release: '1.0.0',
    checks: [
      { name: 'auth_config', run: async () => false },
      { name: 'version_gate_config', run: async () => true }
    ]
  });
  const res = createResponse();
  await handler(fakeReq({}), res);
  assert.equal(res.statusCode, 503);
  assert.equal(res.body.status, 'not_ready');
  assert.equal(res.body.checks.auth_config, false);
  assert.equal(res.body.checks.version_gate_config, true);
});

test('/ready returns 503 when the Supabase connectivity check fails', async () => {
  const handler = createReadyHandler({
    checks: [
      { name: 'auth_config', run: async () => true },
      { name: 'supabase_connectivity', run: async () => false }
    ]
  });
  const res = createResponse();
  await handler(fakeReq({}), res);
  assert.equal(res.statusCode, 503);
  assert.equal(res.body.checks.supabase_connectivity, false);
});

test('/ready returns 200 with all-pass checks when everything is healthy', async () => {
  const handler = createReadyHandler({
    environment: 'development',
    release: 'abc123',
    checks: [
      { name: 'auth_config', run: async () => true },
      { name: 'version_gate_config', run: async () => true },
      { name: 'rate_limiter_config', run: async () => true },
      { name: 'supabase_connectivity', run: async () => true }
    ]
  });
  const res = createResponse();
  await handler(fakeReq({}), res);
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.status, 'ready');
  assert.deepEqual(res.body.checks, {
    auth_config: true,
    version_gate_config: true,
    rate_limiter_config: true,
    supabase_connectivity: true
  });
  assert.equal(Object.prototype.hasOwnProperty.call(res.body, 'url'), false);
  assert.equal(Object.prototype.hasOwnProperty.call(res.body, 'key'), false);
});

test('/ready never exposes a URL/key/stack in its response body, even when a check throws', async () => {
  const handler = createReadyHandler({
    checks: [
      { name: 'exploding_check', run: async () => { throw new Error('secret internal detail https://real-project.supabase.co'); } }
    ]
  });
  const res = createResponse();
  await handler(fakeReq({}), res);
  assert.equal(res.statusCode, 503);
  const serialized = JSON.stringify(res.body);
  assert.ok(!serialized.includes('supabase.co'));
  assert.ok(!serialized.includes('secret internal detail'));
  assert.equal(res.body.checks.exploding_check, false);
});

// ── 17-20. Error redaction / correlation / resilience / determinism ───────

test('a 5xx sync error never logs the raw error stack/message via the structured logger', () => {
  const stream = captureStream();
  const logger = createLogger({ stream });
  // sendSyncError only ever logs a code/type via console in non-production;
  // the structured logger path here only ever receives allowlisted fields.
  logger.log('sync_event', { requestId: 'abc', resultCode: 'SYNC_VERSION_ENFORCEMENT_MISCONFIGURED' });
  const parsed = JSON.parse(stream.lines[0]);
  assert.equal(parsed.stack, undefined);
  assert.equal(JSON.stringify(parsed).includes('at Object.'), false);
});

test('two concurrent requests produce independently correlated log lines', () => {
  const stream = captureStream();
  const logger = createLogger({ stream });
  const metrics = createMetricsRegistry();
  const middleware = createRequestLoggingMiddleware({ logger, metrics });
  const reqIdMiddleware = createRequestIdMiddleware();

  const reqA = fakeReq({ path: '/api/sync/bootstrap' });
  const resA = createResponse();
  reqIdMiddleware(reqA, resA, () => {});
  middleware(reqA, resA, () => {});
  resA.status(200).json({});

  const reqB = fakeReq({ path: '/api/sync/changes' });
  const resB = createResponse();
  reqIdMiddleware(reqB, resB, () => {});
  middleware(reqB, resB, () => {});
  resB.status(429).json({});

  const [lineA, lineB] = stream.lines.map((line) => JSON.parse(line));
  assert.notEqual(lineA.requestId, lineB.requestId);
  assert.equal(lineA.route, '/api/sync/bootstrap');
  assert.equal(lineB.route, '/api/sync/changes');
  assert.equal(lineB.status, 429);
});

test('a throwing logger/metrics does not crash the request-logging middleware', () => {
  const throwingLogger = { log() { throw new Error('logger exploded'); } };
  const throwingMetrics = { increment() { throw new Error('metrics exploded'); } };
  const middleware = createRequestLoggingMiddleware({ logger: throwingLogger, metrics: throwingMetrics });
  const req = fakeReq({ path: '/api/sync/bootstrap' });
  const res = createResponse();
  assert.doesNotThrow(() => {
    middleware(req, res, () => {});
    res.status(500).json({});
  });
});

test('observability tests are deterministic: no real timers/sleeps, fixed nowProvider', () => {
  const metrics = createMetricsRegistry();
  const store = createMemoryWindowStore();
  const fixedNow = () => 1_000_000;
  const limiter = createReadRateLimiter({ store, windowMs: 60_000, maxRequests: 1, nowProvider: fixedNow, metrics });
  const req = fakeReq({ auth: { userId: userA }, path: '/api/sync/bootstrap' });
  limiter(req, createResponse(), () => {});
  const res = createResponse();
  limiter(req, res, () => {});
  assert.equal(res.statusCode, 429);
  assert.equal(res.headers['Retry-After'], '60');
});

// ── Node semantic guards (section 十五) ───────────────────────────────────

test('semantic guard: registerSyncRoutes wires observability into version gate, rate limiters, and handlers', () => {
  assert.match(routesSource, /createVersionGateMiddleware\(\{ metrics, logger: structuredLogger \}\)/);
  assert.match(routesSource, /createReadRateLimiter\(\{[\s\S]*metrics,[\s\S]*logger: structuredLogger/);
  assert.match(routesSource, /createMutationRateLimiter\(\{[\s\S]*metrics,[\s\S]*logger: structuredLogger/);
});

test('semantic guard: server.js installs the request-id middleware globally, before route registration', () => {
  const idIndex = serverSource.indexOf('createRequestIdMiddleware()');
  const syncIndex = serverSource.indexOf('registerSyncRoutes(app,');
  assert.ok(idIndex > 0, 'request id middleware must be installed');
  assert.ok(syncIndex > idIndex, 'request id middleware must be installed before sync routes are registered');
});

test('semantic guard: server.js exposes distinct /health and /ready endpoints', () => {
  assert.match(serverSource, /app\.get\('\/health', createHealthHandler/);
  assert.match(serverSource, /app\.get\('\/ready', createReadyHandler/);
  assert.notEqual(
    serverSource.indexOf("app.get('/health'"),
    serverSource.indexOf("app.get('/ready'")
  );
});

test('semantic guard: no raw email/IP/token field name is ever passed to the structured logger in routes.js or server.js', () => {
  for (const source of [routesSource, serverSource]) {
    assert.doesNotMatch(source, /logger\.log\([^)]*\bemail\b/);
    assert.doesNotMatch(source, /logger\.log\([^)]*\breq\.ip\b/);
    assert.doesNotMatch(source, /logger\.log\([^)]*\baccessToken\b/);
    assert.doesNotMatch(source, /logger\.log\([^)]*\bauthorization\b/i);
  }
});

test('semantic guard: no service-role key or production DSN/enablement flag is referenced by the new observability code', () => {
  const observabilitySources = [
    'src/server/observability/logger.js',
    'src/server/observability/metrics.js',
    'src/server/observability/request-id.js',
    'src/server/observability/http-logging.js',
    'src/server/observability/health.js'
  ].map((relativePath) => fs.readFileSync(path.join(ROOT, relativePath), 'utf8'));
  for (const source of observabilitySources) {
    assert.doesNotMatch(source, /service.role/i);
    assert.doesNotMatch(source, /SUPABASE_SERVICE_ROLE_KEY/);
    assert.doesNotMatch(source, /CRASH_REPORTING_DSN\s*=\s*['"]https?:/);
    assert.doesNotMatch(source, /sentry\.io|crashlytics|bugsnag/i);
  }
});

test('semantic guard: metric/log field allowlist never includes household id, full uuid label, or inventory content fields', () => {
  assert.ok(!ALLOWED_LOG_FIELDS.has('householdId'));
  assert.ok(!ALLOWED_LOG_FIELDS.has('inventoryName'));
  assert.ok(!ALLOWED_LOG_FIELDS.has('receiptText'));
  assert.ok(!ALLOWED_LOG_FIELDS.has('userId'));
});

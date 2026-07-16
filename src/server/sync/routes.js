const { authenticateRequest, createRequireAuthRole } = require('../auth/jwt');
const { SyncError, toSyncError } = require('./errors');
const { createSyncService } = require('./service');
const { validateChangesQuery, validateMutationsRequest } = require('./validation');
const { createVersionGateMiddleware } = require('./version-gate');
const {
  createMemoryWindowStore,
  createReadRateLimiter,
  createMutationRateLimiter
} = require('./rate-limit');
const {
  SYNC_READ_RATE_LIMIT_WINDOW_MS,
  SYNC_READ_RATE_LIMIT_MAX,
  SYNC_MUTATION_RATE_LIMIT_WINDOW_MS,
  SYNC_MUTATION_RATE_LIMIT_MAX_REQUESTS,
  SYNC_MUTATION_OPERATION_RATE_LIMIT_WINDOW_MS,
  SYNC_MUTATION_OPERATION_RATE_LIMIT_MAX
} = require('../config');

function sendSyncError(res, error, logger = console) {
  const safe = toSyncError(error);
  if (safe.status >= 500 && process.env.NODE_ENV !== 'production') {
    logger.error(`[sync] request failed: code=${safe.code} type=${safe.name}`);
  }
  return res.status(safe.status).json({
    error: { code: safe.code, message: safe.message }
  });
}

// Phase 2C-2: `observability` is optional ({ metrics, logger }, both
// duck-typed with the same shape as src/server/observability/*). When
// omitted, handlers behave exactly as before Phase 2C-2 — this keeps every
// existing direct construction of createSyncHandlers()/registerSyncRoutes()
// (including Phase 2A/2C-1 tests) unaffected.
//
// Metrics only ever carry a route/status/result-shaped label, never a raw
// userId/email/token — see docs/BACKEND_OBSERVABILITY.md.
function createSyncHandlers({ service = createSyncService(), logger = console, observability = {} } = {}) {
  const { metrics } = observability;
  const nowProvider = observability.nowProvider || Date.now;

  function recordRequestOutcome({ routeCategory, latencyMetric, start, success }) {
    const durationMs = nowProvider() - start;
    metrics?.increment('sync_request_total', 1, { route: routeCategory });
    metrics?.increment(success ? 'sync_request_success' : 'sync_request_failure', 1, { route: routeCategory });
    metrics?.observe(latencyMetric, durationMs, { route: routeCategory });
  }

  function recordMutationResults(results) {
    if (!Array.isArray(results)) return;
    metrics?.increment('sync_mutation_operations', results.length);
    for (const result of results) {
      if (result?.status === 'applied') metrics?.increment('sync_mutation_applied');
      else if (result?.status === 'conflict') metrics?.increment('sync_mutation_conflict');
      else if (result?.status === 'rejected') metrics?.increment('sync_mutation_rejected');
      else if (result?.status === 'duplicate') metrics?.increment('sync_mutation_duplicate');
    }
  }

  return {
    bootstrap: async (req, res) => {
      const start = nowProvider();
      try {
        const result = await service.bootstrap({ auth: req.auth });
        recordRequestOutcome({ routeCategory: 'bootstrap', latencyMetric: 'sync_read_latency', start, success: true });
        return res.json(result);
      } catch (error) {
        recordRequestOutcome({ routeCategory: 'bootstrap', latencyMetric: 'sync_read_latency', start, success: false });
        return sendSyncError(res, error, logger);
      }
    },
    changes: async (req, res) => {
      const start = nowProvider();
      try {
        const input = validateChangesQuery(req.query || {});
        const result = await service.pullChanges({ auth: req.auth, input });
        recordRequestOutcome({ routeCategory: 'changes', latencyMetric: 'sync_read_latency', start, success: true });
        return res.json(result);
      } catch (error) {
        recordRequestOutcome({ routeCategory: 'changes', latencyMetric: 'sync_read_latency', start, success: false });
        return sendSyncError(res, error, logger);
      }
    },
    mutations: async (req, res) => {
      const start = nowProvider();
      try {
        const input = validateMutationsRequest(req.body);
        const result = await service.applyMutations({ auth: req.auth, input });
        recordRequestOutcome({ routeCategory: 'mutations', latencyMetric: 'sync_write_latency', start, success: true });
        recordMutationResults(result?.results);
        return res.json(result);
      } catch (error) {
        recordRequestOutcome({ routeCategory: 'mutations', latencyMetric: 'sync_write_latency', start, success: false });
        return sendSyncError(res, error, logger);
      }
    }
  };
}

function chain(...handlers) {
  return async function chainedHandler(req, res) {
    async function dispatch(index) {
      const handler = handlers[index];
      if (!handler) return undefined;
      let nextCalled = false;
      let nextPromise;
      const next = () => {
        if (nextCalled) throw new SyncError('middleware_error', '同步中间件重复调用 next。', 503);
        nextCalled = true;
        nextPromise = dispatch(index + 1);
        return nextPromise;
      };
      await handler(req, res, next);
      if (nextPromise) await nextPromise;
      return undefined;
    }
    return dispatch(0);
  };
}

// Middleware order (Phase 2C-1): auth -> role -> versionGate -> rateLimiter
// -> handler. Body-size gating already happens inside validation.js before
// any RPC call; scope validation (household membership, user-scope subject
// match) happens inside the handler's own service/RPC call, backed by RLS —
// there is no separate scope-validation middleware layer to insert before
// the handler, since that check requires the parsed, validated query/body
// the handler itself produces.
//
// A rejected request (426 from versionGate, 429 from a rate limiter) never
// reaches the handler at all, so it can never write a PendingMutation or a
// sync_mutations ledger row — enforced by placement, not a separate check.
function registerSyncRoutes(app, options = {}) {
  const handlers = createSyncHandlers(options);
  const auth = options.authenticate || authenticateRequest;
  const role = options.requireRole || createRequireAuthRole(['authenticated']);
  // Phase 2D-2: freezes /api/sync/* for a user whose account deletion is
  // underway (see src/server/account/deletion-sync-guard.js). Defaults to a
  // no-op passthrough so every existing caller/test of this module is
  // unaffected unless it opts in.
  const accountDeletionGuard = options.accountDeletionGuard || ((req, res, next) => next());
  const { metrics, logger: structuredLogger } = options.observability || {};
  const versionGate = options.versionGate || createVersionGateMiddleware({ metrics, logger: structuredLogger });

  const readStore = options.readRateLimitStore || createMemoryWindowStore();
  const readRateLimiter = options.readRateLimiter || createReadRateLimiter({
    store: readStore,
    windowMs: SYNC_READ_RATE_LIMIT_WINDOW_MS,
    maxRequests: SYNC_READ_RATE_LIMIT_MAX,
    metrics,
    logger: structuredLogger
  });

  const mutationStore = options.mutationRateLimitStore || createMemoryWindowStore();
  const mutationRateLimiter = options.mutationRateLimiter || createMutationRateLimiter({
    store: mutationStore,
    requestWindowMs: SYNC_MUTATION_RATE_LIMIT_WINDOW_MS,
    maxRequests: SYNC_MUTATION_RATE_LIMIT_MAX_REQUESTS,
    operationWindowMs: SYNC_MUTATION_OPERATION_RATE_LIMIT_WINDOW_MS,
    maxOperations: SYNC_MUTATION_OPERATION_RATE_LIMIT_MAX,
    metrics,
    logger: structuredLogger
  });

  app.get('/api/sync/bootstrap', chain(auth, role, accountDeletionGuard, versionGate, readRateLimiter, handlers.bootstrap));
  app.get('/api/sync/changes', chain(auth, role, accountDeletionGuard, versionGate, readRateLimiter, handlers.changes));
  app.post('/api/sync/mutations', chain(auth, role, accountDeletionGuard, versionGate, mutationRateLimiter, handlers.mutations));
  return handlers;
}

module.exports = { chain, createSyncHandlers, registerSyncRoutes, sendSyncError };

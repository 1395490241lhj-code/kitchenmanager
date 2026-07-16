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

function createSyncHandlers({ service = createSyncService(), logger = console } = {}) {
  return {
    bootstrap: async (req, res) => {
      try { return res.json(await service.bootstrap({ auth: req.auth })); }
      catch (error) { return sendSyncError(res, error, logger); }
    },
    changes: async (req, res) => {
      try {
        const input = validateChangesQuery(req.query || {});
        return res.json(await service.pullChanges({ auth: req.auth, input }));
      } catch (error) { return sendSyncError(res, error, logger); }
    },
    mutations: async (req, res) => {
      try {
        const input = validateMutationsRequest(req.body);
        return res.json(await service.applyMutations({ auth: req.auth, input }));
      } catch (error) { return sendSyncError(res, error, logger); }
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
  const versionGate = options.versionGate || createVersionGateMiddleware();

  const readStore = options.readRateLimitStore || createMemoryWindowStore();
  const readRateLimiter = options.readRateLimiter || createReadRateLimiter({
    store: readStore,
    windowMs: SYNC_READ_RATE_LIMIT_WINDOW_MS,
    maxRequests: SYNC_READ_RATE_LIMIT_MAX
  });

  const mutationStore = options.mutationRateLimitStore || createMemoryWindowStore();
  const mutationRateLimiter = options.mutationRateLimiter || createMutationRateLimiter({
    store: mutationStore,
    requestWindowMs: SYNC_MUTATION_RATE_LIMIT_WINDOW_MS,
    maxRequests: SYNC_MUTATION_RATE_LIMIT_MAX_REQUESTS,
    operationWindowMs: SYNC_MUTATION_OPERATION_RATE_LIMIT_WINDOW_MS,
    maxOperations: SYNC_MUTATION_OPERATION_RATE_LIMIT_MAX
  });

  app.get('/api/sync/bootstrap', chain(auth, role, versionGate, readRateLimiter, handlers.bootstrap));
  app.get('/api/sync/changes', chain(auth, role, versionGate, readRateLimiter, handlers.changes));
  app.post('/api/sync/mutations', chain(auth, role, versionGate, mutationRateLimiter, handlers.mutations));
  return handlers;
}

module.exports = { chain, createSyncHandlers, registerSyncRoutes, sendSyncError };

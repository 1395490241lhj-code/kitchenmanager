const { authenticateRequest, createRequireAuthRole } = require('../auth/jwt');
const { SyncError, toSyncError } = require('./errors');
const { createSyncService } = require('./service');
const { validateChangesQuery, validateMutationsRequest } = require('./validation');

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

function registerSyncRoutes(app, options = {}) {
  const handlers = createSyncHandlers(options);
  const auth = options.authenticate || authenticateRequest;
  const role = options.requireRole || createRequireAuthRole(['authenticated']);
  app.get('/api/sync/bootstrap', chain(auth, role, handlers.bootstrap));
  app.get('/api/sync/changes', chain(auth, role, handlers.changes));
  app.post('/api/sync/mutations', chain(auth, role, handlers.mutations));
  return handlers;
}

module.exports = { chain, createSyncHandlers, registerSyncRoutes, sendSyncError };

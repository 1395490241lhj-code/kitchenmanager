// Phase 2C-2 structured HTTP access logging. One line per request, emitted
// once on `finish` (never duplicated on error), independent of any
// route-specific business logging. A logger/metrics failure must never take
// down the request it was trying to observe — both are wrapped defensively.
function resolveAuthState(req, res) {
  if (req.auth) return 'authenticated';
  if (req.auth === null) return 'anonymous'; // optional-auth route, no token supplied
  if (res.statusCode === 401 || res.statusCode === 403) return 'invalid';
  return 'anonymous';
}

function createRequestLoggingMiddleware({ logger, metrics, nowProvider = () => Date.now() } = {}) {
  return function requestLoggingMiddleware(req, res, next) {
    const start = nowProvider();
    res.on('finish', () => {
      try {
        const durationMs = nowProvider() - start;
        const authState = resolveAuthState(req, res);
        logger?.log('http_request', {
          requestId: req.requestId,
          method: req.method,
          route: req.path,
          status: res.statusCode,
          durationMs,
          authState
        });
        if (res.statusCode >= 500) {
          metrics?.increment('backend_5xx', 1, { route: req.path });
        }
      } catch {
        // Never let an observability failure affect an already-finished
        // response or crash the process.
      }
    });
    next();
  };
}

module.exports = { createRequestLoggingMiddleware, resolveAuthState };

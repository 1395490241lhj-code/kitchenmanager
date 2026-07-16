// Rate limiting for /api/sync/* only. Never applied to any other route.
//
// Storage strategy (Phase 2C-1): an in-memory, per-process fixed-window
// counter. This is deliberately NOT safe across multiple Render instances or
// a process restart — each instance/restart starts every bucket back at
// zero. That is an accepted, documented limitation for Stage 1 (a small,
// known set of internal test accounts on what is today a single backend
// instance) — see docs/SYNC_API_RATE_LIMITING.md. Scaling to more than one
// backend instance requires a shared store (Redis/Upstash) behind the same
// `store` interface used here; this module never assumes memory is the only
// implementation.
//
// Identity: every bucket is keyed by the authenticated JWT subject
// (`req.auth.userId`, a stable UUID) — never email, never the raw
// Authorization header/token, never a device name, never an IP alone (a
// shared NAT/office network would otherwise collide innocent users
// together). A request that never reached `req.auth` (rejected earlier by
// auth/role middleware) never touches any bucket at all.

function createMemoryWindowStore() {
  const buckets = new Map();

  function consumeBy(key, windowMs, amount, now) {
    let bucket = buckets.get(key);
    if (!bucket || now - bucket.windowStart >= windowMs) {
      bucket = { windowStart: now, count: 0 };
      buckets.set(key, bucket);
    }
    bucket.count += amount;
    const retryAfterSeconds = Math.max(1, Math.ceil((bucket.windowStart + windowMs - now) / 1000));
    return { count: bucket.count, retryAfterSeconds };
  }

  return {
    consume(key, windowMs, now) { return consumeBy(key, windowMs, 1, now); },
    consumeBy,
    // Test/diagnostic only — never used by request-handling code.
    _size() { return buckets.size; },
    _clear() { buckets.clear(); }
  };
}

function sendRateLimited(res, retryAfterSeconds, { req, metrics, logger, routeCategory } = {}) {
  metrics?.increment('sync_rate_limited', 1, { route: req?.path });
  logger?.log('sync_rate_limited', {
    requestId: req?.requestId,
    route: req?.path,
    routeCategory,
    retryAfterSeconds,
    resultCode: 'SYNC_RATE_LIMITED'
  });
  res.set('Retry-After', String(retryAfterSeconds));
  return res.status(429).json({
    error: 'rate_limited',
    code: 'SYNC_RATE_LIMITED',
    message: 'Too many sync requests. Please try again shortly.',
    retryAfterSeconds
  });
}

// Keys by `userId + route path` so bootstrap/changes each get their own
// budget — a burst of `changes` pagination pages can never starve a later
// `bootstrap` call, and vice versa.
//
// `metrics`/`logger` (Phase 2C-2) are optional; only emitted on the 429
// path, and only with route/requestId/retryAfterSeconds — never the bucket
// key or userId itself.
function createReadRateLimiter({
  store = createMemoryWindowStore(),
  windowMs = 5 * 60 * 1000,
  maxRequests = 120,
  nowProvider = Date.now,
  metrics,
  logger
} = {}) {
  return function readRateLimiter(req, res, next) {
    const userId = req.auth?.userId;
    if (!userId) return next(); // defensive only — auth/role already reject this case
    const routeKey = req.route?.path || req.path;
    const key = `read:${userId}:${routeKey}`;
    const { count, retryAfterSeconds } = store.consume(key, windowMs, nowProvider());
    if (count > maxRequests) {
      return sendRateLimited(res, retryAfterSeconds, { req, metrics, logger, routeCategory: 'read' });
    }
    return next();
  };
}

// Two independent budgets per user: how many mutation *requests* they send,
// and how many total mutation *operations* those requests contain (a single
// request can batch up to 100 mutations). Either one tripping is a 429 —
// this stops both "many tiny requests" and "few huge batches" abuse shapes.
function createMutationRateLimiter({
  store = createMemoryWindowStore(),
  requestWindowMs = 5 * 60 * 1000,
  maxRequests = 40,
  operationWindowMs = 5 * 60 * 1000,
  maxOperations = 500,
  nowProvider = Date.now,
  metrics,
  logger
} = {}) {
  return function mutationRateLimiter(req, res, next) {
    const userId = req.auth?.userId;
    if (!userId) return next();
    const now = nowProvider();

    const requestKey = `mutreq:${userId}`;
    const requestResult = store.consume(requestKey, requestWindowMs, now);
    if (requestResult.count > maxRequests) {
      return sendRateLimited(res, requestResult.retryAfterSeconds, { req, metrics, logger, routeCategory: 'mutation' });
    }

    const operationCount = Array.isArray(req.body?.mutations) ? req.body.mutations.length : 0;
    const operationKey = `mutops:${userId}`;
    const operationResult = store.consumeBy(operationKey, operationWindowMs, operationCount, now);
    if (operationResult.count > maxOperations) {
      return sendRateLimited(res, operationResult.retryAfterSeconds, { req, metrics, logger, routeCategory: 'mutation' });
    }

    return next();
  };
}

module.exports = {
  createMemoryWindowStore,
  createReadRateLimiter,
  createMutationRateLimiter,
  sendRateLimited
};

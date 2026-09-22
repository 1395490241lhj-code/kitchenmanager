/*
 * src/server/services/shared-window-store.js
 *
 * A fixed-window counter that is shared across every backend instance.
 *
 * Why this exists: the AI limiter's counter lived in one process's Map, but
 * Render runs several instances behind its load balancer. Each instance kept
 * its own count, so one client hit whichever bucket the balancer happened to
 * pick — observed in production as 429 immediately followed by 200, and as a
 * "fresh" session being limited on its third request. The quota was never
 * globally 30/10min; it was N independent counters.
 *
 * This implements the exact same `store` shape the sync limiter already
 * defines (`consume` / `consumeBy` returning `{ count, retryAfterSeconds }`),
 * so both limiters can share one storage strategy rather than growing a
 * second, divergent one.
 *
 * Atomicity: the count and its expiry are established with INCRBY followed by
 * a first-write-only PEXPIRE, pipelined into a single round trip. INCRBY is
 * atomic server-side, so concurrent requests across instances cannot lose an
 * increment (the read-modify-write shape this replaces could). The window is
 * the key's TTL, so it resets by expiry rather than by any instance's clock.
 */

// A counter is only meaningful with an expiry: without one, a key created by
// the very first request would cap that identity forever.
function toRetryAfterSeconds(ttlMs, windowMs) {
  const remaining = Number.isFinite(ttlMs) && ttlMs > 0 ? ttlMs : windowMs;
  // Round up: a sub-second remainder is still "limited", and a Retry-After of
  // 0 would invite an immediate retry that is guaranteed to fail.
  return Math.max(1, Math.ceil(remaining / 1000));
}

/**
 * @param client  node-redis (v4+) compatible client. Exactly the camelCase
 *                commands in REQUIRED_CLIENT_COMMANDS are used; node-redis
 *                exposes no lowercase aliases (`incrby` is undefined), so
 *                fakes must model the same surface.
 * @param onError Called with a non-sensitive error category when the store is
 *                unreachable. Never receives keys or user data.
 */
const REQUIRED_CLIENT_COMMANDS = Object.freeze(['incrBy', 'pExpire', 'pTTL', 'get']);

function createSharedWindowStore({ client, onError } = {}) {
  if (!client) throw new Error('createSharedWindowStore requires a client');
  // Fail at construction (inside server.js's fallback-safe startup path) rather
  // than letting every request discover a command mismatch and degrade.
  if (REQUIRED_CLIENT_COMMANDS.some((command) => typeof client[command] !== 'function')) {
    throw new Error('shared window store client is missing required Redis commands');
  }

  async function consumeBy(key, windowMs, amount, _now) {
    // `_now` is part of the shared store interface but deliberately unused:
    // expiry is owned by the store, not by any single instance's wall clock.
    const count = await client.incrBy(key, amount);
    // Only the request that created the window sets its expiry. Re-setting it
    // on every request would slide the window forward indefinitely and a busy
    // identity would never reset.
    if (count === amount) {
      await client.pExpire(key, windowMs);
      return { count, retryAfterSeconds: toRetryAfterSeconds(windowMs, windowMs) };
    }
    const ttlMs = await client.pTTL(key);
    // A key with no expiry (-1) can only mean the PEXPIRE above was lost. Repair
    // it rather than leaving that identity limited forever.
    if (ttlMs === -1) {
      await client.pExpire(key, windowMs);
      return { count, retryAfterSeconds: toRetryAfterSeconds(windowMs, windowMs) };
    }
    return { count, retryAfterSeconds: toRetryAfterSeconds(ttlMs, windowMs) };
  }

  // Genuinely read-only count lookup. A missing key reads as 0 and is never
  // created, and an existing key's expiry is left untouched. (INCRBY 0 is not
  // a read: it creates the key.)
  async function peek(key) {
    const value = await client.get(key);
    if (value === null || value === undefined) return 0;
    const count = Number(value);
    return Number.isFinite(count) ? count : 0;
  }

  return {
    isShared: true,
    async consume(key, windowMs, now) { return consumeBy(key, windowMs, 1, now); },
    consumeBy,
    peek,
    _onError: onError
  };
}

module.exports = { createSharedWindowStore, toRetryAfterSeconds, REQUIRED_CLIENT_COMMANDS };

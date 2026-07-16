// Phase 2C-2 structured logging. One JSON line per log() call, written to an
// injectable stream (defaults to process.stdout so Render's own log
// collector picks it up — this project never adds a log-shipping
// dependency).
//
// Safety model: an ALLOWLIST, not a denylist. Only fields named below are
// ever written; anything else passed to log() is silently dropped. This is
// deliberately stricter than "redact known-bad fields", because a denylist
// only protects against field names we already thought of — a caller that
// accidentally passes `{ email }` or `{ body: req.body }` under a new key
// name would otherwise leak straight through. See docs/BACKEND_OBSERVABILITY.md.
const ALLOWED_LOG_FIELDS = new Set([
  'requestId',
  'method',
  'route',
  'status',
  'durationMs',
  'authState',
  'userHash',
  'routeCategory',
  'mutationCountBucket',
  'resultCode',
  'metric',
  'value',
  'retryAfterSeconds',
  'minimumVersion',
  'minimumBuild',
  'checks',
  'reason'
]);

// Irreversible, short, stable per-process identity for log correlation only.
// Never store or transmit the raw userId in any log line.
function hashUserId(userId) {
  if (!userId) return null;
  const crypto = require('crypto');
  return crypto.createHash('sha256').update(String(userId)).digest('hex').slice(0, 16);
}

function createLogger({
  stream = process.stdout,
  environment = process.env.NODE_ENV || 'development',
  release = process.env.SYNC_RELEASE_VERSION || 'unknown',
  nowProvider = () => new Date()
} = {}) {
  function log(event, level, fields = {}) {
    // log(event, fields) is also accepted — level defaults to 'info'.
    if (typeof level === 'object' && level !== null) {
      fields = level;
      level = 'info';
    }
    const safeFields = {};
    for (const [key, value] of Object.entries(fields)) {
      if (ALLOWED_LOG_FIELDS.has(key) && value !== undefined) {
        safeFields[key] = value;
      }
    }
    const line = {
      timestamp: nowProvider().toISOString(),
      level: level || 'info',
      event: String(event),
      environment,
      release,
      ...safeFields
    };
    stream.write(`${JSON.stringify(line)}\n`);
    return line;
  }
  return { log };
}

module.exports = { createLogger, hashUserId, ALLOWED_LOG_FIELDS };

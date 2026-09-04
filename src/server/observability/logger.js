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
  'reason',
  'upstreamRequestId',
  'model',
  'choicesCount',
  'finishReason',
  'contentType',
  'contentLength',
  'reasoningLength',
  'toolCallsCount',
  'promptTokens',
  'completionTokens',
  'reasoningTokens',
  'provider',
  'taskType',
  'timeoutMs',
  'timeoutSource',
  'requestSizeBytes',
  'attempt',
  'primaryProvider',
  'fallbackTriggered',
  'fallbackProvider',
  'fallbackReason',
  // Strict Special Plan response schema. `schemaOutcome` is what makes a
  // legacy-degraded success distinguishable from a strict-schema success, so
  // acceptance evidence can never be read off the wrong one. Both are
  // enum-like and provider-derived; neither can carry prompt text or a key.
  'specialPlanSchema',
  'menuContract',
  'schemaOutcome'
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

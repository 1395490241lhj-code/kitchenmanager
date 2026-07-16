// Phase 2C-2 request correlation id. Applied globally (all routes, not just
// /api/sync/*), before auth, so even a rejected/anonymous request gets a
// stable id to correlate its own log lines.
const crypto = require('crypto');

const REQUEST_ID_HEADER = 'x-request-id';
const MAX_REQUEST_ID_LENGTH = 100;
// Conservative allowlist: letters, digits, dot/dash/underscore only. Rejects
// anything containing whitespace, control characters, or exceeding the
// length cap — an attacker-controlled header is never trusted verbatim.
const REQUEST_ID_PATTERN = /^[A-Za-z0-9._-]{1,100}$/;

function isValidIncomingRequestId(value) {
  return typeof value === 'string'
    && value.length > 0
    && value.length <= MAX_REQUEST_ID_LENGTH
    && REQUEST_ID_PATTERN.test(value);
}

function createRequestIdMiddleware({ generateId = () => crypto.randomUUID() } = {}) {
  return function requestIdMiddleware(req, res, next) {
    const incoming = req.get ? req.get(REQUEST_ID_HEADER) : req.headers?.[REQUEST_ID_HEADER];
    const requestId = isValidIncomingRequestId(incoming) ? incoming : generateId();
    req.requestId = requestId;
    res.setHeader('X-Request-ID', requestId);
    next();
  };
}

module.exports = {
  createRequestIdMiddleware,
  isValidIncomingRequestId,
  REQUEST_ID_HEADER,
  REQUEST_ID_PATTERN,
  MAX_REQUEST_ID_LENGTH
};

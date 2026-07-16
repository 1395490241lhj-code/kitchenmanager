const crypto = require('crypto');
const {
  createSupabaseAccountDeletionRepository,
  createSupabaseAccountDeletionAdmin
} = require('./deletion-repository');
const { AccountDeletionError } = require('./errors');
const { isBucketRateLimited, getClientIp } = require('../services/rate-limit');
const { ACCOUNT_DELETION_RATE_LIMIT_MAX, ACCOUNT_DELETION_NONCE_TTL_MS } = require('../config');

const deletionRateLimitBuckets = new Map();

function limitAccountDeletion(req, res, next) {
  const userId = req.auth?.userId || 'unauthenticated';
  const scopedRequest = { ip: `${userId}:${getClientIp(req)}`, socket: req.socket };
  if (isBucketRateLimited(scopedRequest, deletionRateLimitBuckets, ACCOUNT_DELETION_RATE_LIMIT_MAX)) {
    return res.status(429).json({ error: { code: 'rate_limited', message: '请求过于频繁，请稍后重试。' } });
  }
  return next();
}

// In-memory, single-instance, Stage-1 store for the short-lived deletion
// nonce (see config.js's ACCOUNT_DELETION_NONCE_TTL_MS comment for why this
// exists instead of relaying a password to this backend). Keyed by userId;
// a user can only ever have one live nonce at a time — requesting a new
// preview invalidates any previous one, which is the desired behavior (the
// most recent preview is the only one that should ever be actable on).
function createNonceStore() {
  const nonces = new Map();
  return {
    issue(userId) {
      const nonce = crypto.randomUUID();
      nonces.set(userId, { nonce, expiresAt: Date.now() + ACCOUNT_DELETION_NONCE_TTL_MS });
      return nonce;
    },
    consume(userId, providedNonce) {
      const entry = nonces.get(userId);
      if (!entry) return false;
      // Single-use: whether this call succeeds or fails, the nonce is gone —
      // a rejected/expired/mismatched attempt must not be retryable with the
      // same value, and a successful one must not be replayable.
      nonces.delete(userId);
      if (Date.now() > entry.expiresAt) return false;
      return entry.nonce === providedNonce;
    }
  };
}

function sendAccountDeletionError(res, error) {
  if (error instanceof AccountDeletionError) {
    return res.status(error.status).json({ error: { code: error.code, message: '账号删除请求处理失败，请稍后重试。' } });
  }
  return res.status(502).json({ error: { code: 'account_deletion_failed', message: '账号删除请求处理失败，请稍后重试。' } });
}

// Structured log helper matching the allowlist-based logger elsewhere in
// this codebase (src/server/observability/logger.js): only safe, coarse
// fields — never a raw userId, household id, or error body.
function logSecurityEvent(logger, event, fields) {
  if (!logger || typeof logger.info !== 'function') return;
  logger.info({ route: 'account_deletion', event, ...fields });
}

function registerAccountDeletionRoutes(app, options = {}) {
  const auth = options.authenticate;
  const role = options.requireRole;
  const repository = options.repository || createSupabaseAccountDeletionRepository();
  const admin = options.admin || createSupabaseAccountDeletionAdmin();
  const nonceStore = options.nonceStore || createNonceStore();
  const rateLimiter = options.rateLimiter || limitAccountDeletion;
  const logger = options.logger;

  app.post('/api/account/delete/preview', auth, role, rateLimiter, async (req, res) => {
    try {
      const preview = await repository.getPreview({ accessToken: req.auth.accessToken });
      const nonce = nonceStore.issue(req.auth.userId);
      logSecurityEvent(logger, 'preview_issued', { canDelete: preview.canDelete === true });
      return res.json({
        canDelete: preview.canDelete,
        blockingReason: preview.blockingReason,
        householdCount: preview.householdCount,
        ownedHouseholdCount: preview.ownedHouseholdCount,
        requiresOwnershipTransfer: preview.requiresOwnershipTransfer,
        requiresHouseholdDeletion: preview.requiresHouseholdDeletion,
        pendingMutationCountBucket: preview.pendingMutationCountBucket,
        confirmationVersion: preview.confirmationVersion,
        deletionNonce: nonce
      });
    } catch (error) {
      logSecurityEvent(logger, 'preview_failed', {});
      return sendAccountDeletionError(res, error);
    }
  });

  app.post('/api/account/list-transfer-candidates', auth, role, rateLimiter, async (req, res) => {
    const householdId = typeof req.body?.householdId === 'string' ? req.body.householdId : null;
    if (!householdId) {
      return res.status(400).json({ error: { code: 'invalid_request', message: 'householdId is required.' } });
    }
    try {
      const members = await repository.listMembersForTransfer({ accessToken: req.auth.accessToken, householdId });
      return res.json({ members });
    } catch (error) {
      return sendAccountDeletionError(res, error);
    }
  });

  app.post('/api/account/transfer-ownership', auth, role, rateLimiter, async (req, res) => {
    const householdId = typeof req.body?.householdId === 'string' ? req.body.householdId : null;
    const newOwnerUserId = typeof req.body?.newOwnerUserId === 'string' ? req.body.newOwnerUserId : null;
    if (!householdId || !newOwnerUserId) {
      return res.status(400).json({ error: { code: 'invalid_request', message: 'householdId and newOwnerUserId are required.' } });
    }
    try {
      const result = await repository.transferOwnership({ accessToken: req.auth.accessToken, householdId, newOwnerUserId });
      logSecurityEvent(logger, 'ownership_transferred', {});
      return res.json(result);
    } catch (error) {
      return sendAccountDeletionError(res, error);
    }
  });

  app.post('/api/account/delete/confirm', auth, role, rateLimiter, async (req, res) => {
    const idempotencyKey = typeof req.body?.idempotencyKey === 'string' ? req.body.idempotencyKey : null;
    const previewFingerprint = typeof req.body?.confirmationVersion === 'string' ? req.body.confirmationVersion : null;
    const deletionNonce = typeof req.body?.deletionNonce === 'string' ? req.body.deletionNonce : null;

    if (!idempotencyKey || !previewFingerprint || !deletionNonce) {
      return res.status(400).json({
        error: { code: 'invalid_request', message: 'idempotencyKey, confirmationVersion, and deletionNonce are required.' }
      });
    }

    // The nonce is this Stage-1 codebase's "recent authentication" signal
    // (see config.js) — a missing/expired/mismatched nonce means the client
    // must fetch a fresh preview (which re-establishes recency) before
    // retrying, exactly the same user-facing effect real reauthentication
    // would have, without this backend ever receiving a password.
    if (!nonceStore.consume(req.auth.userId, deletionNonce)) {
      logSecurityEvent(logger, 'confirm_rejected', { reason: 'reauthentication_required' });
      return res.status(401).json({ error: { code: 'REAUTHENTICATION_REQUIRED', message: '请重新获取删除确认信息后再试一次。' } });
    }

    let stepOneResult;
    try {
      stepOneResult = await repository.requestDeletion({
        accessToken: req.auth.accessToken,
        idempotencyKey,
        previewFingerprint
      });
    } catch (error) {
      logSecurityEvent(logger, 'confirm_failed', { stage: 'business_data_cleanup' });
      return sendAccountDeletionError(res, error);
    }

    if (stepOneResult.status === 'rejected') {
      logSecurityEvent(logger, 'confirm_rejected', { reason: stepOneResult.errorCode });
      return res.status(409).json({ error: { code: stepOneResult.errorCode || 'ACCOUNT_DELETION_BLOCKED', message: '账号当前无法删除，请先处理提示的问题。' } });
    }

    // stepOneResult.status is 'business_data_cleaned', 'auth_deletion_pending',
    // or 'completed' (a duplicate confirm after full completion) at this
    // point — all three mean it's safe to proceed to / retry step two.
    if (stepOneResult.status === 'completed') {
      logSecurityEvent(logger, 'confirm_already_completed', {});
      return res.json({ status: 'completed' });
    }

    const deleteResult = await admin.deleteAuthUser({ userId: req.auth.userId });
    if (!deleteResult.deleted) {
      // Business data is already cleaned; the Auth user deletion step can be
      // retried later (by the client calling confirm again with the same
      // idempotencyKey, or by an operator using the runbook) without ever
      // re-running the cleanup, and the account remains otherwise unusable
      // for sync (see the sync-freeze middleware) but not otherwise broken.
      logSecurityEvent(logger, 'confirm_partial', { stage: 'auth_user_deletion' });
      try {
        await admin.markFinalized({ userId: req.auth.userId, idempotencyKey, authDeleted: false, failureCode: 'auth_admin_delete_failed' });
      } catch { /* best-effort status update; the retry path re-attempts regardless */ }
      return res.status(202).json({ status: 'auth_deletion_pending' });
    }

    try {
      await admin.markFinalized({ userId: req.auth.userId, idempotencyKey, authDeleted: true });
    } catch (error) {
      // The Auth user is already gone at this point — this is a bookkeeping
      // failure, not a data-safety one. Still reported as pending so a retry
      // (which will find the user already 404/gone and treat it as success)
      // can finish marking the ledger row completed.
      logSecurityEvent(logger, 'confirm_partial', { stage: 'finalize_ledger' });
      return res.status(202).json({ status: 'auth_deletion_pending' });
    }

    logSecurityEvent(logger, 'confirm_completed', {});
    return res.json({ status: 'completed' });
  });
}

module.exports = { registerAccountDeletionRoutes, limitAccountDeletion, createNonceStore };

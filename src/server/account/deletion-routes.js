const crypto = require('crypto');
const {
  createSupabaseAccountDeletionRepository,
  createSupabaseAccountDeletionAdmin
} = require('./deletion-repository');
const { AccountDeletionError } = require('./errors');
const { isBucketRateLimited, getClientIp } = require('../services/rate-limit');
const { ACCOUNT_DELETION_RATE_LIMIT_MAX, ACCOUNT_DELETION_REAUTH_TTL_MS } = require('../config');

const deletionRateLimitBuckets = new Map();

function limitAccountDeletion(req, res, next) {
  const userId = req.auth?.userId || 'unauthenticated';
  const scopedRequest = { ip: `${userId}:${getClientIp(req)}`, socket: req.socket };
  if (isBucketRateLimited(scopedRequest, deletionRateLimitBuckets, ACCOUNT_DELETION_RATE_LIMIT_MAX)) {
    return res.status(429).json({ error: { code: 'rate_limited', message: '请求过于频繁，请稍后重试。' } });
  }
  return next();
}

function passwordAuthenticationTime(authenticationMethods) {
  if (!Array.isArray(authenticationMethods)) return null;
  const passwordMethod = authenticationMethods.find((entry) => entry?.method === 'password');
  if (!passwordMethod) return null;
  const raw = passwordMethod.timestamp;
  const numeric = typeof raw === 'number' ? raw : Number(raw);
  if (Number.isFinite(numeric)) return numeric > 10_000_000_000 ? numeric : numeric * 1000;
  const date = typeof raw === 'string' ? Date.parse(raw) : Number.NaN;
  return Number.isFinite(date) ? date : null;
}

// Process-local by design: after a restart, an old proof cannot suddenly be
// accepted. This store binds Supabase's signed, recent password-auth event to
// the current user and preview fingerprint; it never receives a password.
function createDeletionReauthenticationStore({ now = Date.now, ttlMs = ACCOUNT_DELETION_REAUTH_TTL_MS } = {}) {
  const previews = new Map();
  const proofs = new Map();
  return {
    issuePreview(userId, fingerprint) {
      proofs.delete(userId);
      previews.set(userId, { fingerprint, issuedAt: now() });
    },
    issueProof({ userId, fingerprint, authenticationMethods }) {
      const preview = previews.get(userId);
      if (!preview) return { error: 'required' };
      if (now() > preview.issuedAt + ttlMs) {
        previews.delete(userId);
        return { error: 'expired' };
      }
      if (preview.fingerprint !== fingerprint) return { error: 'failed' };
      const passwordAt = passwordAuthenticationTime(authenticationMethods);
      // An access-token refresh retains its original AMR timestamp. It is
      // therefore not enough: the password authentication must be both recent
      // and no older than this deletion preview.
      if (
        passwordAt === null
        || passwordAt > now() + 60_000
        || now() - passwordAt > ttlMs
        || passwordAt < Math.floor(preview.issuedAt / 1000) * 1000
      ) return { error: 'failed' };

      const proof = crypto.randomUUID();
      proofs.set(userId, { proof, fingerprint, expiresAt: now() + ttlMs });
      return { proof };
    },
    consumeProof({ userId, fingerprint, proof }) {
      const entry = proofs.get(userId);
      // A replay/wrong proof consumes the entry too. The user may always
      // complete a new provider-native authentication to obtain another one.
      proofs.delete(userId);
      if (!entry) return { error: 'required' };
      if (now() > entry.expiresAt) return { error: 'expired' };
      if (entry.proof !== proof || entry.fingerprint !== fingerprint) return { error: 'failed' };
      return { valid: true };
    }
  };
}

function sendAccountDeletionError(res, error) {
  if (error instanceof AccountDeletionError) {
    return res.status(error.status).json({ error: { code: error.code, message: '账号删除请求处理失败，请稍后重试。' } });
  }
  return res.status(502).json({ error: { code: 'account_deletion_failed', message: '账号删除请求处理失败，请稍后重试。' } });
}

// This guard deliberately runs before every account-deletion operation,
// including preview. A configured user-scoped RPC alone is insufficient: a
// confirm would otherwise be able to clean business data and create a ledger
// row before discovering the Auth Admin/finalize half of the saga is absent.
// A missing server-only key must therefore make the feature unavailable, not
// leave a user in a partial deletion state.
function createAccountDeletionAvailabilityGuard(isConfigured) {
  return function accountDeletionAvailabilityGuard(_req, res, next) {
    let configured = false;
    try {
      configured = isConfigured() === true;
    } catch {
      configured = false;
    }
    if (!configured) {
      return res.status(503).json({
        error: {
          code: 'ACCOUNT_DELETION_UNAVAILABLE',
          message: '账号删除服务当前不可用，请稍后再试。'
        }
      });
    }
    return next();
  };
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
  const reauthenticationStore = options.reauthenticationStore || createDeletionReauthenticationStore();
  const rateLimiter = options.rateLimiter || limitAccountDeletion;
  const logger = options.logger;
  const isAdminConfigured = options.isAdminConfigured || (() => (
    typeof admin.isConfigured === 'function' ? admin.isConfigured() : true
  ));
  const availabilityGuard = options.availabilityGuard || createAccountDeletionAvailabilityGuard(isAdminConfigured);

  app.post('/api/account/delete/preview', auth, role, rateLimiter, availabilityGuard, async (req, res) => {
    try {
      const preview = await repository.getPreview({ accessToken: req.auth.accessToken });
      reauthenticationStore.issuePreview(req.auth.userId, preview.confirmationVersion);
      logSecurityEvent(logger, 'preview_issued', { canDelete: preview.canDelete === true });
      return res.json({
        canDelete: preview.canDelete,
        blockingReason: preview.blockingReason,
        householdCount: preview.householdCount,
        ownedHouseholdCount: preview.ownedHouseholdCount,
        requiresOwnershipTransfer: preview.requiresOwnershipTransfer,
        requiresHouseholdDeletion: preview.requiresHouseholdDeletion,
        pendingMutationCountBucket: preview.pendingMutationCountBucket,
        confirmationVersion: preview.confirmationVersion
      });
    } catch (error) {
      logSecurityEvent(logger, 'preview_failed', {});
      return sendAccountDeletionError(res, error);
    }
  });

  app.post('/api/account/delete/reauthenticate', auth, role, rateLimiter, availabilityGuard, async (req, res) => {
    const previewFingerprint = typeof req.body?.confirmationVersion === 'string' ? req.body.confirmationVersion : null;
    if (!previewFingerprint) {
      return res.status(400).json({ error: { code: 'invalid_request', message: 'confirmationVersion is required.' } });
    }
    const result = reauthenticationStore.issueProof({
      userId: req.auth.userId,
      fingerprint: previewFingerprint,
      authenticationMethods: req.auth.authenticationMethods
    });
    if (!result.proof) {
      const code = result.error === 'expired'
        ? 'ACCOUNT_DELETION_REAUTH_EXPIRED'
        : result.error === 'failed'
          ? 'ACCOUNT_DELETION_REAUTH_FAILED'
          : 'ACCOUNT_DELETION_REAUTH_REQUIRED';
      logSecurityEvent(logger, 'reauthentication_rejected', { reason: code });
      return res.status(401).json({ error: { code, message: '为了保护你的账号，请重新验证身份。' } });
    }
    logSecurityEvent(logger, 'reauthentication_proof_issued', {});
    return res.json({ reauthenticationProof: result.proof });
  });

  app.post('/api/account/list-transfer-candidates', auth, role, rateLimiter, availabilityGuard, async (req, res) => {
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

  app.post('/api/account/transfer-ownership', auth, role, rateLimiter, availabilityGuard, async (req, res) => {
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

  app.post('/api/account/delete/confirm', auth, role, rateLimiter, availabilityGuard, async (req, res) => {
    const idempotencyKey = typeof req.body?.idempotencyKey === 'string' ? req.body.idempotencyKey : null;
    const previewFingerprint = typeof req.body?.confirmationVersion === 'string' ? req.body.confirmationVersion : null;
    const reauthenticationProof = typeof req.body?.reauthenticationProof === 'string' ? req.body.reauthenticationProof : null;

    if (!idempotencyKey || !previewFingerprint || !reauthenticationProof) {
      return res.status(400).json({
        error: { code: 'invalid_request', message: 'idempotencyKey, confirmationVersion, and reauthenticationProof are required.' }
      });
    }

    const proofResult = reauthenticationStore.consumeProof({
      userId: req.auth.userId,
      fingerprint: previewFingerprint,
      proof: reauthenticationProof
    });
    if (!proofResult.valid) {
      const code = proofResult.error === 'expired'
        ? 'ACCOUNT_DELETION_REAUTH_EXPIRED'
        : proofResult.error === 'failed'
          ? 'ACCOUNT_DELETION_REAUTH_FAILED'
          : 'ACCOUNT_DELETION_REAUTH_REQUIRED';
      logSecurityEvent(logger, 'confirm_rejected', { reason: code });
      return res.status(401).json({ error: { code, message: '为了保护你的账号，请重新验证身份。' } });
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

module.exports = {
  registerAccountDeletionRoutes,
  limitAccountDeletion,
  createDeletionReauthenticationStore,
  passwordAuthenticationTime,
  createAccountDeletionAvailabilityGuard
};

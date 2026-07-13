const { createRemoteJWKSet, jwtVerify } = require('jose');
const {
  SUPABASE_JWKS_URL,
  SUPABASE_JWT_AUDIENCE,
  SUPABASE_JWT_ISSUER
} = require('../config');

const ALLOWED_ALGORITHMS = ['ES256', 'RS256'];
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function authError(res, status, code, message) {
  return res.status(status).json({ error: { code, message } });
}

function readBearerToken(authorization) {
  if (typeof authorization !== 'string') return { error: 'missing' };
  const match = authorization.match(/^Bearer\s+(\S+)$/i);
  if (!match) return { error: 'malformed' };
  return { token: match[1] };
}

function createSupabaseTokenVerifier({
  jwksUrl = SUPABASE_JWKS_URL,
  issuer = SUPABASE_JWT_ISSUER,
  audience = SUPABASE_JWT_AUDIENCE,
  cooldownDuration = 30_000,
  cacheMaxAge = 10 * 60_000
} = {}) {
  let keySet;

  return async function verifySupabaseAccessToken(token) {
    if (!jwksUrl || !issuer || !audience) {
      const error = new Error('Supabase authentication is not configured');
      error.code = 'auth_not_configured';
      throw error;
    }
    if (!keySet) {
      keySet = createRemoteJWKSet(new URL(jwksUrl), { cooldownDuration, cacheMaxAge });
    }
    const { payload, protectedHeader } = await jwtVerify(token, keySet, {
      issuer,
      audience,
      algorithms: ALLOWED_ALGORITHMS
    });
    if (!UUID_PATTERN.test(payload.sub || '')) {
      const error = new Error('JWT subject is missing or invalid');
      error.code = 'invalid_subject';
      throw error;
    }
    return {
      userId: payload.sub,
      email: typeof payload.email === 'string' ? payload.email : null,
      role: typeof payload.role === 'string' ? payload.role : null,
      sessionId: typeof payload.session_id === 'string' ? payload.session_id : null,
      algorithm: protectedHeader.alg
    };
  };
}

const verifySupabaseAccessToken = createSupabaseTokenVerifier();

function createAuthenticateRequest({ verifyToken = verifySupabaseAccessToken, optional = false } = {}) {
  return async function authenticateRequest(req, res, next) {
    const parsed = readBearerToken(req.headers?.authorization);
    if (parsed.error === 'missing' && optional) {
      req.auth = null;
      return next();
    }
    if (parsed.error === 'missing') {
      return authError(res, 401, 'auth_required', '需要登录后才能访问。');
    }
    if (parsed.error) {
      return authError(res, 401, 'invalid_authorization', 'Authorization 必须使用 Bearer Token。');
    }

    try {
      const claims = await verifyToken(parsed.token);
      req.auth = Object.freeze({ ...claims, accessToken: parsed.token });
      return next();
    } catch (error) {
      if (error?.code === 'auth_not_configured') {
        return authError(res, 503, 'auth_unavailable', '账户服务暂时不可用。');
      }
      return authError(res, 401, 'invalid_token', '登录凭证无效或已过期。');
    }
  };
}

function createRequireAuthRole(allowedRoles) {
  const allowed = new Set(allowedRoles);
  return function requireAuthRole(req, res, next) {
    if (!req.auth) {
      return authError(res, 401, 'auth_required', '需要登录后才能访问。');
    }
    if (!allowed.has(req.auth.role)) {
      return authError(res, 403, 'forbidden', '当前账户没有执行此操作的权限。');
    }
    return next();
  };
}

module.exports = {
  ALLOWED_ALGORITHMS,
  createAuthenticateRequest,
  createRequireAuthRole,
  createSupabaseTokenVerifier,
  optionalAuthenticateRequest: createAuthenticateRequest({ optional: true }),
  authenticateRequest: createAuthenticateRequest(),
  readBearerToken
};

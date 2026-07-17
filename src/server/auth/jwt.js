const crypto = require('crypto');
const { createRemoteJWKSet, jwtVerify, errors: joseErrors, decodeProtectedHeader, decodeJwt } = require('jose');
const {
  SUPABASE_JWKS_URL,
  SUPABASE_JWT_AUDIENCE,
  SUPABASE_JWT_ISSUER,
  SUPABASE_AUTH_CONFIG_ERRORS
} = require('../config');

const ALLOWED_ALGORITHMS = ['ES256', 'RS256'];
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

// Preserve only the typed, Supabase-signed authentication-method metadata
// needed by destructive flows. The raw JWT stays inside this middleware.
function normalizeAuthenticationMethods(value) {
  if (!Array.isArray(value)) return [];
  return value.flatMap((entry) => {
    if (!entry || typeof entry !== 'object' || typeof entry.method !== 'string') return [];
    const timestamp = typeof entry.timestamp === 'number' || typeof entry.timestamp === 'string'
      ? entry.timestamp
      : null;
    return [{ method: entry.method, timestamp }];
  });
}

// ── 验证失败诊断（脱敏）──────────────────────────────────────────────────
// 目的：把「invalid_token」这个对客户端而言必须保持通用的错误，在服务端日志
// 里拆解成可定位的具体阶段，同时严禁记录 Authorization/完整 JWT/access
// token/密码/任何密钥。header/payload 本身不是加密内容（只是 base64url），
// 记录 alg/iss/aud 是安全的；kid 只记录短哈希前缀，不记录原始值。

function classifyVerificationFailure(error) {
  if (error?.code === 'auth_not_configured') {
    return { stage: 'not_configured', jwksFetched: null, kidFound: null };
  }
  if (error?.code === 'invalid_subject') {
    return { stage: 'invalid_subject', jwksFetched: true, kidFound: true };
  }
  if (error instanceof joseErrors.JWKSNoMatchingKey) {
    return { stage: 'kid_not_found', jwksFetched: true, kidFound: false };
  }
  if (error instanceof joseErrors.JWKSMultipleMatchingKeys) {
    return { stage: 'kid_ambiguous', jwksFetched: true, kidFound: true };
  }
  if (error instanceof joseErrors.JWKSTimeout) {
    return { stage: 'jwks_timeout', jwksFetched: false, kidFound: null };
  }
  if (error instanceof joseErrors.JWTExpired) {
    return { stage: 'expired', jwksFetched: true, kidFound: true };
  }
  if (error instanceof joseErrors.JWTClaimValidationFailed) {
    if (error.claim === 'iss') return { stage: 'issuer_mismatch', jwksFetched: true, kidFound: true };
    if (error.claim === 'aud') return { stage: 'audience_mismatch', jwksFetched: true, kidFound: true };
    return { stage: `claim_mismatch_${error.claim}`, jwksFetched: true, kidFound: true };
  }
  if (error instanceof joseErrors.JWSSignatureVerificationFailed) {
    return { stage: 'signature_invalid', jwksFetched: true, kidFound: true };
  }
  if (error instanceof joseErrors.JOSEAlgNotAllowed) {
    return { stage: 'algorithm_not_allowed', jwksFetched: true, kidFound: null };
  }
  if (error instanceof joseErrors.JWTInvalid || error instanceof joseErrors.JWSInvalid) {
    return { stage: 'malformed_token', jwksFetched: null, kidFound: null };
  }
  // createRemoteJWKSet 在网络层失败时抛的是普通 Node 系统错误
  // （ECONNREFUSED/ENOTFOUND/ETIMEDOUT…），不是 jose 的错误类型。
  if (/^E[A-Z]+$/.test(error?.code || '')) {
    return { stage: 'jwks_fetch_network_error', jwksFetched: false, kidFound: null };
  }
  // JWKS 端点返回非 200（含临时 5xx）：jose 不会把状态码带出来，只给一个通用
  // JOSEError，但对一个公开只读的 JWKS 端点而言，非 200 永远是基础设施问题。
  if (error?.code === 'ERR_JOSE_GENERIC' && /Expected 200 OK/.test(error?.message || '')) {
    return { stage: 'jwks_fetch_http_error', jwksFetched: false, kidFound: null };
  }
  return { stage: 'unknown', jwksFetched: null, kidFound: null };
}

const JWKS_NETWORK_FAILURE_CODES = new Set(['ENOTFOUND', 'EAI_AGAIN', 'ETIMEDOUT', 'ECONNRESET']);

// 这些"确实连不上/连不稳"的失败必须变成 503（我们真的无法判断 token 是否有
// 效），而不是被泛化成 401（听起来像是"这个 token 无效"，其实完全是另一回
// 事）。两种"超时"都算：raw Node 的 ETIMEDOUT（连接层面超时）和 jose 自己
// 内部请求计时器触发的 JWKSTimeout/ERR_JWKS_TIMEOUT（fetch 发出去了但在
// timeoutDuration 内没等到响应）。
function isRemoteJwksNetworkFailure(error) {
  if (JWKS_NETWORK_FAILURE_CODES.has(error?.code)) return true;
  if (error instanceof joseErrors.JWKSTimeout) return true;
  if (error?.code === 'ERR_JOSE_GENERIC' && /Expected 200 OK/.test(error?.message || '')) return true;
  return false;
}

// 防御性脱敏：即便理论上 jose 的错误 message 不会包含 token 原文，也在打印前
// 再做一次兜底替换，防止未来版本变化悄悄把 token 内容拼进 message。
function redactErrorMessage(error) {
  const raw = String(error?.message || 'unknown error');
  return raw
    .replace(/Bearer\s+\S+/gi, 'Bearer [redacted]')
    .replace(/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]*/g, '[redacted-jwt]')
    .slice(0, 300);
}

function shortKidFingerprint(kid) {
  if (typeof kid !== 'string' || !kid) return null;
  return crypto.createHash('sha256').update(kid).digest('hex').slice(0, 8);
}

function safeJwksHostname(jwksUrl) {
  try { return new URL(jwksUrl).hostname; } catch { return jwksUrl ? '(invalid)' : '(not configured)'; }
}

function logVerificationFailure({ logger, error, token, jwksUrl, issuer, audience }) {
  let header = null;
  let payload = null;
  try { header = decodeProtectedHeader(token); } catch { /* not a decodable JWT, nothing to add */ }
  try { payload = decodeJwt(token); } catch { /* not a decodable JWT, nothing to add */ }
  const { stage, jwksFetched, kidFound } = classifyVerificationFailure(error);
  try {
    logger.warn('[auth/jwt] verification failed', {
      stage,
      errorName: error?.name || 'Error',
      errorCode: error?.code || null,
      errorMessage: redactErrorMessage(error),
      tokenAlg: header?.alg || null,
      tokenKidFingerprint: shortKidFingerprint(header?.kid),
      tokenIssuer: typeof payload?.iss === 'string' ? payload.iss : null,
      tokenAudience: payload?.aud ?? null,
      configuredIssuer: issuer || null,
      configuredAudience: audience || null,
      jwksHost: safeJwksHostname(jwksUrl),
      jwksFetched,
      kidFound
    });
  } catch { /* logging must never break the auth response path */ }
}

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
  cacheMaxAge = 10 * 60_000,
  timeoutDuration = 5000,
  logger = console,
  // 只有真正读取 process.env 的那个生产单例（见下方 verifySupabaseAccessToken）
  // 会显式传入 SUPABASE_AUTH_CONFIG_ERRORS；测试/其他调用方显式构造自己的
  // jwksUrl/issuer/audience 时默认不受这份数组影响。
  configErrors = []
} = {}) {
  let keySet;

  return async function verifySupabaseAccessToken(token) {
    if (!jwksUrl || !issuer || !audience || (configErrors && configErrors.length > 0)) {
      const error = new Error('Supabase authentication is not configured');
      error.code = 'auth_not_configured';
      throw error;
    }
    if (!keySet) {
      keySet = createRemoteJWKSet(new URL(jwksUrl), { cooldownDuration, cacheMaxAge, timeoutDuration });
    }
    try {
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
        authenticationMethods: normalizeAuthenticationMethods(payload.amr),
        algorithm: protectedHeader.alg
      };
    } catch (error) {
      logVerificationFailure({ logger, error, token, jwksUrl, issuer, audience });
      if (isRemoteJwksNetworkFailure(error)) {
        // 远程 JWKS 端点连不上/连不稳/超时：我们真的无法判断 token 是否有
        // 效，不能当成"这个 token 无效"，也不能悄悄放行。
        const wrapped = new Error('Supabase JWKS endpoint is temporarily unreachable');
        wrapped.code = 'auth_temporarily_unavailable';
        wrapped.cause = error;
        throw wrapped;
      }
      throw error;
    }
  };
}

const verifySupabaseAccessToken = createSupabaseTokenVerifier({ configErrors: SUPABASE_AUTH_CONFIG_ERRORS });

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
      if (error?.code === 'auth_temporarily_unavailable') {
        return authError(res, 503, 'auth_temporarily_unavailable', '登录服务暂时不可用，请稍后重试。');
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
  readBearerToken,
  classifyVerificationFailure,
  redactErrorMessage,
  shortKidFingerprint,
  isRemoteJwksNetworkFailure,
  normalizeAuthenticationMethods
};

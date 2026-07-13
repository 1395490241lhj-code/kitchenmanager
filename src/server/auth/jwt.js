const crypto = require('crypto');
const {
  createRemoteJWKSet,
  createLocalJWKSet,
  jwtVerify,
  errors: joseErrors,
  decodeProtectedHeader,
  decodeJwt
} = require('jose');
const {
  SUPABASE_JWKS_URL,
  SUPABASE_JWT_AUDIENCE,
  SUPABASE_JWT_ISSUER,
  SUPABASE_AUTH_CONFIG_ERRORS,
  SUPABASE_JWKS_JSON
} = require('../config');

const ALLOWED_ALGORITHMS = ['ES256', 'RS256'];
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

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
  if (error?.code === 'ERR_CRYPTO_INVALID_JWK' || error instanceof joseErrors.JWKInvalid || error instanceof joseErrors.JWKSInvalid) {
    return { stage: 'jwks_key_material_invalid', jwksFetched: true, kidFound: null };
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

// 只有这些"确实连不上/连不稳"的失败才值得尝试本地 fallback；一次成功拿到
// JWKS 之后的签名/issuer/audience/kid 判定都是确定性答案，不应该、也不需要
// 再去问本地 fallback 一遍。
//
// 两种"超时"都算：raw Node 的 ETIMEDOUT（连接层面超时，例如连去一个黑洞
// IP）和 jose 自己内部请求计时器触发的 JWKSTimeout/ERR_JWKS_TIMEOUT（fetch
// 发出去了但在 timeoutDuration 内没等到响应）。
function isRemoteJwksNetworkFailure(error) {
  if (JWKS_NETWORK_FAILURE_CODES.has(error?.code)) return true;
  if (error instanceof joseErrors.JWKSTimeout) return true;
  if (error?.code === 'ERR_JOSE_GENERIC' && /Expected 200 OK/.test(error?.message || '')) return true;
  return false;
}

// createLocalJWKSet() only validates the overall JWKS *shape* eagerly
// (JWKSInvalid, e.g. a missing/non-array `keys`); a structurally fine but
// cryptographically bogus individual key (garbage x/y coordinates) only
// fails lazily, inside jwtVerify, as a Node crypto TypeError. Either way this
// is "the fallback config itself is broken", not "this token is invalid" —
// it must surface as 503, never as a definitive 401.
function isLocalJwksBroken(error) {
  return error?.code === 'ERR_CRYPTO_INVALID_JWK'
    || error instanceof joseErrors.JWKInvalid
    || error instanceof joseErrors.JWKSInvalid;
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

function logVerificationFailure({ logger, error, token, jwksUrl, issuer, audience, usedFallback = false, localJwksKeyCount = null }) {
  let header = null;
  let payload = null;
  try { header = decodeProtectedHeader(token); } catch { /* not a decodable JWT, nothing to add */ }
  try { payload = decodeJwt(token); } catch { /* not a decodable JWT, nothing to add */ }
  const { stage, jwksFetched, kidFound } = classifyVerificationFailure(error);
  try {
    logger.warn('[auth/jwt] verification failed', {
      stage: usedFallback ? `fallback_${stage}` : stage,
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
      kidFound,
      usedFallback,
      localJwksKeyCount
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
  configErrors = [],
  // 远程 JWKS 端点不可达（DNS/超时/连接被重置/临时 5xx）时的最后手段：一份
  // 事先手动获取好、内嵌进环境变量的 JWKS JSON。只在识别出的网络类错误时才
  // 会用它重新验证同一个 JWT——不会绕过签名/issuer/audience 校验，也不会在
  // 远程已经给出确定答案（签名无效/kid 不存在/过期等）时去问它。
  localJwksJson = SUPABASE_JWKS_JSON
} = {}) {
  let remoteKeySet;
  let localKeySet;
  if (localJwksJson) {
    try {
      localKeySet = createLocalJWKSet(localJwksJson);
    } catch (error) {
      logger.warn('[auth/jwt] local JWKS fallback is configured but invalid, fallback disabled', {
        errorCode: error?.code || null,
        errorName: error?.name || null
      });
    }
  }
  const localJwksKeyCount = Array.isArray(localJwksJson?.keys) ? localJwksJson.keys.length : null;

  async function verifyWithKeySet(token, keySet) {
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
  }

  return async function verifySupabaseAccessToken(token) {
    if (!issuer || !audience || (configErrors && configErrors.length > 0)) {
      const error = new Error('Supabase authentication is not configured');
      error.code = 'auth_not_configured';
      throw error;
    }
    if (!jwksUrl && !localKeySet) {
      const error = new Error('Supabase authentication is not configured');
      error.code = 'auth_not_configured';
      throw error;
    }

    let remoteError = null;
    if (jwksUrl) {
      if (!remoteKeySet) {
        remoteKeySet = createRemoteJWKSet(new URL(jwksUrl), { cooldownDuration, cacheMaxAge, timeoutDuration });
      }
      try {
        return await verifyWithKeySet(token, remoteKeySet);
      } catch (error) {
        remoteError = error;
        const eligibleForFallback = Boolean(localKeySet) && isRemoteJwksNetworkFailure(error);
        if (!eligibleForFallback) {
          logVerificationFailure({ logger, error, token, jwksUrl, issuer, audience, usedFallback: false });
          if (isRemoteJwksNetworkFailure(error) && !localKeySet) {
            // 网络类失败，且没有配置本地 fallback：真的无法判断 token 是否
            // 有效，不能当成"这个 token 无效"，也不能悄悄放行。
            const wrapped = new Error('Supabase JWKS endpoint is unreachable and no local fallback is configured');
            wrapped.code = 'auth_temporarily_unavailable';
            wrapped.cause = error;
            throw wrapped;
          }
          throw error;
        }
        // 网络类失败 + 本地 fallback 可用 → 继续往下走 fallback 分支。
      }
    }

    if (remoteError) {
      logger.warn('[auth/jwt] remote JWKS unavailable, attempting local fallback', {
        errorCode: remoteError.code || null,
        errorName: remoteError.name || null,
        jwksHost: safeJwksHostname(jwksUrl),
        localJwksKeyCount
      });
    }
    try {
      const claims = await verifyWithKeySet(token, localKeySet);
      logger.warn('[auth/jwt] verified using local JWKS fallback', {
        stage: 'fallback_success',
        alg: claims.algorithm,
        issuer,
        audience,
        usedFallback: true,
        localJwksKeyCount
      });
      return claims;
    } catch (fallbackError) {
      logVerificationFailure({
        logger, error: fallbackError, token, jwksUrl, issuer, audience,
        usedFallback: true, localJwksKeyCount
      });
      if (isLocalJwksBroken(fallbackError)) {
        // 本地 fallback 的 key 材料本身有问题（结构过了 config.js 的校验，
        // 但实际密钥点位非法）——这是配置问题，不是"这个 token 无效"，不能
        // 当成 401。
        const wrapped = new Error('Local JWKS fallback key material is invalid');
        wrapped.code = 'auth_temporarily_unavailable';
        wrapped.cause = fallbackError;
        throw wrapped;
      }
      throw fallbackError;
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
  isRemoteJwksNetworkFailure
};

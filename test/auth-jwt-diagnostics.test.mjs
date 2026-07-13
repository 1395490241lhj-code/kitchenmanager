// test/auth-jwt-diagnostics.test.mjs
//
// Covers the Render "本地能通过、线上 /api/me 一律 401 invalid_token" incident:
//   1. src/server/config.js must trim SUPABASE_JWT_ISSUER/AUDIENCE/JWKS_URL/URL
//      (jose's issuer/audience check is exact string equality, unlike a URL
//      which the WHATWG URL parser silently trims) and must flag — not
//      silently "fix" — wrapping quotes, duplicated protocols, non-HTTPS JWKS
//      URLs, and an issuer that doesn't share an origin with SUPABASE_URL.
//   2. src/server/auth/jwt.js must classify *why* jwtVerify failed (issuer,
//      audience, unknown kid, JWKS fetch failure, ...) for a redacted,
//      structured server-side log line, while the client-facing response
//      stays the generic 401 invalid_token it always was.
//   3. None of that diagnostic logging may ever contain a full JWT, a
//      complete Authorization header, or any secret.
import test, { after, before } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import http from 'node:http';
import { exportJWK, generateKeyPair, SignJWT } from 'jose';

const require = createRequire(import.meta.url);
const {
  createAuthenticateRequest,
  createSupabaseTokenVerifier,
  classifyVerificationFailure,
  redactErrorMessage,
  shortKidFingerprint
} = require('../src/server/auth/jwt');
const {
  sanitizeSupabaseEnvValue,
  sanitizeSupabaseUrlValue
} = require('../src/server/config');

const issuer = 'https://diagnostics-test.supabase.co/auth/v1';
const audience = 'authenticated';
const userA = '33333333-3333-4333-8333-333333333333';

let keyPair;
let jwk;
let currentKeys;
let jwksServer;
let jwksUrl;

before(async () => {
  keyPair = await generateKeyPair('ES256');
  jwk = { ...(await exportJWK(keyPair.publicKey)), kid: 'diag-key-1', alg: 'ES256', use: 'sig' };
  currentKeys = [jwk];
  jwksServer = http.createServer((_req, res) => {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ keys: currentKeys }));
  });
  await new Promise((resolve, reject) => {
    jwksServer.once('error', reject);
    jwksServer.listen(0, '127.0.0.1', resolve);
  });
  const address = jwksServer.address();
  jwksUrl = `http://127.0.0.1:${address.port}/.well-known/jwks.json`;
});

after(async () => {
  if (jwksServer) await new Promise(resolve => jwksServer.close(resolve));
});

async function tokenFor({
  subject = userA,
  kid = 'diag-key-1',
  tokenIssuer = issuer,
  tokenAudience = audience,
  expiresAt = Math.floor(Date.now() / 1000) + 3600
} = {}) {
  return new SignJWT({ email: 'diag@example.com', role: 'authenticated' })
    .setProtectedHeader({ alg: 'ES256', kid })
    .setSubject(subject)
    .setIssuer(tokenIssuer)
    .setAudience(tokenAudience)
    .setIssuedAt()
    .setExpirationTime(expiresAt)
    .sign(keyPair.privateKey);
}

function captureLogger() {
  const calls = [];
  return {
    calls,
    warn(message, details) { calls.push({ message, details }); }
  };
}

function verifierWithCapture(overrides = {}) {
  const logger = captureLogger();
  const verify = createSupabaseTokenVerifier({
    jwksUrl,
    issuer,
    audience,
    cooldownDuration: 0,
    cacheMaxAge: 60_000,
    logger,
    ...overrides
  });
  return { verify, logger };
}

// ── 1. 正常路径：ES256 + 正确 kid 验证成功 ──────────────────────────────────

test('ES256 token with the correct kid verifies successfully', async () => {
  const { verify, logger } = verifierWithCapture();
  const token = await tokenFor();
  const claims = await verify(token);
  assert.equal(claims.userId, userA);
  assert.equal(claims.algorithm, 'ES256');
  assert.equal(logger.calls.length, 0, 'a successful verification must not log a failure diagnostic');
});

// ── 2. 失败分类：issuer / audience / kid 不存在 / JWKS fetch 失败 ───────────

test('wrong issuer is classified as issuer_mismatch and still returns generic invalid_token to the client', async () => {
  const { verify, logger } = verifierWithCapture();
  const token = await tokenFor({ tokenIssuer: `${issuer}-wrong` });
  const middleware = createAuthenticateRequest({ verifyToken: verify });
  const req = { headers: { authorization: `Bearer ${token}` } };
  const res = {
    statusCode: 200,
    body: null,
    status(code) { this.statusCode = code; return this; },
    json(value) { this.body = value; return this; }
  };
  await middleware(req, res, () => assert.fail('must not call next on failure'));
  assert.equal(res.statusCode, 401);
  assert.equal(res.body.error.code, 'invalid_token');
  assert.equal(logger.calls.length, 1);
  assert.equal(logger.calls[0].details.stage, 'issuer_mismatch');
  assert.equal(logger.calls[0].details.tokenIssuer, `${issuer}-wrong`);
  assert.equal(logger.calls[0].details.configuredIssuer, issuer);
});

test('wrong audience is classified as audience_mismatch', async () => {
  const { verify, logger } = verifierWithCapture();
  const token = await tokenFor({ tokenAudience: 'not-authenticated' });
  await assert.rejects(() => verify(token));
  assert.equal(logger.calls[0].details.stage, 'audience_mismatch');
  assert.equal(logger.calls[0].details.tokenAudience, 'not-authenticated');
  assert.equal(logger.calls[0].details.configuredAudience, audience);
});

test('an unpublished kid is classified as kid_not_found with jwksFetched=true, kidFound=false', async () => {
  const { verify, logger } = verifierWithCapture();
  const token = await tokenFor({ kid: 'never-published' });
  await assert.rejects(() => verify(token));
  const details = logger.calls[0].details;
  assert.equal(details.stage, 'kid_not_found');
  assert.equal(details.jwksFetched, true);
  assert.equal(details.kidFound, false);
  assert.equal(typeof details.tokenKidFingerprint, 'string');
  assert.notEqual(details.tokenKidFingerprint, 'never-published', 'kid must be hashed, never logged raw');
});

test('an unreachable JWKS endpoint is classified as jwks_fetch_network_error with jwksFetched=false', async () => {
  const logger = captureLogger();
  const verify = createSupabaseTokenVerifier({
    jwksUrl: 'https://127.0.0.1:1/.well-known/jwks.json',
    issuer,
    audience,
    cooldownDuration: 0,
    logger
  });
  const token = await tokenFor();
  await assert.rejects(() => verify(token));
  const details = logger.calls[0].details;
  assert.equal(details.jwksFetched, false);
  assert.match(details.stage, /jwks_fetch_network_error|jwks_timeout/);
});

test('classifyVerificationFailure maps auth_not_configured and invalid_subject without a JWKS round trip', () => {
  const notConfigured = new Error('x');
  notConfigured.code = 'auth_not_configured';
  assert.deepEqual(classifyVerificationFailure(notConfigured), { stage: 'not_configured', jwksFetched: null, kidFound: null });

  const invalidSubject = new Error('x');
  invalidSubject.code = 'invalid_subject';
  assert.deepEqual(classifyVerificationFailure(invalidSubject), { stage: 'invalid_subject', jwksFetched: true, kidFound: true });
});

// ── 3. 日志脱敏：不能出现完整 token 或 Authorization header ─────────────────

test('the failure log never contains the full token, Authorization header, or raw kid', async () => {
  const { verify, logger } = verifierWithCapture();
  const token = await tokenFor({ tokenIssuer: `${issuer}-wrong` });
  await assert.rejects(() => verify(token));
  const serialized = JSON.stringify(logger.calls);
  assert.doesNotMatch(serialized, /Bearer\s+eyJ/i, 'must not contain an Authorization header value');
  assert.doesNotMatch(serialized, new RegExp(token.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')), 'must not contain the full token');
  const [headerPart] = token.split('.');
  assert.doesNotMatch(serialized, new RegExp(headerPart), 'must not contain the raw base64url header either');
});

test('redactErrorMessage strips Bearer headers and JWT-shaped substrings from arbitrary error text', () => {
  const fakeError = new Error('failed for Bearer abc.def.ghi while checking eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig');
  const redacted = redactErrorMessage(fakeError);
  assert.doesNotMatch(redacted, /Bearer\s+abc/);
  assert.doesNotMatch(redacted, /eyJhbGciOiJFUzI1NiJ9/);
});

test('shortKidFingerprint hashes the kid instead of returning it verbatim', () => {
  const fingerprint = shortKidFingerprint('some-real-kid-value');
  assert.equal(typeof fingerprint, 'string');
  assert.equal(fingerprint.length, 8);
  assert.notEqual(fingerprint, 'some-real-kid-value');
  assert.equal(shortKidFingerprint(null), null);
});

// ── 4. auth_not_configured 网关：configErrors 非空时必须拒绝，而不是继续尝试 ─

test('a non-empty configErrors list forces auth_not_configured (503) even with valid jwksUrl/issuer/audience', async () => {
  const { verify } = (() => {
    const logger = captureLogger();
    const v = createSupabaseTokenVerifier({
      jwksUrl,
      issuer,
      audience,
      cooldownDuration: 0,
      logger,
      configErrors: ['SUPABASE_JWT_ISSUER 的值首尾包含引号字符']
    });
    return { verify: v, logger };
  })();
  const token = await tokenFor();
  await assert.rejects(verify(token), error => error.code === 'auth_not_configured');
});

// ── 5. 环境变量清洗（config.js）：trim / 引号 / 重复协议 / HTTPS / origin 一致性 ─

test('trailing whitespace/newline in a URL-shaped env var is trimmed transparently (the actual production bug)', () => {
  const result = sanitizeSupabaseUrlValue('SUPABASE_JWT_ISSUER', '  https://project-ref.supabase.co/auth/v1 \n');
  assert.equal(result.error, null);
  assert.equal(result.value, 'https://project-ref.supabase.co/auth/v1');
});

test('trailing whitespace in a non-URL value (audience) is also trimmed transparently', () => {
  const result = sanitizeSupabaseEnvValue('SUPABASE_JWT_AUDIENCE', 'authenticated\n');
  assert.equal(result.error, null);
  assert.equal(result.value, 'authenticated');
});

test('a value wrapped in quotes produces a clear, actionable error instead of a silent mismatch', () => {
  const urlResult = sanitizeSupabaseUrlValue('SUPABASE_JWT_ISSUER', '"https://project-ref.supabase.co/auth/v1"');
  assert.match(urlResult.error, /引号/);
  const plainResult = sanitizeSupabaseEnvValue('SUPABASE_JWT_AUDIENCE', '"authenticated"');
  assert.match(plainResult.error, /引号/);
});

test('a duplicated protocol prefix is rejected with a clear error', () => {
  const result = sanitizeSupabaseUrlValue('SUPABASE_JWKS_URL', 'https://https://project-ref.supabase.co/auth/v1/.well-known/jwks.json');
  assert.match(result.error, /重复的协议/);
});

test('a non-HTTPS JWKS URL is rejected outside of localhost', () => {
  const result = sanitizeSupabaseUrlValue('SUPABASE_JWKS_URL', 'http://project-ref.supabase.co/auth/v1/.well-known/jwks.json');
  assert.match(result.error, /HTTPS/);
});

test('http is allowed for localhost/127.0.0.1 so local JWKS test servers keep working', () => {
  assert.equal(sanitizeSupabaseUrlValue('SUPABASE_JWKS_URL', 'http://127.0.0.1:4000/jwks.json').error, null);
  assert.equal(sanitizeSupabaseUrlValue('SUPABASE_JWKS_URL', 'http://localhost:4000/jwks.json').error, null);
});

test('an empty/unset value is not treated as an error (auth simply stays unconfigured)', () => {
  assert.deepEqual(sanitizeSupabaseUrlValue('SUPABASE_URL', ''), { value: '', error: null });
  assert.deepEqual(sanitizeSupabaseUrlValue('SUPABASE_URL', undefined), { value: '', error: null });
});

test('config.js exposes the real process.env-derived config problems as SUPABASE_AUTH_CONFIG_ERRORS', () => {
  const { SUPABASE_AUTH_CONFIG_ERRORS } = require('../src/server/config');
  assert.ok(Array.isArray(SUPABASE_AUTH_CONFIG_ERRORS));
  assert.ok(Object.isFrozen(SUPABASE_AUTH_CONFIG_ERRORS));
});

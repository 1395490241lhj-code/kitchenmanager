// test/auth-jwt-jwks-fallback.test.mjs
//
// Covers the second Render incident: the box could not resolve the Supabase
// JWKS hostname at all (DNS ENOTFOUND), which took every single login down
// even though the JWTs themselves were perfectly valid. src/server/auth/jwt.js
// now falls back to a locally-embedded JWKS (SUPABASE_JWKS_JSON) — but ONLY
// for genuinely network-shaped remote failures, and ONLY after the same
// signature/issuer/audience checks jose already enforces for the remote path.
import test, { after, before } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import http from 'node:http';
import { exportJWK, generateKeyPair, SignJWT } from 'jose';

const require = createRequire(import.meta.url);
const {
  createAuthenticateRequest,
  createSupabaseTokenVerifier,
  isRemoteJwksNetworkFailure
} = require('../src/server/auth/jwt');
const { validateJwksJsonValue } = require('../src/server/config');

const issuer = 'https://fallback-test.supabase.co/auth/v1';
const audience = 'authenticated';
const userA = '44444444-4444-4444-8444-444444444444';

// A hostname reserved by RFC 2606 to never resolve, anywhere — a real,
// deterministic ENOTFOUND without depending on any external test server.
const UNRESOLVABLE_JWKS_URL = 'https://kitchenmanager-jwks-fallback-test.invalid/.well-known/jwks.json';

let remoteKeyPair;
let remoteJwk;
let currentRemoteKeys;
let remoteJwksServer;
let remoteJwksUrl;

let fallbackKeyPair;
let fallbackJwk;
let fallbackJwksJson;

before(async () => {
  remoteKeyPair = await generateKeyPair('ES256');
  remoteJwk = { ...(await exportJWK(remoteKeyPair.publicKey)), kid: 'remote-key-1', alg: 'ES256', use: 'sig' };
  currentRemoteKeys = [remoteJwk];
  remoteJwksServer = http.createServer((_req, res) => {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ keys: currentRemoteKeys }));
  });
  await new Promise((resolve, reject) => {
    remoteJwksServer.once('error', reject);
    remoteJwksServer.listen(0, '127.0.0.1', resolve);
  });
  const address = remoteJwksServer.address();
  remoteJwksUrl = `http://127.0.0.1:${address.port}/.well-known/jwks.json`;

  fallbackKeyPair = await generateKeyPair('ES256');
  fallbackJwk = { ...(await exportJWK(fallbackKeyPair.publicKey)), kid: 'fallback-key-1', alg: 'ES256', use: 'sig' };
  fallbackJwksJson = { keys: [fallbackJwk] };
});

after(async () => {
  if (remoteJwksServer) await new Promise(resolve => remoteJwksServer.close(resolve));
});

async function signToken({
  signingKey,
  kid,
  subject = userA,
  tokenIssuer = issuer,
  tokenAudience = audience,
  expiresAt = Math.floor(Date.now() / 1000) + 3600
}) {
  return new SignJWT({ email: 'fallback@example.com', role: 'authenticated' })
    .setProtectedHeader({ alg: 'ES256', kid })
    .setSubject(subject)
    .setIssuer(tokenIssuer)
    .setAudience(tokenAudience)
    .setIssuedAt()
    .setExpirationTime(expiresAt)
    .sign(signingKey);
}

function remoteToken(overrides = {}) {
  return signToken({ signingKey: remoteKeyPair.privateKey, kid: 'remote-key-1', ...overrides });
}

function fallbackToken(overrides = {}) {
  return signToken({ signingKey: fallbackKeyPair.privateKey, kid: 'fallback-key-1', ...overrides });
}

function captureLogger() {
  const calls = [];
  return { calls, warn(message, details) { calls.push({ message, details }); } };
}

function createResponse() {
  return {
    statusCode: 200,
    body: null,
    status(code) { this.statusCode = code; return this; },
    json(value) { this.body = value; return this; }
  };
}

async function runMiddleware(middleware, authorization) {
  const req = { headers: { authorization } };
  const res = createResponse();
  let nextCalled = false;
  await middleware(req, res, () => { nextCalled = true; });
  return { req, res, nextCalled };
}

// ── 1. 远程 JWKS 成功：直接使用远程，不碰 fallback ──────────────────────────

test('remote JWKS reachable: verifies via remote, never touches the fallback', async () => {
  const logger = captureLogger();
  const verify = createSupabaseTokenVerifier({
    jwksUrl: remoteJwksUrl, issuer, audience, cooldownDuration: 0, logger,
    localJwksJson: fallbackJwksJson
  });
  const middleware = createAuthenticateRequest({ verifyToken: verify });
  const token = await remoteToken();
  const { res, nextCalled } = await runMiddleware(middleware, `Bearer ${token}`);
  assert.equal(nextCalled, true);
  assert.equal(res.statusCode, 200);
  assert.ok(!logger.calls.some(call => /fallback/i.test(call.message)), 'must not log any fallback activity when remote succeeds');
});

// ── 2-4. 远程网络类失败（ENOTFOUND / 超时 / 5xx），本地 fallback 成功验证 ───

test('remote ENOTFOUND + valid local fallback: verifies via fallback and returns 200', async () => {
  const logger = captureLogger();
  const verify = createSupabaseTokenVerifier({
    jwksUrl: UNRESOLVABLE_JWKS_URL, issuer, audience, cooldownDuration: 0, logger,
    localJwksJson: fallbackJwksJson
  });
  const middleware = createAuthenticateRequest({ verifyToken: verify });
  const token = await fallbackToken();
  const { res, nextCalled, req } = await runMiddleware(middleware, `Bearer ${token}`);
  assert.equal(nextCalled, true, 'a healthy local fallback must let the request through');
  assert.equal(res.statusCode, 200);
  assert.equal(req.auth.userId, userA);
  assert.ok(logger.calls.some(call => /remote JWKS unavailable, attempting local fallback/.test(call.message)));
  assert.ok(logger.calls.some(call => /verified using local JWKS fallback/.test(call.message)));
});

test('remote request timeout (jose JWKSTimeout) + valid local fallback: verifies via fallback', async () => {
  const blackhole = http.createServer(() => { /* never respond, forces a timeout */ });
  await new Promise(resolve => blackhole.listen(0, '127.0.0.1', resolve));
  const port = blackhole.address().port;
  try {
    const logger = captureLogger();
    const verify = createSupabaseTokenVerifier({
      jwksUrl: `http://127.0.0.1:${port}/jwks.json`,
      issuer, audience, cooldownDuration: 0, timeoutDuration: 200, logger,
      localJwksJson: fallbackJwksJson
    });
    const token = await fallbackToken();
    const claims = await verify(token);
    assert.equal(claims.userId, userA);
    assert.ok(logger.calls.some(call => /verified using local JWKS fallback/.test(call.message)));
  } finally {
    await new Promise(resolve => blackhole.close(resolve));
  }
});

test('remote returns a temporary 5xx + valid local fallback: verifies via fallback', async () => {
  const flaky = http.createServer((_req, res) => { res.writeHead(503); res.end('temporarily unavailable'); });
  await new Promise(resolve => flaky.listen(0, '127.0.0.1', resolve));
  const port = flaky.address().port;
  try {
    const logger = captureLogger();
    const verify = createSupabaseTokenVerifier({
      jwksUrl: `http://127.0.0.1:${port}/jwks.json`,
      issuer, audience, cooldownDuration: 0, logger,
      localJwksJson: fallbackJwksJson
    });
    const token = await fallbackToken();
    const claims = await verify(token);
    assert.equal(claims.userId, userA);
  } finally {
    await new Promise(resolve => flaky.close(resolve));
  }
});

test('a reset connection (ECONNRESET) + valid local fallback: verifies via fallback', async () => {
  const resetting = http.createServer((_req, res) => { res.destroy(); });
  await new Promise(resolve => resetting.listen(0, '127.0.0.1', resolve));
  const port = resetting.address().port;
  try {
    const logger = captureLogger();
    const verify = createSupabaseTokenVerifier({
      jwksUrl: `http://127.0.0.1:${port}/jwks.json`,
      issuer, audience, cooldownDuration: 0, logger,
      localJwksJson: fallbackJwksJson
    });
    const token = await fallbackToken();
    const claims = await verify(token);
    assert.equal(claims.userId, userA);
  } finally {
    await new Promise(resolve => resetting.close(resolve));
  }
});

test('isRemoteJwksNetworkFailure recognizes EAI_AGAIN even without a live reproduction', () => {
  const eaiAgain = new Error('getaddrinfo EAI_AGAIN xyz');
  eaiAgain.code = 'EAI_AGAIN';
  assert.equal(isRemoteJwksNetworkFailure(eaiAgain), true);
  const arbitrary = new Error('some unrelated failure');
  arbitrary.code = 'EPERM';
  assert.equal(isRemoteJwksNetworkFailure(arbitrary), false);
});

// ── 5. 远程失败且未配置 fallback：503 auth_temporarily_unavailable ─────────

test('remote ENOTFOUND with no fallback configured returns 503 auth_temporarily_unavailable, not 401', async () => {
  const logger = captureLogger();
  const verify = createSupabaseTokenVerifier({
    jwksUrl: UNRESOLVABLE_JWKS_URL, issuer, audience, cooldownDuration: 0, logger
    // no localJwksJson
  });
  const middleware = createAuthenticateRequest({ verifyToken: verify });
  const token = await remoteToken();
  const { res, nextCalled } = await runMiddleware(middleware, `Bearer ${token}`);
  assert.equal(nextCalled, false);
  assert.equal(res.statusCode, 503);
  assert.equal(res.body.error.code, 'auth_temporarily_unavailable');
});

// ── 6. fallback JSON 在结构上合法但 key 材料本身无效：等同未配置，503 ───────
//
// createLocalJWKSet() 只在构造时校验 JWKS 整体形状（keys 是否存在/是数组）；
// 单个 key 的材料是否真的是合法的椭圆曲线点位，只有在实际验证时才会被 jose
// 底层的 crypto 导入逻辑发现（抛出 ERR_CRYPTO_INVALID_JWK）。两种情况都必须
// 变成 503，不能被误判成"这个 token 无效"。

test('a JWKS with no keys array at all is caught eagerly at construction time (503, not a crash)', async () => {
  const logger = captureLogger();
  const verify = createSupabaseTokenVerifier({
    jwksUrl: UNRESOLVABLE_JWKS_URL, issuer, audience, cooldownDuration: 0, logger,
    localJwksJson: { notKeys: [] }
  });
  assert.ok(logger.calls.some(call => /local JWKS fallback is configured but invalid/.test(call.message)));
  const middleware = createAuthenticateRequest({ verifyToken: verify });
  const token = await remoteToken();
  const { res, nextCalled } = await runMiddleware(middleware, `Bearer ${token}`);
  assert.equal(nextCalled, false);
  assert.equal(res.statusCode, 503);
  assert.equal(res.body.error.code, 'auth_temporarily_unavailable');
});

test('a structurally valid but cryptographically broken key is only caught lazily during verify (still 503, not 401)', async () => {
  const logger = captureLogger();
  const brokenFallback = {
    keys: [{
      kty: 'EC', alg: 'ES256', use: 'sig', kid: 'broken-key', crv: 'P-256',
      x: 'not-a-real-coordinate', y: 'also-not-real'
    }]
  };
  const verify = createSupabaseTokenVerifier({
    jwksUrl: UNRESOLVABLE_JWKS_URL, issuer, audience, cooldownDuration: 0, logger,
    localJwksJson: brokenFallback
  });
  const middleware = createAuthenticateRequest({ verifyToken: verify });
  const token = await signToken({ signingKey: fallbackKeyPair.privateKey, kid: 'broken-key' });
  const { res, nextCalled } = await runMiddleware(middleware, `Bearer ${token}`);
  assert.equal(nextCalled, false);
  assert.equal(res.statusCode, 503);
  assert.equal(res.body.error.code, 'auth_temporarily_unavailable');
  assert.ok(logger.calls.some(call => call.details?.stage === 'fallback_jwks_key_material_invalid'));
});

// ── 7. fallback 含私钥字段被拒绝（config.js 校验层）──────────────────────

test('SUPABASE_JWKS_JSON containing a private key field (d) is rejected by config validation', () => {
  const withPrivateKey = JSON.stringify({
    keys: [{ kty: 'EC', alg: 'ES256', use: 'sig', kid: 'k1', crv: 'P-256', x: 'x', y: 'y', d: 'this-is-a-private-scalar' }]
  });
  const result = validateJwksJsonValue(withPrivateKey);
  assert.equal(result.jwks, null);
  assert.match(result.error, /私钥字段/);
  assert.match(result.error, /"d"/);
});

test('every documented private-field name (d/p/q/dp/dq/qi) is rejected', () => {
  for (const field of ['d', 'p', 'q', 'dp', 'dq', 'qi']) {
    const raw = JSON.stringify({
      keys: [{ kty: 'EC', alg: 'ES256', use: 'sig', kid: 'k1', crv: 'P-256', x: 'x', y: 'y', [field]: 'secret' }]
    });
    const result = validateJwksJsonValue(raw);
    assert.equal(result.jwks, null, `field ${field} should have been rejected`);
  }
});

// ── 8-9. fallback kid 匹配 / 不匹配 ─────────────────────────────────────────

test('fallback kid matches the token: verifies successfully (covered end-to-end above); kid mismatch is a definitive 401', async () => {
  const logger = captureLogger();
  const verify = createSupabaseTokenVerifier({
    jwksUrl: UNRESOLVABLE_JWKS_URL, issuer, audience, cooldownDuration: 0, logger,
    localJwksJson: fallbackJwksJson
  });
  const middleware = createAuthenticateRequest({ verifyToken: verify });
  // Signed with the fallback key's algorithm/material but a kid that isn't in
  // the fallback JWKS at all.
  const mismatchedKidToken = await signToken({ signingKey: fallbackKeyPair.privateKey, kid: 'no-such-kid' });
  const { res, nextCalled } = await runMiddleware(middleware, `Bearer ${mismatchedKidToken}`);
  assert.equal(nextCalled, false);
  assert.equal(res.statusCode, 401);
  assert.equal(res.body.error.code, 'invalid_token');
});

// ── 10-12. issuer / audience / 签名错误：即使配置了 fallback，仍然是确定性 401，不会去问 fallback ──

test('wrong issuer against a reachable remote is still 401, fallback is never attempted', async () => {
  const logger = captureLogger();
  const verify = createSupabaseTokenVerifier({
    jwksUrl: remoteJwksUrl, issuer, audience, cooldownDuration: 0, logger,
    localJwksJson: fallbackJwksJson
  });
  const middleware = createAuthenticateRequest({ verifyToken: verify });
  const token = await remoteToken({ tokenIssuer: `${issuer}-wrong` });
  const { res, nextCalled } = await runMiddleware(middleware, `Bearer ${token}`);
  assert.equal(nextCalled, false);
  assert.equal(res.statusCode, 401);
  assert.equal(res.body.error.code, 'invalid_token');
  assert.ok(!logger.calls.some(call => /fallback/i.test(call.message)), 'a definitive remote answer must not fall through to local fallback');
});

test('wrong audience against a reachable remote is still 401, fallback is never attempted', async () => {
  const logger = captureLogger();
  const verify = createSupabaseTokenVerifier({
    jwksUrl: remoteJwksUrl, issuer, audience, cooldownDuration: 0, logger,
    localJwksJson: fallbackJwksJson
  });
  const middleware = createAuthenticateRequest({ verifyToken: verify });
  const token = await remoteToken({ tokenAudience: 'not-authenticated' });
  const { res, nextCalled } = await runMiddleware(middleware, `Bearer ${token}`);
  assert.equal(nextCalled, false);
  assert.equal(res.statusCode, 401);
  assert.ok(!logger.calls.some(call => /fallback/i.test(call.message)));
});

test('an invalid signature (wrong key, correct kid) against a reachable remote is still 401, fallback is never attempted', async () => {
  const logger = captureLogger();
  const verify = createSupabaseTokenVerifier({
    jwksUrl: remoteJwksUrl, issuer, audience, cooldownDuration: 0, logger,
    localJwksJson: fallbackJwksJson
  });
  const middleware = createAuthenticateRequest({ verifyToken: verify });
  // Signed with the FALLBACK private key but claims the REMOTE kid — signature will not verify.
  const forgedToken = await signToken({ signingKey: fallbackKeyPair.privateKey, kid: 'remote-key-1' });
  const { res, nextCalled } = await runMiddleware(middleware, `Bearer ${forgedToken}`);
  assert.equal(nextCalled, false);
  assert.equal(res.statusCode, 401);
  assert.ok(!logger.calls.some(call => /fallback/i.test(call.message)));
});

// ── 13. 日志脱敏：不含完整 JWT / 完整 JWKS JSON / key 完整值 ────────────────

test('fallback logging never contains the full token, the full JWKS JSON, or raw key coordinates', async () => {
  const logger = captureLogger();
  const verify = createSupabaseTokenVerifier({
    jwksUrl: UNRESOLVABLE_JWKS_URL, issuer, audience, cooldownDuration: 0, logger,
    localJwksJson: fallbackJwksJson
  });
  const token = await fallbackToken();
  await verify(token);
  const serialized = JSON.stringify(logger.calls);
  assert.doesNotMatch(serialized, new RegExp(token.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.doesNotMatch(serialized, new RegExp(fallbackJwk.x), 'must not log the raw EC public key x-coordinate');
  assert.doesNotMatch(serialized, new RegExp(fallbackJwk.y), 'must not log the raw EC public key y-coordinate');
  assert.doesNotMatch(serialized, /"keys"\s*:\s*\[/, 'must not serialize the whole JWKS JSON into a log line');
  assert.doesNotMatch(serialized, /Bearer\s+eyJ/i);
});

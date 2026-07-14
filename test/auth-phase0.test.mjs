import test, { after, before } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import http from 'node:http';
import {
  exportJWK,
  generateKeyPair,
  SignJWT
} from 'jose';

const require = createRequire(import.meta.url);
const {
  createAuthenticateRequest,
  createRequireAuthRole,
  createSupabaseTokenVerifier,
  readBearerToken
} = require('../src/server/auth/jwt');
const {
  authMeRateLimitBuckets,
  isAuthMeRateLimited
} = require('../src/server/services/rate-limit');
const { createSupabaseAccountDataSource } = require('../src/server/auth/account-data');
const { createMeHandler } = require('../src/server/auth/me-route');

const issuer = 'https://phase0-test.supabase.co/auth/v1';
const audience = 'authenticated';
const userA = '11111111-1111-4111-8111-111111111111';
const userB = '22222222-2222-4222-8222-222222222222';
let firstKeyPair;
let secondKeyPair;
let firstJwk;
let secondJwk;
let currentKeys;
let jwksRequests = 0;
let jwksServer;
let jwksUrl;

before(async () => {
  firstKeyPair = await generateKeyPair('ES256');
  secondKeyPair = await generateKeyPair('ES256');
  firstJwk = { ...(await exportJWK(firstKeyPair.publicKey)), kid: 'phase0-key-1', alg: 'ES256', use: 'sig' };
  secondJwk = { ...(await exportJWK(secondKeyPair.publicKey)), kid: 'phase0-key-2', alg: 'ES256', use: 'sig' };
  currentKeys = [firstJwk];
  jwksServer = http.createServer((_req, res) => {
    jwksRequests += 1;
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

function createResponse() {
  return {
    statusCode: 200,
    body: null,
    status(code) { this.statusCode = code; return this; },
    json(value) { this.body = value; return this; }
  };
}

async function runMiddleware(middleware, authorization, body = {}) {
  const req = { headers: {}, body, ip: '127.0.0.1', socket: { remoteAddress: '127.0.0.1' } };
  if (authorization !== undefined) req.headers.authorization = authorization;
  const res = createResponse();
  let nextCalled = false;
  await middleware(req, res, () => { nextCalled = true; });
  return { req, res, nextCalled };
}

async function tokenFor({
  subject = userA,
  signingKey = firstKeyPair.privateKey,
  kid = 'phase0-key-1',
  tokenIssuer = issuer,
  tokenAudience = audience,
  expiresAt = Math.floor(Date.now() / 1000) + 3600
} = {}) {
  return new SignJWT({ email: 'a@example.com', role: 'authenticated' })
    .setProtectedHeader({ alg: 'ES256', kid })
    .setSubject(subject)
    .setIssuer(tokenIssuer)
    .setAudience(tokenAudience)
    .setIssuedAt()
    .setExpirationTime(expiresAt)
    .sign(signingKey);
}

function remoteVerifier() {
  return createSupabaseTokenVerifier({
    jwksUrl,
    issuer,
    audience,
    cooldownDuration: 0,
    cacheMaxAge: 60_000
  });
}

test('Bearer parser rejects missing, non-Bearer, and empty credentials', () => {
  assert.equal(readBearerToken(undefined).error, 'missing');
  assert.equal(readBearerToken('Basic abc').error, 'malformed');
  assert.equal(readBearerToken('Bearer ').error, 'malformed');
});

test('required authentication returns clear 401 responses for absent and malformed headers', async () => {
  const middleware = createAuthenticateRequest({ verifyToken: async () => assert.fail('must not verify') });
  for (const header of [undefined, 'Basic abc', 'Bearer ']) {
    const result = await runMiddleware(middleware, header);
    assert.equal(result.res.statusCode, 401);
    assert.equal(result.nextCalled, false);
    assert.match(result.res.body.error.code, /auth_required|invalid_authorization/);
  }
});

test('valid Supabase JWT verifies signature, issuer, audience, expiry, and subject', async () => {
  const middleware = createAuthenticateRequest({ verifyToken: remoteVerifier() });
  const token = await tokenFor();
  const result = await runMiddleware(middleware, `Bearer ${token}`);
  assert.equal(result.nextCalled, true);
  assert.equal(result.req.auth.userId, userA);
  assert.equal(result.req.auth.email, 'a@example.com');
  assert.equal(result.req.auth.algorithm, 'ES256');
});

test('expired, wrong issuer, and wrong audience tokens are rejected', async () => {
  const cases = [
    await tokenFor({ expiresAt: Math.floor(Date.now() / 1000) - 10 }),
    await tokenFor({ tokenIssuer: `${issuer}/wrong` }),
    await tokenFor({ tokenAudience: 'other-audience' })
  ];
  for (const token of cases) {
    const result = await runMiddleware(
      createAuthenticateRequest({ verifyToken: remoteVerifier() }),
      `Bearer ${token}`
    );
    assert.equal(result.res.statusCode, 401);
    assert.equal(result.res.body.error.code, 'invalid_token');
  }
});

test('unknown kid and invalid signature are rejected without leaking token details', async () => {
  const unknownKid = await tokenFor({ signingKey: secondKeyPair.privateKey, kid: 'not-published' });
  const invalidSignature = await tokenFor({ signingKey: secondKeyPair.privateKey, kid: 'phase0-key-1' });
  for (const token of [unknownKid, invalidSignature]) {
    const result = await runMiddleware(
      createAuthenticateRequest({ verifyToken: remoteVerifier() }),
      `Bearer ${token}`
    );
    assert.equal(result.res.statusCode, 401);
    assert.doesNotMatch(JSON.stringify(result.res.body), new RegExp(token.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
});

test('JWKS unknown kid triggers refresh and accepts a rotated signing key', async () => {
  currentKeys = [firstJwk];
  const verifier = remoteVerifier();
  await verifier(await tokenFor());
  const requestsBeforeRotation = jwksRequests;
  currentKeys = [firstJwk, secondJwk];
  const rotatedToken = await tokenFor({ signingKey: secondKeyPair.privateKey, kid: 'phase0-key-2' });
  const claims = await verifier(rotatedToken);
  assert.equal(claims.userId, userA);
  assert.ok(jwksRequests > requestsBeforeRotation, 'unknown kid should refresh the cached JWKS');
});

test('verified JWT subject wins over a client-supplied userId', async () => {
  const middleware = createAuthenticateRequest({
    verifyToken: async () => ({ userId: userA, email: null, role: 'authenticated' })
  });
  const result = await runMiddleware(middleware, 'Bearer opaque-token', { userId: userB });
  assert.equal(result.nextCalled, true);
  assert.equal(result.req.auth.userId, userA);
  assert.equal(result.req.body.userId, userB);
});

test('optional authentication preserves Guest requests but rejects malformed credentials', async () => {
  const optional = createAuthenticateRequest({ optional: true, verifyToken: async () => ({ userId: userA }) });
  const guest = await runMiddleware(optional, undefined);
  assert.equal(guest.nextCalled, true);
  assert.equal(guest.req.auth, null);
  const malformed = await runMiddleware(optional, 'Token abc');
  assert.equal(malformed.res.statusCode, 401);
});

test('authenticated endpoints return 403 when the verified JWT role is not allowed', () => {
  const middleware = createRequireAuthRole(['authenticated']);
  const req = { auth: { userId: userA, role: 'other-role' } };
  const res = createResponse();
  let nextCalled = false;
  middleware(req, res, () => { nextCalled = true; });
  assert.equal(nextCalled, false);
  assert.equal(res.statusCode, 403);
  assert.equal(res.body.error.code, 'forbidden');
});

test('/api/me limiter keys on verified subject and connection IP', () => {
  authMeRateLimitBuckets.clear();
  const request = { auth: { userId: userA }, ip: '127.0.0.1', socket: { remoteAddress: '127.0.0.1' } };
  for (let index = 0; index < 60; index += 1) assert.equal(isAuthMeRateLimited(request), false);
  assert.equal(isAuthMeRateLimited(request), true);
  assert.equal(isAuthMeRateLimited({ ...request, auth: { userId: userB } }), false);
  authMeRateLimitBuckets.clear();
});

test('/api/me returns only the verified user profile and visible households', async () => {
  let lookup;
  const handler = createMeHandler({
    accountDataSource: {
      async getAccount(input) {
        lookup = input;
        return {
          profile: { id: userA, email: 'a@example.com', display_name: 'Alice' },
          households: [{ id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', name: '我的厨房', role: 'owner' }]
        };
      }
    }
  });
  const req = { auth: { userId: userA, accessToken: 'verified-access-token' }, body: { userId: userB } };
  const res = createResponse();
  await handler(req, res);
  assert.equal(lookup.userId, userA);
  assert.equal(lookup.accessToken, 'verified-access-token');
  assert.equal(res.body.user.id, userA);
  assert.deepEqual(res.body.households, [
    { id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', name: '我的厨房', role: 'owner' }
  ]);
  assert.doesNotMatch(JSON.stringify(res.body), new RegExp(userB));
});

test('/api/me reports trigger initialization lag without creating duplicate data', async () => {
  const handler = createMeHandler({ accountDataSource: { async getAccount() { return null; } } });
  const res = createResponse();
  await handler({ auth: { userId: userA, accessToken: 'token' } }, res);
  assert.equal(res.statusCode, 409);
  assert.equal(res.body.error.code, 'profile_initializing');
});

test('/api/me database failures return a sanitized service error', async () => {
  const logs = [];
  const handler = createMeHandler({
    accountDataSource: { async getAccount() { throw new Error('postgres password=secret SQL detail'); } },
    logger: { error(message) { logs.push(message); } }
  });
  const res = createResponse();
  await handler({ auth: { userId: userA, accessToken: 'secret-token' } }, res);
  assert.equal(res.statusCode, 503);
  assert.equal(res.body.error.code, 'account_unavailable');
  assert.doesNotMatch(JSON.stringify(res.body), /postgres|password|secret-token|SQL detail/i);
  assert.deepEqual(logs, ['[auth/me] account lookup failed: code=unknown type=Error']);
});

test('Supabase account queries use anon key plus user JWT and filter by verified subject', async () => {
  const requests = [];
  const source = createSupabaseAccountDataSource({
    supabaseUrl: 'https://phase0-test.supabase.co',
    anonKey: 'public-anon-key',
    fetchImpl: async (url, options) => {
      requests.push({ url, options });
      if (url.includes('/profiles?')) {
        return { ok: true, json: async () => [{ id: userA, email: 'a@example.com', display_name: null }] };
      }
      return {
        ok: true,
        json: async () => [{ role: 'owner', households: { id: 'household-a', name: '我的厨房' } }]
      };
    }
  });
  const account = await source.getAccount({ userId: userA, accessToken: 'user-jwt' });
  assert.equal(requests.length, 2);
  for (const request of requests) {
    assert.match(request.url, new RegExp(userA));
    assert.equal(request.options.headers.apikey, 'public-anon-key');
    assert.equal(request.options.headers.Authorization, 'Bearer user-jwt');
  }
  assert.deepEqual(account.households, [{ id: 'household-a', name: '我的厨房', role: 'owner' }]);
});

test('Phase 0 migration defines constrained identity tables, idempotent initialization, and RLS', () => {
  const sql = readFileSync(new URL('../supabase/migrations/20260713000100_auth_household_foundation.sql', import.meta.url), 'utf8');
  for (const table of ['profiles', 'households', 'household_members']) {
    assert.match(sql, new RegExp(`create table if not exists public\\.${table}`));
    assert.match(sql, new RegExp(`alter table public\\.${table} enable row level security`));
  }
  assert.match(sql, /primary key \(household_id, user_id\)/);
  assert.match(sql, /role in \('owner', 'admin', 'member'\)/);
  assert.match(sql, /households_one_personal_per_creator_idx/);
  assert.match(sql, /on conflict \(created_by\) where is_personal/);
  assert.match(sql, /on conflict \(household_id, user_id\) do update set role = 'owner'/);
  assert.match(sql, /profiles_select_self[\s\S]*id = \(select auth\.uid\(\)\)/);
  assert.match(sql, /households_select_for_members[\s\S]*private\.is_household_member/);
  assert.match(sql, /household_members_update_for_managers[\s\S]*array\['owner'\]/);
  assert.doesNotMatch(sql, /using\s*\(\s*true\s*\)/i);
});

test('server keeps Guest APIs public while registering protected account and sync routes', () => {
  const server = readFileSync(new URL('../server.js', import.meta.url), 'utf8');
  assert.match(server, /'\/api\/me',[\s\S]*authenticateRequest,[\s\S]*createRequireAuthRole\(\['authenticated'\]\),[\s\S]*limitAuthMe,[\s\S]*createMeHandler\(\)/);
  assert.match(server, /registerSyncRoutes\(app\)/);
  assert.match(server, /Access-Control-Allow-Headers', 'Content-Type, Authorization'/);
  assert.doesNotMatch(server, /app\.use\('\/api', authenticateRequest/);
  for (const publicPath of ['/api/xhs-extract', '/api/ai-chat', '/api/ai-parse']) {
    assert.match(server, new RegExp(`app\\.(?:get|post)\\('${publicPath.replaceAll('/', '\\/')}'`));
  }
});

import assert from 'node:assert/strict';
import http from 'node:http';
import https from 'node:https';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import {
  ensureDevelopmentTarget,
  maskedHost,
  validateHttpUrl
} from './verify-supabase-phase0.mjs';

const SECRET_ENV_NAMES = [
  'SUPABASE_ANON_KEY',
  'SUPABASE_SERVICE_ROLE_KEY',
  'SUPABASE_DB_PASSWORD',
  'TEST_USER_A_EMAIL',
  'TEST_USER_A_PASSWORD',
  'TEST_USER_B_EMAIL',
  'TEST_USER_B_PASSWORD'
];

class SmokeStageError extends Error {
  constructor(stage, message) {
    super(message);
    this.name = 'SmokeStageError';
    this.stage = stage;
  }
}

function required(env, name) {
  const value = String(env[name] || '').trim();
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function base64UrlJson(part) {
  return JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
}

function safeCause(error) {
  return error?.cause?.code || error?.code || error?.name || 'unknown';
}

function redactDiagnostic(message, env = {}) {
  let safe = String(message || 'unexpected failure')
    .replace(/Bearer\s+\S+/gi, 'Bearer [redacted]')
    .replace(/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+/g, '[redacted-jwt]');
  for (const name of SECRET_ENV_NAMES) {
    const value = String(env[name] || '');
    if (value.length >= 4) safe = safe.split(value).join('[redacted]');
  }
  return safe;
}

function networkStageError(stage, error, target, hint) {
  let host = 'invalid-host';
  try { host = maskedHost(target); } catch { /* configuration validation reports the URL separately */ }
  return new SmokeStageError(
    stage,
    `request failed for ${host} (cause=${safeCause(error)}). ${hint}`
  );
}

async function runStage(stage, operation, { env = {}, target, hint = 'Check the development configuration.' } = {}) {
  try {
    return await operation();
  } catch (error) {
    if (error instanceof SmokeStageError) throw error;
    if ((error instanceof TypeError && (error.message === 'fetch failed' || error.cause))
      || error?.cause
      || /^E[A-Z]+$/.test(error?.code || '')) {
      throw networkStageError(stage, error, target, hint);
    }
    throw new SmokeStageError(stage, redactDiagnostic(error?.message, env));
  }
}

async function jsonResponse(response) {
  const text = await response.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = null; }
  return { response, body, text };
}

async function signIn(fetchImpl, supabaseUrl, anonKey, email, password) {
  const responseResult = await jsonResponse(await fetchImpl(
    `${supabaseUrl}/auth/v1/token?grant_type=password`,
    {
      method: 'POST',
      headers: { apikey: anonKey, 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ email, password })
    }
  ));
  const { response, body } = responseResult;
  assert.equal(
    response.ok,
    true,
    `Supabase rejected the sign-in request (HTTP ${response.status}); check this test user's credentials`
  );
  assert.ok(body?.access_token && body?.user?.id, 'Supabase sign-in response is incomplete');
  return { token: body.access_token, userId: body.user.id, email: body.user.email || email };
}

async function requestJson(fetchImpl, url, { token, ...options } = {}) {
  const headers = { Accept: 'application/json', ...(options.headers || {}) };
  if (token) headers.Authorization = `Bearer ${token}`;
  return jsonResponse(await fetchImpl(url, { ...options, headers }));
}

function getWithJsonBody(urlValue, token, body) {
  const url = new URL(urlValue);
  const transport = url.protocol === 'https:' ? https : http;
  const payload = JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const request = transport.request(url, {
      method: 'GET',
      headers: {
        Accept: 'application/json',
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload)
      }
    }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let parsed = null;
        try { parsed = text ? JSON.parse(text) : null; } catch { parsed = null; }
        resolve({ response: { status: response.statusCode, ok: response.statusCode < 400 }, body: parsed, text });
      });
    });
    request.once('error', reject);
    request.end(payload);
  });
}

async function rest(fetchImpl, supabaseUrl, anonKey, token, pathValue, options = {}) {
  return requestJson(fetchImpl, `${supabaseUrl}/rest/v1/${pathValue}`, {
    ...options,
    token,
    headers: {
      apikey: anonKey,
      'Content-Type': 'application/json',
      Prefer: options.prefer || 'return=representation',
      ...(options.headers || {})
    }
  });
}

function assertOwnAccount(account, session) {
  assert.equal(account.response.status, 200, `/api/me failed with HTTP ${account.response.status}`);
  assert.equal(account.body?.user?.id, session.userId, '/api/me returned another user');
  assert.ok(Array.isArray(account.body?.households) && account.body.households.length >= 1);
  const personal = account.body.households.filter(item => item.role === 'owner');
  assert.ok(personal.length >= 1, 'user has no owner household');
}

async function assertRls({ fetchImpl, supabaseUrl, anonKey, a, b }) {
  const aProfiles = await rest(fetchImpl, supabaseUrl, anonKey, a.token, 'profiles?select=id,email,display_name');
  assert.equal(aProfiles.response.status, 200);
  assert.deepEqual(aProfiles.body.map(item => item.id), [a.userId]);
  const hiddenProfile = await rest(
    fetchImpl, supabaseUrl, anonKey, a.token, `profiles?select=id&id=eq.${encodeURIComponent(b.userId)}`
  );
  assert.deepEqual(hiddenProfile.body, [], 'User A can read User B profile');
  assert.equal(aProfiles.body[0].email, a.email, 'Auth trigger copied an unexpected profile email');

  const originalDisplayName = aProfiles.body[0].display_name;
  const temporaryDisplayName = `Phase 0.5 ${Date.now()}`;
  let profileChanged = false;
  try {
    const ownUpdate = await rest(
      fetchImpl, supabaseUrl, anonKey, a.token,
      `profiles?id=eq.${encodeURIComponent(a.userId)}`,
      { method: 'PATCH', body: JSON.stringify({ display_name: temporaryDisplayName }) }
    );
    profileChanged = true;
    assert.equal(ownUpdate.response.status, 200);
    assert.equal(ownUpdate.body[0]?.display_name, temporaryDisplayName);
    const protectedUpdate = await rest(
      fetchImpl, supabaseUrl, anonKey, a.token,
      `profiles?id=eq.${encodeURIComponent(a.userId)}`,
      { method: 'PATCH', body: JSON.stringify({ id: b.userId }) }
    );
    assert.ok(protectedUpdate.response.status === 401 || protectedUpdate.response.status === 403);
  } finally {
    if (profileChanged) {
      const restoreProfile = await rest(
        fetchImpl, supabaseUrl, anonKey, a.token,
        `profiles?id=eq.${encodeURIComponent(a.userId)}`,
        { method: 'PATCH', body: JSON.stringify({ display_name: originalDisplayName }) }
      );
      assert.equal(restoreProfile.response.status, 200);
    }
  }

  const aHouseholds = await rest(fetchImpl, supabaseUrl, anonKey, a.token, 'households?select=id,name,created_by,is_personal');
  const bHouseholds = await rest(fetchImpl, supabaseUrl, anonKey, b.token, 'households?select=id,name,created_by,is_personal');
  assert.equal(aHouseholds.response.status, 200);
  assert.equal(bHouseholds.response.status, 200);
  const aPersonal = aHouseholds.body.filter(item => item.created_by === a.userId && item.is_personal);
  const bPersonal = bHouseholds.body.filter(item => item.created_by === b.userId && item.is_personal);
  assert.equal(aPersonal.length, 1, 'User A must have exactly one personal household');
  assert.equal(bPersonal.length, 1, 'User B must have exactly one personal household');
  assert.ok(!aHouseholds.body.some(item => item.id === bPersonal[0].id), 'User A can read User B household');

  const reverseHiddenProfile = await rest(
    fetchImpl, supabaseUrl, anonKey, b.token, `profiles?select=id&id=eq.${encodeURIComponent(a.userId)}`
  );
  assert.deepEqual(reverseHiddenProfile.body, [], 'User B can read User A profile');
  assert.ok(!bHouseholds.body.some(item => item.id === aPersonal[0].id), 'User B can read User A household');

  const hiddenMembers = await rest(
    fetchImpl, supabaseUrl, anonKey, a.token,
    `household_members?select=household_id,user_id,role&household_id=eq.${bPersonal[0].id}`
  );
  assert.deepEqual(hiddenMembers.body, [], 'User A can read User B household members');
  const reverseHiddenMembers = await rest(
    fetchImpl, supabaseUrl, anonKey, b.token,
    `household_members?select=household_id,user_id,role&household_id=eq.${aPersonal[0].id}`
  );
  assert.deepEqual(reverseHiddenMembers.body, [], 'User B can read User A household members');
  const nonMemberUpdate = await rest(
    fetchImpl, supabaseUrl, anonKey, a.token,
    `households?id=eq.${bPersonal[0].id}`,
    { method: 'PATCH', body: JSON.stringify({ name: 'non-member must not rename' }) }
  );
  assert.equal(nonMemberUpdate.response.status, 200);
  assert.deepEqual(nonMemberUpdate.body, [], 'non-member modified another household');
  const reverseNonMemberUpdate = await rest(
    fetchImpl, supabaseUrl, anonKey, b.token,
    `households?id=eq.${aPersonal[0].id}`,
    { method: 'PATCH', body: JSON.stringify({ name: 'non-member must not rename' }) }
  );
  assert.equal(reverseNonMemberUpdate.response.status, 200);
  assert.deepEqual(reverseNonMemberUpdate.body, [], 'User B modified User A household as a non-member');

  const members = await rest(
    fetchImpl, supabaseUrl, anonKey, a.token,
    `household_members?select=household_id,user_id,role&household_id=eq.${aPersonal[0].id}`
  );
  assert.ok(members.body.some(item => item.user_id === a.userId && item.role === 'owner'));

  const ownerDelete = await rest(
    fetchImpl, supabaseUrl, anonKey, a.token,
    `household_members?household_id=eq.${aPersonal[0].id}&user_id=eq.${a.userId}`,
    { method: 'DELETE' }
  );
  assert.equal(ownerDelete.response.status, 200);
  assert.deepEqual(ownerDelete.body, [], 'last owner membership was deletable');
  const ownerDemotion = await rest(
    fetchImpl, supabaseUrl, anonKey, a.token,
    `household_members?household_id=eq.${aPersonal[0].id}&user_id=eq.${a.userId}`,
    { method: 'PATCH', body: JSON.stringify({ role: 'member' }) }
  );
  assert.equal(ownerDemotion.response.status, 200);
  assert.deepEqual(ownerDemotion.body, [], 'last owner membership was demotable');

  const oldName = aPersonal[0].name;
  const temporaryName = `Phase 0.5 Kitchen ${Date.now()}`;
  let householdChanged = false;
  try {
    const ownerUpdate = await rest(
      fetchImpl, supabaseUrl, anonKey, a.token,
      `households?id=eq.${aPersonal[0].id}`,
      { method: 'PATCH', body: JSON.stringify({ name: temporaryName }) }
    );
    householdChanged = true;
    assert.equal(ownerUpdate.response.status, 200);
    assert.equal(ownerUpdate.body[0]?.name, temporaryName);
  } finally {
    if (householdChanged) {
      const restored = await rest(
        fetchImpl, supabaseUrl, anonKey, a.token,
        `households?id=eq.${aPersonal[0].id}`,
        { method: 'PATCH', body: JSON.stringify({ name: oldName }) }
      );
      assert.equal(restored.response.status, 200);
    }
  }

  const existingMembership = members.body.find(item => item.user_id === b.userId);
  let createdMembership = false;
  if (existingMembership && existingMembership.role !== 'member') {
    throw new Error('User B already has a privileged role in User A household; use fresh smoke users');
  }
  if (!existingMembership) {
    const inserted = await rest(fetchImpl, supabaseUrl, anonKey, a.token, 'household_members', {
      method: 'POST',
      body: JSON.stringify({ household_id: aPersonal[0].id, user_id: b.userId, role: 'member' }),
      prefer: 'return=minimal'
    });
    assert.ok(inserted.response.status === 201 || inserted.response.status === 204);
    createdMembership = true;
  }

  try {
    const memberUpdate = await rest(
      fetchImpl, supabaseUrl, anonKey, b.token,
      `households?id=eq.${aPersonal[0].id}`,
      { method: 'PATCH', body: JSON.stringify({ name: 'member must not rename' }) }
    );
    assert.equal(memberUpdate.response.status, 200);
    assert.deepEqual(memberUpdate.body, [], 'ordinary member performed owner-only update');
  } finally {
    if (createdMembership) {
      const cleanup = await rest(
        fetchImpl, supabaseUrl, anonKey, a.token,
        `household_members?household_id=eq.${aPersonal[0].id}&user_id=eq.${b.userId}`,
        { method: 'DELETE', prefer: 'return=minimal' }
      );
      assert.ok(cleanup.response.status === 204 || cleanup.response.status === 200);
    }
  }
}

async function assertGuestRoutes(fetchImpl, expressBase) {
  const status = await requestJson(fetchImpl, `${expressBase}/api/ai-status`);
  assert.equal(status.response.status, 200, 'Guest /api/ai-status is unavailable');
  const recipes = await requestJson(fetchImpl, `${expressBase}/data/sichuan-recipes.curated.json`);
  assert.equal(recipes.response.status, 200, 'Guest public recipe data is unavailable');
  for (const [pathname, options] of [
    ['/api/xhs-extract', {}],
    ['/api/ai-parse', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' }],
    ['/api/ai-chat', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' }]
  ]) {
    const result = await requestJson(fetchImpl, `${expressBase}${pathname}`, options);
    assert.notEqual(result.response.status, 401, `Guest route unexpectedly requires auth: ${pathname}`);
  }
}

async function optionalRateLimitCheck(fetchImpl, expressBase, a, b, env) {
  if (String(env.AUTH_SMOKE_TEST_RATE_LIMIT || '').toLowerCase() !== 'true') return 'skipped';
  const cap = Number.parseInt(env.AUTH_SMOKE_RATE_LIMIT_REQUEST_CAP || '70', 10);
  let limited = false;
  for (let index = 0; index < cap; index += 1) {
    const result = await requestJson(fetchImpl, `${expressBase}/api/me`, { token: a.token });
    if (result.response.status === 429) { limited = true; break; }
    assert.equal(result.response.status, 200);
  }
  assert.equal(limited, true, `rate limit did not trigger within ${cap} requests`);
  const otherUser = await requestJson(fetchImpl, `${expressBase}/api/me`, { token: b.token });
  assert.equal(otherUser.response.status, 200, 'User A consumed User B rate-limit bucket');
  return 'passed';
}

export async function runAuthSmokeTest({
  env = process.env,
  fetchImpl = globalThis.fetch,
  logger = console,
  getWithBody = getWithJsonBody
} = {}) {
  const config = await runStage('config', async () => {
    const supabaseUrl = validateHttpUrl(required(env, 'SUPABASE_URL'), 'SUPABASE_URL');
    const anonKey = required(env, 'SUPABASE_ANON_KEY');
    const jwksUrl = validateHttpUrl(required(env, 'SUPABASE_JWKS_URL'), 'SUPABASE_JWKS_URL');
    const issuer = validateHttpUrl(required(env, 'SUPABASE_JWT_ISSUER'), 'SUPABASE_JWT_ISSUER');
    const audience = required(env, 'SUPABASE_JWT_AUDIENCE');
    const expressBase = validateHttpUrl(env.EXPRESS_API_BASE || 'http://127.0.0.1:3000', 'EXPRESS_API_BASE');
    const userAEmail = required(env, 'TEST_USER_A_EMAIL');
    const userAPassword = required(env, 'TEST_USER_A_PASSWORD');
    const userBEmail = required(env, 'TEST_USER_B_EMAIL');
    const userBPassword = required(env, 'TEST_USER_B_PASSWORD');
    ensureDevelopmentTarget(env, supabaseUrl);
    assert.equal(issuer, `${supabaseUrl}/auth/v1`, 'JWT issuer does not match SUPABASE_URL');
    assert.equal(jwksUrl, `${supabaseUrl}/auth/v1/.well-known/jwks.json`, 'JWKS URL does not match SUPABASE_URL');
    assert.equal(audience, 'authenticated', 'SUPABASE_JWT_AUDIENCE must be authenticated');
    return {
      supabaseUrl, anonKey, jwksUrl, issuer, audience, expressBase,
      userAEmail, userAPassword, userBEmail, userBPassword
    };
  }, { env });
  const {
    supabaseUrl, anonKey, jwksUrl, issuer, audience, expressBase,
    userAEmail, userAPassword, userBEmail, userBPassword
  } = config;

  let a;
  let b;
  try {
    await runStage('express-reachability', async () => {
      const missing = await requestJson(fetchImpl, `${expressBase}/api/me`);
      assert.equal(
        missing.response.status,
        401,
        `expected unauthenticated /api/me to return 401, got ${missing.response.status}; another process may own the port or Express may be stale`
      );
    }, {
      env,
      target: expressBase,
      hint: 'Start Express with the development env; if the port is occupied, stop the stale process.'
    });

    a = await runStage(
      'supabase-sign-in-a',
      () => signIn(fetchImpl, supabaseUrl, anonKey, userAEmail, userAPassword),
      { env, target: supabaseUrl }
    );
    b = await runStage(
      'supabase-sign-in-b',
      () => signIn(fetchImpl, supabaseUrl, anonKey, userBEmail, userBPassword),
      { env, target: supabaseUrl }
    );
    assert.notEqual(a.userId, b.userId, 'smoke users must be distinct');
    const repeatedA = await runStage(
      'supabase-sign-in-a-repeat',
      () => signIn(fetchImpl, supabaseUrl, anonKey, userAEmail, userAPassword),
      { env, target: supabaseUrl }
    );
    assert.equal(repeatedA.userId, a.userId, 'repeated login resolved to a different user');
    repeatedA.token = '';

    await runStage('jwks', async () => {
      const [header, payload] = a.token.split('.').slice(0, 2).map(base64UrlJson);
      assert.ok(['ES256', 'RS256'].includes(header.alg), `unsupported JWT algorithm: ${header.alg}`);
      assert.ok(header.kid, 'access token has no kid');
      assert.equal(payload.iss, issuer, 'JWT issuer mismatch');
      assert.ok(payload.aud === audience || payload.aud?.includes?.(audience), 'JWT audience mismatch');
      const jwks = await requestJson(fetchImpl, jwksUrl, { headers: { apikey: anonKey } });
      assert.equal(jwks.response.status, 200, `JWKS returned HTTP ${jwks.response.status}`);
      assert.ok(jwks.body?.keys?.some(key => key.kid === header.kid && key.alg === header.alg));
    }, { env, target: jwksUrl, hint: 'Check the signing key and JWKS endpoint.' });

    await runStage('api-me', async () => {
      const accountA = await requestJson(fetchImpl, `${expressBase}/api/me`, { token: a.token });
      const accountB = await requestJson(fetchImpl, `${expressBase}/api/me`, { token: b.token });
      assertOwnAccount(accountA, a);
      assertOwnAccount(accountB, b);
      const aHouseholdIds = new Set(accountA.body.households.map(item => item.id));
      assert.ok(!accountB.body.households.some(item => aHouseholdIds.has(item.id)), 'fresh smoke users share a household unexpectedly');

      const forged = await getWithBody(`${expressBase}/api/me`, a.token, { userID: b.userId, userId: b.userId });
      assert.equal(forged.response.status, 200);
      assert.equal(forged.body?.user?.id, a.userId, 'request body overrode verified JWT subject');
      const forgedQuery = await requestJson(
        fetchImpl,
        `${expressBase}/api/me?userID=${encodeURIComponent(b.userId)}&userId=${encodeURIComponent(b.userId)}`,
        { token: a.token }
      );
      assert.equal(forgedQuery.response.status, 200);
      assert.equal(forgedQuery.body?.user?.id, a.userId, 'request query overrode verified JWT subject');

      const damaged = await requestJson(fetchImpl, `${expressBase}/api/me`, { token: `${a.token.slice(0, -2)}xx` });
      assert.equal(damaged.response.status, 401);
      assert.equal(damaged.body?.error?.code, 'invalid_token');
      assert.doesNotMatch(damaged.text, /JWT|JWKS|signature|issuer|audience/i);
    }, {
      env,
      target: expressBase,
      hint: 'Restart Express after loading the latest development environment variables.'
    });

    await runStage('rls', () => assertRls({ fetchImpl, supabaseUrl, anonKey, a, b }), { env, target: supabaseUrl });
    await runStage('guest-routes', () => assertGuestRoutes(fetchImpl, expressBase), { env, target: expressBase });
    const rateLimit = await runStage(
      'rate-limit',
      () => optionalRateLimitCheck(fetchImpl, expressBase, a, b, env),
      { env, target: expressBase }
    );

    logger.log('[auth-smoke] real Auth/JWKS: PASS');
    logger.log('[auth-smoke] trigger, /api/me, user isolation and RLS: PASS');
    logger.log('[auth-smoke] Guest route authentication boundary: PASS');
    logger.log(`[auth-smoke] rate-limit saturation: ${rateLimit === 'passed' ? 'PASS' : 'SKIP (opt-in)'}`);
    return { users: 2, rateLimit };
  } finally {
    if (a) { a.token = ''; a = null; }
    if (b) { b.token = ''; b = null; }
  }
}

async function main() {
  try {
    await runAuthSmokeTest();
  } catch (error) {
    const stage = error instanceof SmokeStageError ? error.stage : 'unexpected';
    console.error(`[auth-smoke][${stage}] failed: ${redactDiagnostic(error.message, process.env)}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  await main();
}

export {
  SmokeStageError,
  redactDiagnostic,
  runStage,
  safeCause
};

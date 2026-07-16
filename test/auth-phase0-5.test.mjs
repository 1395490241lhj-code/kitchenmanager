import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import {
  ensureDevelopmentTarget,
  maskedHost,
  validateHttpUrl,
  verifyMigrationSource,
  verifySupabasePhase0
} from '../scripts/verify-supabase-phase0.mjs';
import {
  SmokeStageError,
  redactDiagnostic,
  runAuthSmokeTest
} from '../scripts/auth-smoke.mjs';

const require = createRequire(import.meta.url);
const { createAuthenticateRequest } = require('../src/server/auth/jwt');

const safeEnv = {
  SUPABASE_URL: 'https://phase05dev.supabase.co',
  SUPABASE_ANON_KEY: 'public-anon-placeholder-key-with-safe-length',
  SUPABASE_JWKS_URL: 'https://phase05dev.supabase.co/auth/v1/.well-known/jwks.json',
  SUPABASE_JWT_ISSUER: 'https://phase05dev.supabase.co/auth/v1',
  SUPABASE_JWT_AUDIENCE: 'authenticated',
  SUPABASE_ENVIRONMENT: 'development'
};

test('Phase 0.5 verifier accepts matching development metadata and asymmetric JWKS', async () => {
  const logs = [];
  const result = await verifySupabasePhase0({
    env: safeEnv,
    fetchImpl: async () => new Response(JSON.stringify({
      keys: [{ kid: 'dev-key', alg: 'ES256', kty: 'EC', use: 'sig' }]
    }), { status: 200, headers: { 'content-type': 'application/json' } }),
    logger: { log(value) { logs.push(value); } }
  });
  assert.deepEqual(result, { keyCount: 1, algorithms: ['ES256'] });
  assert.ok(logs.some(line => line.includes('JWKS: OK')));
  assert.ok(logs.every(line => !line.includes(safeEnv.SUPABASE_ANON_KEY)));
});

test('Phase 0.5 verifier rejects HS256/shared-secret JWKS', async () => {
  await assert.rejects(
    verifySupabasePhase0({
      env: safeEnv,
      fetchImpl: async () => new Response(JSON.stringify({
        keys: [{ kid: 'legacy', alg: 'HS256', kty: 'oct' }]
      }), { status: 200 })
    }),
    /unsupported signing algorithm|shared-secret/
  );
});

test('remote scripts require an explicit non-production environment marker', () => {
  assert.throws(
    () => ensureDevelopmentTarget({}, safeEnv.SUPABASE_URL),
    /Refusing remote verification/
  );
  assert.doesNotThrow(() => ensureDevelopmentTarget({}, 'http://127.0.0.1:54321'));
  assert.equal(maskedHost(safeEnv.SUPABASE_URL), 'phas…ev.supabase.co');
});

test('URL validation rejects mistyped and duplicate protocols without echoing their values', () => {
  assert.throws(
    () => validateHttpUrl('rhttps://example.invalid', 'SUPABASE_URL'),
    /Invalid SUPABASE_URL: protocol must be http or https/
  );
  assert.throws(
    () => validateHttpUrl('https://https://example.invalid', 'SUPABASE_URL'),
    /Invalid SUPABASE_URL: duplicate protocol/
  );
  assert.equal(validateHttpUrl('https://example.invalid/', 'SUPABASE_URL'), 'https://example.invalid');
});

test('migration semantic verification rejects open RLS policies', () => {
  const minimal = [
    'create table if not exists public.profiles',
    'create table if not exists public.households',
    'create table if not exists public.household_members',
    'households_one_personal_per_creator_idx',
    'primary key (household_id, user_id)',
    "role in ('owner', 'admin', 'member')",
    'create trigger on_auth_user_created_or_email_changed',
    'alter table public.profiles enable row level security',
    'alter table public.households enable row level security',
    'alter table public.household_members enable row level security',
    'profiles_select_self',
    'households_select_for_members',
    'household_members_select_for_members',
    'using (true)'
  ].join('\n');
  assert.throws(() => verifyMigrationSource(minimal), /using \(true\)/i);
});

test('auth smoke fails closed when credentials are missing and never logs a token', async () => {
  const logs = [];
  const fetchImpl = async url => {
    assert.match(String(url), /\/api\/me$/);
    return new Response(JSON.stringify({ error: { code: 'auth_required' } }), { status: 401 });
  };
  await assert.rejects(
    runAuthSmokeTest({
      env: { ...safeEnv, EXPRESS_API_BASE: 'http://127.0.0.1:3000' },
      fetchImpl,
      logger: { log(value) { logs.push(value); } }
    }),
    /TEST_USER_A_EMAIL/
  );
  assert.deepEqual(logs, []);
});

test('auth smoke diagnoses missing User B configuration during config stage before network access', async () => {
  let requests = 0;
  await assert.rejects(
    runAuthSmokeTest({
      env: {
        ...safeEnv,
        EXPRESS_API_BASE: 'http://127.0.0.1:3000',
        TEST_USER_A_EMAIL: 'a@example.invalid',
        TEST_USER_A_PASSWORD: 'secret-a'
      },
      fetchImpl: async () => { requests += 1; throw new Error('must not fetch'); }
    }),
    error => error instanceof SmokeStageError
      && error.stage === 'config'
      && /TEST_USER_B_EMAIL/.test(error.message)
  );
  assert.equal(requests, 0);
});

test('auth smoke attributes rejected User B credentials to the sign-in B stage without response leakage', async () => {
  let signInCount = 0;
  const fetchImpl = async url => {
    if (String(url).endsWith('/api/me')) {
      return new Response(JSON.stringify({ error: { code: 'auth_required' } }), { status: 401 });
    }
    if (String(url).includes('/auth/v1/token')) {
      signInCount += 1;
      if (signInCount === 1) {
        return new Response(JSON.stringify({
          access_token: 'not-logged-or-returned',
          user: { id: '11111111-1111-4111-8111-111111111111' }
        }), { status: 200 });
      }
      return new Response(JSON.stringify({
        error_description: 'sensitive upstream auth response must not appear'
      }), { status: 400 });
    }
    throw new Error('unexpected request');
  };
  await assert.rejects(
    runAuthSmokeTest({
      env: {
        ...safeEnv,
        EXPRESS_API_BASE: 'http://127.0.0.1:3000',
        TEST_USER_A_EMAIL: 'a@example.invalid',
        TEST_USER_A_PASSWORD: 'secret-a',
        TEST_USER_B_EMAIL: 'b@example.invalid',
        TEST_USER_B_PASSWORD: 'secret-b'
      },
      fetchImpl
    }),
    error => error instanceof SmokeStageError
      && error.stage === 'supabase-sign-in-b'
      && /HTTP 400/.test(error.message)
      && !/sensitive upstream/.test(error.message)
  );
});

test('auth smoke reports safe Express reachability diagnostics and redacts known secrets', async () => {
  const networkError = new TypeError('fetch failed', { cause: { code: 'ECONNREFUSED' } });
  await assert.rejects(
    runAuthSmokeTest({
      env: {
        ...safeEnv,
        EXPRESS_API_BASE: 'http://127.0.0.1:3000',
        TEST_USER_A_EMAIL: 'a@example.invalid',
        TEST_USER_A_PASSWORD: 'secret-a',
        TEST_USER_B_EMAIL: 'b@example.invalid',
        TEST_USER_B_PASSWORD: 'secret-b'
      },
      fetchImpl: async () => { throw networkError; }
    }),
    error => error instanceof SmokeStageError
      && error.stage === 'express-reachability'
      && /127\.0\.0\.1/.test(error.message)
      && /ECONNREFUSED/.test(error.message)
      && !/secret-[ab]/.test(error.message)
  );
  assert.equal(
    redactDiagnostic('Bearer secret-a', { TEST_USER_A_PASSWORD: 'secret-a' }),
    'Bearer [redacted]'
  );
});

test('temporary JWKS failure remains a sanitized 401 in authentication middleware', async () => {
  const middleware = createAuthenticateRequest({ verifyToken: async () => {
    const error = new Error('JWKS fetch failed with internal endpoint details');
    error.code = 'ERR_JWKS_TIMEOUT';
    throw error;
  } });
  const req = { headers: { authorization: 'Bearer opaque-value' } };
  const res = {
    statusCode: 200,
    body: null,
    status(code) { this.statusCode = code; return this; },
    json(value) { this.body = value; return this; }
  };
  await middleware(req, res, () => assert.fail('middleware must reject'));
  assert.equal(res.statusCode, 401);
  assert.equal(res.body.error.code, 'invalid_token');
  assert.doesNotMatch(JSON.stringify(res.body), /JWKS|endpoint|timeout/i);
});

test('Phase 0.5 scripts keep credentials environment-only and include required live checks', async () => {
  const source = await readFile(new URL('../scripts/auth-smoke.mjs', import.meta.url), 'utf8');
  assert.match(source, /TEST_USER_A_EMAIL/);
  assert.match(source, /TEST_USER_B_PASSWORD/);
  assert.match(source, /ordinary member performed owner-only update/);
  assert.match(source, /request body overrode verified JWT subject/);
  assert.match(source, /AUTH_SMOKE_TEST_RATE_LIMIT/);
  assert.match(source, /Guest route unexpectedly requires auth/);
  assert.doesNotMatch(source, /password\s*[:=]\s*['"][^'"]+['"]/i);
  assert.doesNotMatch(source, /eyJ[a-zA-Z0-9_-]{20,}\./);
});

test('database object pgTAP checks tables, RLS, indexes, trigger uniqueness, and policies', async () => {
  const source = await readFile(
    new URL('../supabase/tests/auth_household_objects_test.sql', import.meta.url),
    'utf8'
  );
  assert.match(source, /select plan\(12\)/i);
  for (const table of ['profiles', 'households', 'household_members']) {
    assert.match(source, new RegExp(`public\\.${table}`));
  }
  assert.match(source, /relrowsecurity/);
  assert.match(source, /households_one_personal_per_creator_idx/);
  assert.match(source, /on_auth_user_created_or_email_changed/);
  assert.match(source, /pg_policies/);
  assert.match(source, /auth initialization trigger exists exactly once/);
});

test('remote object verifier checks constraints, all triggers/policies, and personal-household integrity', async () => {
  const source = await readFile(
    new URL('../supabase/remote-verify/auth_household_remote_verify.sql', import.meta.url),
    'utf8'
  );
  assert.match(source, /profiles_set_updated_at/);
  assert.match(source, /households_set_updated_at/);
  assert.match(source, /on_auth_user_created_or_email_changed/);
  assert.match(source, /policy set differs from migration/);
  assert.match(source, /profiles\/auth\.users foreign key is invalid/);
  assert.match(source, /membership role constraint is missing/);
  assert.match(source, /duplicate personal household detected/);
  assert.match(source, /personal household owner membership is missing/);
  assert.doesNotMatch(source, /select\s+email|raw_user_meta_data|encrypted_password/i);
});

test('Express startup reports port conflicts without dumping environment or request data', async () => {
  const source = await readFile(new URL('../server.js', import.meta.url), 'utf8');
  assert.match(source, /httpServer\.on\('error'/);
  assert.match(source, /EADDRINUSE/);
  assert.match(source, /端口.*已被占用/);
  const handler = source.match(/httpServer\.on\('error',[\s\S]*?\n\}\);/)?.[0] || '';
  assert.doesNotMatch(handler, /process\.env|authorization|req\.|token/i);
});

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const MIGRATION = path.join(
  ROOT,
  'supabase/migrations/20260713000100_auth_household_foundation.sql'
);
const ALLOWED_ALGORITHMS = new Set(['ES256', 'RS256']);
const SAFE_ENVIRONMENTS = new Set(['development', 'dev', 'test', 'local', 'staging']);

function required(env, name) {
  const value = String(env[name] || '').trim();
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function normalizedUrl(value) {
  return value.replace(/\/+$/, '');
}

function validateHttpUrl(value, name) {
  const trimmed = String(value || '').trim();
  if (!trimmed) throw new Error(`Missing required environment variable: ${name}`);
  const protocolSeparator = trimmed.indexOf('://');
  if (protocolSeparator >= 0 && trimmed.slice(protocolSeparator + 3).includes('://')) {
    throw new Error(`Invalid ${name}: duplicate protocol`);
  }
  let parsed;
  try {
    parsed = new URL(trimmed);
  } catch {
    throw new Error(`Invalid ${name}: expected an absolute http/https URL`);
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new Error(`Invalid ${name}: protocol must be http or https`);
  }
  if (parsed.username || parsed.password) {
    throw new Error(`Invalid ${name}: embedded credentials are not allowed`);
  }
  return normalizedUrl(trimmed);
}

function ensureDevelopmentTarget(env, supabaseUrl) {
  const hostname = new URL(supabaseUrl).hostname;
  if (hostname === '127.0.0.1' || hostname === 'localhost') return;
  const environment = String(env.SUPABASE_ENVIRONMENT || '').trim().toLowerCase();
  if (!SAFE_ENVIRONMENTS.has(environment)) {
    throw new Error(
      'Refusing remote verification unless SUPABASE_ENVIRONMENT=development (or staging/test)'
    );
  }
}

function maskedHost(url) {
  const host = new URL(url).hostname;
  const first = host.split('.')[0] || '';
  if (first.length < 7) return host;
  return `${first.slice(0, 4)}…${first.slice(-2)}.${host.split('.').slice(1).join('.')}`;
}

function verifyMigrationSource(source) {
  const requiredFragments = [
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
    'household_members_select_for_members'
  ];
  for (const fragment of requiredFragments) {
    assert.ok(source.toLowerCase().includes(fragment.toLowerCase()), `migration missing: ${fragment}`);
  }
  assert.doesNotMatch(source, /using\s*\(\s*true\s*\)/i, 'RLS must not contain using (true)');
}

export async function verifySupabasePhase0({
  env = process.env,
  fetchImpl = globalThis.fetch,
  logger = console
} = {}) {
  const supabaseUrl = validateHttpUrl(required(env, 'SUPABASE_URL'), 'SUPABASE_URL');
  const anonKey = required(env, 'SUPABASE_ANON_KEY');
  const jwksUrl = validateHttpUrl(required(env, 'SUPABASE_JWKS_URL'), 'SUPABASE_JWKS_URL');
  const issuer = validateHttpUrl(required(env, 'SUPABASE_JWT_ISSUER'), 'SUPABASE_JWT_ISSUER');
  const audience = required(env, 'SUPABASE_JWT_AUDIENCE');
  ensureDevelopmentTarget(env, supabaseUrl);

  assert.equal(issuer, `${supabaseUrl}/auth/v1`, 'JWT issuer must match the Supabase project URL');
  assert.equal(
    jwksUrl,
    `${supabaseUrl}/auth/v1/.well-known/jwks.json`,
    'JWKS URL must match the Supabase project URL'
  );
  assert.equal(audience, 'authenticated', 'Phase 0 expects Supabase audience "authenticated"');
  assert.ok(anonKey.length >= 20, 'anon/publishable key appears invalid');

  const migrationSource = await readFile(MIGRATION, 'utf8');
  verifyMigrationSource(migrationSource);

  const response = await fetchImpl(jwksUrl, {
    headers: { Accept: 'application/json', apikey: anonKey }
  });
  assert.equal(response.ok, true, `JWKS request failed with HTTP ${response.status}`);
  const jwks = await response.json();
  assert.ok(Array.isArray(jwks.keys) && jwks.keys.length > 0, 'JWKS contains no signing keys');
  for (const key of jwks.keys) {
    assert.ok(key.kid, 'JWKS key is missing kid');
    assert.ok(ALLOWED_ALGORITHMS.has(key.alg), `unsupported signing algorithm: ${key.alg || 'missing'}`);
    assert.notEqual(key.kty, 'oct', 'HS256/shared-secret keys are not accepted');
  }

  logger.log(`[phase0] target=${maskedHost(supabaseUrl)} environment=${env.SUPABASE_ENVIRONMENT || 'local'}`);
  logger.log(`[phase0] migration source: OK (${path.basename(MIGRATION)})`);
  logger.log(`[phase0] JWKS: OK (${jwks.keys.length} asymmetric signing key(s))`);
  logger.log('[phase0] database objects/RLS: run auth smoke and `npx supabase test db` for live proof');
  return { keyCount: jwks.keys.length, algorithms: [...new Set(jwks.keys.map(key => key.alg))] };
}

async function main() {
  try {
    await verifySupabasePhase0();
  } catch (error) {
    console.error(`[phase0] verification failed: ${error.message}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  await main();
}

export { ensureDevelopmentTarget, maskedHost, validateHttpUrl, verifyMigrationSource };

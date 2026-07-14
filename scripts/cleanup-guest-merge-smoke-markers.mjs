// One-off cleanup: soft-deletes any inventory_item in TEST_USER_A's default
// household whose name starts with a known smoke marker prefix, via
// the authorized user-level sync API (no service-role key, no physical
// delete) — used when a hosted Guest merge smoke run is interrupted before
// its own session rollback runs, so orphaned marker rows don't linger.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { ensureDevelopmentTarget, validateHttpUrl } from './verify-supabase-phase0.mjs';
import { redact } from './sync-smoke.mjs';

// Phase 2B-2/2.5 use `__guest_merge_smoke_`; Phase 2B-4's CRUD-sync-staging
// minimal smoke uses its own `__inventory_crud_smoke_` prefix — both are
// swept here so an interrupted run of either never leaves orphaned rows.
const MARKER_PREFIXES = ['__guest_merge_smoke_', '__inventory_crud_smoke_'];

function required(env, name) {
  const value = String(env[name] || '').trim();
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

async function readJson(response) {
  const text = await response.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  return { response, body, text };
}

async function signIn(config, email, password) {
  const result = await readJson(await fetch(`${config.supabaseUrl}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: config.anonKey, Accept: 'application/json', 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password })
  }));
  assert.equal(result.response.status, 200, `development sign-in failed (${result.response.status})`);
  assert.ok(result.body?.access_token && result.body?.user?.id, 'development sign-in response is incomplete');
  return { token: result.body.access_token, userId: result.body.user.id };
}

async function expressRequest(config, session, route, options = {}) {
  const headers = { Accept: 'application/json', ...(options.headers || {}) };
  if (session?.token) headers.Authorization = `Bearer ${session.token}`;
  if (options.body) headers['Content-Type'] = 'application/json';
  return readJson(await fetch(`${config.expressBase}${route}`, { ...options, headers }));
}

async function main() {
  const env = process.env;
  const config = {
    supabaseUrl: validateHttpUrl(required(env, 'SUPABASE_URL'), 'SUPABASE_URL'),
    anonKey: required(env, 'SUPABASE_ANON_KEY'),
    expressBase: validateHttpUrl(env.EXPRESS_API_BASE || 'https://kitchenmanager-b8px.onrender.com', 'EXPRESS_API_BASE')
  };
  ensureDevelopmentTarget(env, config.supabaseUrl);
  const session = await signIn(config, required(env, 'TEST_USER_A_EMAIL'), required(env, 'TEST_USER_A_PASSWORD'));

  const bootstrapResult = await expressRequest(config, session, '/api/sync/bootstrap');
  assert.equal(bootstrapResult.response.status, 200, 'bootstrap failed');
  const householdId = bootstrapResult.body?.defaultHouseholdId;
  assert.ok(householdId, 'no default household on this account');

  const marked = new Map();
  let cursor = '0';
  let hasMore = true;
  let pages = 0;
  while (hasMore && pages < 50) {
    const page = await expressRequest(
      config, session,
      `/api/sync/changes?scopeType=household&scopeId=${householdId}&cursor=${cursor}&limit=100&entityTypes=inventory_item`
    );
    assert.equal(page.response.status, 200, 'changes fetch failed');
    for (const change of page.body?.changes || []) {
      if (change.operation === 'delete') { marked.delete(change.entityId); continue; }
      const name = change.data?.name || '';
      if (MARKER_PREFIXES.some(prefix => name.startsWith(prefix))) {
        marked.set(change.entityId, change.version);
      } else {
        marked.delete(change.entityId);
      }
    }
    cursor = page.body?.cursor ?? cursor;
    hasMore = Boolean(page.body?.hasMore);
    pages += 1;
  }

  console.log(`[cleanup] found ${marked.size} marker row(s) to soft-delete`);
  let deleted = 0;
  for (const [entityId, version] of marked) {
    const result = await expressRequest(config, session, '/api/sync/mutations', {
      method: 'POST',
      body: JSON.stringify({
        scopeType: 'household', scopeId: householdId,
        mutations: [{
          mutationId: randomUUID(), entityType: 'inventory_item', entityId,
          operation: 'delete', baseVersion: String(version), clientUpdatedAt: new Date().toISOString()
        }]
      })
    });
    const status = result.body?.results?.[0]?.status;
    if (result.response.status === 200 && (status === 'applied' || status === 'duplicate')) {
      deleted += 1;
    } else {
      console.error(`[cleanup] failed to delete ${entityId}: status=${result.response.status} body=${JSON.stringify(result.body)}`);
    }
  }
  console.log(`[cleanup] soft-deleted ${deleted}/${marked.size} marker row(s)`);
}

main().catch(error => {
  console.error(`[cleanup] failed: ${redact(error?.message, process.env)}`);
  process.exitCode = 1;
});

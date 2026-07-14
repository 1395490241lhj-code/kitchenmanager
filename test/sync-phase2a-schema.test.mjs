import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const migrationUrl = new URL(
  '../supabase/migrations/20260713000200_sync_business_foundation.sql',
  import.meta.url
);
const sql = readFileSync(migrationUrl, 'utf8');

const householdTables = [
  'inventory_items',
  'shopping_items',
  'today_plan_items',
  'consumption_records',
  'weekly_meal_plans',
  'weekly_meal_plan_items',
  'user_recipes'
];
const personalTables = ['recipe_favorites', 'frequent_recipes'];
const infrastructureTables = ['sync_changes', 'sync_mutations'];

test('Phase 2A-1 migration creates the reviewed business and sync tables', () => {
  for (const table of [...householdTables, ...personalTables, ...infrastructureTables]) {
    assert.match(sql, new RegExp(`create table if not exists public\\.${table}\\s*\\(`));
    assert.match(sql, new RegExp(`alter table public\\.${table} enable row level security`));
  }
});

test('household state has ownership, version, audit, and soft-delete semantics', () => {
  for (const table of householdTables) {
    const start = sql.indexOf(`create table if not exists public.${table}`);
    const end = sql.indexOf('\n);', start);
    const definition = sql.slice(start, end);
    for (const field of [
      'household_id uuid not null',
      'created_at timestamptz not null',
      'updated_at timestamptz not null',
      'deleted_at timestamptz',
      'version bigint not null',
      'created_by uuid not null',
      'updated_by uuid not null'
    ]) {
      assert.ok(definition.includes(field), `${table} is missing ${field}`);
    }
  }
});

test('personal preferences are user-scoped and retain tombstone/version state', () => {
  for (const table of personalTables) {
    const start = sql.indexOf(`create table if not exists public.${table}`);
    const end = sql.indexOf('\n);', start);
    const definition = sql.slice(start, end);
    assert.match(definition, /user_id uuid not null references public\.profiles\(id\)/);
    assert.match(definition, /id uuid primary key/);
    assert.match(definition, /unique \(user_id, recipe_id\)/);
    assert.match(definition, /deleted_at timestamptz/);
    assert.match(definition, /version bigint not null default 1/);
  }
});

test('a monotonic unified feed supports independent household and personal scope cursors', () => {
  assert.match(sql, /sequence bigint generated always as identity primary key/);
  assert.match(sql, /constraint sync_changes_exactly_one_scope check/);
  assert.match(sql, /sync_changes_household_cursor_idx[\s\S]*household_id, sequence/);
  assert.match(sql, /sync_changes_user_cursor_idx[\s\S]*user_id, sequence/);
  assert.match(sql, /operation text not null check \(operation in \('upsert', 'delete'\)\)/);
  assert.match(sql, /entity_id uuid not null/);
  assert.match(sql, /record_data jsonb not null check \(jsonb_typeof\(record_data\) = 'object'\)/);
});

test('mutation IDs are unique per verified user and carry baseVersion', () => {
  assert.match(sql, /primary key \(user_id, mutation_id\)/);
  assert.match(sql, /base_version bigint check \(base_version is null or base_version >= 0\)/);
  assert.match(sql, /status text not null check \(status in \('applied', 'conflict', 'rejected'\)\)/);
  assert.match(sql, /request_hash text not null check \(request_hash ~ '\^\[0-9a-f\]\{64\}\$'\)/);
  assert.match(sql, /result_sequence bigint/);
  assert.match(sql, /result_payload jsonb not null/);
});

test('RLS scopes reads without opening direct client writes', () => {
  assert.match(sql, /private\.is_household_member\(household_id, \(select auth\.uid\(\)\)\)/);
  assert.match(sql, /recipe_favorites_select_self[\s\S]*user_id = \(select auth\.uid\(\)\)/);
  assert.match(sql, /frequent_recipes_select_self[\s\S]*user_id = \(select auth\.uid\(\)\)/);
  assert.doesNotMatch(sql, /using\s*\(\s*true\s*\)/i);
  assert.doesNotMatch(sql, /with check\s*\(\s*true\s*\)/i);
  assert.doesNotMatch(sql, /create policy[^;]+for delete/is);
  for (const table of [...householdTables, ...personalTables]) {
    assert.match(sql, new RegExp(`revoke all on table public\\.${table} from anon, authenticated`));
    assert.match(sql, new RegExp(`grant select on table public\\.${table} to authenticated`));
  }
});

test('triggers own actor fields, increment versions, and emit changes', () => {
  assert.match(sql, /new\.created_by := actor/);
  assert.match(sql, /new\.updated_by := actor/);
  assert.match(sql, /new\.version := old\.version \+ 1/);
  assert.match(sql, /new\.household_id is distinct from old\.household_id/);
  assert.match(sql, /write_household_sync_change/);
  assert.match(sql, /write_personal_sync_change/);
  assert.match(sql, /case when new\.deleted_at is not null then 'delete' else 'upsert' end/);
  assert.match(sql, /to_jsonb\(new\)/);
  assert.doesNotMatch(sql, /new\.id::text/, 'UUID change IDs must not be converted to text before insert');
});

test('atomic mutation RPC locks idempotency keys and never trusts client actor/scope fields', () => {
  const start = sql.indexOf('create or replace function public.apply_sync_mutation');
  const end = sql.indexOf('create or replace function public.get_sync_bootstrap', start);
  const rpc = sql.slice(start, end);
  assert.match(rpc, /security definer[\s\S]*set search_path = pg_catalog/);
  assert.match(rpc, /actor uuid := auth\.uid\(\)/);
  assert.match(rpc, /p_scope_type = 'household'[\s\S]*private\.is_household_member\(p_scope_id, actor\)/);
  assert.match(rpc, /p_scope_type = 'user'[\s\S]*p_scope_id <> actor/);
  assert.match(rpc, /scope_kind <> p_scope_type/);
  assert.match(rpc, /pg_advisory_xact_lock/);
  assert.match(rpc, /sha256\(convert_to\(jsonb_build_object/);
  assert.match(rpc, /ledger\.request_hash <> request_hash/);
  assert.match(rpc, /idempotency_mismatch/);
  assert.match(rpc, /\(current_record ->> 'version'\)::bigint <> p_base_version/);
  assert.match(rpc, /set deleted_at = clock_timestamp\(\)/);
  assert.match(rpc, /p_operation = 'delete'[\s\S]*'deleted_at', server_record -> 'deleted_at'/);
  assert.doesNotMatch(rpc, /delete\s+from\s+public\./i);
  assert.doesNotMatch(rpc, /insert into public\.sync_changes/i, 'change feed must be trigger-only');
  assert.doesNotMatch(rpc, /table_name\s*:=\s*p_entity_type/i);
});

test('pull/bootstrap RPCs return independent scopes and enforce ordered BIGINT pagination', () => {
  assert.match(sql, /create or replace function public\.get_sync_bootstrap\(\)[\s\S]*actor uuid := auth\.uid\(\)/);
  assert.match(sql, /'syncScopes', sync_scopes/);
  assert.match(sql, /create or replace function public\.pull_sync_changes[\s\S]*private\.is_household_member\(p_scope_id, actor\)/);
  assert.match(sql, /p_scope_type = 'user'[\s\S]*p_scope_id <> actor/);
  assert.match(sql, /p_scope_type = 'household' and c\.household_id = p_scope_id/);
  assert.match(sql, /p_scope_type = 'user' and c\.user_id = p_scope_id/);
  assert.match(sql, /where c\.sequence > p_cursor[\s\S]*order by c\.sequence asc[\s\S]*limit p_limit \+ 1/);
  assert.match(sql, /p_entity_types <@ allowed_types/);
  assert.match(sql, /else page\.record_data end/);
  assert.match(sql, /revoke all on function public\.apply_sync_mutation[^;]+from public, anon/);
  assert.match(sql, /grant execute on function public\.apply_sync_mutation[^;]+to authenticated/);
  assert.match(sql, /revoke all on function public\.pull_sync_changes[^;]+from public, anon/);
  assert.match(sql, /grant execute on function public\.pull_sync_changes[^;]+to authenticated/);
});

test('the draft contains no service key, credential, remote push, or permissive bypass', () => {
  assert.doesNotMatch(sql, /service[_ -]?role/i);
  assert.doesNotMatch(sql, /supabase_db_password|authorization:\s*bearer|eyJ[a-zA-Z0-9_-]+\./i);
  assert.doesNotMatch(sql, /db\s+push|--linked/i);
  assert.doesNotMatch(sql, /grant\s+(insert|update|delete|all)[^;]*to authenticated/i);
});

test('pgTAP object audit covers tables, RLS, triggers, indexes, and closed DML', () => {
  const source = readFileSync(
    new URL('../supabase/tests/sync_business_objects_test.sql', import.meta.url),
    'utf8'
  );
  assert.match(source, /select plan\(44\)/);
  assert.match(source, /all nine mutable entity tables have version\/audit triggers/);
  assert.match(source, /inventory direct DML has no RLS policy/);
  assert.match(source, /household cursor index exists/);
  assert.match(source, /personal cursor index exists/);
  assert.match(source, /atomic mutation RPC exists exactly once/);
  assert.match(source, /authenticated direct inventory INSERT remains revoked/);
});

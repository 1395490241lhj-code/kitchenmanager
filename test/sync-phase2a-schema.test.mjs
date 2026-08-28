import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import test from 'node:test';

const migrationUrl = new URL(
  '../supabase/migrations/20260713000200_sync_business_foundation.sql',
  import.meta.url
);
const sql = readFileSync(migrationUrl, 'utf8');

const patchMigrationUrl = new URL(
  '../supabase/migrations/20260827000100_sync_mutation_patch_semantics.sql',
  import.meta.url
);
const patchSql = readFileSync(patchMigrationUrl, 'utf8');

const require = createRequire(import.meta.url);
const { DB_FIELD_NAMES, ENTITY_DEFINITIONS, ENTITY_TYPES } = require('../src/server/sync/entities');

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
  assert.match(source, /select plan\(46\)/);
  assert.match(source, /all nine mutable entity tables have version\/audit triggers/);
  assert.match(source, /inventory direct DML has no RLS policy/);
  assert.match(source, /household cursor index exists/);
  assert.match(source, /personal cursor index exists/);
  assert.match(source, /atomic mutation RPC exists exactly once/);
  assert.match(source, /authenticated direct inventory INSERT remains revoked/);
});

// --- 20260827000100: mutation PATCH semantics ------------------------------

test('the PATCH migration replaces the RPC without editing the reviewed foundation migration', () => {
  assert.match(patchSql, /create or replace function public\.apply_sync_mutation/);
  // Schema-only migration boundary: replacing a function must not smuggle in
  // a table/column change.
  assert.doesNotMatch(patchSql, /create table|alter table|drop (table|column|function)/i);
  // 20260713000200 still carries its original whole-column update, untouched.
  assert.match(sql, /from unnest\(column_names\) item/);
  assert.doesNotMatch(sql, /patch_data/);
});

test('an update writes only the columns the client actually sent', () => {
  assert.match(patchSql, /from jsonb_object_keys\(patch_data\) item/);
  // The update no longer walks the whole per-entity allowlist...
  assert.doesNotMatch(patchSql, /from unnest\(column_names\) item/);
  // ...but the allowlist itself still gates which keys are even accepted.
  assert.match(patchSql, /not \(key = any\(column_names\)\)/);
  assert.match(patchSql, /mutation contains unsupported fields/);
  // Every identifier reaching SQL is still quoted, never interpolated raw.
  assert.match(patchSql, /format\('%I', item\)/);
  assert.doesNotMatch(patchSql, /table_name\s*:=\s*p_entity_type/i);
});

test('a single-column update avoids the parenthesized multi-column form', () => {
  assert.match(patchSql, /array_length\(update_names, 1\) = 1/);
  assert.match(patchSql, /'%I = \(select source\.%I from jsonb_populate_record/);
  assert.match(patchSql, /'\(%s\) = \(select %s from jsonb_populate_record/);
});

test('server-side defaults are applied by the insert branch only', () => {
  // default_data is folded in exactly once, into the create-only payload.
  assert.equal(patchSql.match(/default_data \|\|/g)?.length, 1);
  assert.match(patchSql, /create_data := default_data \|\| p_data/);
  assert.match(patchSql, /system_data := create_data \|\| jsonb_build_object/);
  // The update executes against the client's own payload.
  assert.match(patchSql, /using patch_data, p_entity_id, p_scope_id, p_base_version/);
  assert.match(patchSql, /using patch_data, p_entity_id, actor, p_base_version/);
});

test('every create-time default the validator dropped is supplied by the RPC instead', () => {
  // The validator no longer materializes defaults, so `default_data` in the
  // RPC is now the only thing standing between a sparse create and a NOT NULL
  // violation. Adding a defaulted field to entities.js without adding it here
  // would break creates for that entity at runtime, not at review time.
  const caseBlock = patchSql.slice(patchSql.indexOf('case p_entity_type'), patchSql.indexOf('end case;'));
  for (const entityType of ENTITY_TYPES) {
    const chunk = caseBlock.slice(caseBlock.indexOf(`when '${entityType}' then`));
    const nextWhen = chunk.slice(1).search(/\n\s*when '/);
    const entitySql = nextWhen === -1 ? chunk : chunk.slice(0, nextWhen + 1);
    const declared = entitySql.match(/default_data := '([\s\S]*?)'::jsonb/);

    const expected = {};
    for (const [fieldName, rule] of Object.entries(ENTITY_DEFINITIONS[entityType].fields)) {
      let value;
      if ('default' in rule) value = rule.default;
      else if (rule.type.endsWith('Array')) value = [];
      else if (rule.type === 'jsonObject') value = {};
      else continue;
      expected[DB_FIELD_NAMES[fieldName] || fieldName] = value;
    }
    assert.deepEqual(JSON.parse(declared?.[1] || '{}'), expected, entityType);
  }
});

test('required fields must be present only on a create, but must be valid whenever sent', () => {
  assert.match(patchSql, /coalesce\(p_base_version, 0\) = 0 and exists \([\s\S]*not \(create_data \? required_key\)/);
  assert.match(patchSql, /where patch_data \? required_key[\s\S]*btrim\(patch_data ->> required_key\) = ''/);
});

test('an upsert naming no column is rejected instead of rewriting the row', () => {
  assert.match(patchSql, /p_operation = 'upsert' and patch_data = '\{\}'::jsonb/);
  assert.match(patchSql, /error_code := 'empty_update'/);
});

test('the request hash covers the client payload, never server-side defaults', () => {
  assert.match(patchSql, /sha256\(convert_to\(jsonb_build_object[\s\S]*'data', patch_data/);
  assert.doesNotMatch(patchSql, /normalized_data/);
  assert.match(patchSql, /ledger\.request_hash <> request_hash/);
  assert.match(patchSql, /idempotency_mismatch/);
});

test('the PATCH migration preserves the original RPC safety and tombstone contract', () => {
  assert.match(patchSql, /security definer[\s\S]*set search_path = pg_catalog/);
  assert.match(patchSql, /actor uuid := auth\.uid\(\)/);
  assert.match(patchSql, /private\.is_household_member\(p_scope_id, actor\)/);
  assert.match(patchSql, /p_scope_type = 'user'[\s\S]*p_scope_id <> actor/);
  assert.match(patchSql, /scope_kind <> p_scope_type/);
  assert.match(patchSql, /pg_advisory_xact_lock/);
  // Tombstone / version / conflict behaviour is carried over verbatim.
  assert.match(patchSql, /set deleted_at = clock_timestamp\(\)/);
  assert.match(patchSql, /deleted_at = null where id = \$2/);
  assert.match(patchSql, /result_status := 'conflict'; error_code := 'stale_version'/);
  for (const code of ['not_found', 'invalid_create_version', 'already_deleted', 'invalid_payload']) {
    assert.match(patchSql, new RegExp(`'${code}'`));
  }
  assert.doesNotMatch(patchSql, /delete\s+from\s+public\./i);
  assert.doesNotMatch(patchSql, /insert into public\.sync_changes/i);
});

test('the PATCH migration keeps the RPC grants closed and carries no credential', () => {
  assert.match(patchSql, /revoke all on function public\.apply_sync_mutation[^;]+from public, anon/);
  assert.match(patchSql, /grant execute on function public\.apply_sync_mutation[^;]+to authenticated/);
  assert.doesNotMatch(patchSql, /grant\s+(insert|update|delete|all)[^;]*to authenticated/i);
  assert.doesNotMatch(patchSql, /service[_ -]?role/i);
  assert.doesNotMatch(patchSql, /supabase_db_password|authorization:\s*bearer|eyJ[a-zA-Z0-9_-]+\./i);
  assert.doesNotMatch(patchSql, /db\s+push|--linked/i);
});

test('pgTAP behavioural coverage exists for PATCH semantics', () => {
  const source = readFileSync(
    new URL('../supabase/tests/sync_business_rls_test.sql', import.meta.url),
    'utf8'
  );
  assert.match(source, /select plan\(51\)/);
  assert.match(source, /an iOS upsert never clears the PWA-owned inventory_items\.kind/);
  assert.match(source, /default_data never resets is_frozen\/cooked_count on an update/);
  assert.match(source, /an explicit null clears the column it names/);
  assert.match(source, /an update that omits the required name applies/);
  assert.match(source, /a create missing a required field is still rejected/);
  assert.match(source, /an empty upsert is reported as empty_update/);
  assert.match(source, /single-column SET syntax is valid/);
  for (const entity of ['shopping_item', 'today_plan', 'consumption_record',
    'weekly_meal_plan', 'weekly_meal_plan_item', 'user_recipe']) {
    assert.match(source, new RegExp(`${entity}: an unsent column is preserved`));
  }
});

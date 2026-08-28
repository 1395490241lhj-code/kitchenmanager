import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
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

// The live RPC contract is whichever migration (re)defines apply_sync_mutation
// last. Binding the semantic assertions below to one hardcoded filename would
// let them keep passing against a superseded definition — the exact failure
// mode f0c9619 fixed on the auth side — so resolve the newest definition and
// assert against that.
const migrationsDirUrl = new URL('../supabase/migrations/', import.meta.url);
const migrationFilenames = readdirSync(migrationsDirUrl)
  .filter(name => name.endsWith('.sql'))
  .sort();
const rpcMigrationName = [...migrationFilenames].reverse().find(name =>
  readFileSync(new URL(name, migrationsDirUrl), 'utf8')
    .includes('create or replace function public.apply_sync_mutation'));
const rpcSql = readFileSync(new URL(rpcMigrationName, migrationsDirUrl), 'utf8');

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
  assert.match(source, /select plan\(51\)/);
  assert.match(source, /inventory preparation_kind exists/);
  assert.match(source, /preparation_kind defaults to none/);
  assert.match(source, /preparation_kind CHECK vocabulary is exactly none\/readyToCook/);
  assert.match(source, /all nine mutable entity tables have version\/audit triggers/);
  assert.match(source, /inventory direct DML has no RLS policy/);
  assert.match(source, /household cursor index exists/);
  assert.match(source, /personal cursor index exists/);
  assert.match(source, /atomic mutation RPC exists exactly once/);
  assert.match(source, /authenticated direct inventory INSERT remains revoked/);
});

// --- the current apply_sync_mutation definition (resolved above) -----------

test('the PATCH migration replaces the RPC without editing the reviewed foundation migration', () => {
  assert.match(patchSql, /create or replace function public\.apply_sync_mutation/);
  // The PATCH migration's own boundary was schema-free: replacing the
  // function without smuggling in a table/column change. (20260828000100
  // legitimately pairs an ALTER TABLE with its RPC replacement — that
  // boundary is asserted in its own test below, per file, not globally.)
  assert.doesNotMatch(patchSql, /create table|alter table|drop (table|column|function)/i);
  // 20260713000200 still carries its original whole-column update, untouched.
  assert.match(sql, /from unnest\(column_names\) item/);
  assert.doesNotMatch(sql, /patch_data/);
});

test('an update writes only the columns the client actually sent', () => {
  assert.match(rpcSql, /from jsonb_object_keys\(patch_data\) item/);
  // The update no longer walks the whole per-entity allowlist...
  assert.doesNotMatch(rpcSql, /from unnest\(column_names\) item/);
  // ...but the allowlist itself still gates which keys are even accepted.
  assert.match(rpcSql, /not \(key = any\(column_names\)\)/);
  assert.match(rpcSql, /mutation contains unsupported fields/);
  // Every identifier reaching SQL is still quoted, never interpolated raw.
  assert.match(rpcSql, /format\('%I', item\)/);
  assert.doesNotMatch(rpcSql, /table_name\s*:=\s*p_entity_type/i);
});

test('a single-column update avoids the parenthesized multi-column form', () => {
  assert.match(rpcSql, /array_length\(update_names, 1\) = 1/);
  assert.match(rpcSql, /'%I = \(select source\.%I from jsonb_populate_record/);
  assert.match(rpcSql, /'\(%s\) = \(select %s from jsonb_populate_record/);
});

test('server-side defaults are applied by the insert branch only', () => {
  // default_data is folded in exactly once, into the create-only payload.
  assert.equal(rpcSql.match(/default_data \|\|/g)?.length, 1);
  assert.match(rpcSql, /create_data := default_data \|\| p_data/);
  assert.match(rpcSql, /system_data := create_data \|\| jsonb_build_object/);
  // The update executes against the client's own payload.
  assert.match(rpcSql, /using patch_data, p_entity_id, p_scope_id, p_base_version/);
  assert.match(rpcSql, /using patch_data, p_entity_id, actor, p_base_version/);
});

test('every create-time default the validator dropped is supplied by the RPC instead', () => {
  // The validator no longer materializes defaults, so `default_data` in the
  // RPC is now the only thing standing between a sparse create and a NOT NULL
  // violation. Adding a defaulted field to entities.js without adding it here
  // would break creates for that entity at runtime, not at review time.
  const caseBlock = rpcSql.slice(rpcSql.indexOf('case p_entity_type'), rpcSql.indexOf('end case;'));
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
  assert.match(rpcSql, /coalesce\(p_base_version, 0\) = 0 and exists \([\s\S]*not \(create_data \? required_key\)/);
  assert.match(rpcSql, /where patch_data \? required_key[\s\S]*btrim\(patch_data ->> required_key\) = ''/);
});

test('an upsert naming no column is rejected instead of rewriting the row', () => {
  assert.match(rpcSql, /p_operation = 'upsert' and patch_data = '\{\}'::jsonb/);
  assert.match(rpcSql, /error_code := 'empty_update'/);
});

test('the request hash covers the client payload, never server-side defaults', () => {
  assert.match(rpcSql, /sha256\(convert_to\(jsonb_build_object[\s\S]*'data', patch_data/);
  assert.doesNotMatch(rpcSql, /normalized_data/);
  assert.match(rpcSql, /ledger\.request_hash <> request_hash/);
  assert.match(rpcSql, /idempotency_mismatch/);
});

test('the PATCH migration preserves the original RPC safety and tombstone contract', () => {
  assert.match(rpcSql, /security definer[\s\S]*set search_path = pg_catalog/);
  assert.match(rpcSql, /actor uuid := auth\.uid\(\)/);
  assert.match(rpcSql, /private\.is_household_member\(p_scope_id, actor\)/);
  assert.match(rpcSql, /p_scope_type = 'user'[\s\S]*p_scope_id <> actor/);
  assert.match(rpcSql, /scope_kind <> p_scope_type/);
  assert.match(rpcSql, /pg_advisory_xact_lock/);
  // Tombstone / version / conflict behaviour is carried over verbatim.
  assert.match(rpcSql, /set deleted_at = clock_timestamp\(\)/);
  assert.match(rpcSql, /deleted_at = null where id = \$2/);
  assert.match(rpcSql, /result_status := 'conflict'; error_code := 'stale_version'/);
  for (const code of ['not_found', 'invalid_create_version', 'already_deleted', 'invalid_payload']) {
    assert.match(rpcSql, new RegExp(`'${code}'`));
  }
  assert.doesNotMatch(rpcSql, /delete\s+from\s+public\./i);
  assert.doesNotMatch(rpcSql, /insert into public\.sync_changes/i);
});

test('the current RPC migration keeps the grants closed and carries no credential', () => {
  assert.match(rpcSql, /revoke all on function public\.apply_sync_mutation[^;]+from public, anon/);
  assert.match(rpcSql, /grant execute on function public\.apply_sync_mutation[^;]+to authenticated/);
  assert.doesNotMatch(rpcSql, /grant\s+(insert|update|delete|all)[^;]*to authenticated/i);
  assert.doesNotMatch(rpcSql, /service[_ -]?role/i);
  assert.doesNotMatch(rpcSql, /supabase_db_password|authorization:\s*bearer|eyJ[a-zA-Z0-9_-]+\./i);
  assert.doesNotMatch(rpcSql, /db\s+push|--linked/i);
});

test('pgTAP behavioural coverage exists for PATCH semantics', () => {
  const source = readFileSync(
    new URL('../supabase/tests/sync_business_rls_test.sql', import.meta.url),
    'utf8'
  );
  assert.match(source, /select plan\(59\)/);
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

// --- 20260828000100: inventory preparation_kind ----------------------------

test('the P2 migration pairs the column with its RPC replacement atomically', () => {
  // The resolver above must land on the P2 migration — if a later migration
  // replaces the RPC again, this pin forces the same review this file gives
  // every schema change.
  assert.equal(rpcMigrationName, '20260828000100_inventory_preparation_kind.sql');
  // The column: NOT NULL, constant default, named CHECK with the exact
  // two-value vocabulary.
  assert.match(rpcSql, /alter table public\.inventory_items\s*\n\s*add column preparation_kind text not null default 'none'/);
  assert.match(rpcSql, /constraint inventory_items_preparation_kind_check\s*\n\s*check \(preparation_kind in \('none', 'readyToCook'\)\)/);
  // Atomic: with the column present but the old default_data, the RPC's
  // insert branch supplies an explicit NULL (suppressing the column DEFAULT)
  // and every inventory create is silently rejected — so the ALTER TABLE and
  // the CREATE OR REPLACE must land in one transaction.
  assert.match(rpcSql, /^begin;$/m);
  assert.match(rpcSql, /^commit;$/m);
  const alterAt = rpcSql.indexOf('alter table public.inventory_items');
  assert.ok(rpcSql.indexOf('begin;') < alterAt, 'begin; must precede the ALTER TABLE');
  assert.ok(alterAt < rpcSql.indexOf('create or replace function public.apply_sync_mutation'));
  // ...and commit; must close AFTER the RPC replacement — a commit between
  // the ALTER and the CREATE OR REPLACE would defeat the atomicity.
  assert.ok(
    rpcSql.indexOf('create or replace function public.apply_sync_mutation') < rpcSql.lastIndexOf('commit;'),
    'commit; must follow the RPC replacement'
  );
  assert.equal(rpcSql.match(/^commit;$/gm).length, 1, 'exactly one commit');
  // Backfill rides on ADD COLUMN DEFAULT only: a migration-time UPDATE would
  // trip prepare_household_sync_row's auth.uid() guard, bump versions, and
  // flood the change feed.
  assert.doesNotMatch(rpcSql, /update\s+public\.inventory_items/i);
  assert.doesNotMatch(rpcSql, /drop (table|column|function)/i);
  // The RPC delta itself: allowlisted and create-defaulted.
  assert.match(rpcSql, /'preparation_kind'\]/);
  assert.match(rpcSql, /"preparation_kind":"none"/);
});

test('the RPC column allowlists and the server entity definitions never drift', () => {
  // fromDatabaseRecord silently drops any pulled column that is missing from
  // ENTITY_DEFINITIONS, and toDatabaseData feeds the RPC allowlist — so the
  // two sides must name exactly the same columns, in both directions, for
  // every entity type.
  const caseBlock = rpcSql.slice(rpcSql.indexOf('case p_entity_type'), rpcSql.indexOf('end case;'));
  // Entity-level drift first: an RPC branch for an entity the server does not
  // define would otherwise escape the per-entity loop below, which iterates
  // server-side ENTITY_TYPES only.
  const rpcEntities = [...caseBlock.matchAll(/when '([a-z_]+)' then/g)].map(([, name]) => name);
  assert.deepEqual([...rpcEntities].sort(), [...ENTITY_TYPES].sort());
  for (const entityType of ENTITY_TYPES) {
    const chunk = caseBlock.slice(caseBlock.indexOf(`when '${entityType}' then`));
    const nextWhen = chunk.slice(1).search(/\n\s*when '/);
    const entitySql = nextWhen === -1 ? chunk : chunk.slice(0, nextWhen + 1);
    const declared = entitySql.match(/column_names := array\[([^\]]+)\]/);
    const allowlisted = declared[1].split(',').map(item => item.trim().replace(/^'|'$/g, ''));
    const defined = Object.keys(ENTITY_DEFINITIONS[entityType].fields)
      .map(fieldName => DB_FIELD_NAMES[fieldName] || fieldName);
    assert.deepEqual([...allowlisted].sort(), [...defined].sort(), entityType);
  }
});

test('the sync remote verifier pins the P2 column and the deployed RPC body', () => {
  // The remote verifier is the only check that runs against the hosted
  // database. Until now it audited counts and grants but never a column or a
  // function body, so a stale deployed RPC passed it — the same drift class
  // f0c9619 closed for auth. Pin the new assertions here so removing them
  // fails at review time, not only against a live database.
  const source = readFileSync(
    new URL('../supabase/remote-verify/sync_business_remote_verify.sql', import.meta.url),
    'utf8'
  );
  assert.match(source, /column_name = 'preparation_kind'/);
  assert.match(source, /is_nullable = 'NO'/);
  assert.match(source, /column_default = '''none''::text'/);
  assert.match(source, /inventory_items_preparation_kind_check/);
  assert.match(source, /pg_get_functiondef/);
  assert.match(source, /position\('patch_data' in pg_get_functiondef/);
  assert.match(source, /"preparation_kind":"none"/);
  assert.match(source, /stale function body/);
  assert.doesNotMatch(source, /select\s+email|service[_ -]?role|eyJ[a-zA-Z0-9_-]+\./i);
});

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select plan(44);

select has_table('public', 'inventory_items', 'inventory_items exists');
select has_table('public', 'shopping_items', 'shopping_items exists');
select has_table('public', 'today_plan_items', 'today_plan_items exists');
select has_table('public', 'consumption_records', 'consumption_records exists');
select has_table('public', 'weekly_meal_plans', 'weekly_meal_plans exists');
select has_table('public', 'weekly_meal_plan_items', 'weekly_meal_plan_items exists');
select has_table('public', 'user_recipes', 'user_recipes exists');
select has_table('public', 'recipe_favorites', 'recipe_favorites exists');
select has_table('public', 'frequent_recipes', 'frequent_recipes exists');
select has_table('public', 'sync_changes', 'unified sync_changes feed exists');
select has_table('public', 'sync_mutations', 'idempotency ledger exists');

select ok((select relrowsecurity from pg_class where oid = 'public.inventory_items'::regclass), 'inventory RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.shopping_items'::regclass), 'shopping RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.today_plan_items'::regclass), 'today plan RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.consumption_records'::regclass), 'consumption RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.weekly_meal_plans'::regclass), 'weekly plan RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.weekly_meal_plan_items'::regclass), 'weekly plan item RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.user_recipes'::regclass), 'user recipe RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.recipe_favorites'::regclass), 'favorite RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.frequent_recipes'::regclass), 'frequent recipe RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.sync_changes'::regclass), 'change feed RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.sync_mutations'::regclass), 'mutation ledger RLS enabled');

select is(
  (select count(*) from information_schema.columns
   where table_schema = 'public' and table_name = 'inventory_items'
     and column_name in ('household_id', 'created_at', 'updated_at', 'deleted_at', 'version', 'created_by', 'updated_by')),
  7::bigint,
  'household state carries ownership, tombstone, version, and audit columns'
);
select col_type_is('public', 'sync_changes', 'sequence', 'bigint', 'cursor sequence is bigint');
select col_is_pk('public', 'sync_changes', 'sequence', 'cursor sequence is the primary key');

select is(
  (select count(*) from pg_policies
   where schemaname = 'public' and tablename = 'inventory_items' and cmd = 'SELECT'),
  1::bigint,
  'inventory has one member-scoped read policy'
);
select is(
  (select count(*) from pg_policies
   where schemaname = 'public' and tablename = 'inventory_items' and cmd <> 'SELECT'),
  0::bigint,
  'inventory direct DML has no RLS policy; writes must use the mutation RPC'
);
select is(
  (select count(*) from pg_policies
   where schemaname = 'public' and tablename = 'recipe_favorites' and cmd = 'SELECT'),
  1::bigint,
  'favorites have one user-scoped read policy'
);

select is(
  (select count(*) from pg_trigger
   where tgname like '%_prepare_sync' and not tgisinternal),
  9::bigint,
  'all nine mutable entity tables have version/audit triggers'
);
select is(
  (select count(*) from pg_trigger
   where tgname like '%_write_change' and not tgisinternal),
  9::bigint,
  'all nine mutable entity tables emit unified changes'
);
select is(
  (select count(*) from pg_indexes
   where schemaname = 'public' and indexname = 'weekly_meal_plans_household_week_active_idx'),
  1::bigint,
  'one active weekly plan per household/week is enforced'
);
select is(
  (select count(*) from pg_indexes
   where schemaname = 'public' and indexname = 'sync_changes_household_cursor_idx'),
  1::bigint,
  'household cursor index exists'
);
select is(
  (select count(*) from pg_indexes
   where schemaname = 'public' and indexname = 'sync_changes_user_cursor_idx'),
  1::bigint,
  'personal cursor index exists'
);

select is(
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'apply_sync_mutation'),
  1::bigint,
  'atomic mutation RPC exists exactly once'
);
select is(
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pull_sync_changes'),
  1::bigint,
  'pull RPC exists exactly once'
);
select is(
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_sync_bootstrap'),
  1::bigint,
  'bootstrap RPC exists exactly once'
);
select ok(
  has_function_privilege('authenticated', 'public.apply_sync_mutation(text,uuid,uuid,text,uuid,text,bigint,timestamptz,jsonb)', 'EXECUTE'),
  'authenticated can execute mutation RPC'
);
select ok(
  not has_function_privilege('anon', 'public.apply_sync_mutation(text,uuid,uuid,text,uuid,text,bigint,timestamptz,jsonb)', 'EXECUTE'),
  'anon cannot execute mutation RPC'
);
select ok(
  has_function_privilege('authenticated', 'public.pull_sync_changes(text,uuid,bigint,integer,text[])', 'EXECUTE'),
  'authenticated can execute pull RPC'
);
select ok(
  (select 'search_path=pg_catalog' = any(coalesce(p.proconfig, array[]::text[]))
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'apply_sync_mutation'),
  'mutation RPC fixes search_path to pg_catalog'
);
select is(
  (select count(*) from information_schema.columns
   where table_schema = 'public' and table_name = 'sync_mutations'
     and column_name in ('request_hash', 'result_sequence', 'result_payload')),
  3::bigint,
  'mutation ledger stores canonical hash and minimal result metadata'
);
select ok(
  not has_table_privilege('authenticated', 'public.inventory_items', 'INSERT'),
  'authenticated direct inventory INSERT remains revoked'
);
select col_type_is('public', 'sync_changes', 'entity_id', 'uuid', 'change entity ID is UUID');
select col_type_is('public', 'sync_changes', 'record_data', 'jsonb', 'change stores its transaction-time snapshot');

select * from finish();
rollback;

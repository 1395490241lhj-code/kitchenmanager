do $phase2a_verify$
declare
  business_tables constant text[] := array[
    'inventory_items', 'shopping_items', 'today_plan_items',
    'consumption_records', 'weekly_meal_plans', 'weekly_meal_plan_items',
    'user_recipes', 'recipe_favorites', 'frequent_recipes',
    'sync_changes', 'sync_mutations'
  ];
  table_name text;
begin
  foreach table_name in array business_tables loop
    if to_regclass('public.' || table_name) is null then
      raise exception 'phase2a verification failed: required table % is missing', table_name;
    end if;
    if not (select relrowsecurity from pg_class where oid = to_regclass('public.' || table_name)) then
      raise exception 'phase2a verification failed: RLS is disabled on %', table_name;
    end if;
  end loop;

  if (select count(*) from pg_trigger where not tgisinternal and tgname like '%_prepare_sync') <> 9
    or (select count(*) from pg_trigger where not tgisinternal and tgname like '%_write_change') <> 9 then
    raise exception 'phase2a verification failed: expected exactly 9 prepare and 9 change triggers';
  end if;

  if (select count(*) from pg_policies
      where schemaname = 'public' and tablename = any(business_tables)) <> 11 then
    raise exception 'phase2a verification failed: unexpected business policy count';
  end if;

  if exists (
    select 1 from unnest(array[
      'inventory_items','shopping_items','today_plan_items','consumption_records',
      'weekly_meal_plans','weekly_meal_plan_items','user_recipes',
      'recipe_favorites','frequent_recipes','sync_changes','sync_mutations'
    ]) t(name)
    where has_table_privilege('authenticated', 'public.' || t.name, 'INSERT')
       or has_table_privilege('authenticated', 'public.' || t.name, 'UPDATE')
       or has_table_privilege('authenticated', 'public.' || t.name, 'DELETE')
  ) then
    raise exception 'phase2a verification failed: authenticated direct DML remains open';
  end if;

  if not has_function_privilege(
      'authenticated',
      'public.apply_sync_mutation(text,uuid,uuid,text,uuid,text,bigint,timestamptz,jsonb)',
      'EXECUTE'
    )
    or has_function_privilege(
      'anon',
      'public.apply_sync_mutation(text,uuid,uuid,text,uuid,text,bigint,timestamptz,jsonb)',
      'EXECUTE'
    )
    or exists (
      select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
      where n.nspname = 'public'
        and p.proname = 'apply_sync_mutation'
        and pg_get_function_identity_arguments(p.oid) =
          'p_scope_type text, p_scope_id uuid, p_mutation_id uuid, p_entity_type text, p_entity_id uuid, p_operation text, p_base_version bigint, p_client_updated_at timestamp with time zone, p_data jsonb'
        and acl.grantee = 0
        and acl.privilege_type = 'EXECUTE'
    ) then
    raise exception 'phase2a verification failed: mutation RPC grants are invalid';
  end if;

  if not has_function_privilege(
      'authenticated', 'public.pull_sync_changes(text,uuid,bigint,integer,text[])', 'EXECUTE'
    )
    or has_function_privilege(
      'anon', 'public.pull_sync_changes(text,uuid,bigint,integer,text[])', 'EXECUTE'
    ) then
    raise exception 'phase2a verification failed: pull RPC grants are invalid';
  end if;

  if not has_function_privilege('authenticated', 'public.get_sync_bootstrap()', 'EXECUTE')
    or has_function_privilege('anon', 'public.get_sync_bootstrap()', 'EXECUTE') then
    raise exception 'phase2a verification failed: bootstrap RPC grants are invalid';
  end if;

  if exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('apply_sync_mutation', 'pull_sync_changes', 'get_sync_bootstrap')
      and not ('search_path=pg_catalog' = any(coalesce(p.proconfig, array[]::text[])))
  ) then
    raise exception 'phase2a verification failed: RPC search_path is not fixed';
  end if;

  if (select count(*) from pg_indexes where schemaname = 'public' and indexname in (
      'sync_changes_household_cursor_idx', 'sync_changes_user_cursor_idx',
      'sync_mutations_household_created_idx', 'weekly_meal_plans_household_week_active_idx'
    )) <> 4 then
    raise exception 'phase2a verification failed: required indexes are missing or duplicated';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.sync_changes'::regclass
      and conname = 'sync_changes_exactly_one_scope'
  ) then
    raise exception 'phase2a verification failed: exact-one-scope constraint is missing';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.sync_mutations'::regclass
      and contype = 'p'
      and pg_get_constraintdef(oid) like '%user_id%mutation_id%'
  ) then
    raise exception 'phase2a verification failed: mutation idempotency key is invalid';
  end if;
end
$phase2a_verify$;

select
  'phase2a_remote_objects_verified' as result,
  (select count(*) from pg_policies where schemaname = 'public' and tablename in (
    'inventory_items','shopping_items','today_plan_items','consumption_records',
    'weekly_meal_plans','weekly_meal_plan_items','user_recipes',
    'recipe_favorites','frequent_recipes','sync_changes','sync_mutations'
  )) as policy_count,
  (select count(*) from pg_trigger where not tgisinternal and (tgname like '%_prepare_sync' or tgname like '%_write_change')) as trigger_count,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('apply_sync_mutation','pull_sync_changes','get_sync_bootstrap')) as rpc_count;

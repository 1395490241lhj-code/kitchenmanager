-- Phase 2A-2 draft only. This migration has not been pushed to a hosted project.
--
-- Business rows are readable through RLS, but direct client INSERT/UPDATE/DELETE
-- remains revoked. The authenticated apply_sync_mutation RPC atomically enforces
-- baseVersion and mutationId. Keeping direct DML closed is intentional: a client
-- must not bypass optimistic concurrency through ordinary PostgREST updates.

begin;

create table if not exists public.sync_changes (
  sequence bigint generated always as identity primary key,
  household_id uuid references public.households(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  operation text not null check (operation in ('upsert', 'delete')),
  version bigint not null check (version > 0),
  record_data jsonb not null check (jsonb_typeof(record_data) = 'object'),
  changed_at timestamptz not null default clock_timestamp(),
  changed_by uuid not null references public.profiles(id) on delete restrict,
  constraint sync_changes_exactly_one_scope check (
    (household_id is not null and user_id is null)
    or (household_id is null and user_id is not null)
  )
);

create index if not exists sync_changes_household_cursor_idx
  on public.sync_changes(household_id, sequence) where household_id is not null;
create index if not exists sync_changes_user_cursor_idx
  on public.sync_changes(user_id, sequence) where user_id is not null;

create table if not exists public.sync_mutations (
  user_id uuid not null references public.profiles(id) on delete cascade,
  mutation_id uuid not null,
  household_id uuid references public.households(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  operation text not null check (operation in ('upsert', 'delete')),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  base_version bigint check (base_version is null or base_version >= 0),
  result_version bigint check (result_version is null or result_version > 0),
  result_sequence bigint,
  result_payload jsonb not null default '{}'::jsonb check (jsonb_typeof(result_payload) = 'object'),
  status text not null check (status in ('applied', 'conflict', 'rejected')),
  error_code text,
  created_at timestamptz not null default clock_timestamp(),
  primary key (user_id, mutation_id)
);

create index if not exists sync_mutations_household_created_idx
  on public.sync_mutations(household_id, created_at) where household_id is not null;

create table if not exists public.inventory_items (
  id uuid primary key,
  household_id uuid not null references public.households(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 200),
  normalized_name text not null check (char_length(btrim(normalized_name)) between 1 and 200),
  quantity numeric,
  unit text not null default '',
  purchase_date date,
  expiry_date date,
  shelf_life_days integer check (shelf_life_days is null or shelf_life_days >= 0),
  kind text,
  stock_status text,
  is_frozen boolean not null default false,
  dry_prep text,
  gear text,
  unit_type text,
  out_of_stock_at timestamptz,
  cooked_count integer not null default 0 check (cooked_count >= 0),
  last_cooked_at timestamptz,
  is_staple boolean not null default false,
  low_stock_threshold numeric,
  default_restock_quantity numeric,
  auto_suggest_restock boolean not null default false,
  staple_note text,
  staple_category text,
  staple_tracking_mode text not null default 'quantity'
    check (staple_tracking_mode in ('quantity', 'status')),
  staple_availability_status text not null default 'available'
    check (staple_availability_status in ('available', 'low', 'missing')),
  sort_order integer not null default 0,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  deleted_at timestamptz,
  version bigint not null default 1 check (version > 0),
  created_by uuid not null references public.profiles(id) on delete restrict,
  updated_by uuid not null references public.profiles(id) on delete restrict
);

create index if not exists inventory_items_household_active_idx
  on public.inventory_items(household_id, sort_order, updated_at desc)
  where deleted_at is null;
create index if not exists inventory_items_household_name_idx
  on public.inventory_items(household_id, normalized_name)
  where deleted_at is null;

create table if not exists public.shopping_items (
  id uuid primary key,
  household_id uuid not null references public.households(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 200),
  normalized_name text not null check (char_length(btrim(normalized_name)) between 1 and 200),
  quantity numeric,
  quantity_text text,
  unit text not null default '',
  source text not null default '手动',
  source_detail text,
  is_done boolean not null default false,
  stocked_in boolean not null default false,
  stocked_in_at timestamptz,
  completed_at timestamptz,
  remark text,
  sort_order integer not null default 0,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  deleted_at timestamptz,
  version bigint not null default 1 check (version > 0),
  created_by uuid not null references public.profiles(id) on delete restrict,
  updated_by uuid not null references public.profiles(id) on delete restrict
);

create index if not exists shopping_items_household_open_idx
  on public.shopping_items(household_id, is_done, sort_order, updated_at desc)
  where deleted_at is null;
create index if not exists shopping_items_household_name_idx
  on public.shopping_items(household_id, normalized_name, unit)
  where deleted_at is null;

create table if not exists public.today_plan_items (
  id uuid primary key,
  household_id uuid not null references public.households(id) on delete cascade,
  recipe_id text,
  recipe_name text not null check (char_length(btrim(recipe_name)) between 1 and 300),
  planned_date date not null,
  servings integer not null default 1 check (servings between 1 and 100),
  is_cooked boolean not null default false,
  cooked_at timestamptz,
  sort_order integer not null default 0,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  deleted_at timestamptz,
  version bigint not null default 1 check (version > 0),
  created_by uuid not null references public.profiles(id) on delete restrict,
  updated_by uuid not null references public.profiles(id) on delete restrict
);

create index if not exists today_plan_items_household_date_idx
  on public.today_plan_items(household_id, planned_date, sort_order)
  where deleted_at is null;

create table if not exists public.consumption_records (
  id uuid primary key,
  household_id uuid not null references public.households(id) on delete cascade,
  occurred_at timestamptz not null,
  recipe_id text,
  recipe_name text not null default '',
  plan_ids jsonb not null default '[]'::jsonb check (jsonb_typeof(plan_ids) = 'array'),
  items jsonb not null default '[]'::jsonb check (jsonb_typeof(items) = 'array'),
  is_undone boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  deleted_at timestamptz,
  version bigint not null default 1 check (version > 0),
  created_by uuid not null references public.profiles(id) on delete restrict,
  updated_by uuid not null references public.profiles(id) on delete restrict
);

create index if not exists consumption_records_household_occurred_idx
  on public.consumption_records(household_id, occurred_at desc)
  where deleted_at is null;

create table if not exists public.weekly_meal_plans (
  id uuid primary key,
  household_id uuid not null references public.households(id) on delete cascade,
  week_start date not null,
  servings integer not null default 1 check (servings between 1 and 100),
  summary text,
  shopping_items jsonb not null default '[]'::jsonb
    check (jsonb_typeof(shopping_items) = 'array'),
  source_schema_version integer not null default 1 check (source_schema_version > 0),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  deleted_at timestamptz,
  version bigint not null default 1 check (version > 0),
  created_by uuid not null references public.profiles(id) on delete restrict,
  updated_by uuid not null references public.profiles(id) on delete restrict,
  unique (id, household_id)
);

create unique index if not exists weekly_meal_plans_household_week_active_idx
  on public.weekly_meal_plans(household_id, week_start)
  where deleted_at is null;

create table if not exists public.weekly_meal_plan_items (
  id uuid primary key,
  household_id uuid not null references public.households(id) on delete cascade,
  plan_id uuid not null,
  day_index integer not null check (day_index between 0 and 6),
  meal_index integer not null check (meal_index >= 0),
  meal_title text,
  recipe_id text,
  recipe_title text not null check (char_length(btrim(recipe_title)) between 1 and 300),
  recipe_snapshot jsonb not null default '{}'::jsonb
    check (jsonb_typeof(recipe_snapshot) = 'object'),
  reason text,
  source text,
  is_saved_to_library boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  deleted_at timestamptz,
  version bigint not null default 1 check (version > 0),
  created_by uuid not null references public.profiles(id) on delete restrict,
  updated_by uuid not null references public.profiles(id) on delete restrict,
  constraint weekly_meal_plan_items_plan_household_fk
    foreign key (plan_id, household_id)
    references public.weekly_meal_plans(id, household_id)
    on delete cascade
);

create index if not exists weekly_meal_plan_items_plan_order_idx
  on public.weekly_meal_plan_items(plan_id, day_index, meal_index, sort_order)
  where deleted_at is null;

create table if not exists public.user_recipes (
  id uuid primary key,
  household_id uuid not null references public.households(id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 300),
  tags jsonb not null default '[]'::jsonb check (jsonb_typeof(tags) = 'array'),
  ingredients jsonb not null default '[]'::jsonb check (jsonb_typeof(ingredients) = 'array'),
  seasonings jsonb not null default '[]'::jsonb check (jsonb_typeof(seasonings) = 'array'),
  steps jsonb not null default '[]'::jsonb check (jsonb_typeof(steps) = 'array'),
  cooking_time_minutes integer check (cooking_time_minutes is null or cooking_time_minutes >= 0),
  difficulty text,
  source_platform text,
  source_original_url text,
  source_canonical_url text,
  source_imported_at timestamptz,
  source_title text,
  source_author text,
  content_fingerprint text,
  sort_order integer not null default 0,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  deleted_at timestamptz,
  version bigint not null default 1 check (version > 0),
  created_by uuid not null references public.profiles(id) on delete restrict,
  updated_by uuid not null references public.profiles(id) on delete restrict
);

create index if not exists user_recipes_household_active_idx
  on public.user_recipes(household_id, sort_order, updated_at desc)
  where deleted_at is null;
create unique index if not exists user_recipes_household_source_active_idx
  on public.user_recipes(household_id, source_canonical_url)
  where deleted_at is null and source_canonical_url is not null;
create unique index if not exists user_recipes_household_fingerprint_active_idx
  on public.user_recipes(household_id, content_fingerprint)
  where deleted_at is null and content_fingerprint is not null;

-- Favorites and frequent recipes are personal preferences, not shared kitchen
-- facts. They still receive a stable UUID entity ID; legacy recipe keys map to
-- that UUID deterministically in the client adapter.
create table if not exists public.recipe_favorites (
  id uuid primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  recipe_id text not null check (char_length(btrim(recipe_id)) between 1 and 300),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  deleted_at timestamptz,
  version bigint not null default 1 check (version > 0),
  created_by uuid not null references public.profiles(id) on delete restrict,
  updated_by uuid not null references public.profiles(id) on delete restrict,
  unique (user_id, recipe_id)
);

create table if not exists public.frequent_recipes (
  id uuid primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  recipe_id text not null check (char_length(btrim(recipe_id)) between 1 and 300),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  deleted_at timestamptz,
  version bigint not null default 1 check (version > 0),
  created_by uuid not null references public.profiles(id) on delete restrict,
  updated_by uuid not null references public.profiles(id) on delete restrict,
  unique (user_id, recipe_id)
);

create or replace function private.prepare_household_sync_row()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog
as $$
declare
  actor uuid := auth.uid();
begin
  if actor is null then
    raise exception 'authenticated user required' using errcode = '42501';
  end if;

  if tg_op = 'INSERT' then
    if not private.is_household_member(new.household_id, actor) then
      raise exception 'household membership required' using errcode = '42501';
    end if;
    new.created_at := clock_timestamp();
    new.updated_at := new.created_at;
    new.created_by := actor;
    new.updated_by := actor;
    new.version := 1;
  else
    if new.id is distinct from old.id or new.household_id is distinct from old.household_id then
      raise exception 'record identity and household are immutable' using errcode = '22023';
    end if;
    if not private.is_household_member(old.household_id, actor) then
      raise exception 'household membership required' using errcode = '42501';
    end if;
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    new.updated_at := clock_timestamp();
    new.updated_by := actor;
    new.version := old.version + 1;
  end if;
  return new;
end;
$$;

create or replace function private.prepare_personal_sync_row()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog
as $$
declare
  actor uuid := auth.uid();
begin
  if actor is null then
    raise exception 'authenticated user required' using errcode = '42501';
  end if;

  if tg_op = 'INSERT' then
    new.user_id := actor;
    new.created_at := clock_timestamp();
    new.updated_at := new.created_at;
    new.created_by := actor;
    new.updated_by := actor;
    new.version := 1;
  else
    if new.id is distinct from old.id or new.user_id is distinct from old.user_id or new.recipe_id is distinct from old.recipe_id then
      raise exception 'personal record identity is immutable' using errcode = '22023';
    end if;
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    new.updated_at := clock_timestamp();
    new.updated_by := actor;
    new.version := old.version + 1;
  end if;
  return new;
end;
$$;

create or replace function private.write_household_sync_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  insert into public.sync_changes (
    household_id, entity_type, entity_id, operation, version, record_data, changed_by
  ) values (
    new.household_id,
    tg_argv[0],
    new.id,
    case when new.deleted_at is not null then 'delete' else 'upsert' end,
    new.version,
    to_jsonb(new),
    new.updated_by
  );
  return new;
end;
$$;

create or replace function private.write_personal_sync_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  insert into public.sync_changes (
    user_id, entity_type, entity_id, operation, version, record_data, changed_by
  ) values (
    new.user_id,
    tg_argv[0],
    new.id,
    case when new.deleted_at is not null then 'delete' else 'upsert' end,
    new.version,
    to_jsonb(new),
    new.updated_by
  );
  return new;
end;
$$;

revoke all on function private.prepare_household_sync_row() from public;
revoke all on function private.prepare_personal_sync_row() from public;
revoke all on function private.write_household_sync_change() from public;
revoke all on function private.write_personal_sync_change() from public;

do $$
declare
  table_name text;
  entity_name text;
begin
  foreach table_name in array array[
    'inventory_items', 'shopping_items', 'today_plan_items',
    'consumption_records', 'weekly_meal_plans',
    'weekly_meal_plan_items', 'user_recipes'
  ] loop
    entity_name := case table_name
      when 'inventory_items' then 'inventory_item'
      when 'shopping_items' then 'shopping_item'
      when 'today_plan_items' then 'today_plan'
      when 'consumption_records' then 'consumption_record'
      when 'weekly_meal_plans' then 'weekly_meal_plan'
      when 'weekly_meal_plan_items' then 'weekly_meal_plan_item'
      when 'user_recipes' then 'user_recipe'
    end;
    execute format('drop trigger if exists %I on public.%I', table_name || '_prepare_sync', table_name);
    execute format(
      'create trigger %I before insert or update on public.%I for each row execute function private.prepare_household_sync_row()',
      table_name || '_prepare_sync', table_name
    );
    execute format('drop trigger if exists %I on public.%I', table_name || '_write_change', table_name);
    execute format(
      'create trigger %I after insert or update on public.%I for each row execute function private.write_household_sync_change(%L)',
      table_name || '_write_change', table_name, entity_name
    );
  end loop;

  foreach table_name in array array['recipe_favorites', 'frequent_recipes'] loop
    entity_name := case table_name
      when 'recipe_favorites' then 'recipe_favorite'
      when 'frequent_recipes' then 'frequent_recipe'
    end;
    execute format('drop trigger if exists %I on public.%I', table_name || '_prepare_sync', table_name);
    execute format(
      'create trigger %I before insert or update on public.%I for each row execute function private.prepare_personal_sync_row()',
      table_name || '_prepare_sync', table_name
    );
    execute format('drop trigger if exists %I on public.%I', table_name || '_write_change', table_name);
    execute format(
      'create trigger %I after insert or update on public.%I for each row execute function private.write_personal_sync_change(%L)',
      table_name || '_write_change', table_name, entity_name
    );
  end loop;
end;
$$;

-- Fixed allowlist snapshot mapper used by pull/conflict responses. No table or
-- column identifier comes from a request.
create or replace function private.sync_entity_snapshot(target_entity_type text, target_entity_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  result jsonb;
begin
  case target_entity_type
    when 'inventory_item' then select to_jsonb(t) into result from public.inventory_items t where t.id = target_entity_id;
    when 'shopping_item' then select to_jsonb(t) into result from public.shopping_items t where t.id = target_entity_id;
    when 'today_plan' then select to_jsonb(t) into result from public.today_plan_items t where t.id = target_entity_id;
    when 'consumption_record' then select to_jsonb(t) into result from public.consumption_records t where t.id = target_entity_id;
    when 'weekly_meal_plan' then select to_jsonb(t) into result from public.weekly_meal_plans t where t.id = target_entity_id;
    when 'weekly_meal_plan_item' then select to_jsonb(t) into result from public.weekly_meal_plan_items t where t.id = target_entity_id;
    when 'user_recipe' then select to_jsonb(t) into result from public.user_recipes t where t.id = target_entity_id;
    when 'recipe_favorite' then select to_jsonb(t) into result from public.recipe_favorites t where t.id = target_entity_id;
    when 'frequent_recipe' then select to_jsonb(t) into result from public.frequent_recipes t where t.id = target_entity_id;
    else raise exception 'unsupported entity type' using errcode = '22023';
  end case;
  return result;
end;
$$;

-- One mutation is one database transaction. A transaction-scoped advisory lock
-- serializes retries of the same (user, mutationId), including concurrent first
-- attempts, before the idempotency ledger is inspected.
create or replace function public.apply_sync_mutation(
  p_scope_type text,
  p_scope_id uuid,
  p_mutation_id uuid,
  p_entity_type text,
  p_entity_id uuid,
  p_operation text,
  p_base_version bigint,
  p_client_updated_at timestamptz,
  p_data jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  actor uuid := auth.uid();
  table_name text;
  scope_kind text;
  column_names text[];
  required_names text[];
  default_data jsonb := '{}'::jsonb;
  normalized_data jsonb;
  system_data jsonb;
  column_sql text;
  select_column_sql text;
  current_record jsonb;
  server_record jsonb;
  ledger public.sync_mutations%rowtype;
  request_hash text;
  result_status text;
  error_code text;
  result_version bigint;
  result_sequence bigint;
  result_payload jsonb := '{}'::jsonb;
begin
  if actor is null then raise exception 'authenticated user required' using errcode = '42501'; end if;
  if p_scope_type not in ('household', 'user') or p_scope_id is null then
    raise exception 'valid sync scope required' using errcode = '22023';
  end if;
  if p_scope_type = 'household' and not private.is_household_member(p_scope_id, actor) then
    raise exception 'household membership required' using errcode = '42501';
  end if;
  if p_scope_type = 'user' and p_scope_id <> actor then
    raise exception 'personal scope must match authenticated user' using errcode = '42501';
  end if;
  if p_mutation_id is null or p_entity_id is null then raise exception 'mutation and entity IDs are required' using errcode = '22023'; end if;
  if p_operation not in ('upsert', 'delete') then raise exception 'unsupported operation' using errcode = '22023'; end if;
  if p_base_version is not null and p_base_version < 0 then raise exception 'base version must be non-negative' using errcode = '22023'; end if;
  if p_data is null then p_data := '{}'::jsonb; end if;
  if jsonb_typeof(p_data) <> 'object' or octet_length(p_data::text) > 262144 then
    raise exception 'invalid or oversized mutation data' using errcode = '22023';
  end if;
  if p_operation = 'delete' and p_data <> '{}'::jsonb then
    raise exception 'delete does not accept data' using errcode = '22023';
  end if;

  -- Table names and columns below are constants selected by an allowlist. They
  -- are never copied from p_entity_type or p_data.
  case p_entity_type
    when 'inventory_item' then
      table_name := 'inventory_items'; scope_kind := 'household';
      column_names := array['name','normalized_name','quantity','unit','purchase_date','expiry_date','shelf_life_days','kind','stock_status','is_frozen','dry_prep','gear','unit_type','out_of_stock_at','cooked_count','last_cooked_at','is_staple','low_stock_threshold','default_restock_quantity','auto_suggest_restock','staple_note','staple_category','staple_tracking_mode','staple_availability_status','sort_order'];
      required_names := array['name','normalized_name'];
      default_data := '{"unit":"","is_frozen":false,"cooked_count":0,"is_staple":false,"auto_suggest_restock":false,"staple_tracking_mode":"quantity","staple_availability_status":"available","sort_order":0}'::jsonb;
    when 'shopping_item' then
      table_name := 'shopping_items'; scope_kind := 'household';
      column_names := array['name','normalized_name','quantity','quantity_text','unit','source','source_detail','is_done','stocked_in','stocked_in_at','completed_at','remark','sort_order'];
      required_names := array['name','normalized_name'];
      default_data := '{"unit":"","source":"手动","is_done":false,"stocked_in":false,"sort_order":0}'::jsonb;
    when 'today_plan' then
      table_name := 'today_plan_items'; scope_kind := 'household';
      column_names := array['recipe_id','recipe_name','planned_date','servings','is_cooked','cooked_at','sort_order'];
      required_names := array['recipe_name','planned_date'];
      default_data := '{"servings":1,"is_cooked":false,"sort_order":0}'::jsonb;
    when 'consumption_record' then
      table_name := 'consumption_records'; scope_kind := 'household';
      column_names := array['occurred_at','recipe_id','recipe_name','plan_ids','items','is_undone','sort_order'];
      required_names := array['occurred_at'];
      default_data := '{"recipe_name":"","plan_ids":[],"items":[],"is_undone":false,"sort_order":0}'::jsonb;
    when 'weekly_meal_plan' then
      table_name := 'weekly_meal_plans'; scope_kind := 'household';
      column_names := array['week_start','servings','summary','shopping_items','source_schema_version'];
      required_names := array['week_start'];
      default_data := '{"servings":1,"shopping_items":[],"source_schema_version":1}'::jsonb;
    when 'weekly_meal_plan_item' then
      table_name := 'weekly_meal_plan_items'; scope_kind := 'household';
      column_names := array['plan_id','day_index','meal_index','meal_title','recipe_id','recipe_title','recipe_snapshot','reason','source','is_saved_to_library','sort_order'];
      required_names := array['plan_id','day_index','meal_index','recipe_title'];
      default_data := '{"recipe_snapshot":{},"is_saved_to_library":false,"sort_order":0}'::jsonb;
    when 'user_recipe' then
      table_name := 'user_recipes'; scope_kind := 'household';
      column_names := array['title','tags','ingredients','seasonings','steps','cooking_time_minutes','difficulty','source_platform','source_original_url','source_canonical_url','source_imported_at','source_title','source_author','content_fingerprint','sort_order'];
      required_names := array['title'];
      default_data := '{"tags":[],"ingredients":[],"seasonings":[],"steps":[],"sort_order":0}'::jsonb;
    when 'recipe_favorite' then
      table_name := 'recipe_favorites'; scope_kind := 'user';
      column_names := array['recipe_id']; required_names := array['recipe_id'];
    when 'frequent_recipe' then
      table_name := 'frequent_recipes'; scope_kind := 'user';
      column_names := array['recipe_id']; required_names := array['recipe_id'];
    else raise exception 'unsupported entity type' using errcode = '22023';
  end case;

  if scope_kind <> p_scope_type then
    raise exception 'entity type does not belong to requested scope' using errcode = '22023';
  end if;

  if exists (select 1 from jsonb_object_keys(p_data) key where not (key = any(column_names))) then
    raise exception 'mutation contains unsupported fields' using errcode = '22023';
  end if;
  normalized_data := default_data || p_data;
  if p_operation = 'upsert' and exists (
    select 1 from unnest(required_names) required_key
    where not (normalized_data ? required_key)
      or normalized_data -> required_key = 'null'::jsonb
      or (jsonb_typeof(normalized_data -> required_key) = 'string' and btrim(normalized_data ->> required_key) = '')
  ) then
    raise exception 'mutation is missing required fields' using errcode = '22023';
  end if;

  request_hash := encode(sha256(convert_to(jsonb_build_object(
    'scopeType', p_scope_type, 'scopeId', p_scope_id, 'entityType', p_entity_type,
    'entityId', p_entity_id, 'operation', p_operation,
    'baseVersion', p_base_version, 'clientUpdatedAt', p_client_updated_at,
    'data', normalized_data
  )::text, 'utf8')), 'hex');

  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':' || p_mutation_id::text, 0));
  select * into ledger from public.sync_mutations
  where user_id = actor and mutation_id = p_mutation_id;
  if found then
    if ledger.request_hash <> request_hash then
      return jsonb_build_object(
        'mutationId', p_mutation_id, 'entityId', p_entity_id,
        'status', 'rejected', 'errorCode', 'idempotency_mismatch'
      );
    end if;
    return jsonb_build_object(
      'mutationId', p_mutation_id, 'entityId', ledger.entity_id,
      'status', 'duplicate', 'originalStatus', ledger.status,
      'version', ledger.result_version, 'sequence', ledger.result_sequence,
      'errorCode', ledger.error_code
    );
  end if;

  if scope_kind = 'household' then
    execute format('select to_jsonb(t) from public.%I t where t.id = $1 and t.household_id = $2', table_name)
      into current_record using p_entity_id, p_scope_id;
  else
    execute format('select to_jsonb(t) from public.%I t where t.id = $1 and t.user_id = $2', table_name)
      into current_record using p_entity_id, actor;
  end if;

  if current_record is null then
    if p_operation = 'delete' then
      result_status := 'rejected'; error_code := 'not_found';
    elsif coalesce(p_base_version, 0) <> 0 then
      result_status := 'rejected'; error_code := 'invalid_create_version';
    else
      system_data := normalized_data || jsonb_build_object(
        'id', p_entity_id,
        case when scope_kind = 'household' then 'household_id' else 'user_id' end,
        p_scope_id,
        'created_by', actor, 'updated_by', actor,
        'created_at', clock_timestamp(), 'updated_at', clock_timestamp(), 'version', 1
      );
      begin
        execute format(
          'insert into public.%I as target select (jsonb_populate_record(null::public.%I, $1)).* returning to_jsonb(target)',
          table_name, table_name
        ) into server_record using system_data;
        result_status := 'applied';
      exception when others then
        result_status := 'rejected'; error_code := 'invalid_payload'; server_record := null;
      end;
    end if;
  elsif p_base_version is null or (current_record ->> 'version')::bigint <> p_base_version then
    result_status := 'conflict'; error_code := 'stale_version'; server_record := current_record;
  elsif p_operation = 'delete' and current_record -> 'deleted_at' <> 'null'::jsonb then
    result_status := 'rejected'; error_code := 'already_deleted'; server_record := current_record;
  else
    begin
      if p_operation = 'delete' then
        if scope_kind = 'household' then
          execute format('update public.%I as target set deleted_at = clock_timestamp() where id = $1 and household_id = $2 and version = $3 returning to_jsonb(target)', table_name)
            into server_record using p_entity_id, p_scope_id, p_base_version;
        else
          execute format('update public.%I as target set deleted_at = clock_timestamp() where id = $1 and user_id = $2 and version = $3 returning to_jsonb(target)', table_name)
            into server_record using p_entity_id, actor, p_base_version;
        end if;
      else
        select string_agg(format('%I', item), ', ') into column_sql from unnest(column_names) item;
        select string_agg(format('source.%I', item), ', ') into select_column_sql from unnest(column_names) item;
        if scope_kind = 'household' then
          execute format(
            'update public.%I as target set (%s) = (select %s from jsonb_populate_record(null::public.%I, $1) source), deleted_at = null where id = $2 and household_id = $3 and version = $4 returning to_jsonb(target)',
            table_name, column_sql, select_column_sql, table_name
          ) into server_record using normalized_data, p_entity_id, p_scope_id, p_base_version;
        else
          execute format(
            'update public.%I as target set (%s) = (select %s from jsonb_populate_record(null::public.%I, $1) source), deleted_at = null where id = $2 and user_id = $3 and version = $4 returning to_jsonb(target)',
            table_name, column_sql, select_column_sql, table_name
          ) into server_record using normalized_data, p_entity_id, actor, p_base_version;
        end if;
      end if;
      if server_record is null then
        result_status := 'conflict'; error_code := 'stale_version';
        server_record := private.sync_entity_snapshot(p_entity_type, p_entity_id);
      else
        result_status := 'applied';
      end if;
    exception when others then
      result_status := 'rejected'; error_code := 'invalid_payload'; server_record := null;
    end;
  end if;

  if result_status = 'applied' then
    result_version := (server_record ->> 'version')::bigint;
    select sequence into result_sequence from public.sync_changes
    where entity_type = p_entity_type and entity_id = p_entity_id and version = result_version
      and changed_by = actor
    order by sequence desc limit 1;
    if result_sequence is null then raise exception 'change feed invariant failed' using errcode = 'P0001'; end if;
  elsif result_status = 'conflict' and server_record is not null then
    result_version := (server_record ->> 'version')::bigint;
  end if;

  result_payload := jsonb_strip_nulls(jsonb_build_object('errorCode', error_code));
  insert into public.sync_mutations (
    user_id, mutation_id, household_id, entity_type, entity_id, operation,
    request_hash, base_version, result_version, result_sequence, status,
    error_code, result_payload
  ) values (
    actor, p_mutation_id,
    case when p_scope_type = 'household' then p_scope_id else null end,
    p_entity_type, p_entity_id, p_operation,
    request_hash, p_base_version, result_version, result_sequence, result_status,
    error_code, result_payload
  );

  return jsonb_strip_nulls(jsonb_build_object(
    'mutationId', p_mutation_id, 'entityId', p_entity_id,
    'status', result_status, 'version', result_version,
    'sequence', result_sequence, 'errorCode', error_code,
    'serverRecord', case
      when result_status = 'applied' and p_operation = 'delete' then
        jsonb_build_object(
          'id', p_entity_id,
          'deleted_at', server_record -> 'deleted_at',
          'version', result_version
        )
      else server_record
    end
  ));
end;
$$;

create or replace function public.get_sync_bootstrap()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  actor uuid := auth.uid();
  profile_row public.profiles%rowtype;
  household_rows jsonb;
  sync_scopes jsonb;
  default_household uuid;
begin
  if actor is null then raise exception 'authenticated user required' using errcode = '42501'; end if;
  select * into profile_row from public.profiles where id = actor;
  if not found then raise exception 'profile is not initialized' using errcode = 'P0001'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'role', hm.role) order by h.is_personal desc, hm.created_at), '[]'::jsonb),
         coalesce(jsonb_agg(jsonb_build_object(
           'type', 'household',
           'id', h.id,
           'cursor', coalesce((select max(c.sequence) from public.sync_changes c where c.household_id = h.id), 0)::text
         ) order by h.is_personal desc, hm.created_at), '[]'::jsonb),
         (array_agg(h.id order by h.is_personal desc, hm.created_at))[1]
    into household_rows, sync_scopes, default_household
  from public.household_members hm
  join public.households h on h.id = hm.household_id
  where hm.user_id = actor;
  sync_scopes := sync_scopes || jsonb_build_array(jsonb_build_object(
    'type', 'user',
    'id', actor,
    'cursor', coalesce((select max(c.sequence) from public.sync_changes c where c.user_id = actor), 0)::text
  ));
  return jsonb_build_object(
    'user', jsonb_build_object('id', profile_row.id, 'email', profile_row.email),
    'households', household_rows, 'defaultHouseholdId', default_household,
    'syncScopes', sync_scopes, 'serverTime', statement_timestamp()
  );
end;
$$;

create or replace function public.pull_sync_changes(
  p_scope_type text,
  p_scope_id uuid,
  p_cursor bigint default 0,
  p_limit integer default 100,
  p_entity_types text[] default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  actor uuid := auth.uid();
  household_types constant text[] := array['inventory_item','shopping_item','today_plan','consumption_record','weekly_meal_plan','weekly_meal_plan_item','user_recipe'];
  user_types constant text[] := array['recipe_favorite','frequent_recipe'];
  allowed_types text[];
  changes jsonb;
  has_more boolean;
  next_cursor bigint := p_cursor;
begin
  if actor is null then raise exception 'authenticated user required' using errcode = '42501'; end if;
  if p_scope_type = 'household' then
    if p_scope_id is null or not private.is_household_member(p_scope_id, actor) then
      raise exception 'household membership required' using errcode = '42501';
    end if;
    allowed_types := household_types;
  elsif p_scope_type = 'user' then
    if p_scope_id is null or p_scope_id <> actor then
      raise exception 'personal scope must match authenticated user' using errcode = '42501';
    end if;
    allowed_types := user_types;
  else
    raise exception 'unsupported scope type' using errcode = '22023';
  end if;
  if p_cursor is null or p_cursor < 0 or p_limit < 1 or p_limit > 100 then
    raise exception 'invalid cursor or limit' using errcode = '22023';
  end if;
  if p_entity_types is not null and not (p_entity_types <@ allowed_types) then
    raise exception 'unsupported entity type' using errcode = '22023';
  end if;

  with candidates as materialized (
    select c.*
    from public.sync_changes c
    where c.sequence > p_cursor
      and (
        (p_scope_type = 'household' and c.household_id = p_scope_id)
        or (p_scope_type = 'user' and c.user_id = p_scope_id)
      )
      and (p_entity_types is null or c.entity_type = any(p_entity_types))
    order by c.sequence asc
    limit p_limit + 1
  ), page as (
    select * from candidates order by sequence asc limit p_limit
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'sequence', page.sequence::text,
      'entityType', page.entity_type,
      'entityId', page.entity_id,
      'operation', page.operation,
      'version', page.version::text,
      'changedAt', page.changed_at,
      'data', case when page.operation = 'delete' then
        jsonb_build_object(
          'id', page.entity_id,
          'deleted_at', page.record_data -> 'deleted_at',
          'version', page.version
        )
      else page.record_data end
    ) order by page.sequence), '[]'::jsonb),
    coalesce(max(page.sequence), p_cursor),
    (select count(*) > p_limit from candidates)
  into changes, next_cursor, has_more
  from page;

  return jsonb_build_object(
    'scopeType', p_scope_type, 'scopeId', p_scope_id,
    'cursor', next_cursor::text, 'hasMore', has_more, 'changes', changes
  );
end;
$$;

revoke all on function private.sync_entity_snapshot(text, uuid) from public;
revoke all on function public.apply_sync_mutation(text, uuid, uuid, text, uuid, text, bigint, timestamptz, jsonb) from public, anon;
revoke all on function public.get_sync_bootstrap() from public, anon;
revoke all on function public.pull_sync_changes(text, uuid, bigint, integer, text[]) from public, anon;
grant execute on function public.apply_sync_mutation(text, uuid, uuid, text, uuid, text, bigint, timestamptz, jsonb) to authenticated;
grant execute on function public.get_sync_bootstrap() to authenticated;
grant execute on function public.pull_sync_changes(text, uuid, bigint, integer, text[]) to authenticated;

alter table public.sync_changes enable row level security;
alter table public.sync_mutations enable row level security;
alter table public.inventory_items enable row level security;
alter table public.shopping_items enable row level security;
alter table public.today_plan_items enable row level security;
alter table public.consumption_records enable row level security;
alter table public.weekly_meal_plans enable row level security;
alter table public.weekly_meal_plan_items enable row level security;
alter table public.user_recipes enable row level security;
alter table public.recipe_favorites enable row level security;
alter table public.frequent_recipes enable row level security;

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'inventory_items', 'shopping_items', 'today_plan_items',
    'consumption_records', 'weekly_meal_plans',
    'weekly_meal_plan_items', 'user_recipes'
  ] loop
    execute format('drop policy if exists %I on public.%I', table_name || '_select_for_members', table_name);
    execute format(
      'create policy %I on public.%I for select to authenticated using (private.is_household_member(household_id, (select auth.uid())))',
      table_name || '_select_for_members', table_name
    );
  end loop;
end;
$$;

drop policy if exists recipe_favorites_select_self on public.recipe_favorites;
create policy recipe_favorites_select_self on public.recipe_favorites
for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists frequent_recipes_select_self on public.frequent_recipes;
create policy frequent_recipes_select_self on public.frequent_recipes
for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists sync_changes_select_visible on public.sync_changes;
create policy sync_changes_select_visible on public.sync_changes
for select to authenticated using (
  (household_id is not null and private.is_household_member(household_id, (select auth.uid())))
  or (user_id is not null and user_id = (select auth.uid()))
);

drop policy if exists sync_mutations_select_self on public.sync_mutations;
create policy sync_mutations_select_self on public.sync_mutations
for select to authenticated using (user_id = (select auth.uid()));

-- Explicitly close direct writes. The Phase 2A-2 mutation RPC will be the only
-- authenticated write surface and will require both mutationId and baseVersion.
revoke all on table public.sync_changes from anon, authenticated;
revoke all on table public.sync_mutations from anon, authenticated;
revoke all on table public.inventory_items from anon, authenticated;
revoke all on table public.shopping_items from anon, authenticated;
revoke all on table public.today_plan_items from anon, authenticated;
revoke all on table public.consumption_records from anon, authenticated;
revoke all on table public.weekly_meal_plans from anon, authenticated;
revoke all on table public.weekly_meal_plan_items from anon, authenticated;
revoke all on table public.user_recipes from anon, authenticated;
revoke all on table public.recipe_favorites from anon, authenticated;
revoke all on table public.frequent_recipes from anon, authenticated;

grant select on table public.sync_changes to authenticated;
grant select on table public.sync_mutations to authenticated;
grant select on table public.inventory_items to authenticated;
grant select on table public.shopping_items to authenticated;
grant select on table public.today_plan_items to authenticated;
grant select on table public.consumption_records to authenticated;
grant select on table public.weekly_meal_plans to authenticated;
grant select on table public.weekly_meal_plan_items to authenticated;
grant select on table public.user_recipes to authenticated;
grant select on table public.recipe_favorites to authenticated;
grant select on table public.frequent_recipes to authenticated;

commit;

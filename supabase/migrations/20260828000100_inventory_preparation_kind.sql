-- Sync P2: inventory `preparation_kind` (ready-to-cook preparation axis).
--
-- iOS models a three-way `InventoryItemKind` (ordinary / staple / readyToCook)
-- but sync only carries the staple axis (`is_staple`), so a `.readyToCook`
-- row would degrade to `.ordinary` on any round-trip. This migration gives
-- the preparation axis its own column instead of touching either existing
-- classification field:
--
--   * `inventory_items.kind` stays wholly PWA-owned (its raw/dry/staple
--     vocabulary and item-identity semantics are not reused or reinterpreted);
--   * `is_staple` stays the canonical staple sync axis;
--   * `preparation_kind` is the new, orthogonal preparation axis:
--     `none` (default) or `readyToCook` — the camelCase value deliberately
--     matches the Swift enum rawValue so no client mapping layer is needed.
--
-- `is_staple = true` together with `preparation_kind = 'readyToCook'` is a
-- legal stored state on purpose: PATCH mutations may touch one axis at a
-- time, so a cross-axis CHECK would reject a valid sparse update based on
-- stored state the client cannot see. Clients that project both axes into a
-- single classification resolve the combination by decode precedence
-- (staple > readyToCook > ordinary); see SYNC_API_CONTRACT.md §4.1.
--
-- Backfill rides entirely on `ADD COLUMN ... DEFAULT 'none'` (PG 11+ stores
-- the constant without a table rewrite): no row is UPDATEd, so no version is
-- bumped and no sync_changes rows are written. A migration-time UPDATE would
-- in fact fail outright — `private.prepare_household_sync_row()` raises
-- `authenticated user required` when `auth.uid()` is null. `'none'` is
-- correct for every existing row because no client has ever transmitted a
-- ready-to-cook state.
--
-- The RPC below re-issues `20260827000100`'s `apply_sync_mutation` body
-- verbatim with exactly two changes, both scoped to `inventory_item`:
-- `'preparation_kind'` added to `column_names`, and `"preparation_kind":
-- "none"` added to `default_data`. PATCH / null / required-field /
-- idempotency / tombstone semantics are unchanged; `request_hash` covers
-- only `patch_data`, so this migration — unlike `20260827000100` — cannot
-- invalidate any previously staged mutation. Neither `20260713000200` nor
-- `20260827000100` is edited.
--
-- The ALTER TABLE and the RPC replacement must land atomically: with the
-- column present but the old `default_data`, the insert branch's
-- `jsonb_populate_record` supplies an explicit NULL for the absent key
-- (suppressing the column DEFAULT), so every inventory create would be
-- silently rejected as `invalid_payload` and poison the idempotency ledger.
-- Hence the single transaction below.
--
-- (`preparation_kind` is unrelated to the iOS QuickMeal `preparationState`
-- on prepared components and to `dry_prep` — different models.)

begin;

alter table public.inventory_items
  add column preparation_kind text not null default 'none'
    constraint inventory_items_preparation_kind_check
      check (preparation_kind in ('none', 'readyToCook'));

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
  -- `patch_data` is exactly what the client sent (after the allowlist check);
  -- `create_data` is that payload plus the server-side defaults, and is only
  -- ever used by the insert branch.
  patch_data jsonb;
  create_data jsonb;
  update_names text[];
  system_data jsonb;
  column_sql text;
  select_column_sql text;
  set_sql text;
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
      column_names := array['name','normalized_name','quantity','unit','purchase_date','expiry_date','shelf_life_days','kind','stock_status','is_frozen','dry_prep','gear','unit_type','out_of_stock_at','cooked_count','last_cooked_at','is_staple','low_stock_threshold','default_restock_quantity','auto_suggest_restock','staple_note','staple_category','staple_tracking_mode','staple_availability_status','sort_order','preparation_kind'];
      required_names := array['name','normalized_name'];
      default_data := '{"unit":"","is_frozen":false,"cooked_count":0,"is_staple":false,"auto_suggest_restock":false,"staple_tracking_mode":"quantity","staple_availability_status":"available","sort_order":0,"preparation_kind":"none"}'::jsonb;
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
  patch_data := p_data;
  create_data := default_data || p_data;

  -- An update is a PATCH: a key the client did not send means "leave that
  -- column alone", so demanding that every required field be re-sent would
  -- reject a perfectly good partial update. Presence is therefore only
  -- required when this mutation is a create attempt -- the same condition
  -- the `invalid_create_version` rule below already uses.
  if p_operation = 'upsert' and coalesce(p_base_version, 0) = 0 and exists (
    select 1 from unnest(required_names) required_key
    where not (create_data ? required_key)
  ) then
    raise exception 'mutation is missing required fields' using errcode = '22023';
  end if;
  -- A required field that IS sent must still carry a usable value, on a
  -- create and on an update alike. Omitting `name` keeps the stored one;
  -- sending `name: null` or `name: ''` is still a rejection.
  if p_operation = 'upsert' and exists (
    select 1 from unnest(required_names) required_key
    where patch_data ? required_key
      and (patch_data -> required_key = 'null'::jsonb
        or (jsonb_typeof(patch_data -> required_key) = 'string' and btrim(patch_data ->> required_key) = ''))
  ) then
    raise exception 'mutation is missing required fields' using errcode = '22023';
  end if;

  -- Hashed over the client's own payload, never over server-side defaults:
  -- changing a default must not retroactively change the request hash of a
  -- mutation a client already staged. `jsonb` normalizes key order, so two
  -- semantically identical payloads always hash the same.
  request_hash := encode(sha256(convert_to(jsonb_build_object(
    'scopeType', p_scope_type, 'scopeId', p_scope_id, 'entityType', p_entity_type,
    'entityId', p_entity_id, 'operation', p_operation,
    'baseVersion', p_base_version, 'clientUpdatedAt', p_client_updated_at,
    'data', patch_data
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
      system_data := create_data || jsonb_build_object(
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
  elsif p_operation = 'upsert' and patch_data = '{}'::jsonb then
    -- Under PATCH semantics an empty payload asks for no column to change at
    -- all. Nothing was compared, so there is nothing to reconcile and no
    -- server record worth returning.
    result_status := 'rejected'; error_code := 'empty_update'; server_record := null;
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
        -- Only the columns the client actually sent are written. Every name
        -- here came out of `patch_data` and was already checked against the
        -- hardcoded `column_names` allowlist above, and `%I` quotes it a
        -- second time, so a client key can never reach SQL as a bare
        -- identifier. Columns the client never mentioned keep their stored
        -- values; an explicit JSON null still clears one, because
        -- `jsonb_populate_record` maps it to a SQL NULL.
        select coalesce(array_agg(item order by item), array[]::text[])
          into update_names
          from jsonb_object_keys(patch_data) item;
        if array_length(update_names, 1) = 1 then
          -- A single-column assignment must not use the parenthesized
          -- multi-column form, which PostgreSQL rejects.
          set_sql := format(
            '%I = (select source.%I from jsonb_populate_record(null::public.%I, $1) source)',
            update_names[1], update_names[1], table_name
          );
        else
          select string_agg(format('%I', item), ', ' order by item) into column_sql from unnest(update_names) item;
          select string_agg(format('source.%I', item), ', ' order by item) into select_column_sql from unnest(update_names) item;
          set_sql := format(
            '(%s) = (select %s from jsonb_populate_record(null::public.%I, $1) source)',
            column_sql, select_column_sql, table_name
          );
        end if;
        if scope_kind = 'household' then
          execute format(
            'update public.%I as target set %s, deleted_at = null where id = $2 and household_id = $3 and version = $4 returning to_jsonb(target)',
            table_name, set_sql
          ) into server_record using patch_data, p_entity_id, p_scope_id, p_base_version;
        else
          execute format(
            'update public.%I as target set %s, deleted_at = null where id = $2 and user_id = $3 and version = $4 returning to_jsonb(target)',
            table_name, set_sql
          ) into server_record using patch_data, p_entity_id, actor, p_base_version;
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

-- Re-asserted so this migration is self-contained; `create or replace`
-- preserves the existing ACL, and these grants match `20260713000200` and
-- `20260827000100`.
revoke all on function public.apply_sync_mutation(text, uuid, uuid, text, uuid, text, bigint, timestamptz, jsonb) from public, anon;
grant execute on function public.apply_sync_mutation(text, uuid, uuid, text, uuid, text, bigint, timestamptz, jsonb) to authenticated;

commit;

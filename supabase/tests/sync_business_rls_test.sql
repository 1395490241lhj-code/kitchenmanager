-- Phase 2C-3: behavioral RLS/RPC coverage for the sync business schema,
-- mirroring supabase/tests/auth_household_rls_test.sql's pattern (local role
-- switching via `set local role authenticated` + `request.jwt.claim.sub`).
-- This is a local pgTAP test intended to run inside `supabase test db`
-- (which requires a local Postgres via Docker) — see
-- docs/DATABASE_MIGRATION_PARITY.md for this repository's current Docker
-- availability status. It has not been executed in this environment; do not
-- treat its presence as a passing result.
--
-- Complements (does not replace) scripts/sync-smoke.mjs, which already
-- exercises the same apply_sync_mutation/pull_sync_changes RPCs over real
-- HTTP against the real development Supabase project — this file adds
-- direct-SQL, Docker-local coverage of the same invariants as defense in
-- depth, independent of the Express layer.
begin;
select plan(51);

-- Two households (auto-created by the handle_new_auth_user trigger), two
-- users, no cross-membership — A and B must never see each other's data.
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('33333333-3333-4333-8333-333333333331', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'sync-a@example.com', '', now(), '{}'::jsonb, '{"display_name":"SyncA"}'::jsonb, now(), now()),
  ('33333333-3333-4333-8333-333333333332', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'sync-b@example.com', '', now(), '{}'::jsonb, '{"display_name":"SyncB"}'::jsonb, now(), now());

-- 1: required tables exist (spot check the ones this file exercises).
select has_table('public', 'inventory_items', 'inventory_items exists');

-- Resolve each user's personal household id for use in RPC calls below.
do $$
declare
  household_a uuid;
  household_b uuid;
begin
  select id into household_a from public.households where created_by = '33333333-3333-4333-8333-333333333331';
  select id into household_b from public.households where created_by = '33333333-3333-4333-8333-333333333332';
  perform set_config('pgtap.household_a', household_a::text, false);
  perform set_config('pgtap.household_b', household_b::text, false);
end;
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub', '33333333-3333-4333-8333-333333333331', true);

-- 2: household member can read own household inventory (empty but reachable).
select lives_ok(
  $$select count(*) from public.inventory_items where household_id = current_setting('pgtap.household_a')::uuid$$,
  'user A can query own household inventory without error'
);

-- A fixed literal timestamp — not now() — for every mutation pair meant to
-- test true idempotent retry: the request_hash the RPC computes includes
-- clientUpdatedAt, so two calls using now() would never hash-match and
-- would be (correctly) reported as idempotency_mismatch, not 'duplicate'.
-- Real retries from the iOS client always resend the exact original
-- request, including its original clientUpdatedAt — this mirrors that.
do $$ begin perform set_config('pgtap.fixed_client_updated_at', '2026-07-16T00:00:00Z', false); end $$;

-- 3: a valid create mutation applies once.
select is(
  (
    select (public.apply_sync_mutation(
      'household', current_setting('pgtap.household_a')::uuid,
      '44444444-4444-4444-8444-444444444441'::uuid,
      'inventory_item', '55555555-5555-4555-8555-555555555551'::uuid,
      'upsert', 0, current_setting('pgtap.fixed_client_updated_at')::timestamptz,
      '{"name":"鸡蛋","normalized_name":"鸡蛋"}'::jsonb
    ) ->> 'status')
  ),
  'applied',
  'a valid create mutation applies'
);

-- 4: duplicate mutation id (identical payload, including clientUpdatedAt) is
-- idempotent, not re-applied.
select is(
  (
    select (public.apply_sync_mutation(
      'household', current_setting('pgtap.household_a')::uuid,
      '44444444-4444-4444-8444-444444444441'::uuid,
      'inventory_item', '55555555-5555-4555-8555-555555555551'::uuid,
      'upsert', 0, current_setting('pgtap.fixed_client_updated_at')::timestamptz,
      '{"name":"鸡蛋","normalized_name":"鸡蛋"}'::jsonb
    ) ->> 'status')
  ),
  'duplicate',
  'retrying the identical mutationId+payload is idempotent'
);

-- 5: stale baseVersion is rejected as a conflict, not silently applied.
select is(
  (
    select (public.apply_sync_mutation(
      'household', current_setting('pgtap.household_a')::uuid,
      '44444444-4444-4444-8444-444444444442'::uuid,
      'inventory_item', '55555555-5555-4555-8555-555555555551'::uuid,
      'upsert', 0, now(),
      '{"name":"鸡蛋(更新)","normalized_name":"鸡蛋"}'::jsonb
    ) ->> 'status')
  ),
  'conflict',
  'a stale baseVersion (0, but the row is already at version 1) is rejected as a conflict'
);

-- 6: an invalid operation value is rejected before any write.
select throws_ok(
  $$select public.apply_sync_mutation(
    'household', current_setting('pgtap.household_a')::uuid,
    '44444444-4444-4444-8444-444444444443'::uuid,
    'inventory_item', '55555555-5555-4555-8555-555555555552'::uuid,
    'not_a_real_operation', 0, now(), '{}'::jsonb
  )$$,
  '22023',
  null,
  'an invalid operation is rejected'
);

-- 7: an invalid/unowned scope is rejected — user A may not write into
-- household B's scope even with an otherwise well-formed mutation.
select throws_ok(
  format(
    $$select public.apply_sync_mutation(
      'household', %L::uuid,
      '44444444-4444-4444-8444-444444444444'::uuid,
      'inventory_item', '55555555-5555-4555-8555-555555555553'::uuid,
      'upsert', 0, now(), '{"name":"偷偷写入","normalized_name":"偷偷写入"}'::jsonb
    )$$,
    current_setting('pgtap.household_b')
  ),
  '42501',
  null,
  'user A cannot write into household B''s scope'
);

-- 8: user A cannot read household B's inventory via the pull RPC.
select throws_ok(
  format(
    $$select public.pull_sync_changes('household', %L::uuid, 0, 100, null)$$,
    current_setting('pgtap.household_b')
  ),
  '42501',
  null,
  'user A cannot pull household B''s change feed'
);

-- 9: a delete creates a tombstone (deleted_at set), not a physical row removal.
select is(
  (
    select (public.apply_sync_mutation(
      'household', current_setting('pgtap.household_a')::uuid,
      '44444444-4444-4444-8444-444444444445'::uuid,
      'inventory_item', '55555555-5555-4555-8555-555555555551'::uuid,
      'delete', 1, current_setting('pgtap.fixed_client_updated_at')::timestamptz, '{}'::jsonb
    ) ->> 'status')
  ),
  'applied',
  'a delete on the current version applies (version is still 1 — mutation 442 above was rejected as a conflict and never advanced it)'
);
select ok(
  (select deleted_at is not null from public.inventory_items where id = '55555555-5555-4555-8555-555555555551'::uuid),
  'the deleted row remains present as a tombstone, never physically removed'
);

-- 10: the delete appears in the change feed as an operation=delete row.
select is(
  (
    select count(*) from public.sync_changes
    where entity_id = '55555555-5555-4555-8555-555555555551'::uuid and operation = 'delete'
  ),
  1::bigint,
  'the delete is recorded exactly once in the change feed'
);

-- 11: pulling the change feed after the delete returns a monotonically
-- increasing cursor and never goes backward.
select ok(
  (
    select (public.pull_sync_changes('household', current_setting('pgtap.household_a')::uuid, 0, 100, null) ->> 'cursor')::bigint
    >= (public.pull_sync_changes('household', current_setting('pgtap.household_a')::uuid, 0, 1, null) ->> 'cursor')::bigint
  ),
  'the pull cursor is monotonic across page sizes for the same scope'
);

-- 12: re-attempting the already-applied delete (same mutationId) is still
-- idempotent, not re-applied or reported as a fresh failure.
select is(
  (
    select (public.apply_sync_mutation(
      'household', current_setting('pgtap.household_a')::uuid,
      '44444444-4444-4444-8444-444444444445'::uuid,
      'inventory_item', '55555555-5555-4555-8555-555555555551'::uuid,
      'delete', 1, current_setting('pgtap.fixed_client_updated_at')::timestamptz, '{}'::jsonb
    ) ->> 'status')
  ),
  'duplicate',
  'retrying an already-applied delete mutationId is idempotent, not reprocessed'
);

-- 13: every mutation attempted above that actually reached the ledger insert
-- recorded exactly one row (create=applied, stale-conflict=conflict,
-- delete=applied — three distinct mutationIds; both duplicate retries and
-- every throws_ok rejection above return/raise before ever reaching the
-- ledger insert, so neither adds a row).
select is(
  (select count(*) from public.sync_mutations where user_id = '33333333-3333-4333-8333-333333333331'::uuid),
  3::bigint,
  'the idempotency ledger has exactly one row per distinct mutationId, never duplicated on retry'
);

-- 14: an unsupported entity type is rejected.
select throws_ok(
  format(
    $$select public.apply_sync_mutation(
      'household', %L::uuid, '44444444-4444-4444-8444-444444444446'::uuid,
      'not_a_real_entity_type', '55555555-5555-4555-8555-555555555554'::uuid,
      'upsert', 0, now(), '{}'::jsonb
    )$$,
    current_setting('pgtap.household_a')
  ),
  '22023',
  null,
  'an unsupported entity type is rejected'
);

-- 15: personal (user-scoped) entities are isolated the same way household
-- ones are — user A cannot create a recipe_favorite under user B's scope.
select throws_ok(
  format(
    $$select public.apply_sync_mutation(
      'user', %L::uuid, '44444444-4444-4444-8444-444444444447'::uuid,
      'recipe_favorite', '55555555-5555-4555-8555-555555555555'::uuid,
      'upsert', 0, now(), '{"recipe_id":"r1"}'::jsonb
    )$$,
    '33333333-3333-4333-8333-333333333332'
  ),
  '42501',
  null,
  'user A cannot write a personal-scope mutation as user B'
);

-- Switch to user B: confirm the reverse isolation direction too.
select set_config('request.jwt.claim.sub', '33333333-3333-4333-8333-333333333332', true);

-- 16: user B cannot see user A's now-tombstoned inventory row at all.
select is(
  (select count(*) from public.inventory_items where id = '55555555-5555-4555-8555-555555555551'::uuid),
  0::bigint,
  'user B cannot read user A''s household inventory row'
);

-- 17: user B cannot pull household A's change feed either.
select throws_ok(
  format(
    $$select public.pull_sync_changes('household', %L::uuid, 0, 100, null)$$,
    current_setting('pgtap.household_a')
  ),
  '42501',
  null,
  'user B cannot pull household A''s change feed'
);

-- 18: user B cannot see user A's mutation ledger rows.
select is(
  (select count(*) from public.sync_mutations where user_id = '33333333-3333-4333-8333-333333333331'::uuid),
  0::bigint,
  'user B cannot read user A''s mutation ledger rows (RLS is user_id = auth.uid())'
);

-- 19: anonymous (no authenticated JWT) cannot call the mutation RPC at all —
-- privilege is revoked at the function-grant level, checked here via
-- has_function_privilege rather than actually invoking as anon (a bare
-- REVOKE means anon fails before the function body's own actor check runs).
select ok(
  not has_function_privilege('anon', 'public.apply_sync_mutation(text,uuid,uuid,text,uuid,text,bigint,timestamptz,jsonb)', 'EXECUTE'),
  'anon has no EXECUTE privilege on the mutation RPC'
);
select ok(
  not has_function_privilege('anon', 'public.pull_sync_changes(text,uuid,bigint,integer,text[])', 'EXECUTE'),
  'anon has no EXECUTE privilege on the pull RPC'
);

-- 20: anonymous cannot read business tables directly either (RLS grants are
-- to `authenticated` only, `anon` was never granted SELECT in the migration).
select ok(
  not has_table_privilege('anon', 'public.inventory_items', 'SELECT'),
  'anon has no direct SELECT privilege on inventory_items'
);

-- 21: search_path is fixed on every user-facing sync RPC (defense against a
-- schema-injection/shadowing attack via a malicious search_path).
select ok(
  (select 'search_path=pg_catalog' = any(coalesce(p.proconfig, array[]::text[]))
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pull_sync_changes'),
  'pull_sync_changes fixes search_path to pg_catalog'
);

-- 22: no metadata/result payload from any RPC call above ever contains a
-- secret-shaped value (a defensive shape check, not a claim about what the
-- app displays — the RPC's own contract already excludes tokens/passwords).
select ok(
  not exists (
    select 1 from public.sync_mutations
    where result_payload::text ~* 'password|token|service_role|secret'
  ),
  'no mutation ledger result payload contains a secret-shaped key'
);

-- 23: reset to user A and confirm a rollback-shaped delete (undoing a
-- session's own just-created row) still applies cleanly — rollback in this
-- schema is simply another delete mutation through the same RPC, so this is
-- exactly the same code path exercised by GuestMergeController.rollback.
select set_config('request.jwt.claim.sub', '33333333-3333-4333-8333-333333333331', true);
select is(
  (
    select (public.apply_sync_mutation(
      'household', current_setting('pgtap.household_a')::uuid,
      '44444444-4444-4444-8444-444444444448'::uuid,
      'inventory_item', '55555555-5555-4555-8555-555555555556'::uuid,
      'upsert', 0, now(), '{"name":"待回滚","normalized_name":"待回滚"}'::jsonb
    ) ->> 'status')
  ),
  'applied',
  'setup: a fresh create for the rollback-shaped delete scenario applies'
);
select is(
  (
    select (public.apply_sync_mutation(
      'household', current_setting('pgtap.household_a')::uuid,
      '44444444-4444-4444-8444-444444444449'::uuid,
      'inventory_item', '55555555-5555-4555-8555-555555555556'::uuid,
      'delete', 1, now(), '{}'::jsonb
    ) ->> 'status')
  ),
  'applied',
  'a rollback-shaped delete (undoing a just-created row) applies via the same RPC path'
);

-- 24-27: household membership removal immediately revokes read access. This
-- requires an actual second member to exist first — household A otherwise
-- only ever has its owner (user A) as a member, so "removing a membership"
-- would be a no-op without first adding one. The current jwt claim is
-- already user A (the owner, reset just above for the rollback scenario),
-- so this INSERT is an ordinary owner-invites-a-member action — no elevated
-- role is needed (`household_members_insert_for_managers` already permits
-- it for an owner acting as themselves).
insert into public.household_members (household_id, user_id, role)
values (current_setting('pgtap.household_a')::uuid, '33333333-3333-4333-8333-333333333332'::uuid, 'member');

-- 24: with membership granted, user B can now read household A's inventory
-- (still reachable without error — the row count itself is incidental).
select set_config('request.jwt.claim.sub', '33333333-3333-4333-8333-333333333332', true);
select lives_ok(
  format($$select count(*) from public.inventory_items where household_id = %L::uuid$$, current_setting('pgtap.household_a')),
  'user B, once granted membership, can read household A''s inventory without error'
);

-- 25: the owner (user A) revokes user B's membership. A data-modifying WITH
-- cannot be embedded as a subquery inside is(...)'s first argument ("WITH
-- clause containing a data-modifying statement must be at the top level")
-- — run the DELETE as its own statement and capture the affected row count
-- via GET DIAGNOSTICS instead (same fix as auth_household_rls_test.sql).
select set_config('request.jwt.claim.sub', '33333333-3333-4333-8333-333333333331', true);
do $$
declare
  affected int;
begin
  delete from public.household_members
  where household_id = current_setting('pgtap.household_a')::uuid
    and user_id = '33333333-3333-4333-8333-333333333332'::uuid
    and role <> 'owner';
  get diagnostics affected = row_count;
  perform set_config('pgtap.rows_removed', affected::text, false);
end;
$$;
select is(current_setting('pgtap.rows_removed')::int, 1, 'the owner can remove a non-owner membership');

-- 26: immediately after removal (same session, no re-login/new JWT needed),
-- user B loses access to household A's change feed — access is re-checked
-- on every call via a live membership query, never cached.
select set_config('request.jwt.claim.sub', '33333333-3333-4333-8333-333333333332', true);
select throws_ok(
  format(
    $$select public.pull_sync_changes('household', %L::uuid, 0, 100, null)$$,
    current_setting('pgtap.household_a')
  ),
  '42501',
  null,
  'a former member immediately loses access to the change feed once membership is removed'
);

-- 27: user B likewise loses the ability to see household A's inventory
-- directly (RLS re-evaluates membership per query, not just per RPC call).
select is(
  (select count(*) from public.inventory_items where household_id = current_setting('pgtap.household_a')::uuid),
  0::bigint,
  'a former member immediately loses direct read access to the household''s inventory too'
);

-- ---------------------------------------------------------------------------
-- PATCH semantics (20260827000100_sync_mutation_patch_semantics).
--
-- Before that migration an upsert rewrote every column in the entity's
-- `column_names` list, so a client blanked every column it did not know
-- about. These cases pin the fixed behaviour: absent key = unchanged,
-- explicit null = cleared, defaults only on insert, required-presence only
-- on create.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '33333333-3333-4333-8333-333333333331', true);

-- Setup runs through `perform` inside DO blocks so it never consumes a pgTAP
-- plan slot. Row 557 is written the way a *different* client would write it:
-- it carries the columns the iOS payload has never heard of.
do $$
begin
  perform public.apply_sync_mutation(
    'household', current_setting('pgtap.household_a')::uuid,
    '44444444-4444-4444-8444-444444444450'::uuid,
    'inventory_item', '55555555-5555-4555-8555-555555555557'::uuid,
    'upsert', 0, now(),
    '{"name":"三文鱼","normalized_name":"三文鱼","quantity":2,"unit":"份",
      "kind":"raw","purchase_date":"2026-08-01","shelf_life_days":5,
      "stock_status":"ok","dry_prep":"泡发 30 分钟","gear":"冰箱",
      "unit_type":"weight","out_of_stock_at":"2026-08-10T00:00:00Z",
      "last_cooked_at":"2026-08-05T00:00:00Z","is_frozen":true,
      "cooked_count":3,"staple_note":"备注"}'::jsonb
  );
end;
$$;

-- the iOS-shaped payload — exactly the keys InventorySyncAdapter.payload
-- builds today — applies as an ordinary update.
select is(
  (
    select (public.apply_sync_mutation(
      'household', current_setting('pgtap.household_a')::uuid,
      '44444444-4444-4444-8444-444444444451'::uuid,
      'inventory_item', '55555555-5555-4555-8555-555555555557'::uuid,
      'upsert', 1, now(),
      '{"name":"三文鱼","normalized_name":"三文鱼","quantity":1,"unit":"份",
        "is_staple":false,"auto_suggest_restock":false,
        "staple_tracking_mode":"quantity","staple_availability_status":"available",
        "sort_order":0,"expiry_date":"2026-09-01","low_stock_threshold":null,
        "default_restock_quantity":null,"staple_note":null,"staple_category":null}'::jsonb
    ) ->> 'status')
  ),
  'applied',
  'an iOS-shaped partial inventory upsert applies'
);

-- the PWA-owned classification column survives an iOS write. This is the
-- single most important assertion in this file: it was 'raw' before the
-- update and had become NULL under the old whole-row semantics.
select is(
  (select kind from public.inventory_items where id = '55555555-5555-4555-8555-555555555557'::uuid),
  'raw',
  'an iOS upsert never clears the PWA-owned inventory_items.kind'
);

-- every other column the iOS payload omits is equally untouched —
-- including the two that `default_data` used to reset to a constant.
select ok(
  (select purchase_date = date '2026-08-01'
      and shelf_life_days = 5
      and stock_status = 'ok'
      and dry_prep = '泡发 30 分钟'
      and gear = '冰箱'
      and unit_type = 'weight'
      and out_of_stock_at = timestamptz '2026-08-10T00:00:00Z'
      and last_cooked_at = timestamptz '2026-08-05T00:00:00Z'
      and is_frozen
      and cooked_count = 3
   from public.inventory_items where id = '55555555-5555-4555-8555-555555555557'::uuid),
  'columns absent from the payload keep their stored values, and default_data never resets is_frozen/cooked_count on an update'
);

-- the update is a real update, not a no-op — the sent columns did change.
select ok(
  (select quantity = 1::numeric and expiry_date = date '2026-09-01'
   from public.inventory_items where id = '55555555-5555-4555-8555-555555555557'::uuid),
  'columns present in the payload are written'
);

-- an explicit JSON null still clears a column — absence and null are not
-- the same instruction.
select ok(
  (select staple_note is null from public.inventory_items where id = '55555555-5555-4555-8555-555555555557'::uuid),
  'an explicit null clears the column it names'
);

-- an update that never re-sends a required field succeeds.
select is(
  (
    select (public.apply_sync_mutation(
      'household', current_setting('pgtap.household_a')::uuid,
      '44444444-4444-4444-8444-444444444452'::uuid,
      'inventory_item', '55555555-5555-4555-8555-555555555557'::uuid,
      'upsert', 2, now(), '{"quantity":5}'::jsonb
    ) ->> 'status')
  ),
  'applied',
  'an update that omits the required name applies'
);

-- ...and keeps the stored name rather than blanking it.
select is(
  (select name from public.inventory_items where id = '55555555-5555-4555-8555-555555555557'::uuid),
  '三文鱼',
  'an update that omits name keeps the stored name'
);

-- a create still has to carry every required field.
select throws_ok(
  $$select public.apply_sync_mutation(
    'household', current_setting('pgtap.household_a')::uuid,
    '44444444-4444-4444-8444-444444444453'::uuid,
    'inventory_item', '55555555-5555-4555-8555-555555555558'::uuid,
    'upsert', 0, now(), '{"quantity":1}'::jsonb
  )$$,
  '22023',
  null,
  'a create missing a required field is still rejected'
);

-- a required field that IS sent must still be usable, on an update too.
select throws_ok(
  $$select public.apply_sync_mutation(
    'household', current_setting('pgtap.household_a')::uuid,
    '44444444-4444-4444-8444-444444444454'::uuid,
    'inventory_item', '55555555-5555-4555-8555-555555555557'::uuid,
    'upsert', 3, now(), '{"name":"   "}'::jsonb
  )$$,
  '22023',
  null,
  'an update sending a blank required value is rejected'
);
select throws_ok(
  $$select public.apply_sync_mutation(
    'household', current_setting('pgtap.household_a')::uuid,
    '44444444-4444-4444-8444-444444444455'::uuid,
    'inventory_item', '55555555-5555-4555-8555-555555555557'::uuid,
    'upsert', 3, now(), '{"name":null}'::jsonb
  )$$,
  '22023',
  null,
  'an update sending null for a required value is rejected'
);

-- an upsert that names no column at all changes nothing and says so,
-- rather than silently rewriting the row with defaults.
select is(
  (
    select (public.apply_sync_mutation(
      'household', current_setting('pgtap.household_a')::uuid,
      '44444444-4444-4444-8444-444444444456'::uuid,
      'inventory_item', '55555555-5555-4555-8555-555555555557'::uuid,
      'upsert', 3, now(), '{}'::jsonb
    ) ->> 'status')
  ),
  'rejected',
  'an empty upsert against an existing row is rejected'
);
select is(
  (
    select (public.apply_sync_mutation(
      'household', current_setting('pgtap.household_a')::uuid,
      '44444444-4444-4444-8444-444444444457'::uuid,
      'inventory_item', '55555555-5555-4555-8555-555555555557'::uuid,
      'upsert', 3, now(), '{}'::jsonb
    ) ->> 'errorCode')
  ),
  'empty_update',
  'an empty upsert is reported as empty_update'
);

-- an unsupported field is still refused outright.
select throws_ok(
  $$select public.apply_sync_mutation(
    'household', current_setting('pgtap.household_a')::uuid,
    '44444444-4444-4444-8444-444444444458'::uuid,
    'inventory_item', '55555555-5555-4555-8555-555555555557'::uuid,
    'upsert', 3, now(), '{"name":"三文鱼","not_a_real_column":1}'::jsonb
  )$$,
  '22023',
  null,
  'an unsupported field is still rejected under PATCH semantics'
);

-- a single-column assignment must not be emitted in the parenthesized
-- multi-column form, which PostgreSQL rejects. Under PATCH semantics any
-- entity can produce one (the `{"quantity":5}` update above already did);
-- recipe_favorite is the case where it is *unavoidable*, since a single
-- client-writable column is all it has.
do $$
begin
  perform public.apply_sync_mutation(
    'user', '33333333-3333-4333-8333-333333333331'::uuid,
    '44444444-4444-4444-8444-444444444459'::uuid,
    'recipe_favorite', '55555555-5555-4555-8555-555555555559'::uuid,
    'upsert', 0, now(), '{"recipe_id":"sample-mapotofu"}'::jsonb
  );
end;
$$;
select is(
  (
    select (public.apply_sync_mutation(
      'user', '33333333-3333-4333-8333-333333333331'::uuid,
      '44444444-4444-4444-8444-444444444460'::uuid,
      'recipe_favorite', '55555555-5555-4555-8555-555555555559'::uuid,
      'upsert', 1, now(), '{"recipe_id":"sample-mapotofu"}'::jsonb
    ) ->> 'status')
  ),
  'applied',
  'a single-column entity update applies (single-column SET syntax is valid)'
);

-- ---------------------------------------------------------------------------
-- PATCH is a contract shared by every sync entity, not an inventory
-- fix. Each household entity below is created with a value in a column its
-- partial update never mentions, then asserted unchanged.
-- ---------------------------------------------------------------------------
do $$
declare
  household uuid := current_setting('pgtap.household_a')::uuid;
begin
  perform public.apply_sync_mutation(
    'household', household, '44444444-4444-4444-8444-444444444461'::uuid,
    'shopping_item', '55555555-5555-4555-8555-555555555560'::uuid,
    'upsert', 0, now(),
    '{"name":"牛奶","normalized_name":"牛奶","remark":"低脂"}'::jsonb
  );
  perform public.apply_sync_mutation(
    'household', household, '44444444-4444-4444-8444-444444444462'::uuid,
    'shopping_item', '55555555-5555-4555-8555-555555555560'::uuid,
    'upsert', 1, now(), '{"is_done":true}'::jsonb
  );

  perform public.apply_sync_mutation(
    'household', household, '44444444-4444-4444-8444-444444444463'::uuid,
    'today_plan', '55555555-5555-4555-8555-555555555561'::uuid,
    'upsert', 0, now(),
    '{"recipe_name":"番茄炒蛋","planned_date":"2026-08-27","recipe_id":"r-1"}'::jsonb
  );
  perform public.apply_sync_mutation(
    'household', household, '44444444-4444-4444-8444-444444444464'::uuid,
    'today_plan', '55555555-5555-4555-8555-555555555561'::uuid,
    'upsert', 1, now(), '{"servings":3}'::jsonb
  );

  perform public.apply_sync_mutation(
    'household', household, '44444444-4444-4444-8444-444444444465'::uuid,
    'consumption_record', '55555555-5555-4555-8555-555555555562'::uuid,
    'upsert', 0, now(),
    '{"occurred_at":"2026-08-27T10:00:00Z","recipe_id":"r-2"}'::jsonb
  );
  perform public.apply_sync_mutation(
    'household', household, '44444444-4444-4444-8444-444444444466'::uuid,
    'consumption_record', '55555555-5555-4555-8555-555555555562'::uuid,
    'upsert', 1, now(), '{"is_undone":true}'::jsonb
  );

  perform public.apply_sync_mutation(
    'household', household, '44444444-4444-4444-8444-444444444467'::uuid,
    'weekly_meal_plan', '55555555-5555-4555-8555-555555555563'::uuid,
    'upsert', 0, now(),
    '{"week_start":"2026-08-24","summary":"本周概要"}'::jsonb
  );
  perform public.apply_sync_mutation(
    'household', household, '44444444-4444-4444-8444-444444444468'::uuid,
    'weekly_meal_plan', '55555555-5555-4555-8555-555555555563'::uuid,
    'upsert', 1, now(), '{"servings":2}'::jsonb
  );

  perform public.apply_sync_mutation(
    'household', household, '44444444-4444-4444-8444-444444444469'::uuid,
    'weekly_meal_plan_item', '55555555-5555-4555-8555-555555555564'::uuid,
    'upsert', 0, now(),
    '{"plan_id":"55555555-5555-4555-8555-555555555563","day_index":0,"meal_index":0,
      "recipe_title":"番茄炒蛋","meal_title":"晚餐"}'::jsonb
  );
  perform public.apply_sync_mutation(
    'household', household, '44444444-4444-4444-8444-444444444470'::uuid,
    'weekly_meal_plan_item', '55555555-5555-4555-8555-555555555564'::uuid,
    'upsert', 1, now(), '{"sort_order":3}'::jsonb
  );

  perform public.apply_sync_mutation(
    'household', household, '44444444-4444-4444-8444-444444444471'::uuid,
    'user_recipe', '55555555-5555-4555-8555-555555555565'::uuid,
    'upsert', 0, now(), '{"title":"家常豆腐","difficulty":"简单"}'::jsonb
  );
  perform public.apply_sync_mutation(
    'household', household, '44444444-4444-4444-8444-444444444472'::uuid,
    'user_recipe', '55555555-5555-4555-8555-555555555565'::uuid,
    'upsert', 1, now(), '{"sort_order":1}'::jsonb
  );
end;
$$;

select ok(
  (select remark = '低脂' and is_done
   from public.shopping_items where id = '55555555-5555-4555-8555-555555555560'::uuid),
  'shopping_item: an unsent column is preserved while the sent one is written'
);
select ok(
  (select recipe_id = 'r-1' and servings = 3
   from public.today_plan_items where id = '55555555-5555-4555-8555-555555555561'::uuid),
  'today_plan: an unsent column is preserved while the sent one is written'
);
select ok(
  (select recipe_id = 'r-2' and is_undone
   from public.consumption_records where id = '55555555-5555-4555-8555-555555555562'::uuid),
  'consumption_record: an unsent column is preserved while the sent one is written'
);
select ok(
  (select summary = '本周概要' and servings = 2
   from public.weekly_meal_plans where id = '55555555-5555-4555-8555-555555555563'::uuid),
  'weekly_meal_plan: an unsent column is preserved while the sent one is written'
);
select ok(
  (select meal_title = '晚餐' and sort_order = 3
   from public.weekly_meal_plan_items where id = '55555555-5555-4555-8555-555555555564'::uuid),
  'weekly_meal_plan_item: an unsent column is preserved while the sent one is written'
);
select ok(
  (select difficulty = '简单' and sort_order = 1
   from public.user_recipes where id = '55555555-5555-4555-8555-555555555565'::uuid),
  'user_recipe: an unsent column is preserved while the sent one is written'
);

-- recipe_favorites and frequent_recipes have exactly one client-writable
-- column each, so "an unsent column is preserved" is not expressible for
-- them — any upsert either sends recipe_id or is an empty_update. Asserting
-- the shape is the honest coverage; the single-column case above already exercises their
-- single-column update path.
select ok(
  (select count(*) from information_schema.columns
   where table_schema = 'public' and table_name in ('recipe_favorites', 'frequent_recipes')
     and column_name not in ('id', 'user_id', 'created_at', 'updated_at', 'deleted_at', 'version', 'created_by', 'updated_by')
  ) = 2::bigint,
  'recipe_favorites/frequent_recipes each expose exactly one client-writable column, so they have no partially-updatable field'
);

select * from finish();
rollback;

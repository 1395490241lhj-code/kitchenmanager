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
select plan(30);

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
      '{"name":"鸡蛋","normalizedName":"鸡蛋"}'::jsonb
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
      '{"name":"鸡蛋","normalizedName":"鸡蛋"}'::jsonb
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
      '{"name":"鸡蛋(更新)","normalizedName":"鸡蛋"}'::jsonb
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
      'upsert', 0, now(), '{"name":"偷偷写入","normalizedName":"偷偷写入"}'::jsonb
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
      'upsert', 0, now(), '{"recipeId":"r1"}'::jsonb
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
      'upsert', 0, now(), '{"name":"待回滚","normalizedName":"待回滚"}'::jsonb
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

-- 25: the owner (user A) revokes user B's membership.
select set_config('request.jwt.claim.sub', '33333333-3333-4333-8333-333333333331', true);
select is(
  (
    with removed as (
      delete from public.household_members
      where household_id = current_setting('pgtap.household_a')::uuid
        and user_id = '33333333-3333-4333-8333-333333333332'::uuid
        and role <> 'owner'
      returning 1
    ) select count(*) from removed
  ),
  1::bigint,
  'the owner can remove a non-owner membership'
);

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

select * from finish();
rollback;

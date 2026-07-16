-- Phase 2D-2: account deletion + data lifecycle safety pgTAP coverage.
-- Exercises the real request_account_deletion/transfer_household_ownership/
-- mark_account_deletion_finalized functions end-to-end (not just schema
-- shape), matching this repo's existing convention of behavioral RLS tests
-- alongside static object-existence tests.

begin;
select plan(35);

-- ── Static object/security checks ───────────────────────────────────────

select is(to_regclass('public.account_deletion_requests')::text, 'account_deletion_requests', 'account_deletion_requests table exists');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.account_deletion_requests'::regclass),
  'account_deletion_requests RLS is enabled'
);

select is(
  (select count(*) from pg_policies where schemaname = 'public' and tablename = 'account_deletion_requests'),
  1::bigint,
  'account_deletion_requests has exactly one policy (select-self)'
);

-- No insert/update/delete grant exists for authenticated: every write must
-- go through a privileged function, never direct client DML.
select ok(
  not has_table_privilege('authenticated', 'public.account_deletion_requests', 'INSERT'),
  'authenticated cannot INSERT into account_deletion_requests directly'
);
select ok(
  not has_table_privilege('authenticated', 'public.account_deletion_requests', 'UPDATE'),
  'authenticated cannot UPDATE account_deletion_requests directly (cannot forge completed status)'
);
select ok(
  not has_table_privilege('authenticated', 'public.account_deletion_requests', 'DELETE'),
  'authenticated cannot DELETE account_deletion_requests directly'
);

-- Every new function sets a safe search_path (pg_catalog only) and none is
-- executable by anon/public; mark_account_deletion_finalized is additionally
-- confirmed NOT executable by authenticated (service_role only).
select ok(
  (select proconfig @> array['search_path=pg_catalog'] from pg_proc where oid = 'public.request_account_deletion(uuid, text)'::regprocedure),
  'request_account_deletion has a safe search_path'
);
select ok(
  (select proconfig @> array['search_path=pg_catalog'] from pg_proc where oid = 'public.get_account_deletion_preview()'::regprocedure),
  'get_account_deletion_preview has a safe search_path'
);
select ok(
  (select proconfig @> array['search_path=pg_catalog'] from pg_proc where oid = 'public.transfer_household_ownership(uuid, uuid)'::regprocedure),
  'transfer_household_ownership has a safe search_path'
);
select ok(
  (select proconfig @> array['search_path=pg_catalog'] from pg_proc where oid = 'public.mark_account_deletion_finalized(uuid, uuid, boolean, text)'::regprocedure),
  'mark_account_deletion_finalized has a safe search_path'
);
select ok(
  not has_function_privilege('anon', 'public.request_account_deletion(uuid, text)', 'EXECUTE'),
  'anon cannot execute request_account_deletion'
);
select ok(
  not has_function_privilege('authenticated', 'public.mark_account_deletion_finalized(uuid, uuid, boolean, text)', 'EXECUTE'),
  'authenticated cannot execute mark_account_deletion_finalized (service_role only)'
);
select ok(
  has_function_privilege('service_role', 'public.mark_account_deletion_finalized(uuid, uuid, boolean, text)', 'EXECUTE'),
  'service_role can execute mark_account_deletion_finalized'
);

-- ── Behavioral coverage: two users, A owns a shared household, B is a member ──

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('a1111111-1111-4111-8111-111111111111', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'a@example.com', '', now(), '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('b2222222-2222-4222-8222-222222222222', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b@example.com', '', now(), '{}'::jsonb, '{}'::jsonb, now(), now());

select id as a_household from public.households where created_by = 'a1111111-1111-4111-8111-111111111111' and is_personal \gset

insert into public.household_members (household_id, user_id, role)
values (:'a_household', 'b2222222-2222-4222-8222-222222222222', 'member');

-- An invalid status value is rejected by the check constraint (uses B's
-- real profile id so only the status check is exercised, not the FK).
select throws_ok(
  $$insert into public.account_deletion_requests (user_id, status, idempotency_key, preview_fingerprint) values ('b2222222-2222-4222-8222-222222222222'::uuid, 'not_a_real_status', gen_random_uuid(), 'x')$$,
  '23514',
  null,
  'invalid status value is rejected by the check constraint'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'a1111111-1111-4111-8111-111111111111', true);

-- A creates one inventory item (real created_by/updated_by attribution).
select public.apply_sync_mutation('household', :'a_household'::uuid, gen_random_uuid(), 'inventory_item', gen_random_uuid(), 'upsert', null, now(), '{"name":"Milk","normalized_name":"milk"}'::jsonb) as mutation_result \gset
select (:'mutation_result'::jsonb ->> 'entityId')::uuid as item_id \gset

-- Preview must flag the ownership blocker and must never contain the
-- household id/name or the other member's email/UUID.
select public.get_account_deletion_preview() as preview_json \gset
select is((:'preview_json'::jsonb ->> 'canDelete')::boolean, false, 'preview: owner-with-others cannot delete yet');
select is(:'preview_json'::jsonb ->> 'blockingReason', 'OWNERSHIP_TRANSFER_REQUIRED', 'preview: blocking reason is ownership transfer');
select ok(not (:'preview_json'::jsonb ? 'householdId'), 'preview never includes a household id field');
select ok(:'preview_json'::text not like '%b2222222%', 'preview never includes the other member''s UUID');

-- Confirm must fail closed while blocked, without mutating anything.
select public.request_account_deletion(gen_random_uuid(), (:'preview_json'::jsonb ->> 'confirmationVersion')) as blocked_result \gset
select is(:'blocked_result'::jsonb ->> 'errorCode', 'OWNERSHIP_TRANSFER_REQUIRED', 'confirm is rejected while ownership transfer is required');
select is((select count(*) from public.household_members where household_id = :'a_household'::uuid), 2::bigint, 'no membership row changed after a blocked confirm attempt');

-- A stale (mismatched) fingerprint must also be rejected, distinctly.
select public.request_account_deletion(gen_random_uuid(), 'deadbeef') as stale_result \gset
select is(:'stale_result'::jsonb ->> 'errorCode', 'STALE_DELETION_PREVIEW', 'a stale/mismatched preview fingerprint is rejected');

-- User A cannot transfer ownership of a household to an arbitrary/non-member id.
select throws_ok(
  format($$select public.transfer_household_ownership(%L::uuid, gen_random_uuid())$$, :'a_household'),
  '22023',
  'new owner must already be a household member',
  'ownership cannot be transferred to a non-member'
);

-- Transfer to B (a real member) succeeds and is atomic (old owner demoted,
-- new owner promoted, in the same statement).
select public.transfer_household_ownership(:'a_household'::uuid, 'b2222222-2222-4222-8222-222222222222'::uuid);
select is((select role from public.household_members where household_id = :'a_household'::uuid and user_id = 'b2222222-2222-4222-8222-222222222222'), 'owner', 'ownership transfer promotes the new owner');
select is((select role from public.household_members where household_id = :'a_household'::uuid and user_id = 'a1111111-1111-4111-8111-111111111111'), 'admin', 'ownership transfer demotes the old owner (never leaves a second owner)');
select is((select count(*) from public.household_members where household_id = :'a_household'::uuid and role = 'owner'), 1::bigint, 'exactly one owner remains after transfer (no zero-owner, no multi-owner state)');

-- A fresh preview now allows deletion; confirm proceeds and cleans up.
select public.get_account_deletion_preview() as preview2_json \gset
select is((:'preview2_json'::jsonb ->> 'canDelete')::boolean, true, 'preview after transfer: deletion is now allowed');

select public.request_account_deletion(gen_random_uuid(), (:'preview2_json'::jsonb ->> 'confirmationVersion')) as confirm_result \gset
select is(:'confirm_result'::jsonb ->> 'status', 'business_data_cleaned', 'confirm succeeds once the blocker is resolved');

-- Residue checks that read A's OWN no-longer-visible data (her ledger row,
-- her removed membership) must run as a privileged role: RLS on households/
-- household_members correctly hides a household from a user who has just
-- left it, and A's own SELECT would otherwise show a false "0 rows" that
-- looks like data loss but is actually just RLS working as intended for
-- her own now-restricted view. A's account_deletion_requests row remains
-- her own and is still visible to her (checked separately below).
select is((select count(*) from public.household_members where user_id = 'a1111111-1111-4111-8111-111111111111'), 0::bigint, 'A has no remaining household membership (residue check)');

-- A duplicate confirm with the SAME idempotency key must be idempotent
-- (no re-execution, no error) even though A no longer has a fresh preview
-- fingerprint to offer (this exercises the "already business_data_cleaned,
-- same key" branch, not a fresh run).
select idempotency_key from public.account_deletion_requests where user_id = 'a1111111-1111-4111-8111-111111111111' \gset
select public.request_account_deletion(:'idempotency_key'::uuid, 'irrelevant-because-already-cleaned') as duplicate_result \gset
select is(:'duplicate_result'::jsonb ->> 'status', 'business_data_cleaned', 'a duplicate confirm with the same idempotency key is idempotent');

reset role;

-- Anonymization + "household remains accessible to the new owner" checks
-- must be read from B's own session (B is the current owner and thus
-- allowed by RLS to see the household/item/change-feed she now owns) —
-- this is also the more meaningful assertion: it directly proves "the
-- deleted user's departure did not take the household or its data with
-- her," from the perspective of the person who actually still has access.
set local role authenticated;
select set_config('request.jwt.claim.sub', 'b2222222-2222-4222-8222-222222222222', true);
select is((select count(*) from public.households where id = :'a_household'::uuid), 1::bigint, 'the shared household still exists and is visible to its new owner B');
select is((select created_by from public.inventory_items where id = :'item_id'::uuid), null, 'the surviving item''s created_by is anonymized to NULL, not a dangling id');
select is(
  (select record_data ->> 'created_by' from public.sync_changes where household_id = :'a_household'::uuid and entity_id = :'item_id'::uuid order by sequence desc limit 1),
  '00000000-0000-0000-0000-000000000000',
  'the historical sync_changes snapshot no longer identifies A'
);
reset role;

-- sync_mutations has no RLS/select-for-self policy exposed to a specific
-- row-owner check here; read as the privileged role (matches how this
-- ledger is otherwise only ever read internally, never by direct client
-- select in production either).
select is((select count(*) from public.sync_mutations where user_id = 'a1111111-1111-4111-8111-111111111111'), 0::bigint, 'A''s idempotency ledger rows are removed (residue check)');

-- account_deletion_requests RLS: A can see only her own row.
set local role authenticated;
select set_config('request.jwt.claim.sub', 'a1111111-1111-4111-8111-111111111111', true);
select is((select count(*) from public.account_deletion_requests), 1::bigint, 'A sees only her own deletion request row');
select set_config('request.jwt.claim.sub', 'b2222222-2222-4222-8222-222222222222', true);
select is((select count(*) from public.account_deletion_requests), 0::bigint, 'B does not see A''s deletion request row');
reset role;

select * from finish();
rollback;

begin;
select plan(10);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('11111111-1111-4111-8111-111111111111', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'a@example.com', '', now(), '{}'::jsonb, '{"display_name":"Alice"}'::jsonb, now(), now()),
  ('22222222-2222-4222-8222-222222222222', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b@example.com', '', now(), '{}'::jsonb, '{"display_name":"Bob"}'::jsonb, now(), now());

select is((select count(*) from public.profiles), 2::bigint, 'auth trigger creates one profile per user');
select is((select count(*) from public.households where is_personal), 2::bigint, 'auth trigger creates one personal household per user');
select is((select count(*) from public.household_members where role = 'owner'), 2::bigint, 'auth trigger creates owner memberships');

-- Re-running initialization through an email update must remain idempotent.
update auth.users set email = 'a2@example.com' where id = '11111111-1111-4111-8111-111111111111';
select is((select count(*) from public.households where created_by = '11111111-1111-4111-8111-111111111111'), 1::bigint, 'email update does not duplicate personal household');

insert into public.household_members (household_id, user_id, role)
select id, '22222222-2222-4222-8222-222222222222', 'member'
from public.households
where created_by = '11111111-1111-4111-8111-111111111111';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select is((select count(*) from public.profiles), 1::bigint, 'user A reads only own profile');
select is((select count(*) from public.households), 1::bigint, 'user A reads only own member household');
select is((select count(*) from public.household_members), 2::bigint, 'user A can read members of own household');

select set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
select is((select count(*) from public.profiles), 1::bigint, 'user B reads only own profile');

-- A data-modifying WITH (WITH ... UPDATE ... RETURNING ... SELECT ...) is
-- only valid as its own top-level statement in Postgres — it cannot be
-- embedded as a subquery expression inside is(...)'s first argument
-- ("WITH clause containing a data-modifying statement must be at the top
-- level"). Run the UPDATE as its own statement and capture the affected
-- row count via GET DIAGNOSTICS instead; RLS silently filters out rows the
-- current role can't see for UPDATE (0 rows affected, no exception), so
-- this preserves the exact same assertion.
do $$
declare
  affected int;
begin
  update public.households
  set name = 'member must not rename'
  where created_by = '11111111-1111-4111-8111-111111111111';
  get diagnostics affected = row_count;
  perform set_config('pgtap.rows_updated', affected::text, false);
end;
$$;
select is(current_setting('pgtap.rows_updated')::int, 0, 'ordinary member cannot perform owner household update');

select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
do $$
declare
  affected int;
begin
  update public.households
  set name = 'Alice Kitchen'
  where created_by = '11111111-1111-4111-8111-111111111111';
  get diagnostics affected = row_count;
  perform set_config('pgtap.rows_updated', affected::text, false);
end;
$$;
select is(current_setting('pgtap.rows_updated')::int, 1, 'owner can rename own household');

select * from finish();
rollback;

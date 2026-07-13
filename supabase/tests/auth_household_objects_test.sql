begin;
select plan(12);

select is(to_regclass('public.profiles')::text, 'profiles', 'profiles table exists');
select is(to_regclass('public.households')::text, 'households', 'households table exists');
select is(to_regclass('public.household_members')::text, 'household_members', 'household_members table exists');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.profiles'::regclass),
  'profiles RLS is enabled'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.households'::regclass),
  'households RLS is enabled'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.household_members'::regclass),
  'household_members RLS is enabled'
);

select is(
  (select count(*) from pg_indexes where schemaname = 'public' and indexname = 'households_one_personal_per_creator_idx'),
  1::bigint,
  'one-personal-household partial unique index exists'
);
select is(
  (select count(*) from pg_indexes where schemaname = 'public' and indexname = 'household_members_user_id_idx'),
  1::bigint,
  'membership user index exists'
);
select is(
  (select count(*) from pg_trigger where tgrelid = 'auth.users'::regclass and tgname = 'on_auth_user_created_or_email_changed' and not tgisinternal),
  1::bigint,
  'auth initialization trigger exists exactly once'
);

select is(
  (select count(*) from pg_policies where schemaname = 'public' and tablename = 'profiles'),
  2::bigint,
  'profiles has the expected policy count'
);
select is(
  (select count(*) from pg_policies where schemaname = 'public' and tablename = 'households'),
  3::bigint,
  'households has the expected policy count'
);
select is(
  (select count(*) from pg_policies where schemaname = 'public' and tablename = 'household_members'),
  4::bigint,
  'household_members has the expected policy count'
);

select * from finish();
rollback;

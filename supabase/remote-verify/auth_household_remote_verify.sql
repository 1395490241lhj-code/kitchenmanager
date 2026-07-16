do $phase0_verify$
declare
  actual_policies text[];
begin
  if to_regclass('public.profiles') is null
    or to_regclass('public.households') is null
    or to_regclass('public.household_members') is null then
    raise exception 'phase0 verification failed: required table missing';
  end if;

  if exists (
    select 1
    from pg_class
    where oid in (
      'public.profiles'::regclass,
      'public.households'::regclass,
      'public.household_members'::regclass
    )
      and not relrowsecurity
  ) then
    raise exception 'phase0 verification failed: RLS is not enabled on every table';
  end if;

  if (select count(*) from pg_indexes
      where schemaname = 'public'
        and indexname in (
          'households_one_personal_per_creator_idx',
          'household_members_user_id_idx',
          'household_members_household_role_idx'
        )) <> 3 then
    raise exception 'phase0 verification failed: expected index missing or duplicated';
  end if;

  if not exists (
    select 1
    from pg_index i
    join pg_class c on c.oid = i.indexrelid
    where c.relname = 'households_one_personal_per_creator_idx'
      and i.indisunique
      and pg_get_expr(i.indpred, i.indrelid) is not null
  ) then
    raise exception 'phase0 verification failed: personal household partial unique index is invalid';
  end if;

  if (select count(*)
      from pg_trigger
      where not tgisinternal
        and (
          (tgrelid = 'public.profiles'::regclass and tgname = 'profiles_set_updated_at')
          or (tgrelid = 'public.households'::regclass and tgname = 'households_set_updated_at')
          or (tgrelid = 'auth.users'::regclass and tgname = 'on_auth_user_created_or_email_changed')
        )) <> 3 then
    raise exception 'phase0 verification failed: expected trigger missing or duplicated';
  end if;

  select array_agg(format('%s.%s', tablename, policyname) order by tablename, policyname)
  into actual_policies
  from pg_policies
  where schemaname = 'public'
    and tablename in ('profiles', 'households', 'household_members');

  if actual_policies <> array[
    'household_members.household_members_delete_for_managers',
    'household_members.household_members_insert_for_managers',
    'household_members.household_members_select_for_members',
    'household_members.household_members_update_for_managers',
    'households.households_delete_for_owner',
    'households.households_select_for_members',
    'households.households_update_for_owner',
    'profiles.profiles_select_self',
    'profiles.profiles_update_self'
  ]::text[] then
    raise exception 'phase0 verification failed: policy set differs from migration';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.profiles'::regclass
      and contype = 'f'
      and confrelid = 'auth.users'::regclass
      and confdeltype = 'c'
  ) then
    raise exception 'phase0 verification failed: profiles/auth.users foreign key is invalid';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.households'::regclass
      and contype = 'f'
      and confrelid = 'public.profiles'::regclass
      and confdeltype = 'r'
  ) then
    raise exception 'phase0 verification failed: household creator foreign key is invalid';
  end if;

  if (select count(*) from pg_constraint
      where conrelid = 'public.household_members'::regclass
        and contype = 'f'
        and confdeltype = 'c') <> 2 then
    raise exception 'phase0 verification failed: membership foreign keys are invalid';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.household_members'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) like '%owner%admin%member%'
  ) then
    raise exception 'phase0 verification failed: membership role constraint is missing';
  end if;

  if exists (
    select created_by
    from public.households
    where is_personal
    group by created_by
    having count(*) <> 1
  ) then
    raise exception 'phase0 verification failed: duplicate personal household detected';
  end if;

  if exists (
    select 1
    from public.households h
    left join public.household_members hm
      on hm.household_id = h.id
      and hm.user_id = h.created_by
      and hm.role = 'owner'
    where h.is_personal and hm.user_id is null
  ) then
    raise exception 'phase0 verification failed: personal household owner membership is missing';
  end if;
end
$phase0_verify$;

select
  'phase0_remote_objects_verified' as result,
  (select count(*) from pg_policies where schemaname = 'public' and tablename in ('profiles', 'households', 'household_members')) as policy_count,
  (select count(*) from pg_trigger where not tgisinternal and tgname in ('profiles_set_updated_at', 'households_set_updated_at', 'on_auth_user_created_or_email_changed')) as trigger_count,
  (select count(*) from public.profiles) as profile_count,
  (select count(*) from public.households where is_personal) as personal_household_count;

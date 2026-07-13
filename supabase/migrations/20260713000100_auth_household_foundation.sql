begin;

create schema if not exists private;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text check (display_name is null or char_length(display_name) between 1 and 100),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 100),
  created_by uuid not null references public.profiles(id) on delete restrict,
  is_personal boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists households_one_personal_per_creator_idx
  on public.households(created_by) where is_personal;

create table if not exists public.household_members (
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null check (role in ('owner', 'admin', 'member')),
  created_at timestamptz not null default now(),
  primary key (household_id, user_id)
);

create index if not exists household_members_user_id_idx
  on public.household_members(user_id);
create index if not exists household_members_household_role_idx
  on public.household_members(household_id, role);

create or replace function private.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function private.set_updated_at();

drop trigger if exists households_set_updated_at on public.households;
create trigger households_set_updated_at
before update on public.households
for each row execute function private.set_updated_at();

-- One idempotent transaction initializes the profile, a single personal
-- household, and owner membership. The partial unique index plus composite PK
-- make repeated/concurrent execution converge without duplicate rows.
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  personal_household_id uuid;
  requested_name text;
begin
  requested_name := nullif(left(btrim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), 100), '');

  insert into public.profiles (id, email, display_name)
  values (new.id, new.email, requested_name)
  on conflict (id) do update
    set email = excluded.email,
        display_name = coalesce(public.profiles.display_name, excluded.display_name);

  insert into public.households (name, created_by, is_personal)
  values ('我的厨房', new.id, true)
  on conflict (created_by) where is_personal
  do update set updated_at = public.households.updated_at
  returning id into personal_household_id;

  insert into public.household_members (household_id, user_id, role)
  values (personal_household_id, new.id, 'owner')
  on conflict (household_id, user_id) do update set role = 'owner';

  return new;
end;
$$;

revoke all on function public.handle_new_auth_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created_or_email_changed on auth.users;
create trigger on_auth_user_created_or_email_changed
after insert or update of email on auth.users
for each row execute function public.handle_new_auth_user();

-- Security-definer membership helpers live outside exposed schemas to avoid
-- recursive household_members RLS evaluation. They accept the caller UUID
-- only from policy-controlled auth.uid(), never from an API payload.
create or replace function private.is_household_member(target_household_id uuid, target_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select exists (
    select 1
    from public.household_members hm
    where hm.household_id = target_household_id
      and hm.user_id = target_user_id
  );
$$;

create or replace function private.has_household_role(target_household_id uuid, target_user_id uuid, allowed_roles text[])
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select exists (
    select 1
    from public.household_members hm
    where hm.household_id = target_household_id
      and hm.user_id = target_user_id
      and hm.role = any(allowed_roles)
  );
$$;

revoke all on function private.is_household_member(uuid, uuid) from public;
revoke all on function private.has_household_role(uuid, uuid, text[]) from public;
grant usage on schema private to authenticated;
grant execute on function private.is_household_member(uuid, uuid) to authenticated;
grant execute on function private.has_household_role(uuid, uuid, text[]) to authenticated;

alter table public.profiles enable row level security;
alter table public.households enable row level security;
alter table public.household_members enable row level security;

drop policy if exists profiles_select_self on public.profiles;
create policy profiles_select_self on public.profiles
for select to authenticated
using ((select auth.uid()) is not null and id = (select auth.uid()));

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles
for update to authenticated
using ((select auth.uid()) is not null and id = (select auth.uid()))
with check (id = (select auth.uid()));

drop policy if exists households_select_for_members on public.households;
create policy households_select_for_members on public.households
for select to authenticated
using (private.is_household_member(id, (select auth.uid())));

drop policy if exists households_update_for_owner on public.households;
create policy households_update_for_owner on public.households
for update to authenticated
using (private.has_household_role(id, (select auth.uid()), array['owner']))
with check (private.has_household_role(id, (select auth.uid()), array['owner']));

drop policy if exists households_delete_for_owner on public.households;
create policy households_delete_for_owner on public.households
for delete to authenticated
using (private.has_household_role(id, (select auth.uid()), array['owner']));

drop policy if exists household_members_select_for_members on public.household_members;
create policy household_members_select_for_members on public.household_members
for select to authenticated
using (private.is_household_member(household_id, (select auth.uid())));

drop policy if exists household_members_insert_for_managers on public.household_members;
create policy household_members_insert_for_managers on public.household_members
for insert to authenticated
with check (private.has_household_role(household_id, (select auth.uid()), array['owner']));

drop policy if exists household_members_update_for_managers on public.household_members;
create policy household_members_update_for_managers on public.household_members
for update to authenticated
using (
  not (user_id = (select auth.uid()) and role = 'owner')
  and private.has_household_role(household_id, (select auth.uid()), array['owner'])
)
with check (private.has_household_role(household_id, (select auth.uid()), array['owner']));

drop policy if exists household_members_delete_for_managers on public.household_members;
create policy household_members_delete_for_managers on public.household_members
for delete to authenticated
using (
  role <> 'owner'
  and private.has_household_role(household_id, (select auth.uid()), array['owner'])
);

grant select, update(display_name) on public.profiles to authenticated;
grant select, update(name), delete on public.households to authenticated;
grant select, insert, update, delete on public.household_members to authenticated;

commit;

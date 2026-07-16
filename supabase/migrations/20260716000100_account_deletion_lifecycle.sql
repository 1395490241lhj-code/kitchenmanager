-- Phase 2D-2: account deletion + data lifecycle safety.
--
-- This migration only prepares the database side of account deletion:
-- (1) relaxes specific audit-column foreign keys from ON DELETE RESTRICT to
--     ON DELETE SET NULL so a profile can eventually be removed without a
--     stale row permanently blocking it, (2) adds an idempotent, auditable
--     account_deletion_requests ledger, and (3) adds privileged functions
--     for preview, business-data cleanup, ownership transfer, and the
--     backend-only finalize step. It does NOT delete any auth.users row —
--     Supabase Auth user deletion must go through the Admin API (session/
--     identity/refresh-token cleanup is owned by GoTrue, not reachable via
--     plain SQL), which only the Express backend (holding the service-role
--     key) may call. See docs/ACCOUNT_DELETION_DESIGN.md for the full saga.
--
-- Anonymization strategy: rather than nulling audit columns to NULL (which
-- would still be "no creator" but distinguishable across many resulting
-- NULLs), every deleted actor's remaining historical attribution is
-- rewritten to ONE well-known, shared placeholder UUID
-- (00000000-0000-0000-0000-000000000000) rather than a per-deletion-unique
-- value. A shared constant cannot be used to correlate which specific
-- deleted user performed a given historical action; a unique-per-deletion
-- placeholder could. This column never resolves to a real profile row (no
-- such profile is ever created), so it's inert data, not a live identity.

begin;

-- ── 1. Relax audit-column FKs from RESTRICT to SET NULL ────────────────────
-- Default Postgres FK constraint names for an inline, unnamed
-- `column references table` clause are `{table}_{column}_fkey` — verified
-- against this project's actual schema (not assumed) before use here.

alter table public.households
  drop constraint if exists households_created_by_fkey,
  alter column created_by drop not null,
  add constraint households_created_by_fkey
    foreign key (created_by) references public.profiles(id) on delete set null;

alter table public.sync_changes
  drop constraint if exists sync_changes_changed_by_fkey,
  alter column changed_by drop not null,
  add constraint sync_changes_changed_by_fkey
    foreign key (changed_by) references public.profiles(id) on delete set null;

do $$
declare
  business_table text;
begin
  foreach business_table in array array[
    'inventory_items', 'shopping_items', 'today_plan_items', 'consumption_records',
    'weekly_meal_plans', 'weekly_meal_plan_items', 'user_recipes',
    'recipe_favorites', 'frequent_recipes'
  ]
  loop
    execute format(
      'alter table public.%I
         drop constraint if exists %I,
         alter column created_by drop not null,
         add constraint %I foreign key (created_by) references public.profiles(id) on delete set null',
      business_table, business_table || '_created_by_fkey', business_table || '_created_by_fkey'
    );
    execute format(
      'alter table public.%I
         drop constraint if exists %I,
         alter column updated_by drop not null,
         add constraint %I foreign key (updated_by) references public.profiles(id) on delete set null',
      business_table, business_table || '_updated_by_fkey', business_table || '_updated_by_fkey'
    );
  end loop;
end;
$$;

-- ── 2. Account deletion request ledger ──────────────────────────────────────

create table if not exists public.account_deletion_requests (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  status text not null default 'requested'
    check (status in ('requested', 'business_data_cleaned', 'auth_deletion_pending', 'completed', 'failed')),
  idempotency_key uuid not null,
  preview_fingerprint text not null check (char_length(preview_fingerprint) between 1 and 128),
  requested_at timestamptz not null default clock_timestamp(),
  business_data_cleaned_at timestamptz,
  auth_user_deleted_at timestamptz,
  completed_at timestamptz,
  failure_code text,
  retry_count integer not null default 0 check (retry_count >= 0),
  local_cleanup_required boolean not null default true,
  anonymized_actor_id uuid,
  updated_at timestamptz not null default clock_timestamp()
);

drop trigger if exists account_deletion_requests_set_updated_at on public.account_deletion_requests;
create trigger account_deletion_requests_set_updated_at
before update on public.account_deletion_requests
for each row execute function private.set_updated_at();

alter table public.account_deletion_requests enable row level security;

-- Users may only ever read their own request; no direct insert/update/delete
-- grant exists for authenticated — every write goes through the privileged
-- functions below, which run as the table owner and bypass RLS by design,
-- exactly like every other write path in this schema (apply_sync_mutation).
drop policy if exists account_deletion_requests_select_self on public.account_deletion_requests;
create policy account_deletion_requests_select_self on public.account_deletion_requests
for select to authenticated
using (user_id = (select auth.uid()));

revoke all on public.account_deletion_requests from public, anon, authenticated;
grant select on public.account_deletion_requests to authenticated;

-- ── 3. Preview ───────────────────────────────────────────────────────────

-- Coarse, non-identifying summary only: no household id/name, no email, no
-- raw row is ever returned. confirmationVersion is the fingerprint the
-- client must echo back to request_account_deletion; it changes whenever
-- the live blocking state changes, so a stale client-side preview is
-- rejected rather than acted on blindly.
create or replace function private.account_deletion_preview(actor uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  household_count integer;
  owned_count integer;
  owned_with_others_count integer;
  owned_alone_count integer;
  mutation_count bigint;
  mutation_bucket text;
  fingerprint text;
  can_delete boolean;
  blocking_reason text;
begin
  select count(*) into household_count
  from public.household_members where user_id = actor;

  select count(*) into owned_count
  from public.household_members where user_id = actor and role = 'owner';

  select count(*) into owned_with_others_count
  from public.household_members hm
  where hm.user_id = actor and hm.role = 'owner'
    and exists (
      select 1 from public.household_members other
      where other.household_id = hm.household_id and other.user_id <> actor
    );

  owned_alone_count := owned_count - owned_with_others_count;

  select count(*) into mutation_count
  from public.sync_mutations where user_id = actor;

  mutation_bucket := case
    when mutation_count = 0 then '0'
    when mutation_count <= 10 then '1-10'
    when mutation_count <= 100 then '11-100'
    else '100+'
  end;

  blocking_reason := case when owned_with_others_count > 0 then 'OWNERSHIP_TRANSFER_REQUIRED' else null end;
  can_delete := owned_with_others_count = 0;

  -- The fingerprint covers exactly the fields that would make a previously
  -- issued preview stale if they changed (blocking state + mutation bucket),
  -- not the whole payload — a purely informational field changing alone
  -- should not force a client to re-fetch before it can act.
  fingerprint := encode(sha256(convert_to(
    actor::text || ':' || owned_with_others_count::text || ':' || owned_alone_count::text || ':' || mutation_bucket,
    'utf8'
  )), 'hex');

  return jsonb_build_object(
    'canDelete', can_delete,
    'blockingReason', blocking_reason,
    'householdCount', household_count,
    'ownedHouseholdCount', owned_count,
    'requiresOwnershipTransfer', owned_with_others_count > 0,
    'requiresHouseholdDeletion', owned_alone_count > 0,
    'pendingMutationCountBucket', mutation_bucket,
    'confirmationVersion', fingerprint
  );
end;
$$;

revoke all on function private.account_deletion_preview(uuid) from public;

create or replace function public.get_account_deletion_preview()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  actor uuid := auth.uid();
begin
  if actor is null then raise exception 'authenticated user required' using errcode = '42501'; end if;
  return private.account_deletion_preview(actor);
end;
$$;

revoke all on function public.get_account_deletion_preview() from public, anon;
grant execute on function public.get_account_deletion_preview() to authenticated;

-- ── 4. Ownership transfer (used to resolve a preview blocker) ────────────

-- Only the household's current owner may call this; the new owner must
-- already be a member (never a pending invitation, never an arbitrary
-- user id) — this directly satisfies "non-member cannot receive
-- ownership" and "User A cannot transfer User B's household" by construction
-- (there is no household_id parameter path that skips the has_household_role
-- check, and the target must already have a household_members row).
create or replace function public.transfer_household_ownership(p_household_id uuid, p_new_owner_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  actor uuid := auth.uid();
begin
  if actor is null then raise exception 'authenticated user required' using errcode = '42501'; end if;
  if p_household_id is null or p_new_owner_user_id is null then
    raise exception 'household and new owner are required' using errcode = '22023';
  end if;
  if not private.has_household_role(p_household_id, actor, array['owner']) then
    raise exception 'only the current owner may transfer ownership' using errcode = '42501';
  end if;
  if p_new_owner_user_id = actor then
    raise exception 'new owner must be a different member' using errcode = '22023';
  end if;
  if not private.is_household_member(p_household_id, p_new_owner_user_id) then
    raise exception 'new owner must already be a household member' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_household_id::text, 1));

  update public.household_members
    set role = 'owner'
    where household_id = p_household_id and user_id = p_new_owner_user_id;

  update public.household_members
    set role = 'admin'
    where household_id = p_household_id and user_id = actor;

  return jsonb_build_object('householdId', p_household_id, 'newOwnerUserId', p_new_owner_user_id, 'status', 'transferred');
end;
$$;

revoke all on function public.transfer_household_ownership(uuid, uuid) from public, anon;
grant execute on function public.transfer_household_ownership(uuid, uuid) to authenticated;

-- Lists candidate members (excluding the caller) so an owner can choose a
-- new owner without the client needing its own profiles-join (profiles RLS
-- restricts a normal client read to the caller's own row only).
create or replace function public.list_household_members_for_transfer(p_household_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  actor uuid := auth.uid();
  members jsonb;
begin
  if actor is null then raise exception 'authenticated user required' using errcode = '42501'; end if;
  if not private.has_household_role(p_household_id, actor, array['owner']) then
    raise exception 'only the current owner may list transfer candidates' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'userId', hm.user_id,
    'role', hm.role,
    'displayName', coalesce(p.display_name, '')
  ) order by hm.created_at), '[]'::jsonb)
  into members
  from public.household_members hm
  join public.profiles p on p.id = hm.user_id
  where hm.household_id = p_household_id and hm.user_id <> actor;

  return members;
end;
$$;

revoke all on function public.list_household_members_for_transfer(uuid) from public, anon;
grant execute on function public.list_household_members_for_transfer(uuid) to authenticated;

-- ── 5. Business-data cleanup step (saga step 1) ─────────────────────────

-- Well-known, shared, non-resolvable placeholder — never a real profile id.
-- See the file-header comment for why a shared constant is used instead of
-- a per-deletion-unique value.
create or replace function public.request_account_deletion(p_idempotency_key uuid, p_preview_fingerprint text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  actor uuid := auth.uid();
  anon_id constant uuid := '00000000-0000-0000-0000-000000000000';
  fresh_preview jsonb;
  existing public.account_deletion_requests%rowtype;
  business_table text;
begin
  if actor is null then raise exception 'authenticated user required' using errcode = '42501'; end if;
  if p_idempotency_key is null or p_preview_fingerprint is null or btrim(p_preview_fingerprint) = '' then
    raise exception 'idempotency key and preview fingerprint are required' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(actor::text, 2));

  select * into existing from public.account_deletion_requests where user_id = actor;

  if found then
    if existing.status = 'completed' then
      return jsonb_build_object('status', 'completed', 'errorCode', null);
    end if;
    if existing.status in ('business_data_cleaned', 'auth_deletion_pending') then
      if existing.idempotency_key = p_idempotency_key then
        return jsonb_build_object('status', existing.status, 'errorCode', null);
      end if;
      return jsonb_build_object('status', 'rejected', 'errorCode', 'ACCOUNT_DELETION_IN_PROGRESS');
    end if;
    -- status = 'requested' (crashed before finishing) or 'failed': safe to
    -- restart, but only with a fresh, non-stale preview.
  end if;

  fresh_preview := private.account_deletion_preview(actor);
  if (fresh_preview ->> 'confirmationVersion') <> p_preview_fingerprint then
    return jsonb_build_object('status', 'rejected', 'errorCode', 'STALE_DELETION_PREVIEW');
  end if;
  if not (fresh_preview ->> 'canDelete')::boolean then
    return jsonb_build_object(
      'status', 'rejected',
      'errorCode', case
        when (fresh_preview ->> 'requiresOwnershipTransfer')::boolean then 'OWNERSHIP_TRANSFER_REQUIRED'
        else 'HOUSEHOLD_ACTION_REQUIRED'
      end
    );
  end if;

  insert into public.account_deletion_requests (user_id, status, idempotency_key, preview_fingerprint, anonymized_actor_id)
  values (actor, 'requested', p_idempotency_key, p_preview_fingerprint, anon_id)
  on conflict (user_id) do update
    set status = 'requested',
        idempotency_key = excluded.idempotency_key,
        preview_fingerprint = excluded.preview_fingerprint,
        anonymized_actor_id = excluded.anonymized_actor_id,
        failure_code = null,
        retry_count = public.account_deletion_requests.retry_count + 1;

  -- Households the actor owns alone (no other members) are deleted outright;
  -- FK cascade on household_id removes every business row scoped to them.
  delete from public.households h
  where h.id in (
    select hm.household_id from public.household_members hm
    where hm.user_id = actor and hm.role = 'owner'
      and not exists (
        select 1 from public.household_members other
        where other.household_id = hm.household_id and other.user_id <> actor
      )
  );

  -- Any remaining membership (never an unresolved owner-with-others row —
  -- that would already have failed the preview check above) is just a
  -- membership departure: delete the row, leave the household intact.
  delete from public.household_members where user_id = actor;

  -- Personal-scope rows belong exclusively to this user; no one else will
  -- ever read them again, so they are deleted outright rather than
  -- anonymized.
  delete from public.recipe_favorites where user_id = actor;
  delete from public.frequent_recipes where user_id = actor;
  delete from public.sync_changes where user_id = actor;

  -- Anonymize remaining historical attribution the actor left behind in
  -- households/business tables that still exist (because another member
  -- owns or shares them). These columns are real foreign keys: only NULL
  -- or an existing profiles row satisfies the constraint, so the live
  -- columns are set to NULL (never the placeholder UUID below, which
  -- deliberately does not correspond to any real profile row). The
  -- placeholder is used only inside record_data JSONB (not FK-constrained)
  -- so a historical snapshot still shows a well-formed, non-identifying
  -- UUID string rather than an absent field.
  update public.households set created_by = null where created_by = actor;

  -- inventory_items/shopping_items/... each carry a `_prepare_sync` (BEFORE
  -- INSERT/UPDATE) and `_write_change` (AFTER INSERT/UPDATE) trigger meant
  -- for ordinary user-driven mutations: `_prepare_sync` re-checks the
  -- CALLING role's own household membership via auth.uid() (which this
  -- actor may no longer have, since membership rows were already removed
  -- above) and would overwrite updated_by back to actor/bump version;
  -- `_write_change` would additionally record a brand-new sync_changes
  -- entry attributing this administrative anonymization back to the very
  -- actor being anonymized. Both must be suspended for this specific,
  -- privileged, non-user-driven update. This function's owner also owns
  -- these tables (both created by the same migration-running role), so
  -- disabling/re-enabling is permitted without requiring superuser-only
  -- session_replication_role. Re-enabled before returning, and — since
  -- ALTER TABLE ... TRIGGER is itself transactional — a rollback from any
  -- later error in this function restores the triggers automatically too.
  foreach business_table in array array[
    'inventory_items', 'shopping_items', 'today_plan_items', 'consumption_records',
    'weekly_meal_plans', 'weekly_meal_plan_items', 'user_recipes'
  ]
  loop
    execute format('alter table public.%I disable trigger %I', business_table, business_table || '_prepare_sync');
    execute format('alter table public.%I disable trigger %I', business_table, business_table || '_write_change');
  end loop;

  foreach business_table in array array[
    'inventory_items', 'shopping_items', 'today_plan_items', 'consumption_records',
    'weekly_meal_plans', 'weekly_meal_plan_items', 'user_recipes'
  ]
  loop
    execute format('update public.%I set created_by = null where created_by = $1', business_table) using actor;
    execute format('update public.%I set updated_by = null where updated_by = $1', business_table) using actor;
  end loop;

  foreach business_table in array array[
    'inventory_items', 'shopping_items', 'today_plan_items', 'consumption_records',
    'weekly_meal_plans', 'weekly_meal_plan_items', 'user_recipes'
  ]
  loop
    execute format('alter table public.%I enable trigger %I', business_table, business_table || '_prepare_sync');
    execute format('alter table public.%I enable trigger %I', business_table, business_table || '_write_change');
  end loop;

  update public.sync_changes set changed_by = null where changed_by = actor;

  -- record_data is a point-in-time JSONB snapshot, not a live reference —
  -- rewriting the live columns above does not touch already-recorded
  -- history. Rewrite the two known attribution keys in place, preserving
  -- the JSON shape (still a well-formed UUID string) rather than deleting
  -- the keys outright.
  update public.sync_changes
  set record_data = jsonb_set(record_data, '{created_by}', to_jsonb(anon_id::text))
  where record_data ->> 'created_by' = actor::text;

  update public.sync_changes
  set record_data = jsonb_set(record_data, '{updated_by}', to_jsonb(anon_id::text))
  where record_data ->> 'updated_by' = actor::text;

  delete from public.sync_mutations where user_id = actor;

  update public.account_deletion_requests
    set status = 'business_data_cleaned', business_data_cleaned_at = clock_timestamp()
    where user_id = actor;

  return jsonb_build_object('status', 'business_data_cleaned', 'errorCode', null);
end;
$$;

revoke all on function public.request_account_deletion(uuid, text) from public, anon;
grant execute on function public.request_account_deletion(uuid, text) to authenticated;

-- ── 6. Backend-only finalize step (saga step 2 result) ──────────────────

-- Callable only by the backend's own service-role credential — never by an
-- ordinary authenticated user for an arbitrary target, since it takes
-- p_user_id directly rather than deriving it from auth.uid().
create or replace function public.mark_account_deletion_finalized(
  p_user_id uuid,
  p_idempotency_key uuid,
  p_auth_deleted boolean,
  p_failure_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  existing public.account_deletion_requests%rowtype;
begin
  if p_user_id is null or p_idempotency_key is null then
    raise exception 'user id and idempotency key are required' using errcode = '22023';
  end if;

  select * into existing from public.account_deletion_requests where user_id = p_user_id;
  if not found or existing.idempotency_key <> p_idempotency_key then
    raise exception 'no matching deletion request' using errcode = 'P0002';
  end if;

  if p_auth_deleted then
    update public.account_deletion_requests
      set status = 'completed',
          auth_user_deleted_at = clock_timestamp(),
          completed_at = clock_timestamp(),
          failure_code = null
      where user_id = p_user_id;
    return jsonb_build_object('status', 'completed');
  else
    update public.account_deletion_requests
      set status = 'auth_deletion_pending',
          failure_code = p_failure_code,
          retry_count = retry_count + 1
      where user_id = p_user_id;
    return jsonb_build_object('status', 'auth_deletion_pending');
  end if;
end;
$$;

revoke all on function public.mark_account_deletion_finalized(uuid, uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.mark_account_deletion_finalized(uuid, uuid, boolean, text) to service_role;

commit;

# Database Migration Parity (Phase 2C-3)

Status: **migrations validated against the development project (read-only);
not applied to any production project (none exists); local pgTAP execution
remains BLOCKED (no Docker/local Postgres available in this environment).**

## 1. Migration inventory (redacted — no project ref/URL/key below)

| File | Order | Purpose | Applied to dev? | Idempotent? | Rollback | Data migration? | Destructive DDL? | RLS? | Indexes? | RPC/functions? | Triggers? | Change feed? | Mutation ledger? | Tombstone/rollback metadata? | Extensions? | Order-dependent? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `20260713000100_auth_household_foundation.sql` | 1 | Auth trigger, profiles/households/household_members, membership RLS helpers | Yes (confirmed this phase) | Yes — `create table if not exists`, `on conflict` upserts, `drop trigger if exists` before create | Forward-only (no down-migration; a fix would be a new migration) | No | No | Yes | Yes | Yes (`handle_new_auth_user`, `is_household_member`, `has_household_role`) | Yes (`set_updated_at`, auth-init trigger) | No | No | No | No | No — depends only on `auth.users` existing (Supabase-managed) |
| `20260713000200_sync_business_foundation.sql` | 2 | Business tables, unified change feed, mutation ledger, sync RPCs, RLS | Yes (confirmed this phase) | Yes — same `if not exists`/`or replace`/`drop ... if exists` conventions | Forward-only | No | No | Yes | Yes (household/personal cursor indexes, uniqueness indexes) | Yes (`apply_sync_mutation`, `pull_sync_changes`, `get_sync_bootstrap`, snapshot/prepare/write-change helpers) | Yes (per-table prepare/write-change triggers, 9+9) | Yes (`sync_changes`) | Yes (`sync_mutations`) | Yes (`deleted_at` tombstone column on every mutable table; rollback in this app is implemented as another delete mutation through the same RPC, not separate metadata) | No | Yes — depends on migration 1's `profiles`/`households`/`household_members` and helper functions |

Both files use `begin;`/`commit;` as a single transaction each — a failure
partway through either migration rolls back cleanly, never leaving a
half-applied schema.

## 2. Migration history integrity (checked this phase)

1. **File order stable**: both filenames sort identically by timestamp
   prefix and by filesystem listing — confirmed via the new
   `src/server/utils/migration-manifest.js` (`loadMigrationManifest`),
   covered by `test/phase2c3-migration-manifest.test.mjs`.
2. **No duplicate numbering**: confirmed by the same module (an empty
   `errors` array for the real repository directory).
3. **No local-migration-not-applied**: `npx supabase migration list`
   (read-only, does not require Docker) reports both `20260713000100` and
   `20260713000200` present on **both** local and remote, with matching
   timestamps.
4. **No remote-migration-missing-locally**: same command — the remote list
   contains exactly the two local files, nothing extra.
5. **No modified-history migration**: both files' content matches what has
   shipped since Phase 2A (verified by reading the tracked files directly;
   no separate checksum store exists in this repository beyond
   `supabase migration list`'s own local/remote timestamp comparison, which
   matched exactly).
6. **No applied-timestamp drift**: `supabase migration list`'s local and
   remote timestamps for both migrations are identical. This is a
   version/timestamp-history comparison only — no content-level schema
   checksum/diff was computed (that would require `supabase db diff`,
   which is blocked; see §3).
7. **No temporary SQL files**: `supabase/.temp/` is gitignored and contains
   only Supabase CLI's own local link-state files (project ref, pooler URL,
   CLI/Postgres/GoTrue version markers) — no ad hoc SQL dumps.
8. **No undocumented production-only manual SQL**: there is no production
   project, so this is vacuously true today; it becomes a real ongoing
   requirement once one exists (every schema change must be a tracked
   migration file, never a one-off dashboard SQL edit).
9. **Schema version tracking**: `schemaVersion` is exposed to the iOS client
   via the sync bootstrap response contract (`docs/SYNC_API_CONTRACT.md`);
   migration-level versioning is the filename timestamp itself, tracked by
   Supabase's own `supabase_migrations.schema_migrations` table (not
   queried directly by this repository's tooling, but is what
   `migration list` reads).
10. **Dev project matches repository migration history**: confirmed by
    item 3 above — exact match, zero drift.

## 3. Local replay / shadow-database validation

**BLOCKED** — this environment has no Docker daemon and no local Postgres.
Attempted this phase and captured the real failure, rather than assuming or
faking a result:

```
$ npx supabase test db
Connecting to local database...
{"_tag":"Error","error":{"code":"LegacyDbConnectError","message":"failed to
connect to postgres: effect/sql/SqlError: PgClient: Failed to connect"}}

$ npx supabase db diff --linked
Creating shadow database...
failed to inspect docker image: Cannot connect to the Docker daemon at
unix:///var/run/docker.sock. Is the docker daemon running?
```

This is a carried-forward gap, not new to this phase — see
`docs/AUTH_SYNC_PHASE0_5_VALIDATION.md` and
`docs/INVENTORY_SYNC_PRODUCTION_CONFIG_AUDIT.md`, both of which documented
the identical Docker-unavailable blocker in earlier phases. It remains
unresolved. The following, which do **not** require Docker, were run
instead and are real, executed evidence:

- `npx supabase migration list` (see §2 item 3) — read-only, remote API
  only.
- `npx supabase db query --linked --file supabase/tests/auth_household_remote_verify.sql`
  and the equivalent `sync_business_remote_verify.sql` — read-only SQL
  assertions executed directly against the real dev database (see
  `docs/RLS_SECURITY_VERIFICATION.md` for results).
- `scripts/auth-smoke.mjs` / `scripts/sync-smoke.mjs` — real behavioral
  integration tests against the dev project over HTTP (results in
  `docs/PHASE2C3_VALIDATION.md`).

**Not performed and not claimed**: a local `supabase db reset`, a fresh
from-empty migration replay, a migration-replayed-twice idempotency check,
or a `supabase db diff` schema comparison. All four require the same local
Postgres/Docker this environment lacks. Closing this gap requires either a
machine with Docker available or a CI runner configured for it — tracked as
an open item, not silently skipped.

## 4. Remote dev parity (read-only, executed this phase)

Both `supabase/tests/auth_household_remote_verify.sql` and
`supabase/tests/sync_business_remote_verify.sql` were executed against the
real development project via `supabase db query --linked` and returned
their success markers with no exception raised:

- `phase0_remote_objects_verified` — 2 personal households, 9 policies, 3
  triggers (matching the auth/household schema's expected shape exactly;
  household/profile counts reflect the two pre-existing seeded test
  accounts, not new data created this phase).
- `phase2a_remote_objects_verified` — 11 policies, 18 triggers (9 prepare +
  9 write-change), 3 RPCs (`apply_sync_mutation`, `pull_sync_changes`,
  `get_sync_bootstrap`) — matching the sync/business schema's expected
  shape exactly.

These SQL scripts assert (and would raise an exception, failing the
command, if not true): required tables exist, RLS is enabled on all of
them, the exact expected trigger/policy counts, the exact-one-scope
constraint on `sync_changes`, and the mutation-ledger idempotency primary
key shape. No row content, project ref, URL, or key was ever printed by
these queries — only counts and a fixed result label.

## 5. What this phase explicitly does NOT claim

- Migrations are **not** applied to any production project — none exists.
- Local pgTAP execution is **not** done — remains BLOCKED (Docker
  unavailable), not silently skipped or faked as passing.
- A local migration-replay-from-empty or replay-twice idempotency check was
  **not** performed, for the same Docker-unavailable reason.
- This document does not claim "production database configured" or
  "production migrations applied" under any circumstance.

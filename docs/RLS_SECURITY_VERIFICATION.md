# RLS Security Verification (Phase 2C-3)

Status: **RLS behaviorally validated against the development project via
authenticated application-layer smoke tests; a new local pgTAP behavioral
test file exists but is unexecuted (Docker unavailable — see
`docs/DATABASE_MIGRATION_PARITY.md`); RLS has not been validated against any
production project (none exists).**

## 1. Why this document separates roles carefully

A security conclusion is only meaningful if it describes what an ordinary
**authenticated app user** or an **anonymous** caller can actually do — not
what the database owner or a service-role key can do (both bypass RLS by
design and prove nothing about app-level safety). Every claim in this
document is qualified by which role it was checked as; **no service-role
key was used to assert or imply any security conclusion this phase.**

## 2. What each role can see, as implemented

- **Database owner / migration runner**: full access — this is expected and
  is how the migrations themselves are applied; it says nothing about app
  security.
- **`service_role` (Supabase's elevated API key)**: bypasses RLS entirely
  by Supabase's own design. This project's Express backend **never**
  forwards `service_role` into any app request path — `/api/me` and every
  `/api/sync/*` route forward the verified *user's own* JWT to PostgREST/RPC
  calls, so RLS always applies (unchanged from earlier phases; re-confirmed
  by reading `src/server/sync/routes.js` and `src/server/auth/jwt.js` this
  phase — no service-role usage found anywhere in the request path).
- **`authenticated` (a real signed-in user, scoped by their own JWT)**: can
  read their own profile, the households they are a member of, and — for
  business tables — only rows in a household they belong to (or, for
  personal-scope tables, only their own rows). Can never `INSERT`/`UPDATE`/
  `DELETE` a business table directly (those grants are revoked); all writes
  go through `apply_sync_mutation`, which re-checks membership/ownership
  itself before touching any row.
- **`anon` (no JWT at all)**: has **no** grant on any business table and
  **no** `EXECUTE` privilege on `apply_sync_mutation`, `pull_sync_changes`,
  or `get_sync_bootstrap` — confirmed both by reading the migration's
  explicit `revoke all ... from public, anon` statements and by the
  existing `sync_business_objects_test.sql` pgTAP assertions
  (`has_function_privilege('anon', ..., 'EXECUTE')` is false for all three).

**Every security conclusion below is about the `authenticated` and `anon`
rows above — never about what the owner or service-role can do.**

## 3. User A / User B isolation — verified this phase

Executed against the real development project via
`scripts/sync-smoke.mjs` (real HTTP requests, real JWTs for the two seeded
`TEST_USER_A`/`TEST_USER_B` accounts, never a service-role key):

- **PASS** — user A cannot read household B's inventory (`pull_sync_changes`
  on B's scope is rejected).
- **PASS** — user A cannot write into household B's scope
  (`apply_sync_mutation` on B's scope is rejected before any row is
  touched).
- **PASS** — direct-DML denial: `authenticated` cannot `INSERT`/`UPDATE`/
  `DELETE` any business table directly, only through the RPC.
- **PASS** — create/update/conflict/delete/idempotency/change-feed/pagination
  round trip, exercised end to end through the real Express + Supabase
  stack.

See `docs/PHASE2C3_VALIDATION.md` for the exact command and its (redacted)
output.

Additional isolation properties confirmed by reading the schema/RPC source
this phase (not independently re-executed, since they are enforced by the
same `is_household_member`/`auth.uid()` checks already exercised above):

- A user cannot forge a `household_id` to gain access — every RLS policy
  and the RPC's own internal check calls `private.is_household_member`,
  which is `security definer` and reads `auth.uid()` from the verified JWT,
  never from client-supplied input.
- A membership row's removal takes effect immediately on the next request —
  there is no cached membership state anywhere server-side; every check is
  a live query.
- Change feed and mutation ledger rows are filtered by the same
  `is_household_member`/`user_id = auth.uid()` predicates as the business
  tables — a user cannot see another household's changes or another user's
  mutation history.
- Rollback in this app is implemented as an ordinary delete mutation through
  `apply_sync_mutation` (see `GuestMergeController.rollback`) — it carries
  no separate metadata/table of its own, so it inherits exactly the same
  scope/ownership checks as every other mutation, with no separate code
  path that could diverge from them.

**Not independently re-verified this phase** (would require a revoked or
expired real session, which risks disrupting the shared dev test accounts):
stale/revoked-JWT behavior beyond what the existing JWT-verification test
suite already covers offline (`src/server/auth/jwt.js`'s own extensive
signature/issuer/audience/algorithm tests), and a live household-switch
mid-session scenario.

## 4. New pgTAP behavioral test (written, execution BLOCKED)

`supabase/tests/sync_business_rls_test.sql` (new this phase, 27 assertions)
adds direct-SQL, Docker-local coverage of the same invariants as defense in
depth — independent of the Express layer, using local role-switching
(`set local role authenticated` + `request.jwt.claim.sub`, the same pattern
as the pre-existing `auth_household_rls_test.sql`). It covers: table
existence, a valid create applying once, duplicate-mutationId idempotency,
stale-baseVersion conflict, invalid-operation rejection, cross-household
write/read rejection, tombstone-on-delete, change-feed recording, cursor
monotonicity, idempotent delete retry, exact ledger-row counting, unsupported-
entity-type rejection, personal-scope isolation, reverse-direction (B
cannot see A) isolation, anon privilege absence (function and table level),
`search_path` safety, no-secret-shaped ledger payload content, a
rollback-shaped delete applying through the same RPC, and membership
removal.

**This file has not been executed** — `npx supabase test db` requires a
local Postgres via Docker, unavailable in this environment (see
`docs/DATABASE_MIGRATION_PARITY.md` §3 for the captured error). Every
assertion was hand-traced against the actual migration SQL (not guessed),
but it has not been run, and this document does not claim it has passed.

## 5. Backup / restore readiness

See `docs/PRODUCTION_ENABLEMENT_READINESS.md` and the rollback runbook for
the broader operational picture; specific to RLS/data-recovery:

- Supabase's own PITR (point-in-time recovery) is a paid-plan feature not
  currently confirmed enabled on the (single, dev-tier) project used today.
- No schema-only or data export has been taken as part of this phase.
- Migration rollback in this codebase is forward-only by design (a fix is a
  new migration, never an automatic down-migration) — unchanged from
  `docs/PRODUCTION_ROLLBACK_RUNBOOK.md`.
- Tombstone/ledger recovery: both are additive-only (soft-delete, append-only
  ledger) — there is no "recovery" operation needed for them beyond what
  already exists, since nothing is ever physically deleted by normal
  application operation.
- Who can access backups: whoever has dashboard access to the Supabase
  project — today that is the same single dev project, so this is not yet a
  meaningfully separate concern from "who has dev project access."
- Production project deletion protection: not applicable — no production
  project exists to protect.

This phase **designs against** this list but performs no real backup/restore
operation and creates no production project.

## 6. What this phase explicitly does NOT claim

- RLS has **not** been validated against a production project — none
  exists.
- The new pgTAP file exists but has **not** been executed.
- No service-role query was used to draw any conclusion in this document.
- No destructive migration, reset, or repair was performed against any
  database.

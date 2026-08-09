# Local Supabase Validation (Phase 2C-4)

Status: **local migration replay executed and passing; local pgTAP executed
and passing; local schema diff clean. Development (remote) project
untouched beyond read-only re-checks. No production project exists; no
production migration was executed.**

This document records the first-ever successful local Docker-based
Supabase validation for this repository, closing the long-standing
"Docker unavailable" gap documented since Phase 0.5 (see
`docs/AUTH_SYNC_PHASE0_5_VALIDATION.md`,
`docs/INVENTORY_SYNC_PRODUCTION_CONFIG_AUDIT.md`, and Phase 2C-3's
`docs/DATABASE_MIGRATION_PARITY.md`).

## 1. Environment

- Docker runtime: **Colima** (Docker Engine 29.6.1 client / 29.5.2 server,
  context `colima`). Confirmed via `docker version`/`docker info` before
  any database operation.
- Supabase CLI: `2.109.1` (unchanged from earlier phases).
- Before starting: zero existing containers, volumes, or images on this
  machine — a genuinely clean slate, nothing to preserve or audit around.

## 2. A Colima-specific startup issue (fixed, not a schema defect)

The first `supabase start` attempt failed:

```
failed to start docker container "supabase_vector_kitchenmanager": Error
response from daemon: error while creating mount source path
'/Users/.../.colima/default/docker.sock': mkdir .../docker.sock:
operation not supported
```

This is a known Colima limitation: the Supabase CLI's `vector`/`logflare`
analytics/log-routing containers try to bind-mount the host Docker socket
in a way Colima's VM filesystem doesn't support. It has nothing to do with
migrations, RLS, or any product code. Fixed by adding `[analytics]
enabled = false` to `supabase/config.toml` — analytics/log-routing has no
bearing on migration replay, pgTAP, or RLS validation, and disabling it is
a local-development-only CLI setting (not a remote/production config
change). After this, `supabase start` succeeded cleanly.

## 3. Local Supabase startup

`npx supabase start` succeeded. All 10 core service containers (`db`,
`kong`, `auth` (gotrue), `rest` (postgrest), `realtime`, `storage`,
`pg_meta`, `studio`, `edge_runtime`, `inbucket`/mailpit) came up healthy,
all named `*_kitchenmanager` (confirmed via `docker ps` — no other
project's containers exist on this machine to conflict with). Pooler,
imgproxy, analytics, and vector were intentionally stopped (pooler/imgproxy
are unused by this repo's local validation needs; analytics/vector
disabled per §2). All ports are local-machine-only (127.0.0.1 bindings for
54321–54324); nothing here is reachable remotely. The CLI's own printed
local credentials (`ANON_KEY`, `SERVICE_ROLE_KEY`, `JWT_SECRET`, etc.) are
Supabase's own well-known, identical-on-every-local-install demo defaults
— not reproduced in this document, and not usable against anything but this
throwaway local instance.

**Target: LOCAL SUPABASE ONLY. Remote linked project: NOT TOUCHED** — every
write operation this phase (`supabase start`, `supabase db reset`,
`supabase test db`, `supabase db lint`, `supabase db diff`) ran with no
`--linked` flag, against the local instance exclusively. The only commands
that touched the linked remote project were read-only
(`supabase migration list`, `supabase db query --linked --file
supabase/remote-verify/*.sql`) — see §7.

## 4. Two independent full rounds

Per this phase's requirement, migration replay + pgTAP + lint + residue
check were run twice from an independent fresh `supabase db reset` each
time (not by reusing round 1's already-populated database), to rule out
order-dependent or stateful flakiness.

| Check | Round 1 | Round 2 | Consistent? |
| --- | --- | --- | --- |
| `supabase db reset` (fresh migration replay) | PASS | PASS | Yes |
| `supabase test db` (pgTAP) | 96/96 pass | 96/96 pass | Yes, identical |
| `supabase db lint` | 1 finding (assessed false positive, §6) | Same finding | Yes, identical |
| Residue check (row counts post-pgTAP) | 0 rows in every checked table | 0 rows | Yes, identical |
| `supabase db diff` (local schema vs. migration-defined schema) | No schema changes found | Not re-run (unchanged since no file changed between rounds) | N/A |

No flakiness, no order-dependent behavior, no reliance on prior state —
each round started from a genuinely empty database.

## 5. Migration replay (both rounds)

Both `20260713000100_auth_household_foundation.sql` and
`20260713000200_sync_business_foundation.sql` applied cleanly from an empty
database, in the correct order, both times. The only console output beyond
"Applying migration ..." was a long series of `NOTICE ... does not exist,
skipping` lines — these are expected and harmless: every `DROP TRIGGER/POLICY
IF EXISTS` in the migrations naturally has nothing to drop on a truly fresh
database. No syntax error, no missing-extension error, no duplicate-object
error, no destructive behavior, no seed data resembling real user content
(`supabase/seed.sql` is a placeholder file, confirmed empty of real data).

## 6. pgTAP — real execution results, both rounds identical

`npx supabase test db` (no flag needed — always local):

```
/Users/.../supabase/tests/auth_household_objects_test.sql .. ok
/Users/.../supabase/tests/auth_household_rls_test.sql ...... ok
/Users/.../supabase/tests/sync_business_objects_test.sql ... ok
/Users/.../supabase/tests/sync_business_rls_test.sql ....... ok
All tests successful.
Files=4, Tests=96, ...
Result: PASS
```

**96/96 assertions passed, 0 failed, 0 skipped**, across all four discovered
test files (12 + 10 + 44 + 30). This is the first genuine local pgTAP
execution in this repository's history — every prior phase's mention of
pgTAP was either "written, not executed" or a remote read-only shape check,
never this.

### Two real bugs found and fixed to get here

Both were found only because pgTAP could finally actually run — neither was
(or could have been) caught by the remote read-only verify scripts, by
`sync-smoke.mjs`, or by static reading of the SQL.

1. **`auth_household_rls_test.sql` (pre-existing file, written in an
   earlier phase): a Postgres syntax defect.** `WITH changed AS (UPDATE ...
   RETURNING 1) SELECT count(*) FROM changed` was embedded as a subquery
   expression inside `is(...)`'s first argument — Postgres rejects this
   with "WITH clause containing a data-modifying statement must be at the
   top level" (a data-modifying WITH must be its own top-level statement,
   never nested). **Category: test-file SQL syntax defect, not a schema or
   RLS defect** — the RLS behavior itself (member cannot rename, owner can)
   was never in question; the assertion's own SQL was malformed. Fixed by
   running the `UPDATE` as its own statement inside a `DO $$ ... $$` block
   and capturing the affected-row count via `GET DIAGNOSTICS`, then
   asserting on that captured value — same semantic check, valid SQL.
2. **`sync_business_rls_test.sql` (new this cycle, Phase 2C-3): a field-
   naming defect in the test's own mutation payloads.** The test called
   `apply_sync_mutation` directly with camelCase JSON keys (`"normalizedName"`,
   `"recipeId"`) as if it were the client-facing API contract — but the RPC's
   own `column_names` allowlist (see the migration source) uses the literal
   database column names, which are snake_case (`normalized_name`,
   `recipe_id`). The camelCase-to-snake_case translation happens in the
   Express/repository layer (`docs/SYNC_API_CONTRACT.md` §1), never inside
   the RPC itself. **Category: test-fixture/expectation defect in a file
   written this cycle, not a schema or RPC defect** — `sync-smoke.mjs`
   already proved the real, full-stack path (client → Express → RPC) works
   correctly with real camelCase-to-snake_case translation; this pgTAP file
   was simply calling the RPC's own lower-level contract incorrectly. Fixed
   by using the correct snake_case keys. The same WITH-clause syntax defect
   as item 1 also appeared once in this file's own membership-revocation
   assertion (a fix I wrote this same phase) — fixed identically.

Neither fix touched any migration, RLS policy, RPC, trigger, or table
definition. **No new migration was needed or created.**

### A tooling/organization issue, not a test failure

`auth_household_remote_verify.sql` and `sync_business_remote_verify.sql`
are plain `DO $$ ... RAISE EXCEPTION ...$$` scripts meant for
`supabase db query --linked` (see §7) — they were never written in pgTAP's
`plan()`/`finish()` format. Living in `supabase/tests/`, they were
incorrectly auto-discovered and run by `supabase test db`, which reported
"No plan found in TAP output" for both (not a real test failure — a
discovery/categorization mismatch that was undetectable before this phase,
since `supabase test db` had never successfully run at all). Fixed by
moving both files to a new `supabase/remote-verify/` directory (outside
`supabase test db`'s scan path) and updating the two `package.json` scripts
(`verify:auth-db`/`verify:sync-db`) and one Node test
(`test/auth-phase0-5.test.mjs`) that reference their paths.

## 7. Read-only remote re-check (development project, untouched otherwise)

After local validation passed, three read-only checks were re-run against
the real development Supabase project — no write, no reset, no migration
apply:

- `npx supabase migration list` — local == remote for both migrations,
  zero drift (unchanged from Phase 2C-3).
- `npm run verify:auth-db` / `npm run verify:sync-db` (now pointing at the
  moved files) — both pass, identical shape counts to Phase 2C-3 (9
  policies/3 triggers auth; 11 policies/18 triggers/3 RPCs sync).

`auth-smoke.mjs`/`sync-smoke.mjs` were **not** re-run this phase — nothing
in the Express/sync request path changed (only local Supabase tooling and
pgTAP test files were touched), and the read-only checks above already
reconfirm parity without the overhead/risk of another real-write smoke run.

## 8. `db lint` finding — assessed as a false positive, not a defect

```
{"function":"public.apply_sync_mutation","issues":[{"level":"error",
"message":"column t.household_id does not exist", ...,
"query":{"text":"select to_jsonb(t) from public.frequent_recipes t
where t.id = $1 and t.household_id = $2"}}]}
```

`supabase db lint`'s static analyzer flags that `apply_sync_mutation`'s
`EXECUTE format('... t.household_id = $2', table_name)` template, if
`table_name` were `frequent_recipes` (a personal/user-scoped table with no
`household_id` column), would be invalid SQL. This is a real observation
about that one template string in isolation — but the linter's static
analysis does not track that `table_name` and `scope_kind` are always set
together from the same `CASE p_entity_type ... END CASE` (see the
migration source): `table_name := 'frequent_recipes'` is **only ever**
paired with `scope_kind := 'user'`, and the function's own `if scope_kind =
'household' then ... else ...` branch guarantees the `household_id`-based
template is **never** reached when `table_name = 'frequent_recipes'`. This
correlation is invisible to a linter that only pattern-matches individual
`EXECUTE format(...)` call sites against all values a variable can take,
not the runtime control-flow correlating two variables.

This is assessed as a **linter false positive, not a runtime defect**,
based on: (1) the function's own source, traced by hand; (2) 96/96 pgTAP
assertions passing, including this phase's new direct behavioral coverage
of `recipe_favorite` (the sibling personal-scope entity) via
`apply_sync_mutation`; (3) `sync-smoke.mjs`'s pre-existing
"representative entity families" check, which has exercised
`frequent_recipe`/`recipe_favorite` mutations successfully against the real
development project since Phase 2A. No migration or code change was made
in response to this finding — introducing one to satisfy a linter
limitation, when real behavioral evidence already proves correctness, was
judged unnecessary complexity. This finding is recorded here for future
reference in case `supabase db lint`'s analysis improves or this
assessment needs revisiting.

## 9. Residue

After both pgTAP rounds, a direct row-count query against `auth.users`,
`public.households`, `public.household_members`, `public.inventory_items`,
and `public.sync_mutations` returned **zero rows in every table**, both
rounds. Every pgTAP file wraps its assertions in `BEGIN; ... ROLLBACK;` —
this confirms that guarantee holds in practice, not just by inspection of
the SQL.

## 10. What this phase explicitly does NOT claim

- Production database is **not** ready, configured, or validated — no
  production project exists.
- Production migrations were **not** applied anywhere.
- The development (remote) project's schema was **not** modified — every
  touch was either local-only or explicitly read-only against the remote.
- This local validation supersedes the "Docker unavailable" caveat in
  `docs/DATABASE_MIGRATION_PARITY.md` and `docs/RLS_SECURITY_VERIFICATION.md`
  for **local** execution specifically; it does not change anything about
  the production-readiness conditions unrelated to this gap (production
  project provisioning, crash/alert provider, TestFlight pipeline, shared
  rate-limit store).

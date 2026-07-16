# Phase 2C-4 Validation — Local Supabase Migration Replay + pgTAP Execution

Status: **local migration replay executed (2 rounds, both PASS); local
pgTAP executed (2 rounds, both 96/96 PASS); local schema diff clean.
Development project touched read-only only. No production project exists;
no production migration executed; production not enabled.**

See `docs/LOCAL_SUPABASE_VALIDATION.md` for full detail — this document is
the phase-level summary.

## 1. Git gate

At start: `HEAD == origin/main == 710358b`, ahead count 0, workspace clean,
`.env.development.local`/`Local.xcconfig` ignored, no stray artifacts.

## 2. Docker runtime

Colima (Docker Engine 29.6.1/29.5.2, context `colima`) — healthy,
confirmed via `docker version`/`docker info`/`docker context show` before
any database operation. Supabase CLI `2.109.1`.

## 3. What closed this phase

Both previously-BLOCKED items from Phase 2C-3 are now closed:

- **Local migration replay**: executed twice, both from an empty database,
  both PASS — both migrations apply cleanly in the correct order.
- **pgTAP execution**: executed twice, both **96/96 assertions passed, 0
  failed, 0 skipped**, across all 4 pgTAP files. Two real bugs (both in
  test files, not in schema/RLS/RPC — see `docs/LOCAL_SUPABASE_VALIDATION.md`
  §6) and one file-organization issue were found and fixed to get a clean
  first pass; a second, fully independent round then confirmed the fixed
  state is stable and deterministic.
- **Local schema diff**: `supabase db diff` reports "No schema changes
  found" — the migration files are a complete, accurate description of the
  schema, with zero drift.

## 4. What was fixed (no schema/RLS/RPC defect found)

1. `supabase/tests/auth_household_rls_test.sql` (pre-existing) — a Postgres
   syntax defect (a data-modifying `WITH` embedded as a subquery
   expression). Fixed with `GET DIAGNOSTICS` instead. **Test-file syntax
   fix only.**
2. `supabase/tests/sync_business_rls_test.sql` (written in Phase 2C-3) —
   used camelCase JSON keys (`normalizedName`, `recipeId`) against
   `apply_sync_mutation`'s snake_case column-name contract, and the same
   WITH-clause syntax defect as item 1 in one assertion. Fixed both.
   **Test-file fix only** — the real client → Express → RPC path already
   correctly translates camelCase to snake_case (unchanged, confirmed by
   `sync-smoke.mjs`).
3. `supabase/tests/auth_household_remote_verify.sql` and
   `sync_business_remote_verify.sql` were not pgTAP files at all (plain
   `DO $$ RAISE EXCEPTION $$` scripts for `--linked` read-only checks) but
   lived in the pgTAP-scanned `supabase/tests/` directory, causing
   `supabase test db` to misreport them as failing tests ("No plan found").
   Moved to a new `supabase/remote-verify/` directory; updated the two
   `package.json` scripts and one Node test that reference their paths.
   **Tooling/organization fix, not a test-content change.**
4. `supabase/config.toml` — added `[analytics] enabled = false`. A
   Colima-specific limitation (the `vector`/`logflare` containers' Docker-
   socket bind-mount is incompatible with Colima's VM filesystem) prevented
   `supabase start` from succeeding at all; analytics/log-routing has no
   bearing on migration/pgTAP/RLS validation. **Local-dev CLI config only —
   never a remote/production setting.**

**No new migration was created.** No schema, RLS policy, RPC, trigger, or
table definition was found to be defective — every fix was to test files,
test-file organization, or local tooling configuration.

## 5. pgTAP results (both rounds identical)

| File | Assertions | Result |
| --- | --- | --- |
| `auth_household_objects_test.sql` | 12 | ok |
| `auth_household_rls_test.sql` | 10 | ok |
| `sync_business_objects_test.sql` | 44 | ok |
| `sync_business_rls_test.sql` | 30 | ok |
| **Total** | **96** | **PASS, 0 failed, 0 skipped** |

Coverage includes (all executed, not inferred from source): anonymous
read/write denial (function- and table-privilege level), authenticated
legitimate access, User A/B read and write isolation, RPC household-scope
isolation, membership grant and revoke (with immediate access loss
re-verified live, no re-login needed), duplicate-mutation idempotency,
stale-baseVersion conflict, delete-creates-tombstone, delete-appears-in-
change-feed, monotonic pull cursor, mutation-ledger row accounting,
idempotent delete retry (no duplicate side effects), invalid-operation
rejection, invalid-scope rejection, `search_path` safety, and no
public/anon privilege escalation.

## 6. `db lint`

One finding, both rounds identical, assessed as a **linter false
positive** (the static analyzer can't correlate `table_name` with
`scope_kind` in `apply_sync_mutation`'s dynamic SQL) — not treated as a
blocking failure. Full reasoning and evidence in
`docs/LOCAL_SUPABASE_VALIDATION.md` §8. No code change was made in
response.

## 7. Residue

Zero rows in every checked table (`auth.users`, `households`,
`household_members`, `inventory_items`, `sync_mutations`) after both pgTAP
rounds — every test file's `BEGIN; ... ROLLBACK;` guarantee confirmed in
practice.

## 8. Remote development project

Touched **read-only only**: `supabase migration list` (local==remote,
zero drift) and the two remote-verify scripts (moved, paths updated, same
pass results as Phase 2C-3). No reset, no migration apply, no write of any
kind. `auth-smoke.mjs`/`sync-smoke.mjs` were not re-run — nothing in the
request path changed this phase.

## 9. Regression

Node: **948/948** (unchanged from before this phase — same count, since the
Node-side fixes were path corrections, not new behavior, plus the same 9
migration-manifest-adjacent tests already counted). `npm audit
--omit=dev --audit-level=high`: 0 vulnerabilities. iOS Unit: **635 unique
test cases, 0 failed** (exceeds the 631 baseline — no database work touches
iOS code, so this is the same suite re-confirmed clean); `GuestMergeTests`
138/138; `APIEnvironmentTests` 10/10. iOS UI: **8/8**. Debug and Release
clean builds: **0 errors**.

## 10. Security checks

`git diff --check` clean; no secret/project-ref/JWT pattern found in the
diff; all iOS feature flags remain `NO`; both sensitive files remain
ignored; no stray dump/log/token/xcresult/DerivedData files; local Docker
containers stopped and confirmed absent after this session
(`docker ps -a` empty); remote project confirmed untouched beyond the
read-only checks in §8.

## 11. What this phase explicitly does NOT claim

- Production database is not ready, configured, or validated.
- No production Supabase project was created.
- No production migration was applied anywhere.
- Production is not enabled.
- This closes the *local* replay/pgTAP blockers specifically — it does not
  close the production-Supabase-project, crash/alert-provider, TestFlight,
  or shared-rate-limit-store conditions, which remain open.

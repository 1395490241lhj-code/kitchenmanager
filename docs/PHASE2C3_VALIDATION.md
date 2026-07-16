# Phase 2C-3 Validation — Production Supabase Topology + Migration/RLS Parity

Status: **topology decision made; migration/RLS parity re-verified against
the development project (read-only); no production project created; no
production migration executed; production not enabled.**

## 1. Git gate

At start: `HEAD == origin/main == fd03948179363d55c7eb7d96e022478ae79aa197`,
ahead count 0, workspace clean, `git diff --check` clean, both
`.env.development.local` and `Local.xcconfig` confirmed ignored/untracked,
no stray zip/DerivedData/xcresult/schema-dump/token/credential artifacts.

## 2. Supabase topology audit (redacted)

See `docs/SUPABASE_ENVIRONMENT_TOPOLOGY.md` for the full audit. Summary:
**one** Supabase project exists (development), used identically by iOS
`.production`/`.development`, the Express backend, and every test/smoke
script. No production project exists. Config is injected via
`.env.development.local` (gitignored) and Render's own dashboard
(unauditable from this repository) — never hardcoded in tracked source.
An existing, already-tested `ensureDevelopmentTarget` fail-closed guard
(re-verified this phase) prevents every write-capable script from targeting
anything but a loopback address or an explicitly `SUPABASE_ENVIRONMENT`-
labeled safe target.

## 3. Topology decision

**B. SEPARATE DEV + PROD PROJECT RECOMMENDED** (target topology), with
**A (shared project) explicitly accepted as a bounded, temporary Stage-1-only
exception.** See `docs/SUPABASE_ENVIRONMENT_TOPOLOGY.md` §3 for the full
comparison and reasoning. No production project was created this phase.

## 4. Environment safety guards added this phase

- iOS: `APIEnvironment.isSafeForCurrentBuildConfiguration` and `.label` —
  a Release build now has a real (if today mostly inert, since only one
  host exists) guard against ever resolving to a loopback address; a safe,
  non-secret environment label is available for diagnostics. 5 new tests in
  `APIEnvironmentTests.swift`.
- Backend: re-verified (not re-implemented — already existed and already
  tested) that `ensureDevelopmentTarget` gates `auth-smoke.mjs`,
  `sync-smoke.mjs`, and `cleanup-guest-merge-smoke-markers.mjs`, all
  fail-closed on a missing/production `SUPABASE_ENVIRONMENT` value.
- New `src/server/utils/migration-manifest.js` — a pure, dependency-free
  check that the migration filename manifest itself has stable ordering, no
  duplicate version prefixes, and no malformed filenames. 8 new Node tests.

## 5. Migration inventory + parity

See `docs/DATABASE_MIGRATION_PARITY.md` for the full redacted matrix.
Summary: 2 migrations, both applied to the dev project, `npx supabase
migration list` confirms local == remote with zero drift. Manifest ordering/
duplicate-detection is now automatically checked by a unit test (previously
only implicitly true). Local pgTAP execution and `db diff --linked` are
**BLOCKED** (Docker unavailable — real CLI errors captured, not assumed):

```
$ npx supabase test db
{"_tag":"Error","error":{"code":"LegacyDbConnectError", ...}}

$ npx supabase db diff --linked
Cannot connect to the Docker daemon at unix:///var/run/docker.sock.
```

## 6. Remote dev parity (read-only, executed)

`npx supabase db query --linked --file supabase/tests/auth_household_remote_verify.sql`
and the equivalent `sync_business_remote_verify.sql` both executed cleanly
against the real dev project with no exception raised:

- Auth/household: `phase0_remote_objects_verified` — 2 personal households
  (the two pre-existing seeded test accounts, not new data), 9 policies, 3
  triggers.
- Sync/business: `phase2a_remote_objects_verified` — 11 policies, 18
  triggers (9+9), 3 RPCs.

## 7. pgTAP

- Pre-existing: `auth_household_objects_test.sql` (12 assertions),
  `auth_household_rls_test.sql` (10 assertions, behavioral A/B isolation),
  `sync_business_objects_test.sql` (44 assertions, object/RLS/privilege
  shape) — all written and previously documented; **not re-executed this
  phase** (same Docker-unavailable blocker).
- New this phase: `sync_business_rls_test.sql` (30 assertions) — behavioral
  RLS/idempotency/conflict/tombstone/change-feed/rollback coverage for the
  sync business schema, the one gap the auth-side test didn't cover. See
  `docs/RLS_SECURITY_VERIFICATION.md` §4 for exactly what it checks.
  **Written, not executed** — Docker unavailable in this environment.

## 8. RLS verification

See `docs/RLS_SECURITY_VERIFICATION.md` for the full writeup, including the
explicit owner/service-role/authenticated/anon role separation this
document insists on. All security conclusions are based on `authenticated`/
`anon` behavior only — **no service-role query was used to assert app
security** anywhere in this phase.

## 9. User A/B isolation, idempotency, conflict, tombstone/feed/ledger —
re-executed this phase against the real dev project

```
$ node --env-file=.env.development.local scripts/sync-smoke.mjs
[sync-smoke] auth, direct-DML denial and A/B isolation: PASS
[sync-smoke] create/update/conflict/delete/idempotency/feed/pagination: PASS
[sync-smoke] representative entity families: PASS (8)
[sync-smoke] real Express sync contract: PASS

$ node --env-file=.env.development.local scripts/auth-smoke.mjs
[auth-smoke] real Auth/JWKS: PASS
[auth-smoke] trigger, /api/me, user isolation and RLS: PASS
[auth-smoke] Guest route authentication boundary: PASS
[auth-smoke] rate-limit saturation: SKIP (opt-in)
```

Both scripts self-clean their own created rows (`cleanupRecords` in
`sync-smoke.mjs`); no external marker-cleanup script invocation was needed
for this run. Zero email/token/Authorization content appeared in any
captured output (verified by grep before including it above).

## 10. Backup/restore readiness

Designed, not executed — see `docs/RLS_SECURITY_VERIFICATION.md` §5. No
real backup/restore/PITR operation was performed against any database.

## 11. Script safety re-audit

`auth-smoke.mjs`, `sync-smoke.mjs`, and `cleanup-guest-merge-smoke-markers.mjs`
were re-read this phase: all three already call `ensureDevelopmentTarget`
before any remote write, all three redact known secret env-var values and
JWT/Bearer patterns from any thrown error message, all three use exact
entity-ID (never prefix/broad) cleanup, none uses a service-role key, and
none reads from an unvalidated environment source. No changes were needed
to these three files this phase — the existing design already satisfies
the requested safety properties, confirmed by re-reading the source and by
this phase's fresh, real execution of two of them (§9).

## 12. Node tests

New: `test/phase2c3-migration-manifest.test.mjs` (9 tests — manifest
ordering, duplicate-version rejection, malformed-filename rejection,
filename pattern shape, the real repository manifest's current validity, an
unreadable-directory failure mode, and — added during final review — a
regression test proving `loadMigrationManifest` doesn't depend on
filesystem enumeration order). Full suite: **948/948 passed** (up from the
Phase 2C-2 baseline of 939).

## 13. iOS tests

New: `APIEnvironmentTests.swift` (10 tests — Debug resolves to development,
safe non-secret label, Debug-always-safe, both cases share one HTTPS host
today, neither resolves to loopback today, and — added during final review
— 5 tests for `isLoopbackHost`'s case/trailing-dot/IPv6/`.local` edge
cases). Full iOS Unit suite: **631/631 passed** (up from the Phase 2C-2
baseline of 621; `GuestMergeTests` alone: **138/138**, unchanged — no
regression). iOS UI suite: **8/8 passed** (unchanged — no new UI tests were
needed this phase). Debug and Release clean builds: **0 errors**.

## 13b. Findings from a final pre-push review pass

A review pass before push found three real issues (test-quality and one
implementation gap), all fixed and re-verified this same round — the counts
in §12/§13 above already include the fixes.

- **`isSafeForCurrentBuildConfiguration`'s loopback check had real bypasses**:
  case-sensitivity ("LOCALHOST"), a trailing root-DNS dot ("localhost."),
  and IPv6 loopback ("::1") were not covered. Fixed by extracting a
  standalone, normalized, directly-testable `APIEnvironment.isLoopbackHost(_:)`
  function; added 5 tests covering exactly these cases.
- **`loadMigrationManifest`'s "already in order" check depended on
  `fs.readdirSync`'s incidental, OS-dependent enumeration order**, which is
  not a meaningful signal and could have produced a false failure on a
  different filesystem/CI runner even with nothing actually wrong. Fixed by
  sorting filenames before validating; added a regression test that writes
  migration files to a temp directory in reverse order and confirms the
  loader still reports them valid.
- **The original `sync_business_rls_test.sql`'s final assertion (household
  membership removal) never actually added a second household member
  before "removing" one** — the delete matched zero rows, so the assertion
  was vacuously true and didn't test what its own comment claimed. Fixed by
  granting user B membership in household A first (via an ordinary
  owner-acting-as-themselves INSERT, already permitted by the existing
  `household_members_insert_for_managers` policy — no elevated role
  needed), confirming B can then read the household, then removing the
  membership and confirming both the RPC and direct-table read paths
  immediately lose access. Assertion count increased from 27 to 30.

## 14. Security checks

`git diff --check` clean; no secret/project-ref pattern found in the diff;
all iOS feature flags remain `NO`; `npm audit --omit=dev --audit-level=high`
found 0 vulnerabilities; no stray artifacts in `/tmp` or the repository; both
sensitive files remain correctly ignored.

## 15. What this phase explicitly does NOT claim

- No production Supabase project was created.
- No production migration was executed.
- No production RLS validation was performed (no production project
  exists).
- Production is not enabled.
- Local pgTAP execution remains unresolved (Docker unavailable) — not
  silently skipped, not faked as passing.

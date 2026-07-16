# Phase 2D-2 Validation

Read-only/local-only validation record, except for one local Docker-based
Supabase instance actually exercised end-to-end (see §4). No production
Supabase project was created or touched. No real user account was used or
deleted. No secret, Team ID, Apple ID, Supabase key, or service-role value
is reproduced anywhere below.

## 1. Git gate (start of phase)

- `origin/main` and local `HEAD` were both `bd94e23` before this phase's
  work began, ahead count 0, workspace clean.
- `.env.development.local` and `ios-native/Kitchen Manager/Config/Local.xcconfig`
  confirmed still gitignored/untracked throughout.

## 2. Database migration validation

New migration:
`supabase/migrations/20260716000100_account_deletion_lifecycle.sql`
(does not modify either prior migration file).

- **Two independent `supabase db reset` + `supabase test db` rounds**,
  fresh each time: **131/131 pgTAP assertions pass** both rounds (96
  pre-existing + 35 new in `supabase/tests/account_deletion_test.sql`).
- **`supabase db lint`**: two findings, both confirmed **static-analyzer
  false positives** by direct runtime testing (not assumed):
  - `apply_sync_mutation`/`frequent_recipes` — pre-existing finding,
    already assessed as a false positive in Phase 2C-4; unchanged by this
    phase.
  - `request_account_deletion`'s `foreach … loop execute format(...)`
    pattern — the linter (`plpgsql_check`) cannot trace a loop variable's
    runtime values and evaluates the array literal itself as if it were a
    static argument. Verified false by directly exercising the function
    against real households/business rows across all 7 iterated tables
    (see §4) — the anonymization genuinely applies per-table, correctly,
    at runtime.
  - The lint tool's only other message for `request_account_deletion` is
    a `warning` (not `error`) about the `anon_id` constant's type cast,
    which is intentional (see the migration's own header comment on the
    shared, non-resolvable placeholder UUID).
- **`supabase db diff`**: "No schema changes found" — both rounds.
- **Residue check** (both rounds, immediately after reset before any test
  data was inserted): `profiles`, `households`, `household_members`,
  `account_deletion_requests`, `sync_mutations`, `sync_changes` all `0`
  rows.

## 3. A real bug found and fixed during migration development

The first draft anonymized live foreign-key columns (`created_by`/
`updated_by`/`changed_by`) by rewriting them to a shared placeholder UUID
(`00000000-…-000000000000`). This **violated the foreign key constraint**
the moment it ran, because no `profiles` row exists with that id — `ON
DELETE SET NULL` only governs what happens when the *referenced* row is
deleted, it does not relax the requirement that a *live* non-null value
must reference an existing row. Fixed by setting these specific live
columns to real SQL `NULL` (which the relaxed FK does permit), while
keeping the placeholder string substitution only inside the `sync_changes.record_data`
JSONB snapshot (not FK-constrained, so the placeholder is safe there and
keeps the JSON shape well-formed rather than deleting the key outright).

A second bug was found immediately after fixing the first: the plain
anonymization `UPDATE` statements on the 7 household-scope business tables
fired their existing `_prepare_sync`/`_write_change` triggers (designed
for ordinary user-driven mutations), which re-checked the *calling* JWT's
own household membership (already removed by that point in the same
function) and would have both raised a spurious "membership required"
error and, had it not errored, silently overwritten the anonymization
by re-attributing the row back to the actor and recording a new,
mis-attributed `sync_changes` entry. Fixed by temporarily
`ALTER TABLE … DISABLE/ENABLE TRIGGER` around exactly those statements
(the function owner also owns these tables, so this doesn't require
superuser-only `session_replication_role`).

Both bugs were found by actually running the SQL against a live local
database and observing real errors/incorrect results — not caught by
static review alone. See the migration file's inline comments for the
permanent record of both, and §4 below for the exact interactive session
that surfaced them.

## 4. Local Docker-based Supabase — full saga exercised end-to-end

Using disposable, phase-local test user ids created via raw SQL against
the local instance only (never the shared `TEST_USER_A`/`TEST_USER_B`
dev-project fixtures other phases' smoke scripts depend on):

- **Ownership blocker**: preview correctly reports
  `canDelete: false, blockingReason: "OWNERSHIP_TRANSFER_REQUIRED"` for an
  owner with another member; confirm correctly rejects with the same code
  without mutating any row.
- **Ownership transfer**: `transfer_household_ownership` promotes the new
  owner and demotes the caller to `admin` in one call; a non-member
  target and a User-A-transferring-User-B's-household attempt both
  correctly fail.
- **Confirm after transfer**: preview refreshes to `canDelete: true`;
  confirm returns `business_data_cleaned`; verified (as the new owner,
  since RLS correctly hides a left household from the departed user's own
  session — see the note below) that the household survives, the
  inventory item's `created_by`/`updated_by` are `NULL`, and the
  historical `sync_changes.record_data` snapshot shows the shared
  placeholder rather than the real actor id.
- **Sole-owner household**: preview correctly reports
  `requiresHouseholdDeletion: true`; confirm deletes the household
  outright (verified as gone globally, not just from the actor's now-
  restricted view).
- **Idempotent duplicate confirm**: a second call with the identical
  `idempotencyKey` after `business_data_cleaned` returns the same status
  without re-running cleanup.
- **`ACCOUNT_DELETION_IN_PROGRESS`**: a second call with a *different*
  idempotency key while still in-flight is correctly rejected.
- **`STALE_DELETION_PREVIEW`**: a mismatched fingerprint is correctly
  rejected.
- **`mark_account_deletion_finalized`**: confirmed callable only as
  `service_role` (an `authenticated`-role call is denied by grant, not
  just by application logic); a wrong idempotency key is rejected; a
  correct call marks `completed`.
- **Real Auth user deletion**: deleting the `auth.users` row directly
  (simulating what the real Admin API call does) cascades cleanly to
  `profiles` and `account_deletion_requests` — zero residue.

**A methodological note worth recording**: partway through manual
verification, "the shared household disappeared after the deleted user's
own session queried it" looked like a data-loss bug. It wasn't — the
query ran under `role authenticated` as the departed user, whose RLS-
governed visibility of that household is correctly gone the moment their
membership row is removed. Re-querying as a superuser (or as the
household's new owner) confirmed the household and its data were fully
intact throughout. This is called out explicitly because it's exactly
the kind of false-positive a real reviewer could also be fooled by if
they didn't switch query context before concluding data was lost.

## 5. Not validated this phase (explicit)

- The real hosted development Supabase project — no
  `SUPABASE_SERVICE_ROLE_KEY` is configured in this environment's
  `.env.development.local` (checked directly), which the Auth Admin API
  step genuinely requires. Running only the business-data-cleanup half
  against the shared dev project's `TEST_USER_A`/`TEST_USER_B` fixtures
  (used by other phases' smoke scripts) without being able to complete or
  cleanly undo the full saga was judged too risky to the state other
  phases depend on — see `docs/ACCOUNT_DELETION_DESIGN.md` §7 for the
  full reasoning.
- Any production Supabase project (none exists).
- Real reauthentication (password/OAuth) — only the nonce fallback was
  built and tested this phase.

## 6. Node regression

- `npm test`: **995/995 passing** (974 baseline + 21 new
  `test/account-deletion-phase2d2.test.mjs` tests).
- `npm audit --omit=dev --audit-level=high`: **0 vulnerabilities**.
- Two pre-existing tests were updated because this phase's real,
  intentional changes made their previous assertions stale, not because
  the tests were wrong: `test/sync-phase2c1-version-and-rate-limit.test.mjs`'s
  middleware-order regex (now includes `accountDeletionGuard`, positioned
  deliberately between `role` and `versionGate`) and
  `test/phase2c3-migration-manifest.test.mjs`'s hardcoded migration count
  (`2` → `3`).

## 7. iOS regression

- Debug build (`generic/platform=iOS Simulator`): **BUILD SUCCEEDED**.
- Release build (`generic/platform=iOS Simulator`): **BUILD SUCCEEDED**.
- iOS Unit tests: **653 executed, 5 skipped, 0 failures** (636 baseline +
  17 new: 6 `APIAccountDeletionServiceTests`, 3
  `APIErrorResponseDecodingTests`, 8 `AccountDeletionControllerTests`).
  `GuestMergeTests`: 138/138 unchanged.
- iOS UI tests (serial): **TEST SUCCEEDED**, unchanged from the Phase
  2D-1 baseline (8 executed, 1 skipped, 0 failures) — this phase added no
  new UI test target scenarios (see
  `docs/ACCOUNT_DELETION_DESIGN.md` §11 for what's deferred).
- `npm run ios:archive:guard`: same two pre-existing, real, un-fabricated
  findings as every prior phase (workspace-not-clean during active
  development; missing app icon) — nothing new introduced by this phase.

## 8. A real, incidental bug found and fixed in shared iOS networking code

`APIErrorResponse` (used by every existing authenticated service, not
just this phase's new one) assumed a flat `{code, error, message, ...}`
JSON shape. This codebase's own `/api/me` and `/api/sync/*` routes
actually return a **nested** `{error: {code, message}}` shape — meaning
`payload?.code` silently came back `nil` for those endpoints too, before
this phase. It was never caught because every existing caller
(`APIAccountService`) only ever branched on HTTP status, never on
`payload?.code`. This phase's account-deletion errors needed the nested
`code` to distinguish several errors sharing one HTTP status (409), which
surfaced the gap. Fixed with a custom `Decodable` initializer that tries
the nested shape first, falling back to the pre-existing flat shape (used
by `version-gate.js`/`rate-limit.js`'s 426/429 responses) — both shapes
now decode correctly, covered by
`APIErrorResponseDecodingTests` (3 new tests).

## 9. Security / PII scan

- `git diff --check`: clean.
- No Apple ID, Team ID, Supabase key, service-role value, project ref, or
  password in any new/modified file (checked directly, not assumed).
- No database dump, `.xcresult`, `DerivedData`, archive/ipa/dSYM, or
  screenshot anywhere in the tracked tree.
- No test-account email/UUID printed in this document or any committed
  file — the disposable test ids used in §4's interactive session were
  never committed anywhere and existed only inside a local Docker
  container that has since been fully reset/stopped.
- Production flags remain `NO`; `AppStore` config remains fail-closed.

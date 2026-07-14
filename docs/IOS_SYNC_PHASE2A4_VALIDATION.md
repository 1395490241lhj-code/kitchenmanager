# iOS Sync Phase 2A-4 Validation

## Scope

Phase 2A-4 adds a deliberately opt-in, Debug-only hosted smoke harness for the
single inventory proof of concept. It is not product synchronization.

- `SYNC_ENABLED` and `SYNC_SMOKE_ENABLED` remain `NO` in committed and example
  configuration.
- The smoke requires an explicit local development environment marker and an
  authenticated session.
- It uses one generated `__sync_smoke_inventory_` record in the signed-in
  user's default household scope only.
- The lifecycle is bootstrap, create, pull, update, idempotent retry, stale
  base-version conflict, soft delete, and final pull.
- It verifies SwiftData metadata, the pending queue, and the per-scope cursor.
- It does not scan, upload, merge, reassign, or clear ordinary Guest data.

## Not yet implemented

- Automatic/background synchronization of any kind (no timer, no startup hook,
  no login hook).
- Guest data merge or upload into a hosted account.
- Any repository adapter beyond the single inventory proof of concept
  (shopping, today plan, weekly plan, and user recipes are not wired to sync).
- Conflict resolution UI (the smoke only proves the server-side conflict is
  correctly detected and retained; there is no user-facing resolution flow).
- Background sync tasks or Realtime/live updates.

## Safety boundary

The smoke runner is compiled only for Debug builds and has no startup, login,
timer, background, or inventory-write hook. Its development-only token provider
reads the already-authenticated session at request time and does not persist or
log credentials. Cleanup only addresses the generated smoke marker and uses a
soft delete.

## Validation status — 2026-07-13

- CoreSimulator was recovered by closing Xcode/Device Hub, shutting down all
  devices, and restarting CoreSimulatorService. The existing iPhone 17 Pro on
  iOS 27.0 (`24A5380g`) then booted reliably.
- Minimal XCTest passed (1/1), Phase 2A-4 focused XCTest passed (7/7), and an
  initial complete Unit/UI run passed (468/468). The valid result bundles remain
  outside the repository under `/tmp`.
- The authorized App -> development Render -> development Supabase smoke passed:
  bootstrap, create, pull, update, duplicate retry, stale-version conflict, soft
  delete, final pull, metadata, pending mutation, and cursor checks all reached
  their expected state. The generated marker was soft-deleted.
- Guest inventory, shopping, today-plan, weekly-plan, and user-recipe boundaries
  were unchanged. The normal SwiftData container was retained, session restore
  after a full App relaunch passed, and sign-out returned to Guest mode without
  leaving password-form state.
- `SYNC_ENABLED` and `SYNC_SMOKE_ENABLED` were restored to `NO` in the ignored
  local configuration; committed/example defaults remain `NO`. The temporary App
  process was stopped and no automatic sync hook exists.
- The development backend smoke passed after fixing its validation to start from
  a fresh bootstrap cursor instead of cursor `0`; the accumulated change feed is
  now larger than the first 100-row page.
- An earlier post-fix iOS regression attempt reached 467 passed / 1 existing
  receipt UI failure; the failure exposed a real 16x19pt delete hit target and
  an Xcode 27 off-screen `isHittable` false positive. Both were fixed (44x44pt
  hit target, viewport-bounded visible-element selection in the UI test) and
  the receipt test passed in isolation, but a final serial full-suite rerun had
  not yet been produced.

## Final validation — 2026-07-14

- Audited the handed-off working tree before trusting it: `git status --short`,
  `git diff --stat`, and a file-by-file review of every modified sync file
  confirmed no change to `SyncCoordinator` push/pull ordering, mutation
  create/cleanup semantics, cursor advancement, `SyncMetadata`/`PendingMutation`
  state transitions, `InventorySyncAdapter` create/update/delete/apply, or the
  Express/Supabase sync contract. The only non-additive changes were the
  receipt delete hit-target fix, the matching UI test stabilization, and the
  backend smoke script's fresh-bootstrap-cursor fix — none of which touch sync
  semantics. The previously verified hosted iOS lifecycle result therefore
  remains valid and was not re-run.
- Found and fixed one real gap during this audit:
  `HostedSyncSmokeUITests.swift` was wrapped in `#if HOSTED_SYNC_SMOKE`, a
  compilation condition never defined anywhere in the project — the test would
  have silently compiled out of every ordinary run instead of appearing and
  safely skipping. Removed that dead compile-time gate; the file now compiles
  into every `KitchenManagerUITests` run and relies solely on its existing
  runtime guard (`XCTSkip` when `SYNC_SMOKE_TEST_EMAIL`/`SYNC_SMOKE_TEST_PASSWORD`
  are not supplied).
- Final Node regression: `npm test -- --test-reporter=tap` → **786/786 passed,
  0 failed, 0 skipped**. `npm audit --omit=dev --audit-level=high` → 0
  vulnerabilities. `git diff --check` → clean.
- Final iOS regression on the recovered iPhone 17 Pro (iOS 27.0, runtime
  `24A5380g`), serial (`-parallel-testing-enabled NO`), full rebuild (no
  `-test-without-building`): Unit target `KitchenManagerTests` — 465/465
  passed. UI target `KitchenManagerUITests` — 4 tests, 0 failed, 1 safely
  skipped: `HostedSyncSmokeUITests` skipped exactly as designed ("Hosted sync
  smoke credentials were not supplied"), and it was not excluded from the run.
  `ReceiptCompactListUITests` passed in the full serial suite. Combined: 469
  distinct tests, 0 failed, 1 safe skip. Valid merged `xcresult` produced via
  `xcrun xcresulttool merge`.
- Final Debug build: `xcodebuild clean build` → **BUILD SUCCEEDED**, 0 compile
  errors, 0 warnings (no new Swift concurrency warnings).
- Repeated the safety checklist: `.env.development.local` and `Local.xcconfig`
  remain untracked and `git check-ignore`d; committed/example xcconfig defaults
  and the local ignored config all have `SYNC_ENABLED=NO` and
  `SYNC_SMOKE_ENABLED=NO`; the Debug-only smoke entry point has no Release
  build path, no startup/login/timer/background hook, and requires an explicit
  tap plus confirmation alert; no service-role key, database password, PAT,
  test-account password, access/refresh token, JWT, Authorization header, or
  full publishable key appears anywhere in the diff or new files; no
  DerivedData, xcresult, simulator data, screenshot, or temporary log was
  staged.
- **Phase 2A-4 is checkpoint-complete.** A local commit
  (`test: validate controlled iOS hosted sync`) was created; it was not pushed.

## Required next run

None outstanding for Phase 2A-4. Do not repeat the hosted iOS smoke lifecycle
unless a later code change to sync core semantics invalidates this verified
result — re-audit the diff against the "core semantics" list above first.

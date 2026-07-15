# CHANGELOG.md

All notable project changes should be documented here.

Keep entries concise. Use this file for what changed, not for long design discussion. Put current project state in `PROJECT_STATUS.md`.

---

## 2026-07-14

### Added

- Added Phase 2B-1: a user-initiated, explicitly-confirmed Guest inventory merge. Read-only Guest data detection (`GuestDatasetDetector`), a persisted `GuestMergeSession` state machine bound to `(userId, householdId, inventory_item)`, pure local matching/plan generation (`InventoryMergePlanner`) with content-addressed plan-hash re-validation, explicit per-conflict user choice with partial-commit support, and upload/rollback entirely through the existing `SyncCoordinator`/`InventorySyncAdapter`/`ExpressSyncTransport` — no second upload client. Adds an independent `INVENTORY_SYNC_ENABLED` flag (default `NO` in every configuration, including Release) that never enables or depends on `SYNC_ENABLED`. Only inventory is ever staged or rolled back; Shopping/Today Plan/Weekly Plan/Recipes are counted for display only and never touched. This round is mock/UI-tested only — no real hosted Guest merge, test account, or remote write was performed. See `docs/GUEST_MERGE_PHASE2B.md` and `docs/INVENTORY_MERGE_CONTRACT.md`.

- Added Phase 2B-2: a controlled real hosted Guest inventory merge smoke against the development Supabase project through the existing Render deployment. New Debug-only `GuestMergeSmoke.swift` (`GuestMergeSmokeRunner`/`GuestMergeSmokeConfiguration`/`GuestMergeSmokeReport`) and `HostedGuestMergeSmokeTests.swift`, gated by a new independent `GUEST_MERGE_SMOKE_ENABLED` flag (default `NO`, mirrors `SYNC_SMOKE_ENABLED`) plus two real test-account credential pairs from an ignored environment file — mirrors the Phase 2A-4 `SyncSmokeRunner`/`HostedSyncSmokeUITests` pattern exactly, runs entirely through the real unmodified `GuestMergeController`, and never touches the developer's real local Guest inventory (an isolated in-memory container supplies the test's own marked dataset). Completing this required finishing a piece Phase 2B-1 deliberately deferred: a real read-only pre-merge remote read (`GuestMergeController.preparePreview`'s new optional `remoteTransport` parameter, default `nil` so ordinary preview is unaffected) to populate `knownRemoteItems`, plus a `remoteVersion` field on `RemoteInventorySnapshotItem`/`InventoryMergeCandidate` so `confirmMerge` correctly seeds baseVersion for a same-id update against a remote record this device only just learned about. Adds `scripts/cleanup-guest-merge-smoke-markers.mjs`, a one-off recovery script (authorized user-level API only) for soft-deleting orphaned marker rows from an interrupted run. See `docs/GUEST_MERGE_PHASE2B2_VALIDATION.md`.

- Added Phase 2B-3: a formal, user-facing Guest inventory merge UI and manual sync entry, on top of the already-validated Phase 2B-1/2B-2 merge engine. Enriched preview (target household name, cloud-side known-item count, per-type conflict breakdown), a conflict screen showing local-vs-remote quantity/expiry with a new fourth choice `InventoryMergeConflictChoice.skip` ("稍后处理", persists like the other three but never uploads), and an explicit notice when `keepBoth` on a same-id conflict will create an independent second record. New `GuestMergeController.syncNow(authStore:householdId:)` — the only production `SyncCoordinator.runOnce` call site besides `confirmMerge`/`rollback`, always user-initiated ("立即同步库存"), scoped to `.inventoryItem` only — and a new `InventorySyncStatusView` showing plain-language sync status. New independent flag `INVENTORY_MERGE_UI_ENABLED` (default `NO` everywhere) gates the UI separately from `INVENTORY_SYNC_ENABLED` (network capability). Decided but deliberately deferred: whether ordinary post-merge Inventory CRUD should auto-stage mutations — documented as a conservative policy, not wired into `KitchenStore` this round (would require threading Auth/sync context into an intentionally decoupled component). Added 7 new `GuestMergeTests` cases, 19 new Node semantic-guard assertions, and 1 real credential-free XCUITest. Full regression: Node 822/822, iOS Unit 522/522 (2 safe skips) + UI 5/5 (1 safe skip), Debug build 0 errors/0 new warnings. See `docs/INVENTORY_SYNC_PHASE2B3.md`.

- Added Phase 2B-4: wired ordinary Inventory create/update/delete to the existing sync engine, so a completed Guest merge's items keep staging `PendingMutation`s on later local edits — still only sent on a manual "立即同步库存" tap. New `InventorySyncEnrollment` (per `userId`+`householdId`, transitions to `.enrolled` only from `confirmMerge`'s success branch) and centralized `InventorySyncEligibility.evaluate(...)` (the single place that decides whether a CRUD op may stage). `KitchenStore` gained one optional, generic hook (`onInventoryChanged`, no Auth/Sync import) wired once in `ContentView.swift`'s composition root. New `SwiftDataSyncPersistence.stageInventoryMutation(...)` atomically stages `SyncMetadata`+coalesced `PendingMutation` (create+update, create+delete cancel, update+update, update+delete-as-tombstone, duplicate-delete no-op) without touching `InventoryRecord` (avoiding a dual-`ModelContext` race identified during the pre-implementation audit — `KitchenStore`'s own persistence already wrote the record separately). Delete always stages a soft-delete tombstone, never a physical remote delete. Added 21 new `GuestMergeTests` cases, 14 new Node semantic-guard assertions, and a minimal hosted smoke (`__inventory_crud_smoke_<marker>`) verifying create/update/delete via manual sync plus a Guest-only control item confirmed never staged — passed on the first attempt, zero marker residue. Full regression: Node 836/836, iOS Unit 540/540 (3 safe skips) + UI 5/5 (1 safe skip), Debug build 0 errors/0 new warnings. See `docs/INVENTORY_CRUD_SYNC_PHASE2B4.md` and `docs/INVENTORY_MUTATION_COALESCING.md`.

- Added Phase 2B-5: a release-readiness/dogfood-safeguard audit of Inventory Sync (Phases 2B-1 through 2B-4) — **not** a new feature phase, and the resulting conclusion is No-Go for production. New `InventorySyncDogfoodConfiguration` (`INVENTORY_SYNC_DOGFOOD_ENABLED`, `INVENTORY_SYNC_DIAGNOSTICS_ENABLED`, both default `NO`) only ever unlocks a read-only diagnostics screen and confirms the existing manual-only paths, never automatic sync. New `InventorySyncEligibility.blockedByQueueFull` caps pending-mutation growth per scope (`maxPendingMutations`, default 200) without ever dropping a delete or blocking coalescing into an already-staged mutation. New `InventorySyncDiagnosticsSnapshot` (redacted — no email/password/token/full UUID/household id/payload/item name) and read-only `InventorySyncConsistencyChecker` (14 checks, never auto-fixes) back a new dogfood-gated "库存同步诊断" screen (`InventorySyncDiagnosticsView.swift`) at the bottom of the account page, offering only refresh/export/retry-manual-sync/help. `GuestMergeController` gained `dogfoodConfiguration`, `showsDiagnosticsScreen`, `lastSyncStartedAt`/`lastSyncCompletedAt`, `diagnosticsSnapshot(...)`, and `consistencyCheck(...)`. Verified `syncNow`'s existing `@MainActor` single-flight guard is sufficient by test rather than adding a new gate actor. Added 10 new `GuestMergeTests` cases (82/82 passing, up from 72 baseline); full iOS Unit regression 550/550 (up from 540), 0 regressions. Explicitly not performed this phase (tracked as open Go-blockers): weak-network/error-injection tests, performance/scale tests at 500-1000 items, a production config audit, physical-device dogfood validation, and the hosted development-environment dogfood smoke. See `docs/INVENTORY_SYNC_RELEASE_READINESS_PHASE2B5.md`, `docs/INVENTORY_SYNC_DOGFOOD_PLAYBOOK.md`, `docs/INVENTORY_SYNC_ROLLBACK_PLAYBOOK.md`, `docs/INVENTORY_SYNC_DIAGNOSTICS.md`, and `docs/INVENTORY_SYNC_GO_NO_GO.md`. All flags remain `NO`; nothing pushed.

- Added Phase 2B-6: physical-device dogfood prep, fault injection, scale validation, and a production config audit — closing every Phase 2B-5 evidence gap this environment can close. New conclusion: Dogfood Go / Production No-Go (was No-Go), pending only physical-device validation. New test-only `InventorySyncFaultInjectingTransport` (`KitchenManagerTests/GuestMergeTests.swift`, cannot compile into the app target) models offline/401/403/413/429/500/503/malformed-truncated-JSON/push-applied-then-timeout/pull-succeeded-then-local-save-failure/app-killed-before-cleanup — all confirmed pending-retaining, cursor-safe, and duplicate-safe. Verified single-flight under real concurrency and that a scope mismatch never sticks the guard. Added a queue-cap-at-scale test (250 attempted creates against a 200 cap holds firm). Added scale/performance sanity checks at 1000 metadata rows / 500 pending / 100 conflicts — no O(n²) hotspot found. Ran a real hosted development dogfood smoke (new `GuestMergeSmokeRunner.runInventoryDogfoodMinimalSmoke` / `HostedGuestMergeSmokeTests.testControlledDevelopmentInventoryDogfoodSmoke`) against the actual development Supabase project and Render deployment with an isolated `__inventory_dogfood_<id>` marker — passed on the first attempt, zero marker residue, flags restored to `NO` immediately after (smoke marker prefix added to `scripts/cleanup-guest-merge-smoke-markers.mjs`). Performed a read-only production-config audit and built + inspected a real unsigned Archive (all 8 sync/dogfood/smoke flags confirmed `NO`; zero test credentials/emails/markers in the compiled binary). Added 17 new `GuestMergeTests` cases (99/99, up from 82) and 9 new Node semantic-guard assertions (854/854). Full iOS Unit regression 568/568 (up from 550), 0 regressions. Physical-device validation was not attempted (no device attached to this environment); a 30-step checklist was prepared instead. See `docs/INVENTORY_SYNC_PHASE2B6_VALIDATION.md`, `docs/INVENTORY_SYNC_FAULT_INJECTION.md`, `docs/INVENTORY_SYNC_SCALE_RESULTS.md`, `docs/INVENTORY_SYNC_PRODUCTION_CONFIG_AUDIT.md`, `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_CHECKLIST.md`, and the updated `docs/INVENTORY_SYNC_GO_NO_GO.md`. All flags remain `NO`; nothing pushed.

- Added Phase 2B-7: real physical-device validation — conclusion remains Dogfood Go / Production No-Go, now narrowed to only the human-gesture UI layer. A physical iPhone 17 Pro (iOS 27.0) became available; ran the full `GuestMergeTests`/`HostedGuestMergeSmokeTests` XCTest suites for real on that hardware (real SwiftData/Keychain/network) — 97/99 passed, the 2 failures being an expected side effect of intentionally enabling dogfood flags for the run, not a product bug. The hosted development dogfood smoke ran for real from the device against the real Render deployment/development Supabase project — passed, zero marker residue. Performed a genuine OS-level app-kill/relaunch via `devicectl terminate`/`launch` on the real installed process. Caught and corrected a safety issue mid-phase: the available device was the operator's own signed-in daily-use phone, so all data-touching validation ran only inside the isolated XCTest sandbox, and — since the compiled binary installed on the phone briefly carried the dogfood flags as `YES` — rebuilt with flags back to `NO`, verified via `plutil`, and reinstalled before ending the phase, preserving the operator's app data throughout. Human-gesture steps requiring a touch/tap tool this environment doesn't have (UI taps, Airplane Mode toggle, screen lock/unlock, Instruments profiling) are honestly reported as BLOCKED, not faked. Full regression re-confirmed unchanged: Node 854/854, iOS Unit 568/568 (4 safe skips), UI 5/5 (1 safe skip), `GuestMergeTests` 99/99 (simulator, flags `NO`), 0 regressions. See `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md` and `docs/INVENTORY_SYNC_FINAL_GO_NO_GO.md`. All flags remain `NO`; nothing pushed.

- Continued Phase 2B-7 with a manual, human-driven physical-device round — found and fixed one real crash bug; conclusion still Dogfood Go / Production No-Go, gap now narrowed to only Conflict UI + Rollback (both explicitly not exercised, not failed). The operator personally tapped through sign-in, Guest-merge prompt/skip/recovery/preview, explicit confirm, marker CRUD + manual sync, offline/reconnect, Wi-Fi/cellular switch, background/foreground, lock/unlock, force-quit/restart, User A/B isolation, the real diagnostics screen + export (manually reviewed, redaction confirmed), and cleanup — reporting each step back individually. **Found a real, previously-unknown crash**: deleting an inventory item from its detail screen (after rendering a Toggle) crashed the app — a stale array-index captured by a `Binding` closure in `InventoryItemDetailView` (`KitchenManager/PantryStaples.swift`), a pre-existing bug unrelated to sync/dogfood. Root-caused from real device crash logs (`devicectl device info files --domain-type systemCrashLogs`), fixed by resolving every field binding fresh by item id instead of a captured index, covered by a new regression UI test (`testDeletingInventoryItemAfterTogglingStapleDoesNotCrash`), and re-verified for real on the same device — only the failed step was retried. `scripts/cleanup-guest-merge-smoke-markers.mjs` gained the `__inventory_device_dogfood_` prefix; confirmed 0 residual marker rows. Device rebuilt/reinstalled with all flags back to `NO`, verified via `plutil`. Full regression: Node 854/854, iOS Unit 568/568 (4 safe skips), UI 6/6 (1 safe skip, up from 5), Debug/Release clean builds 0 warnings, 0 regressions. See `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md` and `docs/INVENTORY_SYNC_FINAL_GO_NO_GO.md`. All flags remain `NO`; nothing pushed.

- Completed Phase 2B-7's final round attempting Conflict UI and Rollback — Conflict UI is now a confirmed architectural gap (not a bug), Rollback remains untested; conclusion unchanged at Dogfood Go / Production No-Go. Set up an ambiguous-duplicate conflict scenario against `TEST_USER_B`'s development-project household (one item seeded via the authenticated API, a matching local item created on-device with a different quantity). The real merge preview showed zero conflicts, confirmed by source (`GuestMergeController.preparePreview`'s `remoteTransport` defaults to `nil` and is documented as "never called by the ordinary in-app preview flow") to be deliberate, pre-existing behavior — the conflict-detection logic in `InventoryMergePlanner`, despite being thoroughly unit-tested, is structurally unreachable from the shipped app. Confirming the merge anyway (per operator consent) surfaced two more findings: 2 real personal inventory items were inadvertently included in the upload (an oversight — the "本地库存 3条" count at preview should have been flagged before asking for confirm), and the actual merge outcome was itself unclear (predicted 3 new items, only "已合并1条" reported, plus 2 unrelated pre-existing items of unknown origin in that household). Rollback was correctly **not** attempted against this ambiguous state, per the stop-on-uncertainty rule — the second such stop this phase. Cleaned up the one item this round created (verified soft-deleted); left the unrelated pre-existing items untouched. Device rebuilt with all flags restored to `NO`, verified via `plutil`, reinstalled. Full regression re-confirmed: Node 854/854, `npm run smoke:sync` PASS, iOS Unit 568/568 (4 safe skips), UI 6/6 (1 safe skip), Debug/Release clean builds 0 warnings, 0 regressions. See `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md` and `docs/INVENTORY_SYNC_FINAL_GO_NO_GO.md`. All flags remain `NO`; nothing pushed.

### Fixed

- Fixed Phase 2B-2.5: same-id `keepBoth` conflicts previously could never actually produce a second record — staging always targeted the original, already-versioned remote entity id with baseVersion 0, which the server correctly rejected as a stale-version conflict. `InventoryMergeCandidate` gained `forkedLocalItemId: UUID?` (part of the already-persisted plan, no new SwiftData model); `applyingChoice(.keepBoth)` on a same-id match now allocates a fresh, stable id once and reuses it on every later call (repeat choice, repeat confirm, App restart); the different-id ambiguous-duplicate case is unaffected. `confirmMerge` stages the fork as a plain create at baseVersion 0 and never touches the original entity for that candidate; `createdEntityIds`/`rollback` key off the fork, never the original. Added 8 new offline `GuestMergeTests` cases and 6 new Node semantic-guard assertions. A minimal, dedicated real hosted smoke (`testControlledDevelopmentSameIdKeepBothIdentityFork`, not a repeat of the full Phase 2B-2 matrix) confirmed both the original and forked records exist as distinct real entities and rollback removes only the fork. Full regression: Node 808/808, iOS Unit 515/515 (2 safe skips) + UI 4 (1 safe skip), Debug build 0 errors/0 new warnings, `npm run smoke:sync`/`npm audit`/`git diff --check` clean. See `docs/GUEST_MERGE_PHASE2B2_VALIDATION.md`.

- Corrective/hardening pass on Phase 2B-1, following a design review. `InventoryMergePlanner` now classifies candidates via an explicit `ExpiryIdentity` (both expiry dates absent or equal is "compatible", anything else is "incompatible") and a new `metadataMismatch` conflict reason for `isStaple`/staple-category/threshold/restock/tracking/availability differences — `quantity` and metadata fields are confirmed as never part of the identity/matching key (only `normalizedName + unit`), only compared after matching, so a quantity or metadata difference can never silently escape into `create` or a silent overwrite. `GuestMergeController.confirmMerge`/`rollback` now take the live `AuthStore` reference instead of a raw access-token parameter that a `View` previously had to read via `authStore.currentAccessToken()`; a new private `AuthStoreCredentialProvider` (`weak var authStore`) re-queries the token fresh per network call, so no `View`/`@Published`/SwiftData/`UserDefaults` value ever holds a token and a mid-run sign-out stops further requests. Added 13 new `GuestMergeTests` cases and 3 new Node semantic-guard assertions (`test/ios-native-guest-merge-phase2b1.test.mjs`) covering all of the above plus snapshot-size-cap/corrupted-record/plan-hash-invalidation edge cases. Full regression: Node 802/802, iOS Unit 502/502 + UI 4 (1 safe skip), Debug build 0 errors/0 new warnings, `npm audit`/`git diff --check` clean. Still disabled by default only — no real hosted Guest merge was performed.

## 2026-07-13

### Added

- Added a Debug-only, development-gated iOS Phase 2A-4 inventory sync smoke harness. It stages exactly one marker record through bootstrap/create/pull/update/idempotent retry/conflict/soft delete/final pull and verifies local sync metadata, pending mutations, scope cursors, and Guest inventory/shopping/today/weekly/recipe boundaries without wiring automatic synchronization. The hosted iOS lifecycle passed against development Render/Supabase and restored both safety flags to `NO`. **Phase 2A-4 checkpoint complete**: final Node suite 786/786 passed, final serial iOS Unit/UI regression 469 distinct tests with 0 failed and 1 safe skip (`HostedSyncSmokeUITests` skips cleanly without credentials, not excluded from the run), and a clean Debug build (0 errors/warnings). Also fixed a receipt-row delete control to a 44x44pt hit target, stabilized the matching UI test against an Xcode 27 off-screen-hittable false positive, and fixed the backend smoke script to assert pull results from a fresh bootstrap cursor instead of assuming cursor `0`.
- Added the disabled-by-default iOS Phase 2A-3 sync foundation with contract DTOs, BIGINT-safe cursor strings, separate SwiftData metadata/pending/per-scope cursor records, APIClient-backed transport, an explicit actor coordinator, and an inventory-only atomic adapter POC. No App/Auth/repository automatic sync hook is enabled.
- Added the local-only Phase 2A cloud business-schema draft for household inventory, shopping, today plans, consumption records, normalized weekly plans, and user recipes; personal favorites/frequent recipes; a monotonic RLS-protected change feed; and a mutation idempotency ledger.
- Added the Phase 2A-2 authenticated sync API (`bootstrap`, incremental `changes`, and batched `mutations`), strict entity validation, BIGINT-safe cursors/versions, deterministic legacy UUID mapping, and a user-JWT Supabase RPC repository that never uses service-role credentials.
- Added an undeployed allowlisted atomic mutation RPC with per-user idempotency locking, optimistic `baseVersion` conflicts, soft-delete tombstones, trigger-owned audit/version fields, and same-transaction change snapshots, plus API/schema/pgTAP contract tests and `docs/SYNC_API_CONTRACT.md`.
- Added Phase 2A schema/ownership/model-mapping documentation plus Node semantic and pgTAP object checks. No client SyncEngine is enabled.
- Deployed the reviewed Phase 2A business/sync migration to development Supabase, added a redacted two-user hosted smoke runner and remote object verifier, and validated RLS isolation, closed direct DML, atomic mutation/idempotency/conflicts/tombstones, all entity families, change pagination, and local Express sync endpoints.
- Split the sync contract into explicit household and user scopes with an independent cursor per `(scopeType, scopeId)`, preventing one household's global sequence progress from skipping personal or another household's changes.
- Added `docs/SYNC_PHASE2A_VALIDATION.md` with the real deployment, pgTAP fallback, security gates, repeatable commands, and remaining disabled client-sync boundary.
- Added the native iOS Guest-first account foundation with official `supabase-swift`, Keychain-backed session persistence, email/password registration and login, launch restoration, auth-state observation, sign-out, and native Guest/authenticated account screens.
- Added the iOS `/api/me` account client, recoverable profile/household loading, safe xcconfig generation, ignored local public configuration, mock auth/account tests, security baseline checks, and `docs/IOS_AUTH_PHASE1_SETUP.md`.
- Added project-scoped Supabase CLI tooling plus `verify:auth-phase0`, read-only `verify:auth-db`, and `smoke:auth` commands for non-production project metadata/JWKS validation, database-object integrity, real two-user Auth, `/api/me`, bidirectional RLS, Guest-boundary, and optional rate-limit smoke checks without storing credentials.
- Added pgTAP database-object assertions for the identity tables, RLS flags, key indexes, unique Auth trigger, and exact policy counts.
- Added `docs/AUTH_SYNC_PHASE0_5_VALIDATION.md` with repeatable remote linking, migration, test-user, Express, RLS/JWKS, smoke, security, rollback, and optional CI instructions. The linked development deployment now passes migration/object verification and repeated live two-user smoke; Docker pgTAP and optional rate-limit saturation remain explicitly unexecuted.

### Changed

- Preserved the existing native SwiftData container and all Guest behavior across login, session restoration, `/api/me` failure, and logout. Phase 1 adds identity only; no kitchen business data is uploaded, merged, cleared, or synchronized.
- Added a committed placeholder-only iOS Info.plist so xcconfig public Auth values are actually expanded into the built app, and stabilized account logout navigation plus the existing receipt UI test's interaction with virtualized List rows.
- Extended the environment template with development-only smoke variables and an explicit non-production guard; hardened URL/config/staged smoke diagnostics and server port-conflict reporting without exposing upstream bodies or credentials. Current Guest APIs, SwiftData models, business schemas, and client UI remain unchanged.

## 2026-07-12

### Added

- Added Phase 0 Supabase scaffolding with local CLI configuration, an idempotent Auth trigger for profiles/personal households/owner membership, RLS-protected identity tables, pgTAP isolation checks, and an environment template that separates public project configuration from the server-only service-role key.
- Added Express Supabase JWT/JWKS authentication middleware using `jose`, optional-auth and role guards, user/IP-scoped `/api/me` limiting, a user-JWT/RLS-backed account data source, and protected `GET /api/me` profile/household output.
- Added isolated JWT, rotation, authorization, account response, SQL structure, Guest compatibility, and error-sanitization tests plus `docs/AUTH_SYNC_PHASE0_SETUP.md`.

- Added `docs/AUTH_SYNC_ARCHITECTURE.md`, a repository-wide audit and proposed Guest-first account/sync architecture covering the current PWA, Express backend, native SwiftData app, managed-auth comparison, household ownership, cloud schema, incremental protocol, per-module conflicts, first-login merge, logout isolation, security boundaries, and PWA/iOS contract sharing.
- Added `docs/AUTH_SYNC_ROADMAP.md`, an implementation and test plan from auth/vendor decisions through backend identity, iOS login, cloud models, bootstrap, incremental sync, PWA adoption, and future household sharing.

- Added a dedicated SwiftData `InventoryRecord` that mirrors every current native `InventoryItem` field while leaving the existing Codable business model and backup JSON unchanged.
- Added injected SwiftData inventory persistence with disk-backed production storage, isolated in-memory test storage, and CRUD/bulk-replacement operations.
- Added an idempotent migration from `native_km_inventory_v1`, guarded by `native_km_inventory_swiftdata_migration_v1`; existing SwiftData UUIDs win, missing legacy UUIDs are added, verification precedes completion, and legacy JSON is retained.
- Added fourteen SwiftData inventory tests covering field round-trips, CRUD, UUID semantics, restart loading, migration success/failure/idempotency, partial prepopulation, backup restore, and clearing.
- Added a SwiftData `ShoppingItemRecord`, injected shopping-list persistence, and an idempotent migration from `native_km_shopping_v1` guarded by `native_km_shopping_swiftdata_migration_v1`; legacy JSON remains available for rollback.
- Added seventeen shopping persistence tests covering all business fields, UUID/order semantics, migration and failure paths, Store restart behavior, batch writes, stock-in rollback, backup restore, and complete local-data clearing.
- Added a SwiftData `TodayPlanRecord`, injected today-plan persistence, and an idempotent migration from `native_km_plans_v1` guarded by `native_km_today_plan_swiftdata_migration_v1`; the original plan JSON remains available as an upgrade fallback.
- Added seventeen today-plan persistence tests covering field round-trips, stable order, UUID semantics, migration success/failure/idempotency, Store restart behavior, batch insertion, shopping generation/import, inventory consumption, backup rollback, and complete local-data clearing.
- Added a SwiftData `ConsumptionRecordEntity`, injected consumption persistence, and an idempotent migration from `native_km_consumption_records_v1` guarded by `native_km_consumption_swiftdata_migration_v1`; existing JSON remains an upgrade fallback.
- Added twelve consumption persistence tests covering record/item field round-trips, CRUD, stable order, migration success/failure/idempotency, Store restart, undo idempotency, cooking/undo write-failure rollback, backup restore, and clearing.
- Added SwiftData weekly-plan persistence with a Codable full-plan snapshot and idempotent migration from `native_km_weekly_plan_v1` behind `native_km_weekly_plan_swiftdata_migration_v1`.
- Added two weekly-plan persistence tests for complete AI-plan snapshot CRUD and legacy JSON migration idempotency.
- Added three five-module SwiftData consistency tests covering stale migration-marker recovery, clear-all restart safety, and complete backup restoration across independent contexts.
- Added `UserRecipeRecord` and `RecipePreferenceRecord` to the existing shared native SwiftData container, keeping full recipe payloads lossless while allowing favorite/frequent preferences to exist independently for local or remote recipe IDs.
- Added an idempotent three-key recipe-store migration behind `native_km_recipe_store_swiftdata_migration_v1`, including SwiftData-wins merging, retained legacy fallback, empty-table self-healing, verification before completion, and corrupt-payload isolation.
- Added twelve recipe persistence tests covering migration, restart, CRUD, independent preferences, partial prepopulation, stale-marker recovery, clear/no-resurrection, corrupt-record isolation, migration failure, and existing duplicate rules.
- Added `ManualEntryExpiryUITests` and `ReceiptCompactListUITests` to `KitchenManagerUITests`, exercising the real running manual-entry and receipt-confirmation screens through debug-only launch-argument seed hooks (`UITEST_SEED_RECEIPT_ITEMS`, mirroring the existing `UITEST_SEED_INVENTORY` pattern).

### Changed

- API CORS preflight now permits the `Authorization` header required by the single protected `/api/me` endpoint; no existing endpoint was changed to require authentication.
- Replaced stale native SwiftUI source-shape assertions with semantic baseline checks for consumer Settings sections, inventory expiry assignment, callback-driven inventory navigation, shared Home status sheets, pantry settings, and persist-before-publish stock-in/consumption transactions. The navigation and persistence checks are also tied to their existing XCTest/XCUITest regression coverage; no production behavior changed.

- Rewrote `InventoryExpirySuggestion` so every ordinary ingredient — including dry goods, condiments, and other shelf-stable foods — now gets a real, finite suggested expiry date; only `常备`-categorized items still suggest no date, and an unrecognized name now defaults to a conservative 7 days instead of `nil`.
- `KitchenStore.mergeOrAppendInventoryItem` now falls back to a 7-day default expiry for non-staple items whose name is somehow still unmatched, so a normal add can never silently persist a `nil` `expiryDate`.
- Replaced the receipt confirmation list's one-`Section`-per-item layout (`ReceiptDraftSection`) with a single shared `Section` containing a compact two-line `ReceiptIngredientCompactRow` per item (~78-96pt tall instead of ~200pt+), fitting several more items per screen without changing the top-level receipt/manual chrome.
- Removed the manual-entry and receipt "设置保质期"/"启用保质期" toggle entirely; both flows now always show a plain `保质期` `DatePicker` with a short auto-suggestion caption, and `ManualInventoryDraft` tracks `hasUserEditedExpiry` (set only by a genuine `DatePicker` interaction) so further name edits never overwrite a date the user already chose.

- `KitchenStore.inventory` now persists through SwiftData while keeping its published-array API and notification behavior. Shopping, plans, weekly menus, consumption records, and recipes continue using their existing persistence paths.
- Native backup restore writes inventory to SwiftData before publishing restored state; clearing local data also deletes SwiftData inventory.
- `KitchenStore.shopping` now persists through SwiftData without changing the existing `KitchenShoppingItem` business model or backup format. Recipe/week-plan generation writes one final batch snapshot, while add/edit/toggle/delete/clear operations remain immediately observable.
- Shopping stock-in now persists inventory and shopping changes before publishing either array and rolls inventory back if shopping persistence fails, avoiding an in-memory half-applied operation.
- `KitchenStore.plans` now persists through SwiftData without changing `MealPlanItem`, the version-1 backup payload, or current recipe-ID resolution semantics. Adding a whole generated day publishes and writes one deduplicated final snapshot.
- Backup restore and local-data clearing now coordinate inventory, shopping, and today-plan persistence with best-effort rollback before publishing new in-memory state. Weekly plans and consumption records intentionally remain in UserDefaults.
- `KitchenStore.consumptionRecords` now persists through SwiftData without changing the record business model or backup JSON. Cooking deduction and undo persist local inventory/record snapshots before publishing; if consumption persistence fails, inventory persistence is restored best-effort and the in-memory operation is not applied.
- Backup restore and local-data clearing now include consumption records. Weekly plans, user recipes, favorites, frequent recipes, and settings intentionally remain on their existing persistence paths.
- Inventory, shopping, today-plan, consumption, and weekly-plan migrations now re-check retained legacy JSON when a completion marker exists but the corresponding SwiftData table is unexpectedly empty.
- Weekly-plan migration and save failures now expose the same user-facing notice/debug diagnostics as the other migrated modules instead of being silently ignored.
- `RecipeStore` now persists user recipes, favorites, and frequent-recipe flags through injected SwiftData repositories while retaining its existing observable API, remote/local merge ordering, library-mode setting, and save/import call sites. Preference writes and recipe snapshots are persisted before published state changes; clear failures restore the prior snapshot best-effort.
- The production app now injects recipe persistence from the same `KitchenPersistenceBundle` used by inventory, shopping, today plans, consumption history, and weekly plans. The existing version-1 kitchen backup shape remains unchanged and therefore still does not export user recipes or recipe preferences.

## 2026-07-11

### Added

- Refined native recipe classification into “食材” and “调料与辅料”: bean flour, starches, oils, sauces, spices, cooking liquids, and clearly auxiliary aromatics now share the existing `seasonings` field, while ambiguous flour and aromatics remain conservative.
- Added per-item editor controls to move, edit, add, or delete recipe items between the two classifications without creating a second recipe model.
- Added a native Home recipe-import option sheet with internal `NavigationStack` routes for link, image, AI, and manual creation.
- Added explicit native recipe creation routes for manual, link, image, and AI entry points; a focused medium shopping-item form; and a Home quick-record sheet using the existing receipt/manual flow.
- Added first-class `seasonings` support to native recipes with legacy classification, separate detail/editor sections, and an opt-in “包含调料” shopping-generation setting that defaults off.
- Added PWA-aligned status and quantity tracking modes to the existing native staple inventory source, including inline state cycling and quantity adjustment.
- Added native curated/full recipe-library selection, fallback loading, search/filter menus, inventory match badges, favorites, frequent recipes, edit overrides, reset, and user-recipe deletion.
- Added the native “常备货架” workflow with threshold-aware stock states, existing-inventory selection, presets, add/edit/detail views, filtering, single and batch restock actions, and optional transition-based local notifications.
- Added backward-compatible staple settings to native inventory records, including minimum quantity, default restock quantity, auto-suggestion, category, and notes.
- Added native JSON kitchen backup export/import covering inventory staple rules, plans, shopping, weekly menus, and consumption history.
- Added a unique native `HomeRecommendationStore` and `AIRecommendationService` for the SwiftUI home screen.
- Added relevance-ranked local recipe search across title, tags, ingredients, difficulty, cooking time, and supported preference phrases.
- Added native paged recommendation cards, synchronized custom page indicators, keyboard search submission, cancellable AI supplementation, and full AI batch replacement through the existing `/api/ai-chat` route.
- Completed the native link-import flow: Render-backed page extraction, AI structuring, editable recipe preview, validation, and saving into the recipe library.
- Added Codable local persistence for native user recipes, stored separately from remotely loaded recipes and restored on app launch.
- Added the complete native “AI 做菜” workflow: inventory selection, servings, flavor/cuisine/time/exclusion inputs, Render-backed generation, editable confirmation, regeneration, save, plan, and combined actions.
- Added a shared native recipe-draft editor and mapping layer used by both link import and AI generation.
- Added a shared native `AIChatService`, reused by home recommendations and full recipe generation instead of duplicating the `/api/ai-chat` client.
- Added native receipt capture and import: deferred camera authorization, photo-library selection, image preview/replacement/removal, orientation normalization, 2000px/3.6MB JPEG processing, cancellable vision recognition, editable confidence-aware drafts, optional expiry dates, and selected-item batch import.
- Added a Chinese camera usage description and simulator-safe camera availability handling.
- Added canonical/original URL, source platform, import time, source title, and optional author metadata to native user recipes, with backward-compatible optional decoding and source-based duplicate detection.
- Added six-stage native link-import progress, full-share-text URL detection, retry actions, and user-facing error categories for invalid/login-blocked pages, video, ASR, OCR, rate-limit, and AI-structure failures.

### Changed

- Tightened native inventory lifecycle cards to a denser 145–210pt adaptive grid without fixed card height, while preserving quantity, one expiry phrase, and the compact progress rail.
- Inventory detail navigation now uses one value-based `UUID` destination per tab stack, avoiding collection-built detail destinations; the detail form also exposes an explicit, user-controlled expiry-date section.
- Home “临期食材” and “待买清单” now share one material-backed grouped `List` sheet container, including the same navigation style and drag-dismiss behavior.
- The native Inventory tab now uses a PWA-aligned adaptive card grid for fresh foods: lifecycle color surfaces, one clear expiry phrase, compact four-point expiry progress, urgency sorting, VoiceOver labels, and a confirmed destructive swipe action replace plain rows.
- Added backward-compatible `createdAt` support for new native inventory batches. Its expiry progress falls back to `updatedAt` for older records and remains deliberately unknown when neither exists.
- Native pantry rows now show a distinct stock-to-minimum progress line for quantity-tracked staples; it is not conflated with fresh-food expiry progress.
- The native inventory “+” menu now contains only normal food entry and staple entry; receipt recognition remains available inside the shared recording flow.
- Native manual batch entry now uses the shared `IngredientParser`, including compact Chinese suffixes such as “韭菜花一份” and comma/Chinese-comma/dunhao/newline separation without splitting product names containing digits.
- Added one conservative native `InventoryExpirySuggestion` path in `KitchenStore.addInventory`: fresh produce, meat, seafood, dairy, eggs, tofu, fruit, and frozen foods receive category-specific defaults only when no explicit date exists; staples and shelf-stable goods remain undated.
- Receipt confirmation now preserves a recognized expiry date when available and otherwise pre-fills the same suggested date for user review.
- Home “记食材” and “导入菜谱” now both use the shared `HomeSheet` presentation. Link-import success closes that sheet and returns lightweight Home feedback without forcing a tab switch.
- Updated native AI generation, image import, recommendation, and server import prompts to explicitly place 豆粉、淀粉、生粉、水淀粉 and related cooking auxiliaries in `seasonings`.
- Simplified the native Settings form to appearance, recipe library, reminders, data, and About. AI/provider placeholders are removed from the release UI; developer context is conditionally compiled under `#if DEBUG`.
- Native user recipe overlays now take precedence over remote recipes with the same id and survive recipe-library switching; removing a remote override restores the base recipe.
- Native inventory consumption, manual/receipt/shopping stock-in, and restore operations now automatically recalculate pantry-staple status and restock suggestions through the existing `KitchenStore`.
- Native shopping insertion now merges normalized matching ingredients when units match or can be converted, while preserving incompatible-unit rows separately and identifying pantry-staple sources with user-facing copy.
- The native home recommendation area now keeps search/request state outside the view and preserves the existing batch when AI requests fail.
- Adding a recommendation to today's plan now gives lightweight haptic/toast feedback and visibly prevents duplicate additions.
- The native system `TabView` now uses iOS 27's `.tabBarMinimizeBehavior(.onScrollDown)` so the Liquid Glass tab bar minimizes and restores with system-recognized scrolling.
- The native “我的” root page now uses `Form`; the other tab roots retain their system `ScrollView` or `List` containers.
- `RecipeStore` now exposes separate remote and user recipe collections while preserving the existing merged `recipes` interface used by the app.
- Today-plan insertion now accepts an optional serving count while preserving existing callers and duplicate prevention.
- Saved generated recipes display seasonings and tips in dedicated sections without changing the remote recipe payload format.
- Extended `AIChatService` to carry an optional compressed image while continuing to use the existing Render proxy, so no API key or second AI client is added to the iOS app.
- Inventory batch import now normalizes common aliases/units, merges compatible name/unit/expiry batches without overwriting an existing expiry date, keeps differing expiry batches separate, persists through the existing `KitchenStore`, and shows a native success notice after returning to the Inventory tab.
- Replaced the native receipt placeholder and wired both Home and Inventory entry points to the same `RecordFoodSheet`; recognized pantry items now appear in the existing staples section.
- Switched the native link importer from the older `/api/xhs-extract` plus `/api/ai-parse` sequence to the existing complete `/api/recipe-import-from-url` pipeline, preserving the existing service type and recipe editor.
- Page extraction now returns canonical URL plus available source title/author metadata and distinguishes login-gated pages.
- Complete page text with continuous cooking steps now takes precedence and skips redundant video processing; sparse pages continue through video download, ASR, and frame OCR fallbacks.
- Recipe import now preserves missing quantities/units as empty values rather than inventing amounts; method numbering cleanup and ingredient/seasoning separation remain server-enforced.
- Combined video import now immediately removes its downloaded video, extracted audio, and OCR frames after text extraction; the short-lived retry cache contains text/diagnostics only.

### Removed

- Removed the native home recommendation “换一道” button, its hand-written drag gesture, and the unused all-recommendations destination.

### Verification

- Built successfully with Xcode 27 beta for the iPhone 17 Pro simulator and launched the resulting app.

---

## 2026-07-08

### Added

- Added `AGENTS.md` as the common entry point for AI coding agents.
- Added `AI_CONTEXT.md` to summarize product direction, architecture context, and AI feature boundaries.
- Added `PROJECT_STATUS.md` to track current project status, risks, and next priorities.
- Added `CODING_RULES.md` to define project-specific coding and architecture rules.
- Added `TESTING_RULES.md` to define automated and manual validation expectations.
- Added optional tool adapter files `CLAUDE.md` and `.cursorrules` for Claude Code and Cursor.

### Changed

- No application runtime code changed.

### Fixed

- No bug fixes in this documentation-only update.

### Notes

- These files are designed to complement the existing `PROJECT_GUIDE.zh.md`, `PROJECT_GUIDE.md`, and `PROJECT_WORKFLOW.md` documents.
- The repository should be treated as the source of truth for project progress, coding standards, testing standards, and AI-agent handoff.

---

## 2026-07-09

### Added

- Added a lightweight "unreasonable / dislike" feedback entry for AI recommendations: a "不合理/不喜欢" action on the AI creative recommendation card (home "今日" tab's "更多操作" sheet and the desktop hero panel card) and on the AI draft recipe detail page.
- Added `src/utils/ai-disliked-recipes.js` (`getDislikedAiRecipeNames` / `markAiRecipeDisliked` / `isAiRecipeDisliked`), backed by a new `S.keys.ai_disliked_recipes` (`km_v1_ai_disliked_recipes`) localStorage key, capped at 100 entries (oldest evicted first).
- Added `test/ai-disliked-recipes.test.mjs` covering storage limits, prompt injection, `validateRecommendationResult`/`processAiData` filtering, and the UI wiring.

### Changed

- `callCloudAI()` now injects disliked dish names into the recommendation prompt, asking the AI to avoid recommending the same or highly similar dishes.
- `validateRecommendationResult()` and `processAiData()` now drop any `local`/`creative` entry whose name matches a disliked entry, in addition to the existing dark-cuisine (`isSuspiciousAiCreativeDish`) filter.

### Fixed

- No unrelated bug fixes in this change.

### Notes

- Xiaohongshu import, receipt recognition, weekly-menu planning/date scheduling, the `plan` data structure, `server.js`, and the AI draft-method save flow were not touched.

---

## 2026-07-09 (2)

### Added

- Added a friendly fallback state for the home "今日" tab's "✨ 推荐" panel: when an AI recommendation result has zero cards left after `validateRecommendationResult`/`processAiData` filtering (dark-cuisine or user-disliked), the panel now shows "暂时没有合适的 AI 推荐" with three explicit actions — "换一批" (re-run the AI fetch), "看本地推荐" (switch to inventory-based local recommendations without calling AI), and "规划本周菜单" (switch to the 计划 tab, which already hosts the weekly-menu card).
- Added `test/ai-recommendation-empty-state.test.mjs` covering the no-crash/empty-array behavior of `processAiData`/`validateRecommendationResult` and the new `home-view.js` wiring.

### Changed

- `src/views/home-view.js`: `initRecsState()` now distinguishes "never fetched AI" (falls back to local recommendations, unchanged) from "fetched AI before, but the saved result is now empty after filtering" (new `mode: 'ai-empty'`), instead of silently reusing local recommendations either way.
- Extracted the "AI 换一批" fetch logic into a shared `triggerAiRefresh()` used by both the recommendation-tab footer button and the new empty-state's "换一批" button, so a fresh fetch that also filters down to zero consistently lands back on the same friendly empty state rather than a small inline status line.

### Fixed

- No unrelated bug fixes in this change.

### Notes

- Xiaohongshu import, receipt recognition, weekly-menu planning/date scheduling, the `plan` data structure, `server.js`, and the dislike-feedback recording logic (`src/utils/ai-disliked-recipes.js`) were not touched.

---

## 2026-07-09 (3)

### Fixed

- Prevented temporary `creative-*` AI recommendation ids from entering the saved meal plan.
- Creative recommendation cards and quick detail now direct users to complete/save the draft instead of offering a direct plan action.
- Saving a `creative-ai-temp` method draft now creates a unique user recipe with its own ingredients and routes to that new recipe, avoiding reuse of the temporary id or stale overlay methods.

### Notes

- Existing plan, weekly-menu AI suggestions, Xiaohongshu import, receipt recognition, and the recipe-generation prompt were not changed.

---

## 2026-07-09 (4)

### Fixed

- `todayISO()` (`src/storage.js`) now computes "today" from local date fields (`getFullYear`/`getMonth`/`getDate`) instead of `new Date().toISOString().slice(0, 10)`, which took the UTC calendar date. In negative-offset timezones (e.g. Toronto) this could roll the app's "today" over to tomorrow in the evening, throwing off plan dates, cook-log dates, expiry countdowns, and purchase dates.
- Added `parseLocalDate(iso)` and `addDaysISO(iso, days)` to `src/storage.js` as the shared local-date parsing/arithmetic helpers (DST-safe: operates on local calendar fields via `setDate`, not millisecond addition).
- Replaced the duplicated, timezone-fragile "tomorrow / day after tomorrow" `new Date(iso)` + `toISOString().slice(0, 10)` pattern in `src/recommendations.js`, `src/components/menu-plan.js`, and `src/views/recipe-detail-view.js` with `addDaysISO(today, 1)` / `addDaysISO(today, 2)`.
- `src/views/home/weekly-menu.js` no longer defines its own local `addDaysISO`; it now imports the shared, corrected implementation from `src/storage.js`.
- Added `test/date-utils.test.mjs` covering Toronto/Shanghai/UTC "today" calculation, DST-boundary date addition, and cross-month/cross-year arithmetic.

### Notes

- `src/migrations.js`'s internal `migTodayISO()` was intentionally left untouched — migrations are frozen snapshots of past behavior by design.
- `src/utils/prep-planner.js`'s `nextDateISO()` and `src/inventory.js`'s `daysBetween()` were left untouched: both already compute correctly (pure-UTC arithmetic on date-only strings is self-consistent and DST-safe) and are not part of this bug family.
- Xiaohongshu import, receipt recognition, AI recommendation logic, weekly-menu business logic, the `plan` data structure, `server.js`, backup logic, and migrations logic were not changed.

---

## 2026-07-09 (5)

### Fixed

- The v4 `plan` migration (`src/migrations.js`) used to rebuild each plan row as `{ id, servings, date }`, silently dropping `isCooked`, `cookedAt`, ad-hoc-cook `name`, and any other field. It now spreads the original item first (`{ ...item, id, servings, date }`) and only overrides the three fields it's meant to normalize.
- Applied the same "spread, don't rebuild" fix to the v2 inventory (`migNormalizeInventoryItem`) and shopping (`migNormalizeShoppingItem`) migrations, which had the identical bug: inventory items would lose `gear`/`unitType`/`opened`/`outOfStockAt`, and shopping items would lose `completedAt`/`remark`, on any migration running from a pre-v2 schema version.
- Updated a `migrations.test.mjs` assertion that had locked in the old (buggy) field-dropping behavior for plan rows; added dedicated tests for completed-plan-row preservation, ad-hoc-cook `name` preservation, unknown-field preservation, that id/servings/date normalization still works, and equivalent coverage for the inventory/shopping v2 fixes.

### Notes

- `plan`'s data structure, today's-recommendation logic, weekly-menu business logic, Xiaohongshu import, receipt recognition, backup logic, and `server.js` were not changed — only the migration functions and their tests.

---

## 2026-07-09 (6)

### Fixed

- `validateKitchenBackup()` (`src/backup.js`) used to only check top-level key names and JSON-serializability, not each key's internal shape. A syntactically valid backup with e.g. `overlay.recipe_ingredients.r1 = {}` (an object instead of an array) could pass validation and then crash `applyOverlay()` at `list.slice()`, breaking app startup after import.
- Added per-key structural validators/normalizers for `inventory`, `plan`, `shopping_items`, `settings`, and `overlay`: container-level shape errors (not an array/object, wrong nested shapes like `overlay.recipes.<id>` not being an object or `overlay.recipe_ingredients.<id>` not being an array) now throw and reject the whole backup with zero writes; item-level issues (missing identifying field, non-scalar `qty`/`unit`/`shelf`/`kind`/`storage` pollution, missing/invalid `id`) are sanitized per-item without failing the rest of the array. Oversized arrays (>5000 items) are rejected outright.
- Applied the same normalizers to the legacy (pre-`app`-field) backup import path (`keysFromLegacyData`) so old-format backup files get the same protection.
- `importKitchenBackup()` already validated fully before writing and rolled back on partial write failure — this change makes that "validate everything, write only after full success" guarantee also cover internal key structure, not just top-level shape.
- Added 10 tests in `test/backup.test.mjs` covering the `overlay.recipe_ingredients` crash reproduction, zero-write-on-rejection, non-array `inventory`/`plan`/`shopping_items`, invalid `settings` type, non-object `overlay.recipes` entries, oversized-array rejection, a still-importable valid backup, and a post-import `applyOverlay()` smoke test.

### Notes

- Xiaohongshu import, receipt recognition, AI recommendation logic, weekly-menu logic, the `plan` data structure, `server.js`, and migration logic (`src/migrations.js`) were not changed.

---

## 2026-07-09 (7)

### Fixed

- `sw-register.v18.js` used to hard-code `caches.keys().filter(key => key !== 'km-v18').map(caches.delete)` on every page load. Since `sw.v18.js`'s `CACHE_NAME` moves forward with every release via `scripts/stamp-version.js` (currently `km-v235`), that stale `'km-v18'` string meant the register script was deleting the *current*, just-precached cache on startup, making offline precaching unreliable.
- Removed the cache-deletion logic from `sw-register.v18.js` entirely. The register script now only unregisters stale Service Worker *registrations* (script URL not matching `sw.v18.js`) and handles `register`/`updatefound`/reload-prompt duties. Cache cleanup is now solely owned by `sw.v18.js`'s `activate` handler, which already correctly deletes every cache except its own (dynamic) `CACHE_NAME`.
- Added two `test/version-consistency.test.mjs` guards: `sw-register.v18.js` must not contain a hard-coded `'km-v18'` string, and must not call `caches.keys()`/`caches.delete()` at all.

### Notes

- `sw.v18.js`'s `activate` handler was not changed — it already owned cache cleanup correctly.
- No business code, AI, Xiaohongshu import, receipt recognition, weekly-menu, or `plan` data structure logic was touched.

---

## 2026-07-09 (8)

### Fixed

- `getClientIp()` (`src/server/services/rate-limit.js`) used to trust the client-supplied `X-Forwarded-For` header first, before falling back to `req.ip`/`req.socket.remoteAddress`. Since the app has no `trust proxy` configuration, a non-browser client could send a different `X-Forwarded-For` value on every request and get a fresh rate-limit bucket every time, bypassing the AI/media/import rate limits entirely.
- `getClientIp()` now only uses `req.ip || req.socket?.remoteAddress || 'unknown'` — no header parsing. `req.ip` is Express's own resolution of the connection address (governed by `trust proxy`, currently unset, so it equals the real socket address). If the app is ever deployed behind a trusted reverse proxy, that should be enabled via an explicit `app.set('trust proxy', ...)` call, not by hand-parsing headers in the rate limiter.
- Added `test/rate-limit-client-ip.test.mjs` (6 tests): `getClientIp` ignores `X-Forwarded-For` and falls back correctly when `req.ip` is absent; two requests with the same `remoteAddress` but different `X-Forwarded-For` land in the same rate-limit bucket; different `remoteAddress` values land in different buckets.
- Updated a stale `ai-provider-mode.test.mjs` assertion that had locked in the old header-trusting behavior.

### Notes

- `server.js` was not touched (no large-scale refactor); only `src/server/services/rate-limit.js` and its tests changed. Concurrency pool / temp-directory quota work is explicitly out of scope for this change.

---

## 2026-07-09 (9)

### Added

- The full kitchen backup now covers two previously-missing pieces of user-persistent data: `ai_disliked_recipes` (the "不合理/不喜欢" AI-recommendation feedback list) and `receipt_aliases` (product-name corrections the user taught the receipt scanner). Both were real user data that used to be silently lost on backup/restore.

### Fixed

- `src/utils/receipt-aliases.js` no longer hard-codes its own `'km_v1_receipt_aliases'` string; it now reads `S.keys.receipt_aliases` (added to `src/storage.js`, same literal value, so no existing user data changes key).
- Added structural validators to `src/backup.js` for both new keys, following the same "container-shape errors reject the whole backup, item-level issues are sanitized" policy as the rest of the backup importer: `ai_disliked_recipes` must be a plain object, each entry needs a non-empty dish-name key, `reason`/`ts` are safely coerced, and the import caps at 100 entries (same as the runtime limit in `ai-disliked-recipes.js`, keeping the newest by `ts`). `receipt_aliases` must be a plain object with non-empty, trimmed string keys and values, capped at 500 entries.
- Documented the backup key list in `src/backup.js` as three categories (user-persistent data that must be backed up, rebuildable caches that don't need to be, device-local UI state that's intentionally excluded) so future additions land in the right bucket without re-deriving the reasoning.

### Notes

- Added 10 tests to `test/backup.test.mjs` covering export/import round-trips for both keys, the underlying storage key staying `km_v1_receipt_aliases`, real `isAiRecipeDisliked()`/`lookupReceiptUserAlias()` hits after restore, rejection of non-object structures, sanitization of malformed entries, oversized-map truncation, and old backups that predate these keys still importing cleanly.
- Xiaohongshu import, AI prompts, weekly-menu logic, the `plan` data structure, `server.js`, the migration schema version, and UI were not touched — this was a backup-scope-only change plus its tests.

---

## 2026-07-09 (10)

### Added

- `mustSave(key, value, message)` in `src/storage.js`: wraps `S.save()` and throws an `Error` with `.code = 'STORAGE_WRITE_FAILED'` when the write fails (quota exceeded, private-mode restrictions, etc.), instead of the silent `false` that most callers never checked. Also added the single shared user-facing message, `STORAGE_WRITE_FAILED_MESSAGE`.

### Fixed

`S.save()` returning `false` on failure was widely ignored, so a failed write still showed a success toast — the data would then disappear on refresh. Wired `mustSave` into the six key user-data paths named in this pass, without a codebase-wide mechanical replacement:

- **inventory**: `saveInventory()` now throws on failure; `inventory-view.js`'s batch "记食材" flow catches it and shows the unified failure message instead of "已加入 N 样食材".
- **plan**: `addRecipeToPlan()` now throws on failure; `addRecipeToPlanWithMissingCheck()` catches it, returns `{ added: false, ... }`, and shows the unified message instead of "已加入{计划}" (and never reaches the missing-ingredient confirm dialog on a storage failure).
- **shopping_items**: `saveShoppingItems()` now throws on failure (its one internal opportunistic self-heal call inside `loadShoppingItems()` catches and logs instead of propagating, since that's not a user-initiated save); `shopping-view.js`'s quick-add flow catches the explicit save and shows the unified message instead of "已加入买菜清单".
- **settings**: the BYOK API key/URL/model save button in `settings-view.js` now uses `mustSave` and shows the unified message instead of "已保存，刷新后生效" on failure.
- **overlay / user recipes**: `saveOverlay()` now uses `mustSave` (was already throwing, message aligned). Wired explicit handling into the three most-used save points: `recipe-editor-view.js`'s main save button, `recipe-create-modal.js`'s create-recipe modal (already had a catch block; added the specific storage-failure message), and `recipe-detail-view.js`'s "保存到菜谱" for AI-generated methods.
- **backup import**: `restoreBackupEntries()` already validated everything and rolled back the full snapshot on any mid-import failure — no behavior change needed there, only aligned its error message to reference the same unified text.

### Notes

- Added `test/storage-write-failures.test.mjs` (17 tests) using a real `localStorage.setItem` throwing `DOMException('Quota exceeded', 'QuotaExceededError')`: `S.save`/`mustSave` behavior, each of the six save paths throwing/not-silently-succeeding, source-level checks that each UI entry point's success toast sits after (and is skipped by) the failure branch, the backup-import rollback, and that normal (non-failing) writes are unaffected.
- Deliberately did not touch every scattered `S.save(S.keys.plan, ...)` / inventory / overlay call site (e.g. plan removal on "标记做完", servings edits, the other ~7 `saveOverlay` callers) — only the primary user-facing save-and-confirm flow per category, per "first phase, no codebase-wide mechanical replacement." Non-critical caches (`local_recs`, `ai_recs`, `rec_time`, etc.) were intentionally left on the old silent `S.save()` boolean.
- AI prompts, the Xiaohongshu import flow structure, weekly-menu business structure, the `plan` data structure, `server.js`, and broad UI layout were not touched.

---

## 2026-07-09 (11)

### Changed

- `.github/workflows/deploy.yml`'s `test` job now runs the full validation suite instead of just `node --test`: `npm ci` → `npm test` → `npm run validate:recipe-packs` → `npm run validate:recipe-pack-data` → `npm audit --omit=dev --audit-level=high`, on a Node `['18', '22']` matrix (`fail-fast: false` so both results are visible). Node 18 stays in the matrix because `package.json`'s `engines.node` is `>=18` and all three production dependencies (axios, express, ffmpeg-static) declare Node 18 compatibility — nothing here narrows that.
- Added a `pull_request` trigger (targeting `main`) alongside the existing `push`/`workflow_dispatch` triggers, so PRs get the same validation gate before merge.
- `build` and `deploy` now both carry `if: github.event_name != 'pull_request'`, so PR runs stop at the `test` job and never build or deploy the Pages artifact; `push`/`workflow_dispatch` keep deploying as before via the existing `needs` chain (`build` needs `test`, `deploy` needs `build`).
- Scoped the `concurrency` group to `pages-${{ github.ref }}` (was a single fixed `"pages"` group) so a PR run and an in-progress `main` deploy no longer cancel each other.
- Added `cache: 'npm'` to `actions/setup-node` for the `test` job's dependency install.

### Notes

- Added `test/workflow-config.test.mjs` (8 tests): a dependency-free block-indentation/no-tab sanity check on the workflow YAML, plus source assertions for the triggers, the Node matrix, the exact `test`-job step order, the `build`/`deploy` gating and `needs` chain, and that no `run:` command is duplicated within the `test` job (matrix-driven repetition across Node versions is expected and out of scope for that check).
- `package.json`/`package-lock.json` were not touched — all required commands were either already-existing npm scripts (`test`, `validate:recipe-packs`, `validate:recipe-pack-data`) or plain `npm` CLI invocations (`npm ci`, `npm audit`), so no new scripts were necessary.
- No business code was touched; this was a CI-configuration-only change.

---

## 2026-07-10

### Added

- `src/server/config.js`: `parseTrustProxyHops()` + `TRUST_PROXY_HOPS`/`TRUST_PROXY_HOPS_INVALID_RAW`, parsing the `TRUST_PROXY_HOPS` env var. Only positive-integer strings (`'1'`, `'2'`, ...) are accepted; unset/empty/`'0'` normalize to `0` (the local-dev default, not an error); `'true'`, negative numbers, decimals (`'2.5'`), and any other non-digit string are treated as invalid and safely fall back to `0`.
- `server.js`: right after `const app = express()`, reads those two values and calls `app.set('trust proxy', TRUST_PROXY_HOPS)` only when it's a positive integer; otherwise trust proxy stays off. Logs a one-line status (`[server] trust proxy hops: 1` or `[server] trust proxy disabled`) and, when the env var was invalid, a one-line warning naming the bad raw value — never a user IP or the `X-Forwarded-For` header contents.

### Fixed

Render Web Service's public entry point is Render's own edge proxy — the Node process's `req.socket.remoteAddress` is always that proxy, never the end user. Without `trust proxy` configured, `getClientIp()` (`req.ip || req.socket.remoteAddress`) resolved to the same proxy address for every visitor in production, so the AI/import rate limiters were bucketing effectively all users together instead of per-visitor. `TRUST_PROXY_HOPS=1` on Render now makes Express resolve `req.ip` to the real client address forwarded by that one trusted hop, while still ignoring any additional `X-Forwarded-For` entries a client prepends on their own.

`src/server/services/rate-limit.js`'s `getClientIp()` was intentionally left unchanged (`req.ip || req.socket?.remoteAddress || 'unknown'`) — it already delegates entirely to Express's own trust-proxy-aware IP resolution and never reads `X-Forwarded-For` by hand.

### Notes

- Added `test/trust-proxy.test.mjs` (17 tests), including real integration tests that start an actual `express()` app on an ephemeral port and hit it with Node's built-in `http` client: `TRUST_PROXY_HOPS` string-parsing edge cases (`'true'`/`'2.5'`/`'-1'`/`'1'`/whitespace); `req.ip` resolution under `trust proxy = 1` with no `X-Forwarded-For`, a single forwarded IP, and a client-forged prefix (`"1.2.3.4, 203.0.113.10"` must resolve to `203.0.113.10`, never `1.2.3.4`); `req.ip` staying pinned to the socket address when trust proxy is `0`; real rate-limit bucket assignment showing the same trusted client landing in one bucket regardless of forged prefixes, and different clients landing in different buckets; and source guards against `app.set('trust proxy', true)`, hand-rolled `X-Forwarded-For` reads, and env-var parsing scattered outside `config.js`.
- Documented `TRUST_PROXY_HOPS=1` in `PROJECT_WORKFLOW.md` (new §12.9), including the explicit warning not to guess `2` if a CDN is ever added in front of Render without first verifying the real hop count, and that `true` must never be used.
- Rate-limit thresholds, media pipeline, AI prompts, the Xiaohongshu import flow, the frontend, and the `plan` data structure were not touched — this was a trust-proxy-configuration-only change plus its tests and docs.

---

## 2026-07-10 (2)

### Changed

- Aligned the Chinese and English project guides, route comments, status document, and manual test checklist with the current navigation contract: empty hash redirects to `#today`; `#today` is the kitchen home; `#inventory` is food inventory; and `#shopping` is the shopping list.
- Replaced outdated four-tab and "shopping contains full inventory" descriptions with the current five-entry dock: 今日 / 食材 / 买菜 / 菜谱 / 我的.

### Added

- Added a route-behavior test that executes the current `app.js` `onRoute()` body in a controlled harness and verifies empty-hash redirect, view selection, and dock active-state semantics.

### Notes

- No route branch, navigation link, page layout, AI/import flow, receipt recognition, `plan` data structure, or `server.js` behavior changed.
- The app still does not add a redirect for former `#inventory` home bookmarks; this pass records the current product behavior and does not create compatibility behavior.

---

## 2026-07-10 (3)

### Changed

- Weekly menu planning now distinguishes meal batches from dishes per meal. The modal defaults to two dishes per meal, and both AI and local fallback plans target `mealCount × dishesPerMeal` dishes, capped at 12.
- AI results carry a transient `mealIndex` / `mealLabel`, are rendered in meal groups, and synchronize the planned date within a group. Joining the plan still writes one independent recipe row per dish; the `plan` schema was not changed.
- Updated the weekly-menu prompt to request balanced home-style pairings, discourage duplicate heavy/protein dishes in one meal, and prefer reheatable dishes with appropriate servings for lunchbox plans.

### Added

- Added behavior tests for the 3 meals × 2 dishes path, grouped dates, synchronized date changes, per-dish plan mappings, local fallback, invalid `mealIndex` recovery, the 12-dish cap, and lunchbox prompt rules.

### Notes

- Xiaohongshu import, receipt recognition, today recommendations, AI draft details, shopping data, and the server structure were not changed.
# 2026-07-10 — Native iOS prototype

### Added

- Added a standalone SwiftUI Xcode project in `ios-native/Kitchen Manager`.
- Added native home, recipe list/detail, manual recipe entry, link import, recipe API service, and shared recipe store scaffolding.

### Fixed

- Removed duplicate Swift declarations from `ContentView.swift` by separating models, services, and views into their dedicated files.
- Restored a clean Xcode build with zero compiler issues.
- Aligned the native app's five-tab navigation with the PWA (`Today / Inventory / Shopping / Recipes / Settings`).
- Moved recipe creation/import behind the Recipes toolbar and added native Inventory, Shopping, and Settings page shells.
- Rebuilt the native Today page around the PWA's current status-header plus Plan/Recommendations panel design.
- Added native sheets for expiry, pending shopping, food entry, recipe preview, all recommendations, recommendation actions, cooking calibration, weekly menu planning, and recipe import.
- Added a shared, locally persisted native kitchen store and wired Today, Inventory, Shopping, and Settings to the same inventory/plan/shopping state.
- Reworked the native Today screen as a close SwiftUI reproduction of the deployed PWA mobile home: matching cold-gray gradient, typography hierarchy, compact status pills, custom capsule tabs, search block, white recommendation card, recipe dots/cycling, and two quick-action cards.
- Added `AppTheme.swift` using the PWA's real light/dark design tokens instead of treating system green as the global app color.
- Replaced the visible system tab bar with a SwiftUI floating glass dock while retaining native `TabView` selection and the stable five-tab order.
- Changed the home recommendation “View” action to navigate to the existing native `RecipeDetailView`; existing recipe loading, list/detail, link import, and AI parsing services remain intact.

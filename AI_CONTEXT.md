# AI_CONTEXT.md

This file gives AI coding tools the product and architecture context for Kitchen Manager.

It should be read together with:

- `AGENTS.md`
- `PROJECT_GUIDE.zh.md`
- `PROJECT_WORKFLOW.md`
- `PROJECT_STATUS.md`
- `CODING_RULES.md`
- `TESTING_RULES.md`

---

## 1. Project Identity

Project name: Kitchen Manager / 厨房管理

Kitchen Manager is a local-first home kitchen assistant. It helps the user answer practical daily cooking questions:

- What do I have at home?
- What is about to expire?
- What can I cook today?
- What ingredients am I missing?
- What should go into the shopping list?
- After cooking, how should the inventory be updated?
- How can I import or draft recipes with AI while keeping control?

This is not an enterprise inventory ERP. It should feel like a low-friction daily kitchen companion.

---

## 2. Product Principles

### Local-first

User kitchen data should primarily stay in the browser through `localStorage`.

The app may call AI services only for user-triggered features such as recipe import, recipe drafting, receipt recognition, or recommendation assistance. The app must not silently upload broad personal kitchen data.

### Trust before automation

The app should help the user, not pretend to know things it does not know.

Important examples:

- AI-generated recipes are drafts.
- Imported recipes need review.
- Receipt recognition needs confirmation before writing inventory.
- Cooking completion should deduct inventory only after user confirmation.
- Incomplete Xiaohongshu/video extraction must be marked as uncertain instead of silently producing a fake complete recipe.

### Mobile-first

The primary usage scenario is a phone in or near the kitchen. New UI should work first at around 390px width.

### Small safe iteration

This project should evolve through small, testable, reversible changes. Avoid large rewrites.

---

## 3. Current Technical Context

Kitchen Manager currently uses:

- Plain `index.html`, `styles.css`, and native JavaScript modules.
- `app.js` as the main browser routing/rendering entry.
- `src/views/*` for page-level render functions.
- `src/components/*` for reusable UI pieces.
- `src/*.js` for domain logic such as storage, inventory, ingredients, recommendations, shopping, staples, AI, backup, migrations, theme, PWA install, and recipe packs.
- `server.js` plus `src/server/**` for Express static hosting, AI proxying, link/page extraction, SSRF protection, rate limiting, media pipeline, JSON repair/parsing, and related server-side helpers.
- `data/*` for recipe libraries and recipe completion overlays.
- `test/*` for Node built-in test runner tests.
- `scripts/*` for validation, curation, and version/cache stamping utilities.
- `supabase/*`, `src/server/auth/*`, and `src/server/sync/*` for identity and the Phase 2A synchronization foundation. Migration `20260713000200` is deployed and live-verified on development only. The contract uses independent household/user scope cursors, an allowlisted atomic mutation RPC, idempotency ledger, version conflicts, soft-delete tombstones, and snapshot-backed change feed. No production migration, enabled iOS/PWA automatic sync, upload, merge, account-scoped container switch, invitation, or OAuth flow is implemented.
- Native iOS now contains a Phase 2A-3 sync boundary under `KitchenManager/Synchronization`: DTOs, separate SwiftData metadata/pending/cursor records, transport, disabled coordinator, and inventory POC. `SYNC_ENABLED` is committed as `NO`; there is no App startup, login, timer, background, Guest scan/upload, or hosted-write call site. Treat `runOnce` as test/future explicit infrastructure, not an enabled product feature.
- Phase 2A-4 adds only a Debug-only, locally gated explicit inventory smoke runner. It has no product call site and may operate on one generated marker record in the authenticated development household after a human starts it. The real iOS hosted lifecycle, soft-delete cleanup, Guest boundary, session restore, and disabled-default restoration passed on iPhone 17 Pro / iOS 27.0. **Phase 2A-4 is checkpoint-complete**: final Node (786/786), final serial iOS Unit/UI (469 distinct tests, 0 failed, 1 safe skip — `HostedSyncSmokeUITests` skips without credentials and was not excluded), and Debug build (0 errors/warnings) all passed; see `docs/IOS_SYNC_PHASE2A4_VALIDATION.md`.
- Phase 2B-1 adds a user-initiated, explicitly-confirmed Guest **inventory** merge under `KitchenManager/Synchronization/GuestMerge*.swift` + `KitchenManager/GuestMergeViews.swift`: read-only detection, a persisted `GuestMergeSession` state machine keyed by `(userId, householdId, inventory_item)`, pure local matching/plan generation with hash re-validation, explicit conflict choices (no auto-resolution), and upload/rollback through the existing `SyncCoordinator`/`InventorySyncAdapter`/`ExpressSyncTransport` only — no second client. `INVENTORY_SYNC_ENABLED` (default `NO` everywhere) independently gates this feature from `SYNC_ENABLED`; a confirmed merge builds its own scoped `SyncConfiguration(isEnabled: true)` rather than touching the global flag. Only inventory is ever touched — Shopping/Today Plan/Weekly Plan/Recipes are counted for display only. This phase is mock/UI-tested and disabled-by-default only; no real hosted Guest merge has been performed (that is Phase 2B-2). See `docs/GUEST_MERGE_PHASE2B.md` and `docs/INVENTORY_MERGE_CONTRACT.md`. No automatic sync, background sync, Realtime, or household invitation exists yet.
- **A corrective/hardening pass on Phase 2B-1** followed a design review. Matching key is `normalizedName + normalizedUnit` only — `quantity` is compared *after* matching as a mutable business field and is never an identity key; a new `ExpiryIdentity` (`.compatible`/`.incompatible`) makes expiry-based identity uncertainty explicit, and a new `metadataMismatch` conflict reason (`InventoryMergeConflictReason`) catches `isStaple`/staple-category/threshold/restock/tracking/availability differences so they are never silently overwritten. The token path changed from a `View`-held `AccessTokenReader` closure to `confirmMerge(authStore:)`/`rollback(authStore:)` taking the live `AuthStore` reference, backed by a private `AuthStoreCredentialProvider` (`weak var authStore`) that re-queries `currentAccessToken()` fresh per network call — no `View`, `@Published`/`Sendable` model, SwiftData record, or `UserDefaults` value ever holds a token, and a mid-run sign-out starves further requests. `test/ios-native-guest-merge-phase2b1.test.mjs` now source-enforces the no-View-token-access rule (3 new assertions); `GuestMergeTests.swift` gained 13 new cases for the matching/expiry/metadata rules, sign-out refusal, snapshot-cap-never-truncates-the-plan, corrupted-record-decodes-safely, and plan-hash order-independence/invalidation. Full regression after the fixes: Node 802/802, iOS Unit 502/502 + UI 4 (1 safe skip), Debug build 0 errors/0 new warnings, `npm audit`/`git diff --check` clean.
- **Phase 2B-2 ran a controlled real hosted Guest inventory merge smoke** against the development Supabase project through the existing (only) Render deployment — a new Debug-only `GuestMergeSmokeRunner`/`HostedGuestMergeSmokeTests` harness under `KitchenManager/Synchronization/GuestMergeSmoke.swift` + `KitchenManagerTests/HostedGuestMergeSmokeTests.swift`, gated by a new independent `GUEST_MERGE_SMOKE_ENABLED` flag (default `NO`, mirrors `SYNC_SMOKE_ENABLED`) and two real test-account credential pairs from an ignored environment file, mirroring the Phase 2A-4 `SyncSmokeRunner` pattern exactly and running entirely through the real, unmodified `GuestMergeController` against an isolated in-memory container (never the developer's real local Guest inventory). This required completing the piece Phase 2B-1 deliberately deferred: `preparePreview` gained an optional `remoteTransport` parameter (default `nil`, zero behavior change for ordinary preview) that performs one read-only pre-merge `fetchChanges` pull to populate `knownRemoteItems`, plus a `remoteVersion` field on `RemoteInventorySnapshotItem`/`InventoryMergeCandidate` so `confirmMerge` seeds the correct baseVersion for a same-id update against a remote record this device only just learned about — without this, such an update would send a stale `baseVersion 0` and be correctly rejected by the server as a conflict. The real run verified all of: zero-write preview, create, duplicate-retry idempotency (same mutationId/entityId/payload/baseVersion resent), quantity/expiry/metadata conflicts against real pre-existing remote counterparts, ambiguous duplicate never auto-selected, plan-drift invalidation, restart recovery, logout refusing further requests then resuming after re-login, real cross-account isolation, rollback with a final pull observing the delete tombstone, and the Guest data boundary unchanged. A confirmed follow-up (fixed in Phase 2B-2.5, next): `keepBoth` on a same-id conflict did not allocate a new id (only well-defined for the different-id ambiguous case). All marker rows were soft-deleted afterward (verified via a new `scripts/cleanup-guest-merge-smoke-markers.mjs`, authorized user-level API only); both new/changed flags were restored to `NO` in the ignored `Local.xcconfig`. Final regression: Node 802/802, iOS Unit 507/507 (1 safe skip) + UI 4 (1 safe skip), Debug build 0 errors/0 new warnings, `npm run smoke:sync` passed, `npm audit`/`git diff --check` clean. See `docs/GUEST_MERGE_PHASE2B2_VALIDATION.md`.
- **Phase 2B-2.5 fixed that same-id `keepBoth` gap.** `InventoryMergeCandidate` gained `forkedLocalItemId: UUID?` — part of the already-persisted `plan` (no new SwiftData model). `applyingChoice(.keepBoth)` on a same-id match (`remoteItemId == localItemId`) now sets `forkedLocalItemId = forkedLocalItemId ?? UUID()` (allocated once, reused verbatim on every later call — repeat choice, repeat confirm, or after an App restart re-decodes the same persisted candidate); the different-id ambiguous-duplicate case stays `nil` and is completely unaffected. `GuestMergeController.confirmMerge`'s staging loop checks `forkedLocalItemId` first: when set, it copies the local item under the forked id and stages that as a plain create at baseVersion 0 (guarded against re-staging on retry) — the original, certain entity is never touched by that candidate at all (a true no-op, like `keepRemote`). The read-back loop keys `createdEntityIds` off the forked id, so `rollback` only ever soft-deletes the fork, never the original; the original local `InventoryRecord`'s id is never mutated, and the fork becomes a genuinely independent second local record. Added 8 new offline `GuestMergeTests` cases (fork allocation/baseVersion-0/expiry+metadata variants/idempotent repeat-confirm/restart-survival/rollback-scoped-to-fork/keepLocal+keepRemote-never-fork/different-id-regression) and 6 new Node semantic-guard assertions. A new minimal, dedicated real hosted smoke (`GuestMergeSmokeRunner.runIdentityForkMinimalSmoke` / `HostedGuestMergeSmokeTests.testControlledDevelopmentSameIdKeepBothIdentityFork` — deliberately not a repeat of the full Phase 2B-2 18-point matrix) confirmed on the real development backend that a same-id `keepBoth` produces two real, distinct remote records and that rollback removes only the fork; passed on the first attempt, zero marker rows left before or after (verified via the existing cleanup script). Safety flags restored to `NO`. Final regression: Node 808/808, iOS Unit 515/515 (2 safe skips) + UI 4 (1 safe skip), Debug build 0 errors/0 new warnings, `npm run smoke:sync`/`npm audit`/`git diff --check` clean. See `docs/GUEST_MERGE_PHASE2B2_VALIDATION.md`. Still not entering Phase 2B-3.
- **Phase 2B-3 turned the validated merge engine into a formal UI.** New independent flag `InventoryMergeUIConfiguration`/`INVENTORY_MERGE_UI_ENABLED` (default `NO` everywhere) gates the merge/sync UI separately from `INVENTORY_SYNC_ENABLED` (network capability) — both must be on. `GuestMergeViews.swift`'s `InventoryMergePreviewView` now shows the target household name, `InventoryMergePlan.knownRemoteItemCount` (cloud-side known items from the Phase 2B-2 pre-merge read), and per-type conflict breakdown (`quantityConflicts`/`expiryConflicts`/`metadataConflicts`/`ambiguousConflicts`, new computed properties). `InventoryMergeConflictChoice` gained a fourth case, `.skip` ("稍后处理") — behaviorally identical to unresolved (never uploads, never forks) but recorded so it stops nagging; `InventoryMergeConflictView` also now shows local-vs-remote expiry and an explicit notice when `keepBoth` on a same-id conflict will fork a new record. New `GuestMergeController.syncNow(authStore:householdId:)` — the only production `runOnce` call site besides `confirmMerge`/`rollback`, always triggered by "立即同步库存", scoped to `.inventoryItem` only, mapped through a new `userFacingSyncError(_:)` — plus `pendingInventoryCount(householdId:)` (read-only, display-only) and a new `InventorySyncStatusView` shown whenever signed in with a household. Explicitly decided but deferred: whether ordinary post-merge Inventory CRUD should auto-stage mutations — the conservative policy (only when local `SyncMetadata` is already `.synced`, merge complete, flag on) is documented but not wired into `KitchenStore`, since that would require threading Auth/sync context into a component (`KitchenStore`) that has been intentionally decoupled from `AuthStore` since Phase 1. Added 7 new `GuestMergeTests` cases, 19 new Node semantic-guard assertions (including a hard count that `runOnce` appears in exactly 3 places in `GuestMergeController.swift`), and 1 real credential-free XCUITest confirming Guest mode shows no merge/sync UI before sign-in. See `docs/INVENTORY_SYNC_PHASE2B3.md`. Still no automatic sync anywhere; nothing pushed.
- **Phase 2B-4 wired ordinary Inventory CRUD to the sync engine.** New `InventorySyncEnrollment` (`InventorySyncEnrollmentRecord`, persisted per `userId`+`householdId`; `notEnrolled/mergeRequired/enrolled/paused/revoked`) — only `GuestMergeController.confirmMerge`'s success branch ever moves it to `.enrolled` (Node-verified exactly one such site). New centralized `InventorySyncEligibility.evaluate(isFeatureEnabled:userId:householdId:enrollment:existingMetadata:intent:)` — the single place deciding whether a create/update/delete may stage a mutation (`.localOnly`/`.eligible`/`.blockedByConflict`/`.blockedByPendingDelete`), never duplicated inline in a View or CRUD method. `KitchenStore` gained exactly one new, optional, generic property (`onInventoryChanged: (([InventoryItem], [InventoryItem]) -> Void)?`, fired from `inventory`'s `didSet` only when `!isLoading && !suppressInventoryPersistence`) — `KitchenStore.swift` still imports nothing about Auth/Sync; the only wiring site is `ContentView.swift`'s `KitchenManagerApp.init()` (the composition root), reading the current signed-in user/household fresh per call. New `SwiftDataSyncPersistence.stageInventoryMutation(entityId:scope:operation:payloadData:now:)` — one atomic transaction staging `SyncMetadata` + a coalesced `PendingMutation` (at most one pending mutation per entity: create+update replaces the payload in place keeping the same `mutationId`/`baseVersion`; create+delete cancels entirely since nothing was ever sent; update+delete merges into one delete intent using the real known `remoteVersion`; duplicate delete is a no-op) — deliberately never writes `InventoryRecord` itself, since `KitchenStore`'s own `InventoryPersistenceProtocol` already wrote it through a separate `ModelContext` (a dual-context race identified during the mandatory pre-implementation audit, documented in `docs/INVENTORY_CRUD_SYNC_PHASE2B4.md`). Delete always stages a soft-delete tombstone (`SyncMetadata.state = .pendingDelete` + `deletedAt`), never a physical remote delete. Added 21 new `GuestMergeTests` cases, 14 new Node semantic-guard assertions, and a minimal real hosted smoke (`GuestMergeSmokeRunner.runInventoryCrudSyncMinimalSmoke` / `HostedGuestMergeSmokeTests.testControlledDevelopmentInventoryCrudSync`, marker `__inventory_crud_smoke_<id>`) confirming create/update/delete each apply correctly via manual sync (remote version advancing 0→1→2, then a soft-delete tombstone), a repeat sync is a harmless no-op, and a Guest-only control item is never staged — passed on the first attempt, zero marker residue (the cleanup script now sweeps both marker prefixes). Full regression: Node 836/836, iOS Unit 540/540 (3 safe skips) + UI 5/5 (1 safe skip), Debug build 0 errors/0 new warnings. See `docs/INVENTORY_CRUD_SYNC_PHASE2B4.md` and `docs/INVENTORY_MUTATION_COALESCING.md`. Still no automatic sync anywhere; nothing pushed.
- **Phase 2B-5 is a release-readiness/dogfood audit, not a feature phase — conclusion: No-Go for production.** New `InventorySyncDogfoodConfiguration` (`INVENTORY_SYNC_DOGFOOD_ENABLED`/`INVENTORY_SYNC_DIAGNOSTICS_ENABLED`, both default `NO`) only unlocks a read-only diagnostics screen and confirms existing manual-only paths — dogfood enabling never implies automatic sync. New `InventorySyncEligibility.blockedByQueueFull` bounds `PendingMutation` growth per scope (`maxPendingMutations`, default 200) without ever dropping a delete or blocking coalescing into an already-staged row. New `InventorySyncDiagnosticsSnapshot` (redacted: no email/password/token/full UUID/household id/payload/item name — enforced by a dedicated test) and `InventorySyncConsistencyChecker` (14 pure, read-only checks — orphan metadata, scope/enrollment mismatch, missing remoteVersion, conflicted-with-no-pending, tombstone-still-visible, duplicate pending, duplicate fork id, cursor regression, etc. — never auto-fixes) back a new dogfood-gated "库存同步诊断" screen (`InventorySyncDiagnosticsView.swift`) at the bottom of the account page, offering only refresh/export/retry-manual-sync/help — never delete/clear/force-overwrite. `GuestMergeController` gained `dogfoodConfiguration`, `showsDiagnosticsScreen`, `lastSyncStartedAt`/`lastSyncCompletedAt`, `diagnosticsSnapshot(...)`, `consistencyCheck(...)`. Verified by test (not a new gate actor) that `syncNow`'s existing `@MainActor` `guard !isSyncing` already provides correct single-flight semantics. Added 10 new `GuestMergeTests` cases (82/82, up from 72); full iOS Unit regression 550/550 (up from 540), 0 regressions. Explicitly not done this phase, tracked as open Go-blockers in `docs/INVENTORY_SYNC_GO_NO_GO.md`: weak-network/error-injection tests, performance/scale tests at 500-1000 items, a production config audit, physical-device dogfood validation, and the hosted development-environment dogfood smoke. See `docs/INVENTORY_SYNC_RELEASE_READINESS_PHASE2B5.md`, `docs/INVENTORY_SYNC_DOGFOOD_PLAYBOOK.md`, `docs/INVENTORY_SYNC_ROLLBACK_PLAYBOOK.md`, `docs/INVENTORY_SYNC_DIAGNOSTICS.md`, `docs/INVENTORY_SYNC_GO_NO_GO.md`. All flags remain `NO`; nothing pushed.
- **Phase 2B-6 closed every Phase 2B-5 evidence gap this environment can close — new conclusion: Dogfood Go / Production No-Go** (was plain No-Go), pending only physical-device validation. New test-only `InventorySyncFaultInjectingTransport` (file-scoped `private` inside `KitchenManagerTests/GuestMergeTests.swift`, structurally unreachable from the app target) wraps the existing `SimulatedMergeTransport` fake and injects deterministic faults (`.throwError(SyncError)`, `.malformedOrTruncatedJSON`, `.delay`, plus an `applyFirst` flag that lets the inner fake genuinely record a mutation as applied before the fault reaches the caller — the "push applied, client times out" / "app killed after push" shape). Covers offline/401/403/413/429(→`.backendUnavailable`)/500/503/malformed-truncated-JSON/push-applied-then-timeout/pull-succeeded-then-local-save-failure/app-killed-before-cleanup: every case confirmed pending-retaining, cursor-safe (never advances on a decode or persistence failure), and duplicate-safe (same `mutationId` reused on retry, never a second pending row). Verified single-flight for real under concurrency (`withTaskGroup`, 10 concurrent `syncNow` calls → exactly 1 `sendMutations` call, confirmed via a call-counter on the fault transport) and that a scope-mismatch (`.paused(.forbidden)`) never leaves the guard stuck for a subsequent correctly-scoped call. Added a queue-cap-at-scale test: 250 attempted creates against a 200 cap holds exactly at 200, while a delete-of-an-already-staged-item still fully cancels (create+delete rule) and coalescing an update into an already-staged create still succeeds. Added 3 scale/performance sanity tests (1000 `SyncMetadata` rows through the consistency checker, 500 `evaluate` calls, a 500-pending/100-conflict diagnostics snapshot) — all complete well within generous local time bounds, confirming no O(n²) hotspot in any of these three code paths (each does a single dictionary-backed pass, no nested iteration). Ran a **real** hosted development dogfood smoke — new `GuestMergeSmokeRunner.runInventoryDogfoodMinimalSmoke` / `HostedGuestMergeSmokeTests.testControlledDevelopmentInventoryDogfoodSmoke` — against the actual development Supabase project and the real Render deployment (the same backend `.development`/`.production` both resolve to), using an isolated `__inventory_dogfood_<id>` marker throughout: create→sync→update→sync→offline-stage→reconnect+sync→simulated-restart (fresh `SwiftDataSyncPersistence` actor + fresh `GuestMergeController` over the same container)→duplicate-safe no-op sync→delete→sync→tombstone→diagnostics-snapshot-clean→consistency-checker-clean→cleanup; passed on the first attempt, zero marker residue (verified via `scripts/cleanup-guest-merge-smoke-markers.mjs`, now also sweeping `__inventory_dogfood_`); the two smoke-enabling flags were set to `YES` only in the gitignored `Local.xcconfig` for the run's exact duration, restored to `NO` immediately after, and credentials were injected only via an ephemeral, untracked `.xctestrun` environment override — never a scheme file. Performed a read-only production-config audit (Supabase/Render URL injection mechanism, JWKS/issuer derivation, RLS migration file presence, service-role absence, logging redaction) finding no Blocker, plus built and inspected a real unsigned Archive (`CODE_SIGNING_ALLOWED=NO`): compiled `Info.plist` confirmed all 8 sync/dogfood/smoke flags `NO`, and a `strings` scan of the compiled binary found zero test credentials, emails, or smoke-marker prefixes, and zero `.xcconfig` content inside the bundle. Added 17 new `GuestMergeTests` cases (99/99, up from 82) and 9 new Node semantic-guard assertions (854/854, up from 845). Full iOS Unit regression 568/568 (3 safe skips, up from 550), UI 5/5 unchanged, 0 regressions. Physical-device validation was **not** attempted — no physical device is attached to this automated environment, so a 30-step ready-to-run checklist (`docs/INVENTORY_SYNC_PHYSICAL_DEVICE_CHECKLIST.md`) was prepared instead of fabricating a result. See `docs/INVENTORY_SYNC_PHASE2B6_VALIDATION.md`, `docs/INVENTORY_SYNC_FAULT_INJECTION.md`, `docs/INVENTORY_SYNC_SCALE_RESULTS.md`, `docs/INVENTORY_SYNC_PRODUCTION_CONFIG_AUDIT.md`, `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_CHECKLIST.md`, and the updated `docs/INVENTORY_SYNC_GO_NO_GO.md`. All flags remain `NO`; nothing pushed.
- **Phase 2B-7 ran real physical-device validation for the first time — conclusion remains Dogfood Go / Production No-Go, now narrowed to only the human-gesture UI/network-toggle layer.** A physical iPhone 17 Pro (iOS 27.0) became reachable in this environment (`xcrun devicectl`/`xcodebuild -destination id=<device-udid>`); the existing `GuestMergeTests`/`HostedGuestMergeSmokeTests` XCTest suites — unchanged from Phase 2B-6 — were built and run *directly on that hardware* (`-allowProvisioningUpdates` for the on-device UITest-runner provisioning profile; test credentials injected via the same ephemeral, untracked `.xctestrun` `EnvironmentVariables` technique used in Phase 2B-6, never a scheme file): 97/99 passed, with the 2 failures (`testFeatureGateBlocksPreviewGenerationWhenDisabled`, `testInventoryMergeUIEnabledDefaultsToFalseWhenInfoPlistKeyIsAbsent`) being an expected, correctly-diagnosed side effect of intentionally setting `INVENTORY_SYNC_ENABLED`/`INVENTORY_MERGE_UI_ENABLED` to `YES` in `Local.xcconfig` for this run (both tests assert the disabled-by-default state read from the real compiled bundle) — not a product bug, and in fact positive confirmation that the flags really do take effect on real hardware. The hosted development dogfood smoke (`GuestMergeSmokeRunner.runInventoryDogfoodMinimalSmoke`) ran for real *from the device itself*, over its own network, against the real Render deployment and development Supabase project — passed, with real `[APIClient]` HTTP round trips (bootstrap 100–300ms, sendMutations 170–730ms, fetchChanges 180–770ms) and zero marker residue afterward (confirmed via `scripts/cleanup-guest-merge-smoke-markers.mjs`). A genuine OS-level app-kill/relaunch cycle was performed on the real installed app process via `devicectl device process terminate` + `launch` — clean relaunch with a new PID, no crash. **A safety finding was caught mid-phase and corrected**: the only device available was the operator's own daily-use phone, already signed into a real account with real personalized settings — not a disposable dogfood device. Per the operator's explicit choice, every data-touching validation step ran only inside the isolated XCTest sandbox (its own in-memory `ModelContainer`/`UserDefaults` suite, never the real installed app's persistent store or signed-in session) — the real app's data was never read or written by any test. Because building with the dogfood flags at `YES` meant the *compiled binary actually installed on the phone* carried those flags as `YES` (not just the source), a second Debug build with flags restored to their default `NO` was produced, verified via `plutil` inspection of its compiled `Info.plist`, and reinstalled over the dogfood build before ending the phase (same bundle id/on-disk database, so the operator's own app data was preserved) — the device now runs the same default-off build any ordinary Debug install would produce. A screenshot taken early in the phase (before this constraint was identified) was deleted immediately and its content is not reproduced anywhere. What remains genuinely unautomatable in this environment — no touch/tap-injection tool exists for a physical device (no Appium-style driver) — is the human-gesture layer: tapping through the Guest-merge preview/conflict UI on-screen, a real Airplane Mode/Wi-Fi toggle, a real screen lock/unlock cycle, foreground/background via an actual gesture, and Instruments-based memory profiling. These are honestly reported as BLOCKED (tooling) in `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md`, never claimed as passed. Full regression re-confirmed unchanged on the simulator with flags back to `NO`: Node 854/854, iOS Unit 568/568 (4 safe skips), UI 5/5 (1 safe skip), `GuestMergeTests` 99/99, `npm run smoke:sync` PASS, `npm audit` 0 vulnerabilities, `git diff --check` clean, 0 regressions. See `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md` and `docs/INVENTORY_SYNC_FINAL_GO_NO_GO.md`. All flags remain `NO`; nothing pushed.
- **Phase 2B-7 continued with a full manual, human-driven physical-device round — a real crash bug was found and fixed; conclusion still Dogfood Go / Production No-Go, gap now only Conflict UI + Rollback.** Working turn by turn (the assistant gives 1–3 concrete tap instructions, the operator executes and reports PASS/FAIL, no autonomous device control), the operator personally verified: signing in with `TEST_USER_A`; the Guest-merge prompt appearing and surviving "稍后处理"/re-entry; opening the zero-network-write preview (no conflict indicator appeared, since the account had no pre-existing remote data — Conflict UI could not be exercised as a result, an honest gap, not a failure); explicit merge confirm (only after being asked and explicitly consenting, since this app's local inventory storage isn't partitioned per signed-in account — confirming uploads whatever's currently stored locally, which meant the operator's own real inventory content went to the `TEST_USER_A` household on the *development* project, not production); marker item create/update/delete each followed by a real "立即同步库存" tap; a real Airplane Mode toggle (offline create, reconnect, re-sync); a real Wi-Fi/cellular switch; backgrounding the app immediately after tapping sync; a real lock-screen/unlock cycle; a real force-quit with a pending item followed by relaunch and sync; signing out of `TEST_USER_A` and into `TEST_USER_B`, confirming User B showed a fresh "尚未完成合并" state with zero leakage of User A's already-synced status, then signing back into `TEST_USER_A` and confirming its synced state recovered correctly; opening the real "库存同步诊断" screen and its export JSON directly (manually reviewed field-by-field: only `activeMergeSessionState`/`appBuild`/`conflictCount`/`currentUserPresent`/`enrollmentState`/`environment`/`failedCount`/`householdPresent`/`isDogfoodEnabled`/`isEnrolled`/`isFeatureEnabled`/`lastSuccessfulCursor`/`lastSyncCompletedAt`/`lastSyncStartedAt`/`lastSyncResult`/`localGuestOnlyItemCount`/`localSyncedItemCount`/`localTombstoneCount`/`oldestPendingAgeSeconds`/`pendingCount`/`schemaVersion` — no email/password/token/full UUID/household ID/mutation ID/item name present, confirming the Phase 2B-5 redaction design holds on a real device with real data). Rollback was explicitly **not** exercised — a stale/cached merge-preview screen was encountered while looking for a rollback entry point, and rather than tap either action button against ambiguous state, the operator backed out and confirmed the signed-in account was still correctly "已同步" (nothing harmed), leaving rollback as a genuine open item rather than a guessed pass. **A real, previously-unknown crash was found and fixed**: the first attempt at the final marker-deletion step crashed the app twice. Crash logs were pulled directly off the device (`devicectl device info files --domain-type systemCrashLogs` + `devicectl device copy from`, since `devicectl` has no dedicated crash-log subcommand) and both showed an identical `EXC_BREAKPOINT`/`SIGTRAP` — a Swift array index-out-of-range trap inside `InventoryItemDetailView.body.getter`'s `Toggle` binding closures (`ToggleState.stateFor` → `Binding.readValue()` → `Array.subscript.getter` → `Array._checkSubscript`). Root cause: `InventoryItemDetailView` (`KitchenManager/PantryStaples.swift`) computed `index` once per `body` evaluation and every field `Binding` closed over that specific `Int`; tapping "删除库存" removes the item from `store.inventory` and calls `dismiss()` in the same action, but SwiftUI can still invoke an already-created Toggle binding's closure once more during the dismiss transition, by which point the captured index is out of range for the now-shorter array — a **pre-existing product bug, unrelated to sync/dogfood at all**, reachable any time a user deletes an inventory item from its own detail screen after that screen has rendered a Toggle (e.g. "设置保质期" or "设为常备食材"). Fixed by adding a small generic `binding<Value>(_ keyPath:default:)` helper (plus two hand-written Bindings for the expiry Toggle/DatePicker and the staple Toggle) that resolves the item fresh by `itemID` at get/set time instead of trusting a captured array index — a post-delete invocation of any of these closures is now a safe no-op instead of a crash. Added a regression UI test, `KitchenManagerUITests/InventoryNavigationUITests.testDeletingInventoryItemAfterTogglingStapleDoesNotCrash`, which reproduces the exact sequence (open detail → toggle "设为常备食材" → delete → confirm) and asserts the app is still running in the foreground afterward — passed on simulator after the fix, then the fixed build was redeployed to the physical device and the one failed step was retried there for real (passed, no crash) — no earlier step was rerun, per this phase's "不重跑无关步骤" instruction. `scripts/cleanup-guest-merge-smoke-markers.mjs`'s `MARKER_PREFIXES` gained a fourth entry, `__inventory_device_dogfood_`, for this round's manual-test marker prefix; a post-cleanup run found 0 residual rows across all four prefixes. The device was rebuilt with all flags restored to `NO`, verified via `plutil` on the reinstalled binary's compiled `Info.plist`, and the final app launch showed a clean Guest sign-in prompt (test account cleanly signed out, diagnostics entry gone, no crash). Full regression re-confirmed: Node 854/854, iOS Unit 568/568 (4 safe skips), UI 6/6 (1 safe skip, up from 5 — the new regression test), Debug/Release clean builds 0 warnings/0 errors, `npm audit` 0 vulnerabilities, `git diff --check` clean, secret scan clean (no account names/emails found in any changed file), 0 regressions. See `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md` and `docs/INVENTORY_SYNC_FINAL_GO_NO_GO.md` (status wording: "physical-device checklist passed except Conflict UI and Rollback, not exercised; one real crash bug found and fixed" — never "production ready"). All flags remain `NO`; nothing pushed.

There is no frontend build pipeline. The browser runs the files directly.

---

## 4. Main User Journeys

The most important user journey is:

1. Add or import kitchen inventory.
2. See recommended recipes based on current inventory and expiry state.
3. Add a recipe to today/future plan.
4. If ingredients are missing, optionally add them to the shopping list.
5. Cook the dish.
6. Confirm actual cooking completion and inventory deductions.
7. Keep inventory, shopping list, and future recommendations accurate.
8. Export backup when real user data exists.

Any change that touches inventory, recipes, shopping, plans, recommendations, or backup must protect this loop.

---

## 5. Current Feature Map

Kitchen Manager already includes or is designed around these areas:

- Kitchen home page / today dashboard.
- Inventory management and quick entry.
- Expiry warnings and out-of-stock state handling.
- Recipe recommendation from available inventory.
- Recipe library mode: curated daily recipes and full original recipes.
- Recipe detail and recipe editor.
- User recipe overlay edits.
- Recipe completion overlay.
- Today plan and future meal planning.
- Missing ingredient detection.
- Shopping list generation and manual shopping items.
- Staples / pantry shelf state.
- Cooking feedback / completion flow.
- AI-assisted recipe drafting.
- AI-assisted recipe import from text, link, screenshot, or other source material where supported.
- Receipt/image recognition.
- BYOK advanced AI configuration.
- Default backend AI proxy mode.
- Backup and restore.
- PWA install and Service Worker caching.

---

## 6. Data Model Context

The core persistence layer is `src/storage.js`.

General rules:

- Use `S.load` and `S.save`.
- Use `S.keys.*` constants.
- Do not write raw `localStorage.getItem('km_...')` or `localStorage.setItem('km_...')` outside the storage/migration layer.
- Do not rename existing storage keys without a migration.
- Do not clear user data as a shortcut.

Important persisted concepts:

- Inventory.
- Today/future plan.
- Recipe overlay edits.
- Settings.
- Shopping items.
- Staples/pantry shelf.
- AI/local recommendation caches.
- Favorite recipes.
- Recipe usage/activity.
- Schema version.

When adding persistent fields:

1. Check how the loader normalizes/rebuilds objects.
2. Add migration logic when needed.
3. Update backup/export/restore behavior.
4. Add tests.
5. Update `PROJECT_STATUS.md` and `CHANGELOG.md`.

---

## 7. AI Feature Context

AI is a helper, not an authority.

AI features may include:

- Recipe recommendation assistance.
- Recipe method draft generation.
- Recipe import parsing.
- Receipt recognition.
- Link/page extraction support.
- Future video-to-recipe workflows.

Rules:

- Keep prompts and parsing logic separated from UI code when practical.
- Validate AI output before displaying or saving.
- Preserve warnings and uncertainty when source information is incomplete.
- Do not infer complete recipe steps from weak evidence.
- Do not let AI automatically change inventory without user review.
- Do not expose API Keys in frontend defaults, logs, backups, or committed files.

---

## 8. Future Direction

Likely future priorities:

- Make the current MVP more reliable rather than larger.
- Improve recipe import accuracy and transparency.
- Harden Xiaohongshu/video/URL import failure states.
- Keep tests aligned with real user flows.
- Improve mobile usability and iOS-like polish without changing the native stack.
- Prepare eventual app packaging while preserving local-first data ownership.

Do not assume a rewrite is required for these improvements.

---

## 9. Non-goals Unless Explicitly Requested

Do not pursue these without explicit approval:

- Full React/Vue/Svelte rewrite.
- TypeScript migration.
- Tailwind migration.
- Backend database introduction.
- Client account/login UI or expansion of the verified server-side Phase 0/0.5 authentication foundation.
- Kitchen business-data cloud sync.
- Full native iOS rewrite.
- Replacing localStorage data model.
- Changing the core navigation model.

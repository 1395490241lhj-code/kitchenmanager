# Inventory CRUD Sync Boundary (Phase 2B-4)

## Scope

Phase 2B-4 wires ordinary Inventory create/update/delete to the existing
sync engine (Phase 2B-1 through 2B-3), so that once a device has completed a
Guest merge, subsequent local edits to already-synced-scope inventory items
stage `PendingMutation`s automatically — without ever touching the network
until the user taps "立即同步库存" (`GuestMergeController.syncNow`, Phase
2B-3). It adds no new backend endpoint, no new entity type, and no automatic
network call anywhere.

**Completion criterion**: "当 Inventory 已经完成 Guest merge 并进入 synced 状态
后，用户后续对这些库存进行新增、修改、删除，会安全生成本地 PendingMutation；只有用户明确
点击"立即同步库存"时才发送网络请求。Guest-only 库存和其他模块始终不受影响。" — met.

## Audit findings (before implementing)

- `KitchenStore.inventory`'s `didSet` is the single choke point for every
  CRUD method (`addInventory`, `importInventory`, `deleteInventory`,
  `saveStaple`, direct `$store.inventory[index].field` bindings used by the
  edit UI) — all of them mutate the published array and re-trigger the same
  `didSet` → a **bulk, full-array** `inventoryPersistence.replaceInventory(with:)`.
  There is no existing per-item hook.
- Two independent write paths already exist for the same `InventoryRecord`:
  `SwiftDataInventoryPersistence` (its own plain `ModelContext`, driven by
  `KitchenStore`) and `SwiftDataSyncPersistence` (a `@ModelActor` with its
  own `ModelContext`, driven by `InventorySyncAdapter`/`SyncCoordinator`/
  `GuestMergeController`). Both point at the same `ModelContainer`, but
  writing the *same* `InventoryRecord` through both in one operation risks a
  stale-context race. **Consequence**: the new CRUD-staging path never
  writes `InventoryRecord` itself — `KitchenStore`'s own persistence already
  did that through its own context; the sync actor only ever writes
  `SyncMetadataRecord`/`PendingMutationRecord` for CRUD-originated staging.
- Receipt import (`ReceiptImportStore.importSelected`) calls straight into
  `KitchenStore.importInventory` — no separate write path, so it's covered
  by the same generic hook as every other CRUD method.
- No other module (Recipe cooking-completion `applyConsumption`, shopping
  stock-in `stockInCompletedShopping`) is wired to this hook — both already
  use `suppressInventoryPersistence` to skip `KitchenStore`'s own `didSet`
  bookkeeping for their bulk operations, and the new hook is deliberately
  gated on `!suppressInventoryPersistence` too, so they stay entirely
  out of scope (matches "不扩展到其他模块").
- `InventorySyncAdapter.stageUpsert`/`stageDelete` already existed
  (Phase 2B-1/2/3) but always minted a fresh `mutationId` per call — fine
  for merge (each candidate staged once), not fine for repeated ordinary
  edits (would accumulate unbounded mutations per entity). `SyncCoordinator.runOnce`
  itself is entirely origin-agnostic — it already pushes/pulls whatever is
  staged for a scope, so no coordinator changes were needed.
- Logout (`AuthStore.signOut()`) only resets in-memory auth state; there is
  one shared `ModelContainer` for the whole device, never swapped per
  account. This is a pre-existing characteristic (not introduced by
  Phase 2B-4) — account isolation for enrollment/metadata/mutations is
  achieved by *scoping every query* to the current `(userId, householdId)`,
  the same pattern `GuestMergeSession` already uses, never by container
  separation.

## Inventory Sync Enrollment

A new, independent, persisted concept: whether a `(userId, householdId)`
*workspace* — not any single item — has moved into a state where ordinary
CRUD is expected to stage mutations.

```swift
enum InventorySyncEnrollmentStatus {
    case notEnrolled   // default — no merge has ever completed
    case mergeRequired // Guest data exists but hasn't been merged yet
    case enrolled      // a merge completed — CRUD may stage mutations
    case paused        // reserved, unused in this phase
    case revoked       // reserved, unused in this phase
}
```

`InventorySyncEnrollmentRecord` (`@Model`, unique key `userId:householdId`)
is registered in the same shared `ModelContainer` as everything else
(`KitchenPersistenceFactory`). The **only** place enrollment transitions to
`.enrolled` is inside `GuestMergeController.confirmMerge`'s success branch —
verified by a Node test that counts exactly one `status: .enrolled` site in
the whole file. Enrollment is never inferred from "does any `SyncMetadata`
row happen to exist" (that would conflate one merged item with the whole
workspace, and wouldn't survive a different user signing in on the same
device) and is never set by the mere presence of the feature flag.

## Sync eligibility (`InventorySyncEligibility`)

The single, centralized, pure decision function — never duplicated inline in
a View or a CRUD method:

```swift
InventorySyncEligibility.evaluate(
    isFeatureEnabled: Bool,
    userId: UUID?,
    householdId: UUID?,
    enrollment: InventorySyncEnrollment?,
    existingMetadata: SyncMetadata?,
    intent: .create | .update | .delete
) -> InventorySyncEligibilityResult
```

Returns one of: `.localOnly(reason:)` (feature disabled, not signed in, no
household, not enrolled, or — for update/delete — no existing metadata for
this specific item), `.eligible(baseVersion:)`, `.blockedByConflict` (the
item's metadata is already `.conflicted` — never silently staged over),
or `.blockedByPendingDelete` (an update/create attempt on an item with a
pending delete already staged — refused per spec, never a silent
resurrection). Metadata is only ever treated as "existing" when its own
`scope.type == .household && scope.id == householdId` matches the call's
household — a different household's (or, since scope carries no user id,
implicitly a different session's) metadata is never adopted.

## Category behavior (section 七)

| Category | Signal | create/update/delete |
| --- | --- | --- |
| A. Guest-only | no household-scoped `SyncMetadata`, or not enrolled, or flag off | purely local — no `PendingMutation`, no household binding, no upload |
| B. Synced | household-scoped `SyncMetadata` exists, belongs to this user/household | update → `upsert` mutation; delete → `delete` mutation; sent only on manual sync |
| C. Locally-created synced-scope | brand-new item while enrolled+flag-on+signed-in | stable UUID (the item's own `id`, never regenerated), `SyncMetadata(state: .pendingCreate, remoteVersion: nil)`, `PendingMutation(operation: .upsert, baseVersion: .zero)` — all in one transaction, no immediate network call |

## Create / update / delete semantics

**Create**: a brand-new item id appearing in `KitchenStore.inventory` while
enrolled stages at `baseVersion = "0"` — verified by
`testEnrolledCreateStagesMetadataAndMutationAtBaseVersionZero`.

**Update**: an existing eligible item's changed content stages an `upsert`
using the entity's *already-known* `SyncMetadata.remoteVersion` as
`baseVersion` — never `.zero` for a real update — verified by
`testSyncedUpdateUsesExistingRemoteVersionAsBaseVersion`. A conflicted item
is never touched (`testConflictedMetadataBlocksFurtherStagingWithoutOverwriting`);
resurrecting a pending-delete item via update is refused, not silently
un-deleted (this phase's explicit choice per spec).

**Delete**: stages a tombstone — `SyncMetadata.state = .pendingDelete`,
`deletedAt` set, using the current known `remoteVersion` as `baseVersion` —
never a physical remote delete request. Local UI hides the item immediately
(it's removed from `KitchenStore.inventory`, per existing behavior); the
"tombstone" that survives until the server confirms lives entirely in
`SyncMetadataRecord`/`PendingMutationRecord`, which are in a completely
separate table from `InventoryRecord` and untouched by `KitchenStore`'s own
(unchanged) local delete of the record itself.

Full coalescing rule table (create+update, create+delete cancel,
update+update, update+delete, duplicate-delete): `docs/INVENTORY_MUTATION_COALESCING.md`.

## Transaction boundary

`SwiftDataSyncPersistence.stageInventoryMutation(entityId:scope:operation:payloadData:now:)`
is the single atomic entry point — one `@ModelActor` transaction, one
`context.save()`, writing `SyncMetadataRecord` and (at most one, coalesced)
`PendingMutationRecord` together. It deliberately never writes
`InventoryRecord` (see the dual-context hazard in the audit above) — that
record was already written, moments earlier, by `KitchenStore`'s own
`InventoryPersistenceProtocol` call, through its own `ModelContext`.
`testTransactionFailureLeavesNoOrphanedMutation` verifies a forced save
failure leaves neither a metadata row nor a mutation row behind (SwiftData's
own `modelContext.rollback()` on save failure, already used by every other
method in this actor).

## Architecture: how `KitchenStore` learns anything at all

`KitchenStore` gained exactly one new, optional, generic property:

```swift
var onInventoryChanged: (([InventoryItem], [InventoryItem]) -> Void)?
```

Called from `inventory`'s `didSet` with `(oldValue, newValue)`, but only when
`!isLoading && !suppressInventoryPersistence` — i.e. real, discrete CRUD
edits, never the initial load or a bulk/suppressed operation (consumption,
backup restore, shopping stock-in, clear-all — all out of scope for this
phase). `KitchenStore.swift` itself imports nothing about Auth or Sync; the
closure's only vocabulary is `[InventoryItem]`.

The closure is wired exactly once, in `ContentView.swift`'s (`@main`
`KitchenManagerApp`) `init()` — the app's composition root — reading the
*current* signed-in user/household fresh on every call (never a frozen
snapshot captured at wiring time), then dispatching into
`GuestMergeController.handleInventoryDidChange(old:new:userId:householdId:)`.
This is the **only** place `KitchenStore` and Auth/Sync are connected; a
View never creates a `PendingMutation`, never touches `SyncMetadata`, never
decides a scope or a `baseVersion`, and never sees a token — it just edits
`kitchenStore.inventory` exactly as it always has.

## Manual sync closed loop (unchanged from Phase 2B-3, re-verified)

`GuestMergeController.syncNow` already: checks the feature flag and signed-in
user, guards against a second concurrent run (`guard !isSyncing else {
return }`), scopes to `.inventoryItem` only, and is the only production
`runOnce` call site besides `confirmMerge`/`rollback` (still exactly 3,
Node-verified). Since it re-queries `pendingMutations(scope:maxAttempts:)`
generically, Phase 2B-4-staged mutations are picked up with zero coordinator
changes. `pendingInventoryCount(householdId:)` likewise already filters by
`(scopeType, scopeId)` — a different household's or user's pending count is
never included (verified by `testUserBHouseholdScopeNeverReceivesUserAsInventoryMutation`).

## Status UI

`InventorySyncStatusView` (Phase 2B-3) now also reads
`GuestMergeController.enrollmentStatus(userId:householdId:)` to show "尚未完成
合并" before the ordinary sync-status text (未启用/尚未登录/待同步 N 项/正在同步/已同步/
需要重新登录/暂时离线/同步遇到问题) applies. A new
`@Published var inventoryMutationBlockedMessage: String?` on the controller
surfaces the conflict/pending-delete block reasons in plain language, without
ever undoing the local edit that already happened.

## Account/household isolation

Every enrollment/eligibility/staging lookup is keyed by the caller-supplied
`userId`/`householdId` — never a global default. Verified:
`testEnrollmentIsIsolatedBetweenUsersAndHouseholds` (a different user or a
different household never inherits enrollment),
`testUserBHouseholdScopeNeverReceivesUserAsInventoryMutation` (pending
mutations never leak across household scope), and the pre-existing
`testUserAAndUserBSessionsAreFullyIsolated` (merge sessions, unchanged).
Logout does not delete local `InventoryRecord`s and does not switch
`ModelContainer` — unchanged, pre-existing behavior, re-confirmed by the
audit.

## Error handling

Same plain-language mapping as Phase 2B-3's `userFacingSyncError` — no raw
HTTP body, JWT, `Authorization` header, SQL, stack trace, mutation id, or
entity UUID is ever shown. Blocked-staging reasons (conflict, pending
delete) get their own plain messages via `inventoryMutationBlockedMessage`.

## Minimal hosted validation

`GuestMergeSmokeRunner.runInventoryCrudSyncMinimalSmoke` /
`HostedGuestMergeSmokeTests.testControlledDevelopmentInventoryCrudSync` —
deliberately not a repeat of the full Phase 2B-2 matrix. Against the real
development backend: seeds enrollment directly (bypassing the full merge
UI, since enrollment itself is already covered by mock-transport tests),
creates one `__inventory_crud_smoke_<marker>` item, verifies it stages at
`baseVersion 0` and applies via manual sync (`remoteVersion` becomes `"1"`),
then a local update stages and applies (`remoteVersion` becomes `"2"`), then
a local delete stages and applies as a soft-delete tombstone, then a repeat
manual sync is a harmless no-op, and a separate Guest-only "control" item
(never passed through the change hook) is confirmed to have never been
staged at all. Passed on the first real attempt; zero marker rows remained
afterward (verified via `scripts/cleanup-guest-merge-smoke-markers.mjs`,
extended in this phase to also sweep the new `__inventory_crud_smoke_`
prefix alongside the existing `__guest_merge_smoke_` one). Safety flags
restored to `NO` afterward.

## Testing

21 new `GuestMergeTests` cases covering enrollment (becomes-enrolled-only-
after-merge, user/household isolation, restart survival, flag-off), create
(Guest-only no-op, baseVersion 0, transaction-failure-leaves-no-orphan),
update (baseVersion from existing remoteVersion, create+update coalescing,
update+update coalescing, conflict blocks staging, Guest-only no-op),
delete (tombstone staging, create+delete cancellation, update+delete
coalescing, Guest-only no-op), and account/household isolation. 14 new Node
semantic-guard assertions (`KitchenStore` never touches the network
directly, exactly 3 `runOnce` sites, centralized eligibility never
duplicated inline, enrollment only transitions in one place, all coalescing
branches present, tombstone-not-physical-delete, inventory-only scope,
household-scope matching, no service-role/token-in-View, other modules
never wired in, no timer/background/Realtime, shared payload encoder). 1
real hosted smoke (above).

## Not yet implemented

- Automatic/background sync, any timer or polling.
- Realtime.
- Shopping / Today Plan / Weekly Plan / Recipe / Favorites / Frequent sync.
- Household invitation.
- Public/production enablement of any feature flag.

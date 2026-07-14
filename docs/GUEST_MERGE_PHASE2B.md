# Phase 2B — Guest Inventory Merge (2B-1)

## Scope

Phase 2B-1 adds a user-initiated, explicitly-confirmed flow for merging one
signed-in user's local Guest **inventory** into their household's hosted
inventory. It is not automatic synchronization, not a Guest data upload
pipeline, and not a Shopping/Plan/Recipe migration.

- Guest inventory detection is read-only, in-memory, and only runs on demand
  (account page appearance) — never at App startup, login, or on a timer.
- A merge session is created only after the user opens the preview; nothing
  is written to the network before an explicit "确认合并库存" tap.
- Only inventory is ever staged, uploaded, or rolled back. Shopping, Today
  Plan, Weekly Plan, and user Recipes are counted for context only.
- `INVENTORY_SYNC_ENABLED` (default `NO` everywhere, including Release) is a
  second, independent gate from `SYNC_ENABLED`. Neither flag enables the
  other; a confirmed merge constructs its own scoped
  `SyncConfiguration(isEnabled: true)` for that one push/pull cycle only
  (mirroring the Phase 2A-4 smoke runner's pattern) — the `SYNC_ENABLED` flag
  file is never read or written by this feature.

## Architecture

New files under `KitchenManager/Synchronization/`:

- `GuestMergeModels.swift` — `GuestDatasetSummary`, `InventoryMergeConfiguration`
  (the `INVENTORY_SYNC_ENABLED` loader), `GuestMergeSessionStatus` (11
  states), `GuestMergeSession` + its `@Model` record, `InventoryMergeAction`/
  `InventoryMergeConflictReason`/`InventoryMergeConflictChoice`,
  `InventoryMergeCandidate`, `InventoryMergePlan`.
- `InventoryMergePlanner.swift` — pure, local-only matching/plan generation
  (`InventoryMergePlanner.makePlan`), plan-hash re-validation
  (`isPlanStillValid`), and `GuestDatasetDetector` (read-only counts from
  already-loaded `KitchenStore`/`RecipeStore` state).
- `GuestMergeController.swift` — the `@MainActor ObservableObject`
  orchestrating detect → preview → confirm → upload → rollback, entirely
  through the existing `SyncCoordinator` / `InventorySyncAdapter` /
  `ExpressSyncTransport` (no second upload client).

New view file `KitchenManager/GuestMergeViews.swift`: `GuestMergePromptView`,
`InventoryMergeFlowView`, `InventoryMergePreviewView`,
`InventoryMergeConflictView`, `InventoryMergeProgressView`,
`InventoryMergeResultView`. Wired into `AccountView` (`AccountViews.swift`)
as one `Section`, not a new top-level tab.

Extended (additively) rather than modified:

- `SyncPersistenceProtocol` / `SwiftDataSyncPersistence` /
  `FailingSyncPersistence` gained `activeGuestMergeSession`,
  `guestMergeSession(id:)`, `saveGuestMergeSession` — same `@ModelActor`
  single-`ModelContext` transaction boundary already used for
  `commitInventoryAndSync`.
- `AuthStore` gained `currentUserID` (safe for any caller, including `View`s)
  and `currentAccessToken()` (documented and enforced as callable only by the
  private `AuthStoreCredentialProvider` inside `GuestMergeController.swift` —
  never by a `View`, never persisted/logged, never stored on any
  `@Published`/`Sendable`/SwiftData/`UserDefaults` value). `confirmMerge` and
  `rollback` take the live `AuthStore` reference itself (never a raw token
  string); the provider re-queries the token fresh on every network call, so
  the very next call after a sign-out mid-run returns `nil` and stops further
  uploads/deletes instead of using a stale token.
- `KitchenPersistenceFactory` registers the new `GuestMergeSessionRecord`
  model in the **same, single** `ModelContainer` used everywhere else — the
  Guest/signed-in `ModelContainer` is never switched.

## Matching / preview

The iOS `InventoryItem` already has a stable `UUID` (confirmed in
`docs/SYNC_SCHEMA_PHASE2A.md`); Phase 2B-1 always reuses it and never
generates a second id. There is no "legacy no-UUID" inventory case to handle
on iOS (unlike the PWA's string ids).

Matching key: `normalizedName + unit` (lowercased, trimmed) **only**.
`quantity` is a mutable business value compared *after* identity is resolved,
never part of the identity/matching key — a quantity difference alone must
never let a candidate escape into `create`. `expiryDate` participates in
identity as a compatibility check (`ExpiryIdentity`): both absent, or both
present and equal, is "compatible"; anything else (one absent/one present, or
both present and different) is "incompatible" and is never silently resolved.
`isStaple`/staple category/threshold/restock/tracking-mode/availability are
"metadata" fields — tracked so a same-id metadata-only difference surfaces as
its own conflict (never silently overwritten by an upload), but likewise
never part of the matching key. The current `InventoryRecord` model has no
`location` or general `category`/`opened` field, so those suggested matching
dimensions do not apply to this model; this is a deliberate, documented scope
reduction rather than an oversight.

Rules (implemented in `InventoryMergePlanner`, classification order matters —
same id is a certain identity; different id + same key is only a possible
duplicate, so its identity stays uncertain regardless of which fields match):

1. Same stable id, compatible expiry, same `quantity`, same metadata →
   `skip` (no-op).
2. Same stable id, incompatible expiry → `conflict` (`expiryMismatch`).
3. Same stable id, compatible expiry, different `quantity` → `conflict`
   (`quantityMismatch`).
4. Same stable id, compatible expiry/quantity, different metadata field →
   `conflict` (`metadataMismatch`).
5. No remote match for the business key → `create`.
6. Exactly one remote match under a *different* id, same business key →
   `conflict` (`ambiguousDuplicate`), regardless of whether expiry/quantity
   happen to match — never silently treated as the same record.
7. More than one remote match for the same business key → `conflict`
   (`multipleRemoteCandidates`) — never auto-selected.

Conflicts require an explicit `InventoryMergeConflictChoice`
(`keepLocal` / `keepRemote` / `keepBoth`); no automatic resolution exists.
Partial commit is supported: `InventoryMergePlan.readyToUpload` uploads only
candidates that don't need a decision, leaving unresolved conflicts pending.

The plan is content-addressed (`planHash`, SHA-256 over sorted item
id/quantity/unit/expiry) and re-validated against current local inventory
before any resume; editing Guest inventory after a preview was generated
invalidates it and a fresh plan is produced.

**Known 2B-1 limitation, by design**: `knownRemoteItems` (what the planner
already believes exists remotely) defaults to empty, since this phase
deliberately does not perform a real hosted bootstrap/pull to populate it
(see "Not yet implemented" below). Every Guest item is therefore planned as
`create` until Phase 2B-2 wires a real pre-merge read.

## Merge session lifecycle

`GuestMergeSession` persists through: `detected` → `previewReady` →
`awaitingConfirmation` → `preparing` → `uploading` → (`conflict` | `failed` |
`completed`) → (`rollbackPending` → `rolledBack`), or `cancelled` at any point
before upload. At most one *active* (non-terminal) session exists per
`(userId, householdId, entityType)`; terminal sessions remain queryable by id
as history. Sessions are looked up by this composite key, so User A and User
B (or two households) never see or act on each other's session, and
re-signing-in as the same user resumes the same session id — it is never
regenerated.

## Upload / rollback

`confirmMerge` stages `plan.readyToUpload` candidates via the existing
`InventorySyncAdapter.stageUpsert`, then runs one
`SyncCoordinator.runOnce(scopes: [householdScope])` — identical mechanics to
the Phase 2A-4 smoke. Per-candidate outcome is read back from `SyncMetadata`
(`.synced` → uploaded and, if it was a `create`, recorded in
`createdEntityIds`; `.conflicted` → counted as a conflict, retained;
`.failed` → counted as failed). Re-confirming an already-`completed` session
is a guarded no-op.

Rollback (`rollback`) only ever soft-deletes entity ids in the session's own
`createdEntityIds`, via the same `InventorySyncAdapter.stageDelete` +
`SyncCoordinator.runOnce` path, and is idempotent (a repeated rollback call on
an already-`rolledBack` session is a no-op). It never touches a pre-existing
remote record, a record the user chose `keepRemote` for, or any local Guest
data — local inventory is never deleted by rollback.

## Not yet implemented

- A real hosted pre-merge read to populate `knownRemoteItems` (Phase 2B-2).
- Executing a real Guest merge against a real test account/hosted backend
  (Phase 2B-2 — this round is mock/UI-tested and disabled by default only).
- Shopping, Today Plan, Weekly Plan, or Recipe merge (out of scope for all of
  Phase 2B-1).
- Background sync, Realtime, or household invitation.
- A global "enable Inventory sync for everyone" switch — `INVENTORY_SYNC_ENABLED`
  stays an explicit, developer/operator-controlled flag.

## Testing

- `KitchenManagerTests/GuestMergeTests.swift` — detection, matching/plan
  generation and hashing, stable-id reuse, full session lifecycle, App-restart
  resume, User A/B isolation, upload (create/duplicate/conflict/transport
  failure), completion marker, rollback (scoped + idempotent), conflict
  resolution persistence, Guest data boundary, and the default-disabled flag.
- `test/ios-native-guest-merge-phase2b1.test.mjs` — Node-side source-grep
  semantic guard: default-off flags, inventory-only entity type, no
  auto-upload, single upload client, scoped `SyncConfiguration`, explicit
  conflict resolution only, scoped rollback, session key binding, no App
  startup/login hook, no logged credentials, and that Phase 2A-4's
  inventory-only `SyncCoordinator` restriction is unchanged.

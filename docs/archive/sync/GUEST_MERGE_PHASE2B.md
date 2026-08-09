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

`keepBoth` on a **same-id** conflict (identity certain) allocates a fresh,
stable `forkedLocalItemId` (Phase 2B-2.5) rather than re-using the existing
entity's id — see "Same-id `keepBoth` identity fork" below. On a
**different-id** ambiguous match, the candidate's own id is already
distinct, so `keepBoth` there is already correct as `.create` using that id,
unaffected by the fork mechanism.

The plan is content-addressed (`planHash`, SHA-256 over sorted item
id/quantity/unit/expiry) and re-validated against current local inventory
before any resume; editing Guest inventory after a preview was generated
invalidates it and a fresh plan is produced.

**Phase 2B-1 limitation, resolved in Phase 2B-2**: `knownRemoteItems` (what
the planner already believes exists remotely) defaulted to empty in Phase
2B-1, since that phase deliberately did not perform a real hosted
bootstrap/pull to populate it — every Guest item was therefore always
planned as `create`. Phase 2B-2 added an optional `remoteTransport` parameter
to `GuestMergeController.preparePreview` (default `nil`, so ordinary in-app
preview stays exactly as before — zero network calls) that, when supplied,
performs one read-only `SyncTransport.fetchChanges` pull (a GET, no writes,
no persisted cursor advance) to populate `knownRemoteItems` before the plan
is generated. See `docs/GUEST_MERGE_PHASE2B2_VALIDATION.md` for the real
hosted validation of the resulting conflict detection.

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

## Same-id `keepBoth` identity fork (Phase 2B-2.5)

A same-id conflict means the remote entity's identity is *certain* — staging
a `create` for that same id would collide with a real, already-versioned
remote row. `InventoryMergeCandidate.forkedLocalItemId` (`UUID?`, part of the
already-persisted `plan`, no new SwiftData model) holds a fresh id allocated
once by `applyingChoice(.keepBoth)` and reused verbatim on every later call
— an App restart, a repeated conflict-choice selection, or a repeated
`confirmMerge` call all see the same already-set value, never regenerate it.

`confirmMerge` checks `forkedLocalItemId` first: when set, it copies the
local item's values under the forked id and stages that as a plain create
(`baseVersion` 0, guarded so a retry never re-stages an already-created
fork) — the original entity id is never touched by this candidate at all,
exactly like `keepRemote`. `createdEntityIds` (and therefore `rollback`)
key off the forked id, never the original, so rollback only ever removes
the fork; the original remote record and the original local Guest
`InventoryRecord` (its id, never mutated) are untouched. The local inventory
ends up with two independent records: the original (still mapped to the
original remote entity) and the fork (mapped to the newly created one). The
different-id ambiguous-duplicate case is completely unaffected — its own id
is already distinct, so `forkedLocalItemId` stays `nil` there.

## Phase 2B-3: formal UI and manual sync

The prompt/preview/conflict/progress/result screens described above are now
a real product surface, gated by a second, independent flag
(`INVENTORY_MERGE_UI_ENABLED`, default `NO`) alongside `INVENTORY_SYNC_ENABLED`
(the network capability) — the UI never shows unless both are on. A fourth
conflict choice, `.skip` ("稍后处理"), and a manual "立即同步库存" entry
(`GuestMergeController.syncNow`, the only production `runOnce` call site
besides `confirmMerge`/`rollback`) were added. Full details:
`docs/INVENTORY_SYNC_PHASE2B3.md`.

## Not yet implemented

- Shopping, Today Plan, Weekly Plan, or Recipe merge (out of scope for all of
  Phase 2B).
- Automatic/background sync, Realtime, or household invitation.
- CRUD-to-sync wiring for ordinary (non-merge) inventory edits after a merge
  completes — policy decided in Phase 2B-3, implementation deferred (see
  `docs/INVENTORY_SYNC_PHASE2B3.md`).
- A global "enable Inventory sync for everyone" switch — both
  `INVENTORY_SYNC_ENABLED` and `INVENTORY_MERGE_UI_ENABLED` stay explicit,
  developer/operator-controlled flags, `NO` in every committed configuration.

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

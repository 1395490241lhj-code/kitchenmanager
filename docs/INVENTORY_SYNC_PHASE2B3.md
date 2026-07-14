# Inventory Sync Phase 2B-3 — Formal Guest Merge UI and Manual Sync

## Scope

Phase 2B-3 turns the Phase 2B-1/2B-2 Guest inventory merge engine (already
fully validated, including a real hosted smoke) into a formal, user-facing
product surface: a non-blocking merge prompt, a real preview/conflict/
progress/result flow, and a manual "立即同步库存" entry. It adds **no new
network capability** — `confirmMerge`/`rollback` already existed; this phase
only adds a third, equally explicit, user-initiated entry point (`syncNow`)
and the UI to reach all three. Automatic sync (App startup, sign-in,
background, timers, Realtime) remains entirely out of scope and unimplemented.

## New feature flag: `INVENTORY_MERGE_UI_ENABLED`

A second, independent gate from `INVENTORY_SYNC_ENABLED`:

- `INVENTORY_SYNC_ENABLED` — network **capability**: without it,
  `confirmMerge`/`rollback`/`syncNow` all refuse outright.
- `INVENTORY_MERGE_UI_ENABLED` — UI **visibility**: without it, the merge
  prompt/preview/conflict/result screens and the manual sync section never
  render at all, regardless of the network flag.

Both default `NO` in `Shared.xcconfig`, `Local.example.xcconfig`, and every
Release build; neither is ever set from a remote response. `GuestMergePromptView`
checks `controller.isUIEnabled && controller.isFeatureEnabled` before rendering
anything — flipping one flag alone is never enough to show the UI or grant
network capability.

## UI architecture

All new/changed UI lives in `KitchenManager/GuestMergeViews.swift`, wired from
`KitchenManager/Authentication/AccountViews.swift`'s `AccountView` (signed-in
only — Guest mode shows a different, existing entry point in
`MainFeatureViews.swift`'s "我的" tab that only links to the login screen,
never any merge/sync UI).

- **`GuestMergePromptView`** — the non-blocking card ("发现本地库存"). Shown
  only when signed in, both flags on, and local Guest inventory exists. Its
  own `.task` calls `preparePreview` (local-only, no `remoteTransport`, so
  zero network calls) to keep the summary counts fresh; tapping the button
  opens the full flow in a sheet. "稍后处理" (a toolbar button inside the
  sheet) dismisses without any state change — the session, if one already
  exists, is simply left as-is for next time.
- **`InventoryMergeFlowView`** — routes on `session.status` to the preview,
  conflict, progress, or result screen. Unchanged routing logic from
  Phase 2B-1, now driving the enriched screens below.
- **`InventoryMergePreviewView`** — now also shows the target household name,
  cloud-side known-item count (`plan.knownRemoteItemCount`, populated by the
  Phase 2B-2 pre-merge read when a `remoteTransport` is supplied — the
  ordinary in-app preview passes `nil` and this stays `0`), and a breakdown of
  conflicts by type (quantity / expiry / metadata / ambiguous) using the new
  `InventoryMergePlan.quantityConflicts` / `.expiryConflicts` /
  `.metadataConflicts` / `.ambiguousConflicts` computed properties (`ambiguous`
  merges `.ambiguousDuplicate` and `.multipleRemoteCandidates`). Never shows a
  UUID, mutation id, cursor, token, or internal household id — confirmed by a
  Node semantic-guard test. A `.failed` session's button relabels to "重试合并"
  and a friendly (never raw) error message is derived from the session's
  `lastErrorCode`.
- **`InventoryMergeConflictView`** — now shows local vs. remote quantity *and*
  expiry side by side, a plain-language reason line per conflict type, and a
  fourth picker option, "稍后处理" (`InventoryMergeConflictChoice.skip` — new;
  see below). When the user picks "两条都保留" on a same-id conflict, an
  explicit notice explains that a second, independent record will be created
  (the Phase 2B-2.5 identity-fork behavior) — never silently.
- **`InventoryMergeResultView`** — unchanged rollback flow; the previously
  dead "重试失败项" affordance was removed (a session only ever reaches this
  screen via `.completed`/`.rolledBack`, and `.completed` is only reached when
  `failedCount == 0` by construction — a `.failed` session routes to the
  preview screen instead, where "重试合并" is the real retry path).
- **`InventorySyncStatusView`** (new) — shown whenever signed in with a
  household, independent of whether a merge session exists or Guest data is
  present. Shows a plain-language status (未开启 / 尚未登录 / 没有可同步的家庭 /
  正在同步 / 已同步 / 需要重新登录 / 暂时离线 / 同步遇到问题 / 待同步 N 项) and, when
  eligible, a single "立即同步库存" button that calls `GuestMergeController.syncNow`.
  Never shows raw `SyncError`/HTTP details — mapped through
  `GuestMergeController.userFacingSyncError`.

## New conflict choice: `.skip`

`InventoryMergeConflictChoice` gained a fourth case, `.skip` — "稍后处理" for a
single conflict item. `applyingChoice(.skip)` sets `action = .skip,
forkedLocalItemId = nil`: behaviorally identical to leaving the conflict
unresolved (never uploaded, never overwrites anything, `readyToUpload` never
includes it), except `userChoice` becomes non-nil so `needsDecision` turns
`false` — it drops off the "还需处理" list instead of nagging the user on every
revisit, and the choice is persisted/restart-safe exactly like the other
three.

## Manual sync (`GuestMergeController.syncNow`)

The **only** new production call site of `SyncCoordinator.runOnce` outside of
`confirmMerge`/`rollback` — always in direct response to a user tapping "立即
同步库存". Requires `isFeatureEnabled` and a signed-in `authStore.currentUserID`;
scoped to `.inventoryItem` only, via a locally-scoped
`SyncConfiguration(isEnabled: true)` (never the global flag file, same
pattern as `confirmMerge`). A Node test counts exactly three `runOnce` call
sites in the whole file (`confirmMerge`, `rollback`, `syncNow`) so any future
addition is a deliberate, reviewed change, not an accidental new automatic
trigger. `pendingInventoryCount(householdId:)` is a read-only helper for the
status label, never used to decide whether to sync.

Not automatic anywhere: App startup, sign-in, a timer, and every background
path remain untouched — a Node test confirms `runOnce` never appears in
`ContentView.swift` (outside `#if DEBUG`), `AuthStore.swift`, or
`MainFeatureViews.swift`.

## CRUD-to-sync boundary — decision made, wiring deferred

Section 十四 of the Phase 2B-3 brief asked for a decision on whether ordinary
Inventory CRUD (add/edit/delete outside the merge flow) should start
generating `PendingMutation`s once a device has completed a merge. The
conservative policy specified there (stage only when the entity already has
local `SyncMetadata` in `.synced` state, the merge is complete, and
`INVENTORY_SYNC_ENABLED` is on) is the correct target design, but **wiring it
into `KitchenStore`'s actual CRUD methods (`addInventory`, `importInventory`,
`deleteInventory`, and in-place quantity/expiry edits) is deliberately
deferred to a future phase**, not implemented here. Reasoning: `KitchenStore`
today has zero dependency on `AuthStore`/sync/household-scope state — this is
an intentional, load-bearing architectural boundary (documented since Phase
1: "Authentication has no dependency on `KitchenStore`... so login and logout
do not upload, clear, merge, or switch local kitchen data"). Threading
persistence/auth/household context into every inventory write path to satisfy
the conservative policy is a real, non-trivial architecture change with wide
blast radius, and rushing it risked exactly the outcome section 十四
explicitly warns against ("不要把所有现有库存写入路径一次性改成默认联网"). Until that
follow-up phase, "立即同步库存" only pushes/pulls whatever the merge itself
already staged (`readyToUpload`) plus anything already pending from a prior
attempt — ordinary post-merge inventory edits remain purely local and do not
generate a `PendingMutation`, which is the safe, unsurprising default.

## Account isolation (unchanged, re-verified)

Merge sessions remain keyed by `(userId, householdId, entityType)`
(Phase 2B-1); the new UI reads/writes nothing outside `GuestMergeController`'s
existing published state, which is itself entirely per-controller-instance —
there is one shared `GuestMergeController` instance in the environment, and
its `session`/`plan`/`isSyncing`/`lastSyncOutcome` are all reset to whatever
`preparePreview`/`syncNow` naturally resolve to for the *current* signed-in
user on each call. `GuestMergeTests.testUserAAndUserBSessionsAreFullyIsolated`
(pre-existing, unmodified) continues to cover the underlying guarantee.

## Testing

- 7 new `GuestMergeTests` cases: `INVENTORY_MERGE_UI_ENABLED` default-off and
  independence from the network flag, `.skip` choice persistence/no-upload/
  no-fork, `syncNow` refusing without the flag/sign-in and running the
  coordinator once when eligible, `pendingInventoryCount` accuracy. All pass
  alongside the full pre-existing 49-case suite (56 total).
- 19 new Node semantic-guard assertions in
  `test/ios-native-guest-merge-phase2b1.test.mjs`: the new flag's default-off
  state, exactly-three `runOnce` call sites, sign-in/App-launch never
  triggering sync, preview still creating zero mutations, `syncNow`'s scope
  and guard clauses, no service-role/raw-token/print in the UI, the identity-
  fork semantics surviving the new `.skip` case, Shopping/Plan/Recipe entity
  types absent everywhere, stable accessibility identifiers, 44pt touch
  targets, all four conflict choices present, and no UUID/mutation id/cursor/
  token ever shown in the preview screen.
- 1 new, real, credential-free XCUITest
  (`GuestMergeUIPhase2B3UITests.testGuestModeSettingsTabExplainsInventoryBackupWithoutShowingAnyMergeUI`)
  verifies, on the actual running app: the Guest-mode "我的" tab shows the
  updated backup-explanation copy, no merge/sync UI element exists before
  sign-in, and tapping through to the login screen doesn't crash or leak any
  merge UI. The full merge/preview/conflict/result/rollback/sync flow is
  exercised at the controller level (identical code path a `View` would
  drive) by the mock-transport `GuestMergeTests` suite — a true signed-in
  XCUITest walk of the merge sheet would require real test-account
  credentials, which this phase explicitly avoids using in ordinary tests.

## Not yet implemented

- Automatic/background sync, any timer or polling.
- Realtime.
- Shopping / Today Plan / Weekly Plan / Recipe sync or merge.
- Household invitation.
- CRUD-to-sync wiring for ordinary (non-merge) inventory edits (see above —
  policy decided, implementation deferred).
- Public/production enablement of either feature flag — both remain `NO` in
  every committed and Release configuration; enabling them for real users is
  an explicit, separate release decision outside this phase's scope.

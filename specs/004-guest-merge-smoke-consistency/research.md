# Research: GuestMergeSmoke direct-call consistency window

**Feature**: 004 | **Date**: 2026-09-12 | **Baseline commit**: `2f436899e8c10cbf1fbb78b98270f5eabb9f2434`

All line numbers are as of the baseline commit and are anchors for review, not stable addresses.

## 1. The governing contract (D-028, D-029)

Extracted from the canonical vault Decision D-028 (`Active`, `21bd030`) and D-029 (`Active`,
`fadd26e`), cross-checked against the implementation. This feature changes neither.

- **The unit of the boundary is one operation, not one coordinator run.** Merge and rollback write
  `InventoryRecord` during *staging*, through `stageUpsert`/`stageDelete` →
  `commitInventoryAndSync`, which happens before the coordinator is even constructed. Wrapping
  only `runOnce` leaves the "durable write happened, memory never caught up" window open — R1
  itself.
- **Fail closed**: with no reconciliation target the operation does not start.
- **The window is held by a depth counter, not a Bool**, because two different mutual-exclusion
  flags guard the production operations and they really can overlap.
- **Reconciliation failure keeps the store locked**, and is retryable by calling end again.
- **The edit gate lives in `KitchenStore.inventory.didSet`**, not in a View, because SwiftUI
  bindings write the array directly. Bulk paths that write the database before publishing are
  refused at their entry instead.
- **Reconciliation bypasses the gate via `publishDurableInventory`**, suppressing both
  persistence write-back and outbound staging, so a reconcile can never echo pulled changes back
  out.
- D-029: rollback never physically deletes a local durable inventory row;
  `stageDeleteRemovingLocalRecord` is the destructive helper and its only permitted callers are
  the two smoke files, enforced by a whole-tree Node guard.

**Decision**: reuse the existing primitive unchanged.
**Rationale**: `KitchenStore.beginInventorySyncConsistencyWindow()` /
`endInventorySyncConsistencyWindow()` are already internal, already depth-counted, and
`SyncSmokeController` already drives them with the same begin / defer-end shape from a smoke
context (`SyncSmoke.swift:348`, `:363`). Nothing needs to be newly exposed.
**Alternatives considered**: exposing a new boundary API on `GuestMergeController` — rejected,
the controller's `withInventoryConsistencyBoundary` is private and correctly scoped to its own
three operations; widening it would add a second public path into the same primitive.

## 2. Direct-path inventory

Classification: **A** already protected, **B** requires D-028-equivalent protection,
**C** intentionally outside, **D** needed a design decision.

### Category B — must be wrapped

| # | Site | Call | Why it affects inventory truth |
|---|---|---|---|
| B1 | `runRemainingPhases` duplicate-retry block, 372 | `duplicateAdapter.stageUpsert` | writes `InventoryRecord` via `commitInventoryAndSync` |
| B2 | 378 | `duplicateCoordinator.runOnce` | pull can apply remote changes to durable inventory |
| B3 | 385 | `persistence.savePending` | requeues the original mutation for resend |
| B4 | 386 | second `runOnce` | same as B2 |
| B5 | 396 | `duplicateAdapter.stageDeleteRemovingLocalRecord` | physically removes the local durable row |
| B6 | 397 | `runOnce` | same as B2 |
| B7 | 449 | `finalCoordinator.runOnce` (final pull) | pull writes durable inventory |
| B8 | `runProductionRemotePreviewMinimalSmoke` 999 | `adapter.stageUpsert` (simulated second device) | same as B1 |
| B9 | 1001 | `updateCoordinator.runOnce` | same as B2 |
| B10 | `bestEffortCleanup` 1062, 1064 | `stageDeleteRemovingLocalRecord` loop + `runOnce` | destructive local delete plus a pull |

B1–B6 form one logical operation and take **one** window. B7, B8–B9 and B10 take their own.
B10 is reached from all five runners, on both the success and the `catch` path.

### Category A — already protected

Every `controller.confirmMerge`, `controller.rollback` and `controller.syncNow` call in the file.
`21bd030` already assigns `controller.kitchenStore` at every construction site, so
`withInventoryConsistencyBoundary` has its reconciliation target.

### Category C — intentionally outside

| Site | Call | Why it must stay outside |
|---|---|---|
| 213, 253, 308, 315, 527, 538, 670, 682, 702, 793, 804, 844, 934, 952 | `kitchenStore.inventory = …`, `importInventory` | scenario construction; these are ordinary local edits and the D-028 edit gate would **refuse** them inside a window |
| 651, 671, 683, 784, 794, 805, 845 | `controller.handleInventoryDidChange` | the production local-edit staging path, which in the real app also runs outside any window |
| 635, 766 | `persistence.saveEnrollment` | enrollment state, not inventory truth |
| 373, 380, 388, 451, 957, 987, 1010, 1018 | `pendingMutation`, `metadata`, `pendingMutations` | reads |

This is why a single window around the whole runner is wrong: it would refuse the very edits the
scenarios are built from.

### Category D — resolved

**D1: does reconciliation erase the simulated second-device test condition?**

The concern: closing the B8–B9 window republishes durable inventory into `KitchenStore.inventory`
before the stale-confirm assertion at 1011.

**Resolution: no, and the existing assertions already prove it.** The stale-confirm gate compares
`plan.remoteSnapshotHash`, captured at preview time, against a freshly fetched *remote* snapshot
(`GuestMergeController.swift:668-683`). Reconciliation only republishes *local* durable state; it
touches neither the persisted plan nor the remote. The rejection therefore still fires. The run
then asserts both the rejection (1012, 1015, 1018) and that a fresh preview still reports
`.ambiguousDuplicate` (1030). If reconciliation ever did damage the scenario, those existing
assertions fail loudly rather than passing silently, so no new mechanism is needed.

**D2: is a runner-specific helper justified?**

Yes, minimally. The controller's boundary is private and non-throwing, while the smoke's blocks
are `throws`. A ~12-line throwing helper in the smoke file that opens the window, closes it on
every path, and converts a failed reconciliation into
`GuestMergeSmokeError.validationFailed` is smaller and safer than repeating begin/end at ten call
sites. `bestEffortCleanup` is non-throwing by contract and uses the same primitive directly,
returning whether reconciliation succeeded so a success-path caller can refuse to claim a clean
run.

**D3: cleanup needs a reconciliation target on the `catch` path.**

In four runners `kitchenStore` is declared *inside* the `do` block, so the `catch` cannot see it.
`persistence` was already hoisted above the `do` in `runIdentityForkMinimalSmoke` for exactly this
kind of reason (see its comment at 510-514). The same hoist is required for `kitchenStore`.

## 3. Discovered blocker — baseline seeding cannot complete

**Classification (frozen at spec review): prerequisite harness-integrity repair.** It is
independent of the consistency window and defeats the same goal. It is not a new D-028 semantic,
not part of the window mechanism, not production behavior, and not sync enablement.

Three runners seed a baseline by calling the no-transport preview overload and then confirming:

- `runRemainingPhases` 229 → 230
- `runIdentityForkMinimalSmoke` 532 → 555 (via `baselineController`)
- `runProductionRemotePreviewMinimalSmoke` 939 → 940

`InventoryMergePlanner` computes the remote fingerprint only when a real fetch happened:

    let remoteHash = remoteSnapshotFetchedAt != nil ? remoteSnapshotHash(knownRemoteItems) : nil

(`InventoryMergePlanner.swift:142`), and `preparePreview` sets `remoteSnapshotFetchedAt` only when
a transport was supplied (`GuestMergeController.swift:213`). `performConfirmMerge` then refuses a
plan with no fingerprint:

    guard plan.remoteSnapshotHash != nil else {
        lastErrorMessage = "请重新查看合并预览后再确认。"
        return
    }

(`GuestMergeController.swift:653`). The controller's own comment states the intent plainly: the
no-transport overload "stays available for local preview and tests; its plans simply can never be
confirmed in production."

**Consequence**: each of those three runners throws
`validationFailed("baseline … did not complete")` before reaching any checkpoint. The harness
cannot currently demonstrate the success criteria this feature is meant to make trustworthy.

**Decision**: fix it inside this feature (FR-011) by giving the baseline preview the same real
transport the other previews already use. **Rationale**: it is a one-argument change per site in
the same DEBUG-only file, and it is a hard prerequisite for the hosted acceptance in this feature;
leaving it out would ship a protected-but-unrunnable harness.
**Alternatives considered**: a separate bug-fix change — rejected, it would block this feature's
own acceptance evidence and split one file's repair across two reviews. The owner confirmed this
at spec review and froze the classification above.

**What this repair is not.** The production confirmation gate is behaving exactly as designed: a
plan with no remote fingerprint must never be confirmable. The defect is that the harness builds
such a plan and then tries to confirm it. Nothing here implies D-028 or the fingerprint gate was
wrong, and no production merge behavior changes.

## 4. Test feasibility

Deterministic runner-level tests are possible; this was verified rather than assumed.

- `GuestMergeSmokeConfiguration` has a memberwise initializer, so all four gates can be set
  directly.
- `APIEnvironment.current` is `.development` under `#if DEBUG`, and the unit test target is
  DEBUG, so the environment gate passes.
- `GuestMergeSmokeRunner.init` takes an injectable `transportFactory`.
- `AuthStore` is constructible from a fake auth service; `GuestMergeTests.swift:5408` already has
  a `signedInAuthStore(userID:)` helper, and `SyncSmokeTests.swift` already drives a full smoke
  runner deterministically with a fake transport
  (`testControlledInventorySmokeCompletesWithoutTouchingExistingGuestItem`).

**Decision**: model the new tests on `SyncSmokeTests`, with a fake transport that can be told to
fail a specific push or pull, and a persistence/inventory double that can fail a durable load to
exercise the reconciliation-failure path.

## 5. Drift guard

**Decision**: extend the existing Node guard file `test/ios-native-guest-merge-phase2b1.test.mjs`.
**Rationale**: it already reads `GuestMergeSmoke.swift` and already enforces call-site rules for
`stageDeleteRemovingLocalRecord` across the whole tree (lines 93-125), so the new assertion joins
an established, proven pattern instead of inventing a second mechanism.
**Alternatives considered**: a new test file — rejected, it would split one file's call-site rules
across two guards.



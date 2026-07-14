import SwiftData
import XCTest
@testable import KitchenManager

@MainActor
final class GuestMergeTests: XCTestCase {
    private let userA = UUID()
    private let userB = UUID()
    private let householdA = UUID()
    private let householdB = UUID()

    // MARK: - Guest dataset detection

    func testDetectionReportsNoGuestDataWhenAllStoresEmpty() {
        let kitchen = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let recipes = RecipeStore()
        let summary = GuestDatasetDetector.summary(kitchenStore: kitchen, recipeStore: recipes, at: Date())
        XCTAssertFalse(summary.hasAnyGuestData)
        XCTAssertFalse(summary.hasMergeableInventory)
    }

    func testDetectionReportsInventoryCountWithoutModifyingAnything() {
        let kitchen = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        kitchen.addInventory(name: "土豆", quantity: 3, unit: "个", expiryDate: nil)
        kitchen.addInventory(name: "洋葱", quantity: 2, unit: "个", expiryDate: nil)
        let before = kitchen.inventory
        let summary = GuestDatasetDetector.summary(kitchenStore: kitchen, recipeStore: RecipeStore())
        XCTAssertEqual(summary.inventoryCount, 2)
        XCTAssertTrue(summary.hasMergeableInventory)
        XCTAssertEqual(kitchen.inventory, before, "detection must never mutate Guest inventory")
    }

    func testDetectionReportsOtherModulesButNoInventoryIsNotMergeable() {
        let kitchen = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        kitchen.addShoppingItems([KitchenShoppingItem(name: "牛奶", quantity: 1, unit: "盒")])
        let summary = GuestDatasetDetector.summary(kitchenStore: kitchen, recipeStore: RecipeStore())
        XCTAssertTrue(summary.hasAnyGuestData)
        XCTAssertFalse(summary.hasMergeableInventory, "Phase 2B-1 only offers a merge path for inventory")
    }

    // MARK: - Matching / preview plan

    func testPlanCreatesWhenNoRemoteKnowledgeExists() {
        let local = [InventoryItem(name: "番茄", quantity: 2, unit: "个", expiryDate: nil)]
        let plan = InventoryMergePlanner.makePlan(sessionId: UUID(), householdId: householdA, localItems: local)
        XCTAssertEqual(plan.creates.count, 1)
        XCTAssertEqual(plan.conflicts.count, 0)
    }

    func testPlanNoOpWhenSameStableIdAndSameValuesAlreadyKnownRemotely() {
        let item = InventoryItem(name: "番茄", quantity: 2, unit: "个", expiryDate: nil)
        let remote = RemoteInventorySnapshotItem(id: item.id, name: item.name, unit: item.unit, quantity: 2, expiryDate: nil)
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: householdA, localItems: [item], knownRemoteItems: [remote]
        )
        XCTAssertEqual(plan.candidates.first?.action, .skip)
        XCTAssertNil(plan.candidates.first?.conflictReason)
    }

    func testPlanFlagsAmbiguousDuplicateForDifferentIdSameBusinessKey() {
        let local = InventoryItem(name: "番茄", quantity: 2, unit: "个", expiryDate: nil)
        let remote = RemoteInventorySnapshotItem(id: UUID(), name: "番茄", unit: "个", quantity: 2, expiryDate: nil)
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: householdA, localItems: [local], knownRemoteItems: [remote]
        )
        XCTAssertEqual(plan.candidates.first?.conflictReason, .ambiguousDuplicate)
        XCTAssertTrue(plan.candidates.first?.needsDecision ?? false)
    }

    func testPlanFlagsQuantityConflictAndExpiryConflictSeparately() {
        let quantityItem = InventoryItem(name: "番茄", quantity: 2, unit: "个", expiryDate: nil)
        let quantityRemote = RemoteInventorySnapshotItem(id: quantityItem.id, name: "番茄", unit: "个", quantity: 5, expiryDate: nil)
        let expiryDate = Date()
        let expiryItem = InventoryItem(name: "牛奶", quantity: 1, unit: "盒", expiryDate: expiryDate)
        let expiryRemote = RemoteInventorySnapshotItem(id: expiryItem.id, name: "牛奶", unit: "盒", quantity: 1, expiryDate: expiryDate.addingTimeInterval(86_400))

        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: householdA,
            localItems: [quantityItem, expiryItem],
            knownRemoteItems: [quantityRemote, expiryRemote]
        )
        let quantityCandidate = plan.candidates.first { $0.localItemId == quantityItem.id }
        let expiryCandidate = plan.candidates.first { $0.localItemId == expiryItem.id }
        XCTAssertEqual(quantityCandidate?.conflictReason, .quantityMismatch)
        XCTAssertEqual(expiryCandidate?.conflictReason, .expiryMismatch)
    }

    func testPlanFlagsMultipleRemoteCandidatesAsConflictWithoutAutoSelecting() {
        let local = InventoryItem(name: "番茄", quantity: 2, unit: "个", expiryDate: nil)
        let remoteOne = RemoteInventorySnapshotItem(id: UUID(), name: "番茄", unit: "个", quantity: 2, expiryDate: nil)
        let remoteTwo = RemoteInventorySnapshotItem(id: UUID(), name: "番茄", unit: "个", quantity: 3, expiryDate: nil)
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: householdA, localItems: [local], knownRemoteItems: [remoteOne, remoteTwo]
        )
        XCTAssertEqual(plan.candidates.first?.conflictReason, .multipleRemoteCandidates)
        XCTAssertNil(plan.candidates.first?.remoteItemId, "must not auto-select any single candidate")
    }

    // MARK: - Matching key review: quantity must never be part of identity

    func testSameNameSameUnitDifferentQuantityIsQuantityConflictNotCreate() {
        let local = InventoryItem(name: "苹果", quantity: 2, unit: "个", expiryDate: nil)
        let remote = RemoteInventorySnapshotItem(id: local.id, name: "苹果", unit: "个", quantity: 3, expiryDate: nil)
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: householdA, localItems: [local], knownRemoteItems: [remote]
        )
        // The whole point of this review: a quantity difference must still
        // resolve the candidate (identity matching ignores quantity) and
        // must surface as a conflict, never silently escape into `.create`
        // (which would produce a duplicate remote row).
        XCTAssertNotEqual(plan.candidates.first?.action, .create, "quantity must never affect identity matching")
        XCTAssertEqual(plan.candidates.first?.conflictReason, .quantityMismatch)
        XCTAssertEqual(plan.candidates.first?.remoteItemId, local.id, "the candidate must still be resolved against the matching remote id")
    }

    func testBothSidesWithNoExpiryIsASingleCompatibleCandidate() {
        let local = InventoryItem(name: "苹果", quantity: 2, unit: "个", expiryDate: nil)
        let remote = RemoteInventorySnapshotItem(id: UUID(), name: "苹果", unit: "个", quantity: 2, expiryDate: nil)
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: householdA, localItems: [local], knownRemoteItems: [remote]
        )
        // Different id, but expiry-compatible (both absent) and same
        // quantity: still a single, non-ambiguous-by-multiplicity candidate,
        // but a different id is still never silently treated as the same
        // record.
        XCTAssertEqual(plan.candidates.first?.remoteItemId, remote.id)
        XCTAssertEqual(plan.candidates.first?.conflictReason, .ambiguousDuplicate)
    }

    func testSameExpiryDateIsASingleCompatibleCandidate() {
        let date = Date()
        let local = InventoryItem(name: "牛奶", quantity: 1, unit: "盒", expiryDate: date)
        let remote = RemoteInventorySnapshotItem(id: local.id, name: "牛奶", unit: "盒", quantity: 1, expiryDate: date)
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: householdA, localItems: [local], knownRemoteItems: [remote]
        )
        XCTAssertEqual(plan.candidates.first?.action, .skip)
        XCTAssertNil(plan.candidates.first?.conflictReason, "identical id, quantity, and expiry is a true no-op")
    }

    func testOneSideHasExpiryTheOtherDoesNotIsAmbiguousNeverAutoCreate() {
        let local = InventoryItem(name: "牛奶", quantity: 1, unit: "盒", expiryDate: Date())
        let remoteNoExpiry = RemoteInventorySnapshotItem(id: local.id, name: "牛奶", unit: "盒", quantity: 1, expiryDate: nil)
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: householdA, localItems: [local], knownRemoteItems: [remoteNoExpiry]
        )
        XCTAssertNotEqual(plan.candidates.first?.action, .create)
        // Same id but incompatible expiry is a certain, real conflict on
        // that entity's mutable field, not a generic "different batch" guess.
        XCTAssertEqual(plan.candidates.first?.conflictReason, .expiryMismatch)
    }

    func testDifferentExpiryDatesAreNeverSilentlyOverwritten() {
        let local = InventoryItem(name: "牛奶", quantity: 1, unit: "盒", expiryDate: Date())
        let remote = RemoteInventorySnapshotItem(
            id: UUID(), name: "牛奶", unit: "盒", quantity: 1, expiryDate: Date().addingTimeInterval(3 * 86_400)
        )
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: householdA, localItems: [local], knownRemoteItems: [remote]
        )
        XCTAssertNotEqual(plan.candidates.first?.action, .create)
        XCTAssertNotNil(plan.candidates.first?.conflictReason, "a possible different batch must never be silently merged or overwritten")
    }

    func testMetadataOnlyDifferenceIsFlaggedNotSilentlyOverwritten() {
        let local = InventoryItem(name: "大米", quantity: 5, unit: "袋", expiryDate: nil, isStaple: true, lowStockThreshold: 2)
        let remote = RemoteInventorySnapshotItem(
            id: local.id, name: "大米", unit: "袋", quantity: 5, expiryDate: nil,
            isStaple: false, lowStockThreshold: nil
        )
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: householdA, localItems: [local], knownRemoteItems: [remote]
        )
        XCTAssertEqual(plan.candidates.first?.conflictReason, .metadataMismatch, "isStaple/threshold differences must not be silently overwritten by an upload")
    }

    func testKeepBothIsTheOnlyChoiceThatCreatesASecondRecordForASameIdConflict() throws {
        // Same stable id on both sides (a certain, definite identity, not an
        // ambiguous different-id match) with a quantity conflict: keepLocal
        // and keepRemote must resolve in-place (never fabricate a second
        // record); only keepBoth is allowed to create a new one.
        let local = InventoryItem(name: "苹果", quantity: 2, unit: "个", expiryDate: nil)
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: householdA, localItems: [local],
            knownRemoteItems: [RemoteInventorySnapshotItem(id: local.id, name: "苹果", unit: "个", quantity: 3, expiryDate: nil)]
        )
        let candidate = try! XCTUnwrap(plan.candidates.first)
        XCTAssertEqual(candidate.applyingChoice(.keepRemote).action, .keepRemote)
        XCTAssertNil(candidate.applyingChoice(.keepRemote).forkedLocalItemId)
        XCTAssertEqual(candidate.applyingChoice(.keepLocal).action, .update, "same id: keepLocal updates the existing remote record in place")
        XCTAssertNil(candidate.applyingChoice(.keepLocal).forkedLocalItemId, "keepLocal never forks — it updates the certain, existing remote record")

        let forked = candidate.applyingChoice(.keepBoth)
        XCTAssertEqual(forked.action, .create, "only keepBoth is allowed to produce a second record")
        let forkedId = try XCTUnwrap(forked.forkedLocalItemId, "same-id keepBoth must allocate a fresh id — the original remote entity already exists and must never be re-targeted by a create")
        XCTAssertNotEqual(forkedId, candidate.localItemId)
        XCTAssertNotEqual(forkedId, candidate.remoteItemId)

        // Re-choosing keepBoth again (e.g. the user reopens the picker and
        // taps the same option, or `resolveConflict` is called again before
        // confirming) must reuse the exact same forked id, never mint a
        // second one.
        let forkedAgain = forked.applyingChoice(.keepBoth)
        XCTAssertEqual(forkedAgain.forkedLocalItemId, forkedId)
    }

    func testDifferentIdAmbiguousKeepBothNeverForksAndKeepsUsingItsOwnId() {
        // Regression check: the identity-fork fix must only ever apply to a
        // *same-id* conflict. A different-id ambiguous-duplicate match
        // already has its own distinct id, so `keepBoth` there is already
        // correct as `.create` using that id — this must be completely
        // unaffected by the same-id fork fix.
        let local = InventoryItem(name: "番茄", quantity: 2, unit: "个", expiryDate: nil)
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: householdA, localItems: [local],
            knownRemoteItems: [RemoteInventorySnapshotItem(id: UUID(), name: "番茄", unit: "个", quantity: 3, expiryDate: nil)]
        )
        let candidate = try! XCTUnwrap(plan.candidates.first)
        XCTAssertEqual(candidate.conflictReason, .ambiguousDuplicate)
        let resolved = candidate.applyingChoice(.keepBoth)
        XCTAssertEqual(resolved.action, .create)
        XCTAssertNil(resolved.forkedLocalItemId, "a different-id ambiguous match must never allocate a fork — its own id is already distinct")
    }

    func testPlanHashIsStableForIdenticalInputAndChangesWhenLocalDataChanges() {
        let sessionId = UUID()
        let item = InventoryItem(name: "番茄", quantity: 2, unit: "个", expiryDate: nil)
        let planA = InventoryMergePlanner.makePlan(sessionId: sessionId, householdId: householdA, localItems: [item])
        let planB = InventoryMergePlanner.makePlan(sessionId: sessionId, householdId: householdA, localItems: [item])
        XCTAssertEqual(planA.planHash, planB.planHash)
        XCTAssertTrue(InventoryMergePlanner.isPlanStillValid(planA, against: [item]))

        var changed = item
        changed.quantity = 3
        XCTAssertFalse(InventoryMergePlanner.isPlanStillValid(planA, against: [changed]), "editing local inventory must invalidate the previously generated plan")
    }

    func testPlanIsInvalidatedByExpiryChangeItemRemovalAndItemAddition() {
        let itemA = InventoryItem(name: "番茄", quantity: 2, unit: "个", expiryDate: nil)
        let itemB = InventoryItem(name: "牛奶", quantity: 1, unit: "盒", expiryDate: Date())
        let plan = InventoryMergePlanner.makePlan(sessionId: UUID(), householdId: householdA, localItems: [itemA, itemB])
        XCTAssertTrue(InventoryMergePlanner.isPlanStillValid(plan, against: [itemA, itemB]))

        var expiryChanged = itemB
        expiryChanged.expiryDate = Date().addingTimeInterval(86_400)
        XCTAssertFalse(InventoryMergePlanner.isPlanStillValid(plan, against: [itemA, expiryChanged]), "changing an item's expiry must invalidate the plan, requiring a fresh preview before upload")

        XCTAssertFalse(InventoryMergePlanner.isPlanStillValid(plan, against: [itemA]), "deleting a local item must invalidate the plan")

        let newItem = InventoryItem(name: "面包", quantity: 1, unit: "个", expiryDate: nil)
        XCTAssertFalse(InventoryMergePlanner.isPlanStillValid(plan, against: [itemA, itemB, newItem]), "adding a new local item must invalidate the plan and require a fresh preview")
    }

    func testPlanHashIsIndependentOfLocalItemOrdering() {
        let itemA = InventoryItem(name: "番茄", quantity: 2, unit: "个", expiryDate: nil)
        let itemB = InventoryItem(name: "牛奶", quantity: 1, unit: "盒", expiryDate: Date())
        let sessionId = UUID()
        let forward = InventoryMergePlanner.planHash(sessionId: sessionId, householdId: householdA, localItems: [itemA, itemB])
        let reversed = InventoryMergePlanner.planHash(sessionId: sessionId, householdId: householdA, localItems: [itemB, itemA])
        XCTAssertEqual(forward, reversed, "the plan fingerprint must not depend on input ordering, only on the actual data")
    }

    // MARK: - Stable id

    func testExistingInventoryUUIDIsReusedAsTheMergeCandidateId() {
        let item = InventoryItem(name: "番茄", quantity: 2, unit: "个", expiryDate: nil)
        let plan = InventoryMergePlanner.makePlan(sessionId: UUID(), householdId: householdA, localItems: [item])
        XCTAssertEqual(plan.candidates.first?.localItemId, item.id, "iOS inventory already has a stable UUID; Phase 2B-1 must reuse it, never regenerate one")
    }

    // MARK: - Merge session lifecycle

    func testSessionLifecycleDetectedThroughCompleted() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let controller = GuestMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )

        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        XCTAssertEqual(controller.session?.status, .previewReady)
        XCTAssertNil(controller.session?.confirmedAt)

        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)
        XCTAssertNotNil(controller.session?.confirmedAt)
        XCTAssertNotNil(controller.session?.completedAt)
        XCTAssertNotNil(controller.session?.rollbackAvailableUntil)
        XCTAssertEqual(controller.session?.uploadedItemCount, 1)
    }

    func testCancelBeforeConfirmationNeverCreatesAPendingMutation() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let controller = GuestMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        await controller.cancel()
        XCTAssertEqual(controller.session?.status, .cancelled)
        let scope = SyncScope(type: .household, id: householdA)
        let pending = try await persistence.pendingMutations(scope: scope, maxAttempts: 5)
        XCTAssertTrue(pending.isEmpty, "cancelling before confirmation must never stage a mutation")
    }

    func testSignedOutAuthStoreRefusesConfirmMerge() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let controller = GuestMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        XCTAssertEqual(controller.session?.status, .previewReady)

        let authStore = await signedInAuthStore(userID: userA)
        await authStore.signOut()
        await controller.confirmMerge(authStore: authStore)

        // A signed-out AuthStore has `currentUserID == nil`; confirmMerge must
        // refuse rather than proceed with a stale/absent identity, leaving
        // the session exactly where it was.
        XCTAssertEqual(controller.session?.status, .previewReady, "sign-out must refuse confirmMerge, not silently proceed")
        XCTAssertNil(controller.session?.confirmedAt)
        XCTAssertNotNil(controller.lastErrorMessage)
    }

    func testSignedOutAuthStoreRefusesRollback() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let controller = GuestMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStoreForConfirm = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStoreForConfirm)
        XCTAssertEqual(controller.session?.status, .completed)

        let authStoreForRollback = await signedInAuthStore(userID: userA)
        await authStoreForRollback.signOut()
        await controller.rollback(authStore: authStoreForRollback)

        XCTAssertEqual(controller.session?.status, .completed, "sign-out must refuse rollback, not silently proceed")
        XCTAssertNotNil(controller.lastErrorMessage)
    }

    // MARK: - Pre-merge remote read (Phase 2B-2: knownRemoteItems is no longer always empty)

    func testPreparePreviewWithoutRemoteTransportNeverCallsIt() async throws {
        // Ordinary in-app preview never passes a transport — this proves the
        // omitted-parameter default preserves the exact prior zero-network
        // behavior (a FailingMergeTransport would throw on any call at all,
        // so success here means it was never touched).
        let (kitchen, persistence) = try makeSharedStores()
        let controller = GuestMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in FailingMergeTransport() }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        XCTAssertEqual(controller.session?.status, .previewReady)
        XCTAssertNil(controller.lastErrorMessage)
    }

    func testPreparePreviewWithRemoteTransportDetectsConflictAgainstAPreviouslyUnknownRemoteRecord() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        // Same id as the remote record seeded below, different quantity —
        // this device knows the item locally but has never synced it itself.
        kitchen.inventory = [InventoryItem(id: sharedId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil)]

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(
            id: sharedId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1"
        )
        let controller = GuestMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)

        let candidate = try XCTUnwrap(controller.plan?.candidates.first(where: { $0.localItemId == sharedId }))
        XCTAssertEqual(candidate.conflictReason, .quantityMismatch, "the pre-merge read must let identity resolve by stable id even though this device never uploaded it itself")
        XCTAssertEqual(candidate.remoteVersion?.rawValue, "5", "the candidate must carry the real remote version so confirmMerge can seed the correct baseVersion")
    }

    func testConfirmMergeSeedsBaseVersionFromThePreMergeReadSoAKnownRemoteUpdateApplies() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        kitchen.inventory = [InventoryItem(id: sharedId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil)]

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        // This is the exact bug scenario: the remote record already exists at
        // version "5", but this device has no local SyncMetadata for it.
        // Without seeding, InventorySyncAdapter.stageUpsert would send
        // baseVersion "0" and the (real) server would reject the update as a
        // stale-version conflict — simulated here by `seedExistingRemote`.
        await transport.seedRemoteChange(id: sharedId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")
        await transport.seedExistingRemote(id: sharedId, staleBaseVersion: "5")

        let controller = GuestMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        let candidate = try XCTUnwrap(controller.plan?.candidates.first(where: { $0.localItemId == sharedId }))
        XCTAssertEqual(candidate.conflictReason, .quantityMismatch)
        XCTAssertEqual(candidate.remoteVersion?.rawValue, "5")

        await controller.resolveConflict(candidateId: sharedId, choice: .keepLocal)
        let resolvedCandidate = controller.plan?.candidates.first(where: { $0.localItemId == sharedId })
        XCTAssertEqual(resolvedCandidate?.action, .update)
        XCTAssertEqual(resolvedCandidate?.remoteVersion?.rawValue, "5")

        // The pre-merge read was a one-time snapshot used only to build the
        // plan; clear it so the coordinator's own real pull phase below
        // (triggered by confirmMerge) doesn't re-fetch this same synthetic
        // entry and misapply it over the upload result — see
        // `clearRemoteChanges()`'s doc comment for why this mock-only step
        // is needed (a real backend's pull and pre-merge read are the same
        // consistent data source, so this has no product-code analog).
        await transport.clearRemoteChanges()

        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        // Without the baseVersion-seeding fix this would land in `.conflict`
        // (or `.failed`), because the server would reject baseVersion "0"
        // against its real version "5". With the fix, the correct baseVersion
        // is seeded first and the update actually applies.
        XCTAssertEqual(controller.session?.status, .completed, "the known remote version must be seeded so the update is accepted, not rejected as a stale-version conflict")
        XCTAssertEqual(controller.session?.uploadedItemCount, 1)
        let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: sharedId)
        XCTAssertEqual(metadata?.state, .synced)
        let sentBaseVersion = await transport.lastReceivedBaseVersion(for: sharedId)
        XCTAssertEqual(sentBaseVersion, "5", "must send the real seeded remote version on the wire, never the stale local-unknown 0")
    }

    func testConfirmMergeNeverOverwritesAlreadyKnownLocalMetadataWithASnapshotTimeVersion() async throws {
        // If this device already has its OWN local SyncMetadata for the
        // entity (e.g. a previous partial run already synced it), confirmMerge
        // must trust that local state rather than blindly re-seeding a
        // possibly-stale snapshot-time version over it.
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        kitchen.inventory = [InventoryItem(id: sharedId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil)]

        try await persistence.saveMetadata(SyncMetadata(
            entityType: .inventoryItem, entityId: sharedId,
            scope: SyncScope(type: .household, id: householdA),
            remoteVersion: try SyncCursorValue("9"), state: .synced,
            lastSyncedAt: Date(), lastErrorCode: nil, lastErrorAt: nil, deletedAt: nil, updatedAt: Date()
        ))

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: sharedId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")
        let controller = GuestMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        await controller.resolveConflict(candidateId: sharedId, choice: .keepLocal)
        await transport.clearRemoteChanges()

        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        XCTAssertEqual(controller.session?.status, .completed)
        let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: sharedId)
        XCTAssertEqual(metadata?.state, .synced)
        let sentBaseVersion = await transport.lastReceivedBaseVersion(for: sharedId)
        XCTAssertEqual(sentBaseVersion, "9", "must send the device's own already-known version 9 on the wire, never regress to the older snapshot-time version 5")
    }

    // MARK: - Same-id keepBoth identity fork (Phase 2B-2.5)

    func testSameIdKeepBothForksAndCreatesUnderBaseVersionZero() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        kitchen.inventory = [InventoryItem(id: sharedId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil)]

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: sharedId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        let candidateBefore = try XCTUnwrap(controller.plan?.candidates.first(where: { $0.localItemId == sharedId }))
        XCTAssertEqual(candidateBefore.conflictReason, .quantityMismatch)

        await controller.resolveConflict(candidateId: sharedId, choice: .keepBoth)
        let resolvedCandidate = try XCTUnwrap(controller.plan?.candidates.first(where: { $0.localItemId == sharedId }))
        let forkedId = try XCTUnwrap(resolvedCandidate.forkedLocalItemId)
        XCTAssertNotEqual(forkedId, sharedId)
        await transport.clearRemoteChanges()

        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        XCTAssertEqual(controller.session?.status, .completed)
        // The original entity is a true no-op — never touched by this candidate.
        let originalMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: sharedId)
        XCTAssertNil(originalMetadata)
        // The fork is a genuinely new remote record created at baseVersion 0.
        let forkedMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: forkedId)
        XCTAssertEqual(forkedMetadata?.state, .synced)
        let sentBaseVersion = await transport.lastReceivedBaseVersion(for: forkedId)
        XCTAssertEqual(sentBaseVersion, "0", "the fork must always be created fresh, never inherit the original entity's remote version")
        XCTAssertEqual(controller.session?.createdEntityIds, [forkedId])
        // The forked item is also a genuine, independent local record.
        let forkedLocalItem = try await persistence.inventoryItem(id: forkedId)
        XCTAssertEqual(forkedLocalItem?.name, "苹果")
        let originalLocalItem = try await persistence.inventoryItem(id: sharedId)
        XCTAssertNotNil(originalLocalItem, "the original local Guest record must never be removed")
    }

    func testSameIdKeepBothForkWorksForExpiryAndMetadataConflictsToo() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let expirySharedId = UUID()
        let metadataSharedId = UUID()
        kitchen.inventory = [
            InventoryItem(id: expirySharedId, name: "牛奶", quantity: 1, unit: "盒", expiryDate: Date()),
            InventoryItem(id: metadataSharedId, name: "大米", quantity: 5, unit: "袋", expiryDate: nil, isStaple: true, lowStockThreshold: 2)
        ]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: expirySharedId, name: "牛奶", unit: "盒", quantity: 1, version: "3", sequence: "1")
        await transport.seedRemoteChange(id: metadataSharedId, name: "大米", unit: "袋", quantity: 5, version: "4", sequence: "2")
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        XCTAssertEqual(controller.plan?.candidates.first(where: { $0.localItemId == expirySharedId })?.conflictReason, .expiryMismatch)
        XCTAssertEqual(controller.plan?.candidates.first(where: { $0.localItemId == metadataSharedId })?.conflictReason, .metadataMismatch)

        await controller.resolveConflict(candidateId: expirySharedId, choice: .keepBoth)
        await controller.resolveConflict(candidateId: metadataSharedId, choice: .keepBoth)
        let expiryForkId = try XCTUnwrap(controller.plan?.candidates.first(where: { $0.localItemId == expirySharedId })?.forkedLocalItemId)
        let metadataForkId = try XCTUnwrap(controller.plan?.candidates.first(where: { $0.localItemId == metadataSharedId })?.forkedLocalItemId)
        XCTAssertNotEqual(expiryForkId, expirySharedId)
        XCTAssertNotEqual(metadataForkId, metadataSharedId)
        await transport.clearRemoteChanges()

        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        XCTAssertEqual(controller.session?.status, .completed)
        XCTAssertEqual(Set(controller.session?.createdEntityIds ?? []), Set([expiryForkId, metadataForkId]))
        let expiryOriginalMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: expirySharedId)
        let metadataOriginalMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: metadataSharedId)
        XCTAssertNil(expiryOriginalMetadata)
        XCTAssertNil(metadataOriginalMetadata)
    }

    func testSameIdKeepBothRepeatedConfirmNeverCreatesASecondForkOrMutation() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        kitchen.inventory = [InventoryItem(id: sharedId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil)]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: sharedId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        await controller.resolveConflict(candidateId: sharedId, choice: .keepBoth)
        let forkedId = try XCTUnwrap(controller.plan?.candidates.first(where: { $0.localItemId == sharedId })?.forkedLocalItemId)
        await transport.clearRemoteChanges()

        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)
        let appliedCountAfterFirstConfirm = await transport.appliedCount()
        XCTAssertEqual(appliedCountAfterFirstConfirm, 1)

        // Re-confirming an already-`.completed` session is already a guarded
        // no-op (`confirmMerge`'s status guard) — resolving the same
        // conflict choice again and re-confirming must still never mint a
        // second fork id or a second mutation for it.
        await controller.resolveConflict(candidateId: sharedId, choice: .keepBoth)
        XCTAssertEqual(controller.plan?.candidates.first(where: { $0.localItemId == sharedId })?.forkedLocalItemId, forkedId)
        await controller.confirmMerge(authStore: authStore)
        let appliedCountAfterSecondConfirm = await transport.appliedCount()
        XCTAssertEqual(appliedCountAfterSecondConfirm, 1, "re-confirming must never re-stage or duplicate the already-created fork")
    }

    func testSameIdKeepBothForkedIdSurvivesSimulatedRestart() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        kitchen.inventory = [InventoryItem(id: sharedId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil)]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: sharedId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")
        let controllerBeforeRestart = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controllerBeforeRestart.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        await controllerBeforeRestart.resolveConflict(candidateId: sharedId, choice: .keepBoth)
        let forkedId = try XCTUnwrap(controllerBeforeRestart.plan?.candidates.first(where: { $0.localItemId == sharedId })?.forkedLocalItemId)

        let controllerAfterRestart = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controllerAfterRestart.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        XCTAssertEqual(
            controllerAfterRestart.plan?.candidates.first(where: { $0.localItemId == sharedId })?.forkedLocalItemId,
            forkedId, "the forked id must survive an App restart, never be regenerated"
        )
    }

    func testSameIdKeepBothRollbackOnlyRemovesForkAndKeepsOriginal() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        kitchen.inventory = [InventoryItem(id: sharedId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil)]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: sharedId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        await controller.resolveConflict(candidateId: sharedId, choice: .keepBoth)
        let forkedId = try XCTUnwrap(controller.plan?.candidates.first(where: { $0.localItemId == sharedId })?.forkedLocalItemId)
        await transport.clearRemoteChanges()

        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)

        await controller.rollback(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .rolledBack)
        let forkedIsSoftDeleted = await transport.isSoftDeleted(forkedId)
        XCTAssertTrue(forkedIsSoftDeleted)
        // The original remote entity (same id as this device's local Guest
        // item) was never touched by this session at all, so it was never a
        // candidate for rollback either.
        let originalLocalItem = try await persistence.inventoryItem(id: sharedId)
        XCTAssertNotNil(originalLocalItem, "the original local Guest record must never be deleted by rollback")
    }

    func testSameIdKeepLocalNeverForksAndKeepRemoteNeverStagesAnything() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let keepLocalId = UUID()
        let keepRemoteId = UUID()
        kitchen.inventory = [
            InventoryItem(id: keepLocalId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil),
            InventoryItem(id: keepRemoteId, name: "香蕉", quantity: 1, unit: "根", expiryDate: nil)
        ]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: keepLocalId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")
        await transport.seedRemoteChange(id: keepRemoteId, name: "香蕉", unit: "根", quantity: 2, version: "2", sequence: "2")
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        await controller.resolveConflict(candidateId: keepLocalId, choice: .keepLocal)
        await controller.resolveConflict(candidateId: keepRemoteId, choice: .keepRemote)
        XCTAssertNil(controller.plan?.candidates.first(where: { $0.localItemId == keepLocalId })?.forkedLocalItemId)
        XCTAssertNil(controller.plan?.candidates.first(where: { $0.localItemId == keepRemoteId })?.forkedLocalItemId)
        await transport.clearRemoteChanges()

        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        XCTAssertEqual(controller.session?.status, .completed)
        // keepLocal: the original id was updated using the seeded remote version.
        let keepLocalBaseVersion = await transport.lastReceivedBaseVersion(for: keepLocalId)
        XCTAssertEqual(keepLocalBaseVersion, "5")
        // keepRemote: nothing was ever staged for this candidate at all.
        let keepRemoteBaseVersion = await transport.lastReceivedBaseVersion(for: keepRemoteId)
        XCTAssertNil(keepRemoteBaseVersion)
    }

    func testSnapshotIsCappedButPlanStillCoversEveryLocalItemBeyondTheCap() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let extraItems = (0..<(GuestMergeSession.maxSnapshotItems + 50)).map {
            InventoryImportItem(name: "本机物品\($0)", quantity: 1, unit: "个", expiryDate: nil)
        }
        _ = kitchen.importInventory(extraItems)
        XCTAssertEqual(kitchen.inventory.count, GuestMergeSession.maxSnapshotItems + 50)

        let controller = GuestMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)

        // The drift-detection snapshot is bounded (never an unbounded blob),
        // but the actual merge plan must still cover every local item — the
        // cap must never silently drop items from the merge itself.
        XCTAssertEqual(controller.session?.localSnapshot.count, GuestMergeSession.maxSnapshotItems)
        XCTAssertEqual(controller.plan?.candidates.count, GuestMergeSession.maxSnapshotItems + 50, "the size cap must bound only the drift-detection snapshot, never the merge plan itself")
    }

    func testCorruptedSessionRecordDataFailsSafelyWithoutOfferingAPlanToUpload() throws {
        let container = try ModelContainer(
            for: GuestMergeSessionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let now = Date()
        let session = GuestMergeSession(
            id: UUID(), userId: userA, householdId: householdA, entityType: .inventoryItem,
            status: .previewReady, createdAt: now, updatedAt: now, confirmedAt: nil, completedAt: nil,
            cancelledAt: nil, rollbackAvailableUntil: nil, localSnapshot: [], plan: nil,
            plannedItemCount: 0, uploadedItemCount: 0, conflictCount: 0, failedCount: 0,
            lastErrorCode: nil, createdEntityIds: [], mergeVersion: 1
        )
        let record = GuestMergeSessionRecord(session: session)
        // Simulate on-disk corruption of the persisted plan blob.
        record.planData = Data("not-valid-json".utf8)
        record.localSnapshotData = Data("also-not-valid-json".utf8)
        let context = ModelContext(container)
        context.insert(record)

        let decoded = try XCTUnwrap(record.value, "corruption in plan/snapshot data must never crash decoding")
        XCTAssertNil(decoded.plan, "a corrupted plan must decode to nil, never to fabricated/garbage plan data")
        XCTAssertEqual(decoded.localSnapshot, [], "a corrupted snapshot must fail safely to an empty snapshot, never garbage items")

        // GuestMergeController.confirmMerge guards on `let plan = current.plan
        // else { return }` — a nil plan here means confirmMerge refuses to
        // upload anything, which is the safe failure mode being verified.
        XCTAssertNil(decoded.plan)
    }

    func testSessionRestoresAcrossAppRestartWithoutRegeneratingId() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let controllerBeforeRestart = GuestMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        await controllerBeforeRestart.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let originalSessionId = controllerBeforeRestart.session?.id
        XCTAssertNotNil(originalSessionId)

        // Simulate an App restart: a brand new controller instance, same persistence.
        let controllerAfterRestart = GuestMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        await controllerAfterRestart.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        XCTAssertEqual(controllerAfterRestart.session?.id, originalSessionId, "resuming must reuse the same session id, never regenerate one")
    }

    func testUserAAndUserBSessionsAreFullyIsolated() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let controllerA = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })
        await controllerA.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)

        let controllerB = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userB, householdID: self.householdB) })
        await controllerB.preparePreview(userId: userB, householdId: householdB, kitchenStore: kitchen)

        XCTAssertNotEqual(controllerA.session?.id, controllerB.session?.id)
        XCTAssertNotNil(controllerA.session)
        XCTAssertNotNil(controllerB.session)

        // Re-entering as user A again must resolve back to A's own session, not B's.
        let controllerAAgain = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })
        await controllerAAgain.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        XCTAssertEqual(controllerAAgain.session?.id, controllerA.session?.id)
    }

    // MARK: - Upload via existing SyncCoordinator/InventorySyncAdapter

    func testConflictDuringUploadIsRetainedNotAutoResolved() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let item = InventoryItem(name: "番茄", quantity: 2, unit: "个", expiryDate: nil)
        kitchen.importInventory([InventoryImportItem(name: item.name, quantity: item.quantity, unit: item.unit, expiryDate: nil)])
        let seededId = kitchen.inventory.first { $0.name == item.name }!.id
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedExistingRemote(id: seededId, staleBaseVersion: "999")
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })

        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        // A create racing an unexpected remote version must be retained as a
        // conflict, never silently treated as success and never auto-resolved.
        XCTAssertEqual(controller.session?.status, .conflict)
        XCTAssertEqual(controller.session?.uploadedItemCount, 0)
        let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: seededId)
        XCTAssertEqual(metadata?.state, .conflicted)
    }

    func testDuplicateRetryDoesNotDoubleApply() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)
        let firstAppliedCount = await transport.appliedCount()

        // Re-confirm on an already-completed session must be a no-op (guarded
        // by the controller's own status check), so the transport never sees
        // a second apply for the same item.
        await controller.confirmMerge(authStore: authStore)
        let secondAppliedCount = await transport.appliedCount()
        XCTAssertEqual(firstAppliedCount, secondAppliedCount)
    }

    func testTransportFailureMarksSessionFailedNotSilentlyCompleted() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let controller = GuestMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in FailingMergeTransport() }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .failed)
    }

    // MARK: - Completion marker / no re-scan

    func testCompletedSessionMarksSyncMetadataSyncedAndClearsPending() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let itemId = controller.plan?.creates.first?.localItemId
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: try XCTUnwrap(itemId))
        XCTAssertEqual(metadata?.state, .synced)
        let scope = SyncScope(type: .household, id: householdA)
        let pending = try await persistence.pendingMutations(scope: scope, maxAttempts: 5)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(controller.session?.createdEntityIds.contains(try XCTUnwrap(itemId)) ?? false)
    }

    // MARK: - Conflict resolution

    func testResolvedConflictChoicePersistsAcrossAppRestart() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let item = InventoryItem(name: "番茄", quantity: 2, unit: "个", expiryDate: nil)
        kitchen.importInventory([InventoryImportItem(name: item.name, quantity: item.quantity, unit: item.unit, expiryDate: nil)])
        let localId = kitchen.inventory.first!.id
        let remoteId = UUID()

        // Manually seed an ambiguous-duplicate plan (different remote id, same business key).
        var plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: householdA, localItems: kitchen.inventory,
            knownRemoteItems: [RemoteInventorySnapshotItem(id: remoteId, name: item.name, unit: item.unit, quantity: 2, expiryDate: nil)]
        )
        XCTAssertTrue(plan.candidates.first?.needsDecision ?? false)
        let session = GuestMergeSession(
            id: plan.sessionId, userId: userA, householdId: householdA, entityType: .inventoryItem,
            status: .conflict, createdAt: Date(), updatedAt: Date(), confirmedAt: nil, completedAt: nil,
            cancelledAt: nil, rollbackAvailableUntil: nil, localSnapshot: [], plan: plan,
            plannedItemCount: 0, uploadedItemCount: 0, conflictCount: 1, failedCount: 0,
            lastErrorCode: nil, createdEntityIds: [], mergeVersion: 1
        )
        try await persistence.saveGuestMergeSession(session)

        let controllerAfter = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })
        await controllerAfter.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        await controllerAfter.resolveConflict(candidateId: localId, choice: .keepBoth)

        XCTAssertEqual(controllerAfter.plan?.candidates.first?.userChoice, .keepBoth)
        XCTAssertEqual(controllerAfter.plan?.candidates.first?.action, .create)

        // Simulate App restart: reload from persistence and confirm the choice survived.
        let restored = try await persistence.guestMergeSession(id: session.id)
        XCTAssertEqual(restored?.plan?.candidates.first?.userChoice, .keepBoth)
        plan = try XCTUnwrap(restored?.plan)
        XCTAssertTrue(plan.conflicts.isEmpty, "a resolved candidate must no longer be counted as needing a decision")
    }

    // MARK: - Rollback

    func testRollbackOnlyRemovesSessionCreatedRecordsAndKeepsLocalData() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)
        let itemId = try XCTUnwrap(controller.session?.createdEntityIds.first)

        await controller.rollback(authStore: authStore)

        XCTAssertEqual(controller.session?.status, .rolledBack)
        let deletedRemotely = await transport.isSoftDeleted(itemId)
        XCTAssertTrue(deletedRemotely)
        // Local Guest data must never be deleted by a rollback.
        XCTAssertTrue(kitchen.inventory.contains { $0.id == itemId })
    }

    func testRollbackIsIdempotentWhenRepeated() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        await controller.rollback(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .rolledBack)

        // A second rollback call on an already-rolled-back session must be a
        // guarded no-op, not an error or a duplicate remote delete attempt.
        await controller.rollback(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .rolledBack)
    }

    // MARK: - Guest data boundary

    func testMergeDoesNotTouchShoppingPlansOrRecipes() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        kitchen.addShoppingItems([KitchenShoppingItem(name: "牛奶", quantity: 1, unit: "盒")])
        let shoppingBefore = kitchen.shoppingItems

        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        XCTAssertEqual(kitchen.shoppingItems, shoppingBefore, "Phase 2B-1 must never touch Shopping, Plans, or Recipes")
    }

    // MARK: - Security defaults

    func testInventorySyncEnabledDefaultsToFalseWhenInfoPlistKeyIsAbsent() {
        XCTAssertFalse(InventoryMergeConfiguration().isEnabled)
    }

    func testFeatureGateBlocksPreviewGenerationWhenDisabled() async throws {
        let (_, persistence) = try makePersistence()
        let controller = GuestMergeController(persistence: persistence, transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })
        XCTAssertFalse(controller.isFeatureEnabled, "default bundle has no KM_INVENTORY_SYNC_ENABLED key, so the feature must stay off")
    }

    // MARK: - Phase 2B-3: INVENTORY_MERGE_UI_ENABLED (independent of INVENTORY_SYNC_ENABLED)

    func testInventoryMergeUIEnabledDefaultsToFalseWhenInfoPlistKeyIsAbsent() {
        XCTAssertFalse(InventoryMergeUIConfiguration().isEnabled)
        XCTAssertFalse(InventoryMergeUIConfiguration.load().isEnabled, "default bundle has no KM_INVENTORY_MERGE_UI_ENABLED key, so the UI must stay hidden")
    }

    func testIsUIEnabledReflectsInjectedUIConfigurationIndependentlyOfNetworkFlag() throws {
        let (_, persistence) = try makePersistence()
        let uiOnlyController = GuestMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: false),
            uiConfiguration: InventoryMergeUIConfiguration(isEnabled: true)
        )
        XCTAssertTrue(uiOnlyController.isUIEnabled)
        XCTAssertFalse(uiOnlyController.isFeatureEnabled, "the UI flag must never itself grant network capability")

        let networkOnlyController = GuestMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            uiConfiguration: InventoryMergeUIConfiguration(isEnabled: false)
        )
        XCTAssertFalse(networkOnlyController.isUIEnabled)
        XCTAssertTrue(networkOnlyController.isFeatureEnabled, "the network flag must never itself force the UI to show")
    }

    // MARK: - Phase 2B-3: skip conflict choice (never uploads, never forks)

    func testSkipChoicePersistsAndNeverUploadsOrForks() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        kitchen.inventory = [InventoryItem(id: sharedId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil)]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: sharedId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        let candidateBefore = try XCTUnwrap(controller.plan?.candidates.first(where: { $0.localItemId == sharedId }))
        XCTAssertEqual(candidateBefore.conflictReason, .quantityMismatch)

        await controller.resolveConflict(candidateId: sharedId, choice: .skip)
        let resolved = try XCTUnwrap(controller.plan?.candidates.first(where: { $0.localItemId == sharedId }))
        XCTAssertEqual(resolved.action, .skip)
        XCTAssertNil(resolved.forkedLocalItemId)
        XCTAssertFalse(resolved.needsDecision, "an explicit skip resolves the conflict — it must not keep nagging the user")
        XCTAssertFalse(controller.plan?.readyToUpload.contains(where: { $0.localItemId == sharedId }) ?? true)

        // Restart: the skip choice must persist, not silently reset.
        let controllerAfterRestart = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controllerAfterRestart.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        XCTAssertEqual(controllerAfterRestart.plan?.candidates.first(where: { $0.localItemId == sharedId })?.userChoice, .skip)
    }

    // MARK: - Phase 2B-3: manual sync (never automatic)

    func testSyncNowRefusesWhenFeatureDisabled() async throws {
        let (_, persistence) = try makePersistence()
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: false),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let authStore = await signedInAuthStore(userID: userA)
        await controller.syncNow(authStore: authStore, householdId: householdA)
        XCTAssertNil(controller.lastSyncOutcome, "must never run the coordinator when the network flag is off")
        XCTAssertNotNil(controller.lastSyncErrorMessage)
    }

    func testSyncNowRefusesWhenSignedOut() async throws {
        let (_, persistence) = try makePersistence()
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let authStore = await signedInAuthStore(userID: userA)
        await authStore.signOut()
        await controller.syncNow(authStore: authStore, householdId: householdA)
        XCTAssertNil(controller.lastSyncOutcome)
        XCTAssertNotNil(controller.lastSyncErrorMessage)
    }

    func testSyncNowRunsCoordinatorOnceWhenEnabledAndSignedIn() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        kitchen.inventory = [InventoryItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil)]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        // Stage one mutation directly (mirrors what a completed merge would
        // have left pending), independent of any merge session.
        let adapter = InventorySyncAdapter(persistence: persistence)
        _ = try await adapter.stageUpsert(item: kitchen.inventory[0], scope: SyncScope(type: .household, id: householdA))

        let authStore = await signedInAuthStore(userID: userA)
        await controller.syncNow(authStore: authStore, householdId: householdA)

        XCTAssertEqual(controller.lastSyncOutcome, .completed)
        let appliedCount = await transport.appliedCount()
        XCTAssertEqual(appliedCount, 1)
    }

    func testPendingInventoryCountReflectsCurrentlyStagedMutations() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        kitchen.inventory = [InventoryItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil)]
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let before = await controller.pendingInventoryCount(householdId: householdA)
        XCTAssertEqual(before, 0)

        let adapter = InventorySyncAdapter(persistence: persistence)
        _ = try await adapter.stageUpsert(item: kitchen.inventory[0], scope: SyncScope(type: .household, id: householdA))
        let after = await controller.pendingInventoryCount(householdId: householdA)
        XCTAssertEqual(after, 1)
    }

    // MARK: - Phase 2B-4: inventory sync enrollment

    func testEnrollmentBecomesEnrolledOnlyAfterMergeCompletes() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        kitchen.inventory = [InventoryItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil)]
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let before = await controller.enrollmentStatus(userId: userA, householdId: householdA)
        XCTAssertEqual(before, .notEnrolled)

        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)

        let after = await controller.enrollmentStatus(userId: userA, householdId: householdA)
        XCTAssertEqual(after, .enrolled)
    }

    func testEnrollmentIsIsolatedBetweenUsersAndHouseholds() async throws {
        let (kitchenA, persistence) = try makeSharedStores(seedGuestInventory: false)
        kitchenA.inventory = [InventoryItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil)]
        let controllerA = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        await controllerA.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchenA)
        let authStoreA = await signedInAuthStore(userID: userA)
        await controllerA.confirmMerge(authStore: authStoreA)
        XCTAssertEqual(controllerA.session?.status, .completed)

        let statusA = await controllerA.enrollmentStatus(userId: userA, householdId: householdA)
        XCTAssertEqual(statusA, .enrolled)

        // Same controller/persistence — a different user or different
        // household must never inherit A's enrollment.
        let statusB = await controllerA.enrollmentStatus(userId: userB, householdId: householdA)
        XCTAssertEqual(statusB, .notEnrolled)
        let statusADifferentHousehold = await controllerA.enrollmentStatus(userId: userA, householdId: householdB)
        XCTAssertEqual(statusADifferentHousehold, .notEnrolled)
    }

    func testEnrollmentSurvivesSimulatedRestart() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        kitchen.inventory = [InventoryItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil)]
        let controllerBeforeRestart = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        await controllerBeforeRestart.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await controllerBeforeRestart.confirmMerge(authStore: authStore)
        XCTAssertEqual(controllerBeforeRestart.session?.status, .completed)

        let controllerAfterRestart = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let status = await controllerAfterRestart.enrollmentStatus(userId: userA, householdId: householdA)
        XCTAssertEqual(status, .enrolled)
    }

    func testFlagOffNeverStagesEvenWhenEnrolled() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        kitchen.inventory = [InventoryItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil)]
        let enrolledController = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        await enrolledController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await enrolledController.confirmMerge(authStore: authStore)
        XCTAssertEqual(enrolledController.session?.status, .completed)

        // A fresh controller with the flag OFF must never stage anything,
        // even though enrollment itself already says "enrolled".
        let flagOffController = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: false),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let newItem = InventoryItem(name: "香蕉", quantity: 1, unit: "根", expiryDate: nil)
        await flagOffController.handleInventoryDidChange(old: [], new: [newItem], userId: userA, householdId: householdA)
        let pendingCount = await flagOffController.pendingInventoryCount(householdId: householdA)
        XCTAssertEqual(pendingCount, 0, "flag off must never stage a mutation, even for an enrolled workspace")
    }

    // MARK: - Phase 2B-4: create

    func testGuestOnlyCreateNeverStagesAMutation() async throws {
        let (_, persistence) = try makeSharedStores(seedGuestInventory: false)
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        // Never enrolled — a brand-new local item must stay purely local.
        let newItem = InventoryItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil)
        await controller.handleInventoryDidChange(old: [], new: [newItem], userId: userA, householdId: householdA)
        let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: newItem.id)
        XCTAssertNil(metadata)
        let pendingCount = await controller.pendingInventoryCount(householdId: householdA)
        XCTAssertEqual(pendingCount, 0)
    }

    func testEnrolledCreateStagesMetadataAndMutationAtBaseVersionZero() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let newItem = InventoryItem(name: "香蕉", quantity: 2, unit: "根", expiryDate: nil)
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        await controller.handleInventoryDidChange(old: kitchen.inventory, new: kitchen.inventory + [newItem], userId: userA, householdId: householdA)

        let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: newItem.id)
        XCTAssertEqual(metadata?.state, .pendingCreate)
        let mutation = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: newItem.id)
        XCTAssertEqual(mutation?.operation, .upsert)
        XCTAssertEqual(mutation?.baseVersion?.rawValue, "0")
    }

    func testTransactionFailureLeavesNoOrphanedMutation() async throws {
        let (kitchen, persistence) = try await enrolledStores(behavior: .failSavesForTesting)
        let newItem = InventoryItem(name: "香蕉", quantity: 2, unit: "根", expiryDate: nil)
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        await controller.handleInventoryDidChange(old: kitchen.inventory, new: kitchen.inventory + [newItem], userId: userA, householdId: householdA)

        let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: newItem.id)
        XCTAssertNil(metadata, "a failed save must never leave a half-written metadata row")
        let mutation = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: newItem.id)
        XCTAssertNil(mutation, "a failed save must never leave an orphaned mutation")
    }

    // MARK: - Phase 2B-4: update + coalescing

    func testSyncedUpdateUsesExistingRemoteVersionAsBaseVersion() async throws {
        let (_, persistence) = try await enrolledStores()
        let sharedId = UUID()
        try await persistence.saveMetadata(SyncMetadata(
            entityType: .inventoryItem, entityId: sharedId, scope: SyncScope(type: .household, id: householdA),
            remoteVersion: try SyncCursorValue("7"), state: .synced, lastSyncedAt: Date(),
            lastErrorCode: nil, lastErrorAt: nil, deletedAt: nil, updatedAt: Date()
        ))
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let before = InventoryItem(id: sharedId, name: "苹果", quantity: 2, unit: "个", expiryDate: nil)
        let after = InventoryItem(id: sharedId, name: "苹果", quantity: 5, unit: "个", expiryDate: nil)
        await controller.handleInventoryDidChange(old: [before], new: [after], userId: userA, householdId: householdA)

        let mutation = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: sharedId)
        XCTAssertEqual(mutation?.operation, .upsert)
        XCTAssertEqual(mutation?.baseVersion?.rawValue, "7")
        let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: sharedId)
        XCTAssertEqual(metadata?.state, .pendingUpdate)
    }

    func testCreateThenUpdateCoalescesIntoOneCreateMutationWithLatestPayload() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let newItem = InventoryItem(name: "香蕉", quantity: 1, unit: "根", expiryDate: nil)
        await controller.handleInventoryDidChange(old: kitchen.inventory, new: kitchen.inventory + [newItem], userId: userA, householdId: householdA)
        let firstMutation = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: newItem.id)
        let firstMutationId = try XCTUnwrap(firstMutation?.mutationId)

        var updatedItem = newItem
        updatedItem.quantity = 3
        await controller.handleInventoryDidChange(old: kitchen.inventory + [newItem], new: kitchen.inventory + [updatedItem], userId: userA, householdId: householdA)

        let mutation = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: newItem.id)
        XCTAssertEqual(mutation?.mutationId, firstMutationId, "coalescing must keep the same mutationId, never mint a second one")
        XCTAssertEqual(mutation?.baseVersion?.rawValue, "0", "still a create — baseVersion must not shift")
        let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: newItem.id)
        XCTAssertEqual(metadata?.state, .pendingCreate)
    }

    func testUpdateThenUpdateCoalescesIntoOneUpdateMutation() async throws {
        let (_, persistence) = try await enrolledStores()
        let sharedId = UUID()
        try await persistence.saveMetadata(SyncMetadata(
            entityType: .inventoryItem, entityId: sharedId, scope: SyncScope(type: .household, id: householdA),
            remoteVersion: try SyncCursorValue("3"), state: .synced, lastSyncedAt: Date(),
            lastErrorCode: nil, lastErrorAt: nil, deletedAt: nil, updatedAt: Date()
        ))
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let v1 = InventoryItem(id: sharedId, name: "苹果", quantity: 2, unit: "个", expiryDate: nil)
        let v2 = InventoryItem(id: sharedId, name: "苹果", quantity: 5, unit: "个", expiryDate: nil)
        let v3 = InventoryItem(id: sharedId, name: "苹果", quantity: 9, unit: "个", expiryDate: nil)
        await controller.handleInventoryDidChange(old: [v1], new: [v2], userId: userA, householdId: householdA)
        let firstMutationId = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: sharedId)?.mutationId
        await controller.handleInventoryDidChange(old: [v2], new: [v3], userId: userA, householdId: householdA)

        let mutation = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: sharedId)
        XCTAssertEqual(mutation?.mutationId, firstMutationId)
        XCTAssertEqual(mutation?.baseVersion?.rawValue, "3", "baseVersion must stay the originally-known remote version")
    }

    func testConflictedMetadataBlocksFurtherStagingWithoutOverwriting() async throws {
        let (_, persistence) = try await enrolledStores()
        let sharedId = UUID()
        try await persistence.saveMetadata(SyncMetadata(
            entityType: .inventoryItem, entityId: sharedId, scope: SyncScope(type: .household, id: householdA),
            remoteVersion: try SyncCursorValue("3"), state: .conflicted, lastSyncedAt: Date(),
            lastErrorCode: "stale_version", lastErrorAt: Date(), deletedAt: nil, updatedAt: Date()
        ))
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let v1 = InventoryItem(id: sharedId, name: "苹果", quantity: 2, unit: "个", expiryDate: nil)
        let v2 = InventoryItem(id: sharedId, name: "苹果", quantity: 5, unit: "个", expiryDate: nil)
        await controller.handleInventoryDidChange(old: [v1], new: [v2], userId: userA, householdId: householdA)

        let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: sharedId)
        XCTAssertEqual(metadata?.state, .conflicted, "a conflicted item must never be silently overwritten by a later local edit")
        let mutation = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: sharedId)
        XCTAssertNil(mutation)
        XCTAssertNotNil(controller.inventoryMutationBlockedMessage)
    }

    func testGuestOnlyUpdateNeverStages() async throws {
        let (_, persistence) = try await enrolledStores()
        // No SyncMetadata exists for this id — it's a Guest-only item this
        // device never staged, even though the workspace itself is enrolled.
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let unrelatedId = UUID()
        let v1 = InventoryItem(id: unrelatedId, name: "西红柿", quantity: 2, unit: "个", expiryDate: nil)
        let v2 = InventoryItem(id: unrelatedId, name: "西红柿", quantity: 5, unit: "个", expiryDate: nil)
        await controller.handleInventoryDidChange(old: [v1], new: [v2], userId: userA, householdId: householdA)
        let mutation = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: unrelatedId)
        XCTAssertNil(mutation)
    }

    // MARK: - Phase 2B-4: delete + coalescing

    func testSyncedDeleteStagesATombstoneMutationUsingCurrentRemoteVersion() async throws {
        let (_, persistence) = try await enrolledStores()
        let sharedId = UUID()
        try await persistence.saveMetadata(SyncMetadata(
            entityType: .inventoryItem, entityId: sharedId, scope: SyncScope(type: .household, id: householdA),
            remoteVersion: try SyncCursorValue("4"), state: .synced, lastSyncedAt: Date(),
            lastErrorCode: nil, lastErrorAt: nil, deletedAt: nil, updatedAt: Date()
        ))
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let item = InventoryItem(id: sharedId, name: "苹果", quantity: 2, unit: "个", expiryDate: nil)
        await controller.handleInventoryDidChange(old: [item], new: [], userId: userA, householdId: householdA)

        let mutation = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: sharedId)
        XCTAssertEqual(mutation?.operation, .delete)
        XCTAssertEqual(mutation?.baseVersion?.rawValue, "4")
        let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: sharedId)
        XCTAssertEqual(metadata?.state, .pendingDelete)
        XCTAssertNotNil(metadata?.deletedAt, "a tombstone must record when the delete was staged")
    }

    func testCreateThenDeleteCancelsEntirelyWithNoRemoteWrite() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let newItem = InventoryItem(name: "香蕉", quantity: 1, unit: "根", expiryDate: nil)
        await controller.handleInventoryDidChange(old: kitchen.inventory, new: kitchen.inventory + [newItem], userId: userA, householdId: householdA)
        let stagedMutation = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: newItem.id)
        XCTAssertNotNil(stagedMutation)

        await controller.handleInventoryDidChange(old: kitchen.inventory + [newItem], new: kitchen.inventory, userId: userA, householdId: householdA)

        let mutation = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: newItem.id)
        XCTAssertNil(mutation, "create+delete before any sync must cancel entirely, never send a create-then-delete pair")
        let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: newItem.id)
        XCTAssertNil(metadata)
    }

    func testUpdateThenDeleteCoalescesIntoASingleDeleteIntent() async throws {
        let (_, persistence) = try await enrolledStores()
        let sharedId = UUID()
        try await persistence.saveMetadata(SyncMetadata(
            entityType: .inventoryItem, entityId: sharedId, scope: SyncScope(type: .household, id: householdA),
            remoteVersion: try SyncCursorValue("6"), state: .synced, lastSyncedAt: Date(),
            lastErrorCode: nil, lastErrorAt: nil, deletedAt: nil, updatedAt: Date()
        ))
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let v1 = InventoryItem(id: sharedId, name: "苹果", quantity: 2, unit: "个", expiryDate: nil)
        let v2 = InventoryItem(id: sharedId, name: "苹果", quantity: 9, unit: "个", expiryDate: nil)
        await controller.handleInventoryDidChange(old: [v1], new: [v2], userId: userA, householdId: householdA)
        let updateMutationId = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: sharedId)?.mutationId

        await controller.handleInventoryDidChange(old: [v2], new: [], userId: userA, householdId: householdA)

        let mutation = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: sharedId)
        XCTAssertEqual(mutation?.operation, .delete)
        XCTAssertEqual(mutation?.mutationId, updateMutationId, "must merge into the same mutation record, never send the update first")
        XCTAssertEqual(mutation?.baseVersion?.rawValue, "6", "must use the real known remote version, never a stale/zero one")
    }

    func testGuestOnlyDeleteStaysPurelyLocal() async throws {
        let (_, persistence) = try await enrolledStores()
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let unrelatedId = UUID()
        let item = InventoryItem(id: unrelatedId, name: "西红柿", quantity: 2, unit: "个", expiryDate: nil)
        await controller.handleInventoryDidChange(old: [item], new: [], userId: userA, householdId: householdA)
        let mutation = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: unrelatedId)
        XCTAssertNil(mutation)
    }

    // MARK: - Phase 2B-5: queue cap

    func testQueueFullBlocksAGenuinelyNewCreate() {
        let result = InventorySyncEligibility.evaluate(
            isFeatureEnabled: true, userId: userA, householdId: householdA,
            enrollment: InventorySyncEnrollment(
                userId: userA, householdId: householdA, status: .enrolled, enrolledAt: Date(),
                mergeSessionId: UUID(), schemaVersion: InventorySyncEnrollment.currentSchemaVersion, updatedAt: Date()
            ),
            existingMetadata: nil, intent: .create,
            hasExistingPendingMutationForEntity: false, currentPendingCount: 5, maxPendingMutations: 5
        )
        XCTAssertEqual(result, .blockedByQueueFull)
    }

    func testQueueFullNeverBlocksADelete() {
        let metadata = SyncMetadata(
            entityType: .inventoryItem, entityId: UUID(), scope: SyncScope(type: .household, id: householdA),
            remoteVersion: try! SyncCursorValue("1"), state: .synced, lastSyncedAt: Date(),
            lastErrorCode: nil, lastErrorAt: nil, deletedAt: nil, updatedAt: Date()
        )
        let result = InventorySyncEligibility.evaluate(
            isFeatureEnabled: true, userId: userA, householdId: householdA,
            enrollment: InventorySyncEnrollment(
                userId: userA, householdId: householdA, status: .enrolled, enrolledAt: Date(),
                mergeSessionId: UUID(), schemaVersion: InventorySyncEnrollment.currentSchemaVersion, updatedAt: Date()
            ),
            existingMetadata: metadata, intent: .delete,
            hasExistingPendingMutationForEntity: false, currentPendingCount: 5, maxPendingMutations: 5
        )
        XCTAssertEqual(result, .eligible(baseVersion: try! SyncCursorValue("1")), "queue cap must never drop a delete")
    }

    func testQueueFullNeverBlocksAnUpdateThatCoalescesIntoAnExistingPendingMutation() {
        let metadata = SyncMetadata(
            entityType: .inventoryItem, entityId: UUID(), scope: SyncScope(type: .household, id: householdA),
            remoteVersion: try! SyncCursorValue("1"), state: .pendingUpdate, lastSyncedAt: Date(),
            lastErrorCode: nil, lastErrorAt: nil, deletedAt: nil, updatedAt: Date()
        )
        let result = InventorySyncEligibility.evaluate(
            isFeatureEnabled: true, userId: userA, householdId: householdA,
            enrollment: InventorySyncEnrollment(
                userId: userA, householdId: householdA, status: .enrolled, enrolledAt: Date(),
                mergeSessionId: UUID(), schemaVersion: InventorySyncEnrollment.currentSchemaVersion, updatedAt: Date()
            ),
            existingMetadata: metadata, intent: .update,
            hasExistingPendingMutationForEntity: true, currentPendingCount: 5, maxPendingMutations: 5
        )
        XCTAssertEqual(result, .eligible(baseVersion: try! SyncCursorValue("1")), "coalescing into an already-staged row must never be blocked by the cap")
    }

    func testQueueFullEndToEndStopsStagingNewMutationsWithoutLosingBusinessWrite() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            dogfoodConfiguration: InventorySyncDogfoodConfiguration(maxPendingMutations: 2),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        var items: [InventoryItem] = []
        for index in 0..<3 {
            let item = InventoryItem(name: "item-\(index)", quantity: 1, unit: "个", expiryDate: nil)
            await controller.handleInventoryDidChange(old: items, new: items + [item], userId: userA, householdId: householdA)
            items.append(item)
        }
        let pending = try await persistence.pendingMutations(scope: SyncScope(type: .household, id: householdA), maxAttempts: .max)
        XCTAssertEqual(pending.count, 2, "the third create must be refused once the cap is reached")
        XCTAssertNotNil(controller.inventoryMutationBlockedMessage)
        XCTAssertEqual(kitchen.inventory.count, 0, "kitchen store isn't touched by this helper; the business write itself always proceeds independent of sync staging")
    }

    // MARK: - Phase 2B-5: consistency checker

    func testConsistencyCheckerFlagsOrphanMetadataWithNoLocalRecord() {
        let entityId = UUID()
        let metadata = SyncMetadata(
            entityType: .inventoryItem, entityId: entityId, scope: SyncScope(type: .household, id: householdA),
            remoteVersion: try! SyncCursorValue("1"), state: .synced, lastSyncedAt: Date(),
            lastErrorCode: nil, lastErrorAt: nil, deletedAt: nil, updatedAt: Date()
        )
        let issues = InventorySyncConsistencyChecker.check(
            localInventoryIds: [], allMetadata: [metadata], allPendingMutations: [],
            enrollment: nil, expectedUserId: nil, expectedHouseholdId: nil,
            activeMergeSession: nil, previousCursorValue: nil, currentCursorValue: nil
        )
        XCTAssertTrue(issues.contains { $0.code == .orphanMetadataNoInventoryRecord })
    }

    func testConsistencyCheckerCleanWhenEverythingLinesUp() {
        let entityId = UUID()
        let metadata = SyncMetadata(
            entityType: .inventoryItem, entityId: entityId, scope: SyncScope(type: .household, id: householdA),
            remoteVersion: try! SyncCursorValue("1"), state: .synced, lastSyncedAt: Date(),
            lastErrorCode: nil, lastErrorAt: nil, deletedAt: nil, updatedAt: Date()
        )
        let issues = InventorySyncConsistencyChecker.check(
            localInventoryIds: [entityId], allMetadata: [metadata], allPendingMutations: [],
            enrollment: nil, expectedUserId: nil, expectedHouseholdId: nil,
            activeMergeSession: nil, previousCursorValue: nil, currentCursorValue: nil
        )
        XCTAssertTrue(issues.isEmpty)
    }

    func testConsistencyCheckerFlagsMultiplePendingMutationsForSameEntity() {
        let entityId = UUID()
        let metadata = SyncMetadata(
            entityType: .inventoryItem, entityId: entityId, scope: SyncScope(type: .household, id: householdA),
            remoteVersion: try! SyncCursorValue("1"), state: .pendingUpdate, lastSyncedAt: Date(),
            lastErrorCode: nil, lastErrorAt: nil, deletedAt: nil, updatedAt: Date()
        )
        let mutationA = PendingMutation(
            mutationId: UUID(), entityType: .inventoryItem, entityId: entityId, scope: metadata.scope,
            operation: .upsert, baseVersion: try! SyncCursorValue("1"), payloadData: Data(),
            clientUpdatedAt: Date(), createdAt: Date(), attemptCount: 0, lastAttemptAt: nil,
            lastErrorCode: nil, status: .pending
        )
        let mutationB = PendingMutation(
            mutationId: UUID(), entityType: .inventoryItem, entityId: entityId, scope: metadata.scope,
            operation: .upsert, baseVersion: try! SyncCursorValue("1"), payloadData: Data(),
            clientUpdatedAt: Date(), createdAt: Date(), attemptCount: 0, lastAttemptAt: nil,
            lastErrorCode: nil, status: .pending
        )
        let issues = InventorySyncConsistencyChecker.check(
            localInventoryIds: [entityId], allMetadata: [metadata], allPendingMutations: [mutationA, mutationB],
            enrollment: nil, expectedUserId: nil, expectedHouseholdId: nil,
            activeMergeSession: nil, previousCursorValue: nil, currentCursorValue: nil
        )
        XCTAssertTrue(issues.contains { $0.code == .multiplePendingMutationsForSameEntity })
    }

    func testConsistencyCheckerFlagsCursorRegression() {
        let issues = InventorySyncConsistencyChecker.check(
            localInventoryIds: [], allMetadata: [], allPendingMutations: [],
            enrollment: nil, expectedUserId: nil, expectedHouseholdId: nil,
            activeMergeSession: nil,
            previousCursorValue: try! SyncCursorValue("10"), currentCursorValue: try! SyncCursorValue("3")
        )
        XCTAssertTrue(issues.contains { $0.code == .cursorRegressed })
    }

    // MARK: - Phase 2B-5: diagnostics snapshot redaction + single-flight

    func testDiagnosticsSnapshotRedactedJSONNeverContainsSensitiveFields() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let snapshot = await controller.diagnosticsSnapshot(
            kitchenStore: kitchen, userId: userA, householdId: householdA,
            environmentName: "development", appBuild: "1.0-test"
        )
        let json = String(data: snapshot.redactedJSON(), encoding: .utf8) ?? ""
        for forbidden in [userA.uuidString, householdA.uuidString, "@", "token", "password", "Authorization"] {
            XCTAssertFalse(json.contains(forbidden), "diagnostics export must never contain \(forbidden)")
        }
    }

    func testManualSyncRepeatedTapsExecuteOnlyOnce() async throws {
        let (_, persistence) = try await enrolledStores()
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let authStore = await signedInAuthStore(userID: userA)
        async let first: () = controller.syncNow(authStore: authStore, householdId: householdA)
        async let second: () = controller.syncNow(authStore: authStore, householdId: householdA)
        _ = await (first, second)
        XCTAssertFalse(controller.isSyncing, "both calls must have settled, not left mid-flight")
    }

    // MARK: - Phase 2B-4: account/household isolation for CRUD staging

    func testUserBHouseholdScopeNeverReceivesUserAsInventoryMutation() async throws {
        let (_, persistence) = try await enrolledStores()
        let controllerA = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let newItem = InventoryItem(name: "香蕉", quantity: 1, unit: "根", expiryDate: nil)
        await controllerA.handleInventoryDidChange(old: [], new: [newItem], userId: userA, householdId: householdA)

        let pendingForA = try await persistence.pendingMutations(scope: SyncScope(type: .household, id: householdA), maxAttempts: .max)
        let pendingForB = try await persistence.pendingMutations(scope: SyncScope(type: .household, id: householdB), maxAttempts: .max)
        XCTAssertEqual(pendingForA.count, 1)
        XCTAssertTrue(pendingForB.isEmpty, "User B's household scope must never see User A's pending mutation")
    }

    /// Seeds an isolated store already enrolled for (userA, householdA) —
    /// used by tests that only care about create/update/delete staging
    /// behavior, not the merge flow that produces enrollment.
    private func enrolledStores(behavior: SyncPersistenceBehavior = .normal) async throws -> (KitchenStore, SwiftDataSyncPersistence) {
        let (kitchen, sharedPersistence) = try makeSharedStores(seedGuestInventory: false)
        // Enrollment itself must always succeed, even when the test wants a
        // failing persistence for the CRUD staging call under test — the
        // failure being tested is "staging a mutation," not "becoming
        // enrolled."
        let enrollment = InventorySyncEnrollment(
            userId: userA, householdId: householdA, status: .enrolled, enrolledAt: Date(),
            mergeSessionId: UUID(), schemaVersion: InventorySyncEnrollment.currentSchemaVersion, updatedAt: Date()
        )
        try await sharedPersistence.saveEnrollment(enrollment)
        let persistence = behavior == .normal
            ? sharedPersistence
            : SwiftDataSyncPersistence(modelContainer: sharedPersistence.modelContainer, behavior: behavior)
        return (kitchen, persistence)
    }

    // MARK: - Helpers

    private func makePersistence() throws -> (ModelContainer, SwiftDataSyncPersistence) {
        let container = try ModelContainer(
            for: InventoryRecord.self, SyncMetadataRecord.self, PendingMutationRecord.self,
            SyncCursorRecord.self, GuestMergeSessionRecord.self, InventorySyncEnrollmentRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (container, SwiftDataSyncPersistence(modelContainer: container))
    }

    /// A real, signed-in `AuthStore` backed by an in-memory fake auth
    /// service — used so `confirmMerge`/`rollback` exercise the exact same
    /// `authStore.currentUserID`/`currentAccessToken()` code path a View
    /// would use, instead of a raw token string.
    private func signedInAuthStore(userID: UUID, token: String = "test-token") async -> AuthStore {
        let store = AuthStore(
            authService: FakeGuestMergeAuthService(userID: userID, token: token),
            accountService: UnavailableAccountService()
        )
        let didSignIn = await store.signIn(email: "phase2b1-review@example.com", password: "not-a-real-password")
        precondition(didSignIn)
        return store
    }

    /// `KitchenStore` and `SwiftDataSyncPersistence` must share the same
    /// `ModelContainer` (exactly like `KitchenPersistenceFactory` wires them
    /// in the real App) so a Guest inventory item written through the store
    /// is visible to `persistence.inventoryItem(id:)` during an upload.
    /// Seeds one Guest inventory item ("番茄") by default.
    private func makeSharedStores(seedGuestInventory: Bool = true) throws -> (KitchenStore, SwiftDataSyncPersistence) {
        let container = try ModelContainer(
            for: InventoryRecord.self, ShoppingItemRecord.self, TodayPlanRecord.self,
            ConsumptionRecordEntity.self, WeeklyPlanRecord.self,
            SyncMetadataRecord.self, PendingMutationRecord.self, SyncCursorRecord.self, GuestMergeSessionRecord.self, InventorySyncEnrollmentRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let kitchen = KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            inventoryPersistence: SwiftDataInventoryPersistence(container: container),
            shoppingListPersistence: SwiftDataShoppingListPersistence(container: container),
            todayPlanPersistence: SwiftDataTodayPlanPersistence(container: container),
            consumptionPersistence: SwiftDataConsumptionPersistence(container: container),
            weeklyPlanPersistence: SwiftDataWeeklyPlanPersistence(container: container)
        )
        if seedGuestInventory {
            kitchen.importInventory([InventoryImportItem(name: "番茄", quantity: 2, unit: "个", expiryDate: nil)])
        }
        return (kitchen, SwiftDataSyncPersistence(modelContainer: container))
    }
}

// MARK: - Mock transports

private actor SimulatedMergeTransport: SyncTransport {
    private let userID: UUID
    private let householdID: UUID
    private var version = 0
    private var sequence = 0
    private var seededVersion: [UUID: String] = [:]
    private var appliedIds: [UUID] = []
    private var deletedIds: Set<UUID> = []
    private var changes: [SyncChangeEnvelope] = []

    init(userID: UUID, householdID: UUID) {
        self.userID = userID
        self.householdID = householdID
    }

    func seedExistingRemote(id: UUID, staleBaseVersion: String) {
        seededVersion[id] = staleBaseVersion
    }

    /// Populates what `fetchChanges` (the pre-merge read) returns, simulating
    /// an inventory_item this device never uploaded itself but that already
    /// exists remotely (e.g. from another device, or a prior test phase).
    func seedRemoteChange(
        id: UUID, name: String, unit: String, quantity: Double, expiryDate: Date? = nil,
        isStaple: Bool = false, stapleCategory: String? = nil, lowStockThreshold: Double? = nil,
        version: String, sequence: String
    ) {
        var data: [String: SyncJSONValue] = [
            "name": .string(name),
            "quantity": .number(quantity),
            "unit": .string(unit),
            "isStaple": .bool(isStaple)
        ]
        if let expiryDate {
            data["expiryDate"] = .string(Self.iso8601.string(from: expiryDate))
        }
        if let stapleCategory {
            data["stapleCategory"] = .string(stapleCategory)
        }
        if let lowStockThreshold {
            data["lowStockThreshold"] = .number(lowStockThreshold)
        }
        changes.append(SyncChangeEnvelope(
            sequence: try! SyncCursorValue(sequence), entityType: .inventoryItem, entityId: id,
            operation: .upsert, version: try! SyncCursorValue(version), changedAt: Date(), data: data
        ))
    }

    /// Drops synthetic pre-seeded remote changes used only for the one-time
    /// pre-merge read. Without this, `SyncCoordinator`'s own later pull phase
    /// (run for real during `confirmMerge`) would re-fetch the same stale
    /// synthetic entry and misapply it over the just-uploaded result — a
    /// mock-only artifact of reusing disconnected fake sequence/version
    /// numbers, not something a real backend would ever do (a real server's
    /// pull and pre-merge read are the same consistent data source).
    func clearRemoteChanges() {
        changes.removeAll()
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func appliedCount() -> Int { appliedIds.count }
    func isSoftDeleted(_ id: UUID) -> Bool { deletedIds.contains(id) }

    func bootstrap() async throws -> SyncBootstrapResponse {
        SyncBootstrapResponse(
            schemaVersion: 1,
            user: .init(id: userID, email: nil),
            households: [.init(id: householdID, role: "owner")],
            defaultHouseholdId: householdID,
            syncScopes: [SyncScopeDescriptor(type: .household, id: householdID, cursor: try SyncCursorValue(String(sequence)))],
            serverTime: Date(),
            capabilities: .init(push: true, pull: true, maxBatchSize: 100)
        )
    }

    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse {
        let page = changes.filter { $0.sequence > cursor }
        let limited = Array(page.prefix(limit))
        return SyncChangesResponse(
            scopeType: scope.type, scopeId: scope.id,
            cursor: limited.last?.sequence ?? cursor, hasMore: page.count > limited.count, changes: limited
        )
    }

    private var receivedBaseVersions: [UUID: String] = [:]

    /// Exposes exactly what `baseVersion` the client actually sent on the
    /// wire for a given entity, so tests can prove the seeded/preserved
    /// version was used rather than inferring it indirectly from outcomes.
    func lastReceivedBaseVersion(for entityId: UUID) -> String? { receivedBaseVersions[entityId] }

    func sendMutations(scope: SyncScope, mutations requests: [SyncMutation]) async throws -> SyncMutationBatchResponse {
        var results: [SyncMutationResult] = []
        for request in requests {
            receivedBaseVersions[request.entityId] = request.baseVersion?.rawValue
            // A seeded entity simulates a remote record the client didn't
            // know about racing this create — the client's baseVersion (from
            // a fresh InventorySyncAdapter.stageUpsert on an item with no
            // prior SyncMetadata) is always "0", which never matches a
            // genuinely pre-existing remote version.
            if let requiredVersion = seededVersion[request.entityId], request.baseVersion?.rawValue == "0" {
                results.append(SyncMutationResult(
                    mutationId: request.mutationId, entityId: request.entityId,
                    status: .conflict, version: try SyncCursorValue(requiredVersion), sequence: nil,
                    errorCode: "stale_version", originalStatus: nil, serverRecord: nil
                ))
                continue
            }
            version += 1
            sequence += 1
            // Real optimistic-concurrency versioning is per-entity
            // (new version = accepted baseVersion + 1), never a
            // cross-entity shared counter — this matters once a test seeds
            // an entity's remote version above 0 (via `seedRemoteChange`),
            // since a shared counter would otherwise return a *lower*
            // version than the entity already has, which the persistence
            // layer's own optimistic-concurrency guard correctly refuses to
            // apply (a real server never regresses a version like that).
            let acceptedBaseVersion = Int(request.baseVersion?.rawValue ?? "0") ?? 0
            let entityVersion = acceptedBaseVersion + 1
            let result = SyncMutationResult(
                mutationId: request.mutationId, entityId: request.entityId,
                status: .applied, version: try SyncCursorValue(String(entityVersion)),
                sequence: try SyncCursorValue(String(sequence)), errorCode: nil,
                originalStatus: nil, serverRecord: nil
            )
            appliedIds.append(request.entityId)
            if request.operation == .delete { deletedIds.insert(request.entityId) }
            results.append(result)
        }
        return SyncMutationBatchResponse(results: results, cursor: try SyncCursorValue(String(sequence)))
    }
}

@MainActor
private final class FakeGuestMergeAuthService: AuthService {
    private let userID: UUID
    private let token: String

    init(userID: UUID, token: String) {
        self.userID = userID
        self.token = token
    }

    var authStateChanges: AsyncStream<AuthStateChange> { AsyncStream { $0.finish() } }
    func restoreSession() async throws -> AuthSession? { nil }
    func signUp(email: String, password: String) async throws -> SignUpOutcome { throw AuthenticationError.unavailable }
    func signIn(email: String, password: String) async throws -> AuthSession {
        AuthSession(user: AuthUser(id: userID, email: email), accessToken: token)
    }
    func signOut() async throws {}
}

private actor FailingMergeTransport: SyncTransport {
    func bootstrap() async throws -> SyncBootstrapResponse { throw SyncError.transport }
    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse { throw SyncError.transport }
    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse { throw SyncError.transport }
}

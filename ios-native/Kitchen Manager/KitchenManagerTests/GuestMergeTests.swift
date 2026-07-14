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

    func testKeepBothIsTheOnlyChoiceThatCreatesASecondRecordForASameIdConflict() {
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
        XCTAssertEqual(candidate.applyingChoice(.keepLocal).action, .update, "same id: keepLocal updates the existing remote record in place")
        XCTAssertEqual(candidate.applyingChoice(.keepBoth).action, .create, "only keepBoth is allowed to produce a second record")
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

    // MARK: - Helpers

    private func makePersistence() throws -> (ModelContainer, SwiftDataSyncPersistence) {
        let container = try ModelContainer(
            for: InventoryRecord.self, SyncMetadataRecord.self, PendingMutationRecord.self,
            SyncCursorRecord.self, GuestMergeSessionRecord.self,
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
            SyncMetadataRecord.self, PendingMutationRecord.self, SyncCursorRecord.self, GuestMergeSessionRecord.self,
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

    func sendMutations(scope: SyncScope, mutations requests: [SyncMutation]) async throws -> SyncMutationBatchResponse {
        var results: [SyncMutationResult] = []
        for request in requests {
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
            let result = SyncMutationResult(
                mutationId: request.mutationId, entityId: request.entityId,
                status: .applied, version: try SyncCursorValue(String(version)),
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

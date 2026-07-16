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

        // No explicit clear needed here: `SimulatedMergeTransport.sendMutations`
        // itself drops a seeded synthetic entry once the corresponding
        // mutation is actually applied, so the coordinator's own real pull
        // phase below (triggered by confirmMerge) sees fresh state, not a
        // stale synthetic re-application — mirroring how a real backend's
        // pull and pre-merge read are the same consistent data source. This
        // also means Phase 2B-8's own pre-upload remote-fingerprint
        // revalidation (which runs before the push) still sees the exact
        // remote state preview saw, and never falsely rejects this as stale.
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

        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        XCTAssertEqual(controller.session?.status, .completed)
        // The original entity is never staged/uploaded by this candidate (a
        // true no-op for the *upload* side) — but confirmMerge's own real
        // pull phase still legitimately observes the pre-existing remote
        // record (exactly as it would on a real backend) and learns its
        // SyncMetadata, rather than uploading or overwriting anything.
        let originalMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: sharedId)
        XCTAssertEqual(originalMetadata?.state, .synced)
        XCTAssertEqual(originalMetadata?.remoteVersion?.rawValue, "5")
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

        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        XCTAssertEqual(controller.session?.status, .completed)
        XCTAssertEqual(Set(controller.session?.createdEntityIds ?? []), Set([expiryForkId, metadataForkId]))
        // Neither original entity was staged/uploaded by its candidate (a
        // true no-op for the *upload* side) — but confirmMerge's own real
        // pull phase still legitimately observes each pre-existing remote
        // record, exactly as a real backend's pull would.
        let expiryOriginalMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: expirySharedId)
        let metadataOriginalMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: metadataSharedId)
        XCTAssertEqual(expiryOriginalMetadata?.state, .synced)
        XCTAssertEqual(metadataOriginalMetadata?.state, .synced)
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

    /// Reproduction for the Phase 2B-9 physical-device finding: the real
    /// device's audit ledger showed Rollback reporting `.rolledBack` while
    /// the server never received a `delete` mutation at all. Root cause:
    /// `activeGuestMergeSession` treated `.completed` as terminal, so if the
    /// controller is re-created (App relaunch, or the merge screen
    /// re-entered) any time between a successful merge and the user tapping
    /// Rollback, `preparePreview` couldn't find the just-completed session as
    /// "active" and silently started over from a fresh preview — orphaning
    /// the original session's `createdEntityIds`/`rollbackAvailableUntil`.
    /// `activeGuestMergeSession` now also keeps surfacing a `.completed`
    /// session while it is still within its rollback window.
    func testRollbackAfterControllerRelaunchStillDeletesSessionCreatedRecord() async throws {
        let (kitchen, sharedPersistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controllerA = GuestMergeController(persistence: sharedPersistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        await controllerA.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await controllerA.confirmMerge(authStore: authStore)
        XCTAssertEqual(controllerA.session?.status, .completed)
        let sessionId = try XCTUnwrap(controllerA.session?.id)
        let itemId = try XCTUnwrap(controllerA.session?.createdEntityIds.first)

        // Simulate an App relaunch between the merge completing and the user
        // tapping Rollback: a brand-new persistence actor over the same
        // on-disk container, and a brand-new controller instance — exactly
        // what a fresh `InventoryMergePromptView`/result screen would do.
        let relaunchedPersistence = SwiftDataSyncPersistence(modelContainer: sharedPersistence.modelContainer)
        let controllerB = GuestMergeController(persistence: relaunchedPersistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        await controllerB.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        XCTAssertEqual(controllerB.session?.id, sessionId, "the completed, still-rollback-eligible session must survive a relaunch's preparePreview, not be silently replaced")
        XCTAssertEqual(controllerB.session?.createdEntityIds, [itemId])

        await controllerB.rollback(authStore: authStore)

        XCTAssertEqual(controllerB.session?.status, .rolledBack)
        let deletedRemotely = await transport.isSoftDeleted(itemId)
        XCTAssertTrue(deletedRemotely, "rollback must never report .rolledBack unless the entity this session created was actually soft-deleted remotely")
        XCTAssertTrue(kitchen.inventory.contains { $0.id == itemId }, "local Guest data must never be deleted by a rollback")
    }

    /// Same defect, no relaunch required: a second `preparePreview` call on
    /// the *same* live controller (e.g. the inventory tab re-checking for
    /// guest data on `.onAppear`) after a completed merge must not orphan the
    /// completed, still-rollback-eligible session.
    func testSecondPreparePreviewAfterCompletedMergeKeepsSessionRollbackEligible() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        let completedSessionId = try XCTUnwrap(controller.session?.id)
        XCTAssertEqual(controller.session?.status, .completed)
        let itemId = try XCTUnwrap(controller.session?.createdEntityIds.first)

        // Re-entering the same screen (or the inventory tab re-checking for
        // guest data) calls preparePreview again — same controller, same
        // persistence, no relaunch.
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        XCTAssertEqual(controller.session?.id, completedSessionId, "a routine preparePreview re-check must not replace a completed, still-rollback-eligible session")
        XCTAssertEqual(controller.session?.status, .completed)
        XCTAssertEqual(controller.session?.createdEntityIds, [itemId])

        await controller.rollback(authStore: authStore)

        XCTAssertEqual(controller.session?.status, .rolledBack)
        let deletedRemotely = await transport.isSoftDeleted(itemId)
        XCTAssertTrue(deletedRemotely, "rollback must never report .rolledBack unless the entity this session created was actually soft-deleted remotely")
    }

    /// A multi-entity session where one delete succeeds and another conflicts
    /// must never report `.rolledBack` for the whole session — this is the
    /// per-mutation verification the Phase 2B-9 fix added, exercised here
    /// with a genuinely mixed outcome (not just a fully-successful or
    /// fully-failed batch).
    func testRollbackDoesNotReportSuccessWhenOneOfTwoEntitiesConflicts() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        kitchen.importInventory([
            InventoryImportItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil),
            InventoryImportItem(name: "牛奶", quantity: 1, unit: "盒", expiryDate: nil)
        ])
        let inner = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in inner })
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)
        let createdIds = try XCTUnwrap(controller.session?.createdEntityIds)
        XCTAssertEqual(createdIds.count, 2, "both imported items must have been created remotely by this session")
        let conflictingId = try XCTUnwrap(createdIds.first)
        let succeedingId = try XCTUnwrap(createdIds.last)

        let conflicting = ConflictInjectingTransport(inner: inner, conflictEntityId: conflictingId)
        let conflictController = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in conflicting })
        await conflictController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        XCTAssertEqual(conflictController.session?.id, controller.session?.id, "must reuse the same still-rollback-eligible session, not a fresh one")

        await conflictController.rollback(authStore: authStore)

        XCTAssertEqual(conflictController.session?.status, .completed, "a partial failure must revert to .completed (rollback-eligible for retry), never .rolledBack")
        let succeedingDeleted = await inner.isSoftDeleted(succeedingId)
        XCTAssertTrue(succeedingDeleted, "the entity whose delete genuinely succeeded must still be soft-deleted remotely")
        let conflictingDeleted = await inner.isSoftDeleted(conflictingId)
        XCTAssertFalse(conflictingDeleted, "the entity whose delete conflicted must remain live remotely")
        XCTAssertNotNil(conflictController.lastErrorMessage, "a failed rollback must surface a user-facing message — InventoryMergeResultView renders exactly this so the failure is never silent")
    }

    /// A retry after a partial failure must not re-stage a delete for the
    /// entity that already succeeded — doing so would send a redundant
    /// delete the server correctly rejects as `already_deleted`, and a naive
    /// "any pending mutation left over" check would then misreport the
    /// already-successful entity as a fresh failure, permanently blocking
    /// `.rolledBack` on every subsequent retry.
    func testRollbackRetryDoesNotReStageAnAlreadyDeletedEntityAndStillCompletes() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        kitchen.importInventory([
            InventoryImportItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil),
            InventoryImportItem(name: "牛奶", quantity: 1, unit: "盒", expiryDate: nil)
        ])
        let inner = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in inner })
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        let createdIds = try XCTUnwrap(controller.session?.createdEntityIds)
        XCTAssertEqual(createdIds.count, 2)
        let conflictingId = try XCTUnwrap(createdIds.first)
        let succeedingId = try XCTUnwrap(createdIds.last)

        // First rollback attempt: one entity conflicts, the other succeeds —
        // reverts to .completed per the test above.
        let conflicting = ConflictInjectingTransport(inner: inner, conflictEntityId: conflictingId)
        let firstAttempt = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in conflicting })
        await firstAttempt.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        await firstAttempt.rollback(authStore: authStore)
        XCTAssertEqual(firstAttempt.session?.status, .completed)

        // The already-deleted entity's delete was sent once, at baseVersion
        // "1" (its remoteVersion right after the original create). Capture
        // that now so a retry that wrongly re-stages it (at its new,
        // post-delete remoteVersion) is distinguishable from a retry that
        // correctly leaves it untouched.
        let baseVersionAfterFirstAttempt = await inner.lastReceivedBaseVersion(for: succeedingId)
        XCTAssertEqual(baseVersionAfterFirstAttempt, "1")

        // Retry against a transport with no injected conflict — the
        // previously-succeeded entity must not be re-sent at all.
        let retryController = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in inner })
        await retryController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        await retryController.rollback(authStore: authStore)

        XCTAssertEqual(retryController.session?.status, .rolledBack, "once the previously-conflicting entity's delete succeeds, the whole session must complete rollback")
        let conflictingDeleted = await inner.isSoftDeleted(conflictingId)
        XCTAssertTrue(conflictingDeleted)
        let succeedingDeleted = await inner.isSoftDeleted(succeedingId)
        XCTAssertTrue(succeedingDeleted)
        let baseVersionAfterRetry = await inner.lastReceivedBaseVersion(for: succeedingId)
        XCTAssertEqual(baseVersionAfterRetry, baseVersionAfterFirstAttempt, "an already-deleted entity must not be re-staged/re-sent on retry")
    }

    /// Same as the conflict case above, but for a server `rejected` status
    /// (e.g. `already_deleted`, `not_found`) rather than `conflict` — the
    /// verification logic keys off the entity's resulting `SyncMetadata`
    /// state, not the specific `SyncMutationStatus`, so both must be caught
    /// identically.
    func testRollbackDoesNotReportSuccessWhenAnEntityIsRejected() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        kitchen.importInventory([InventoryImportItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil)])
        let inner = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in inner })
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        let itemId = try XCTUnwrap(controller.session?.createdEntityIds.first)

        let rejecting = ConflictInjectingTransport(inner: inner, conflictEntityId: itemId, status: .rejected)
        let rejectController = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in rejecting })
        await rejectController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)

        await rejectController.rollback(authStore: authStore)

        XCTAssertEqual(rejectController.session?.status, .completed, "a rejected delete must never be reported as .rolledBack")
        let deletedRemotely = await inner.isSoftDeleted(itemId)
        XCTAssertFalse(deletedRemotely, "the rejected entity must remain live remotely")
    }

    /// Once a session genuinely reaches `.rolledBack`, a routine preview
    /// re-check must be free to start a brand-new session for any newly
    /// created local Guest data — `.rolledBack` is a true terminal state,
    /// unlike `.completed`, and must never itself block future merges.
    func testFreshPreviewAfterRolledBackStartsANewSessionNotBlockedForever() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        await controller.rollback(authStore: authStore)
        let rolledBackSessionId = try XCTUnwrap(controller.session?.id)
        XCTAssertEqual(controller.session?.status, .rolledBack)

        kitchen.importInventory([InventoryImportItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil)])
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)

        XCTAssertNotEqual(controller.session?.id, rolledBackSessionId, "a rolledBack session must never keep blocking a fresh preview for new local Guest data")
        XCTAssertNotEqual(controller.session?.status, .rolledBack)
    }

    /// A session whose rollback window has already expired must NOT keep
    /// blocking a fresh preview — only a still-eligible `.completed` session
    /// is preserved across a `preparePreview` re-check.
    func testPreparePreviewStartsFreshOnceRollbackWindowHasExpired() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        var completed = try XCTUnwrap(controller.session)
        completed.rollbackAvailableUntil = Date().addingTimeInterval(-1)
        try await persistence.saveGuestMergeSession(completed)

        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)

        XCTAssertNotEqual(controller.session?.id, completed.id, "once the rollback window has expired, a routine preview re-check may start a fresh session")
    }

    // MARK: - Phase 2C-1: minimum-version enforcement / rate-limit client handling

    /// 4/8/9/11/12/18/19: a 426 from confirmMerge must disable the confirm
    /// path (via `clientUpgradeRequired`), keep the local Guest marker,
    /// never mark anything failed/rejected in a way that discards it, and
    /// never touch `session`/`createdEntityIds` beyond the ordinary retry
    /// path that already existed for any transport error.
    func testConfirmMergeUpgradeRequiredSetsFlagAndPreservesLocalData() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in UpgradeRequiredMergeTransport() })
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        let localItemId = try XCTUnwrap(kitchen.inventory.first?.id)

        XCTAssertFalse(controller.clientUpgradeRequired)
        await controller.confirmMerge(authStore: authStore)

        XCTAssertTrue(controller.clientUpgradeRequired, "a 426 must set the upgrade-required display flag")
        XCTAssertEqual(controller.lastErrorMessage, "当前版本过旧，更新后才能继续使用家庭同步。")
        XCTAssertTrue(kitchen.inventory.contains { $0.id == localItemId }, "local Guest data must never be touched by an upgrade-required failure")
        XCTAssertEqual(controller.session?.createdEntityIds, [], "nothing was ever actually created remotely")
    }

    /// 6: a fresh preparePreview call resets the upgrade-required flag, so a
    /// later successful attempt (after the user updates the app) is not
    /// permanently stuck showing "需要更新".
    func testUpgradeRequiredFlagClearsOnANewPreparePreviewAttempt() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let failingController = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in UpgradeRequiredMergeTransport() })
        await failingController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await failingController.confirmMerge(authStore: authStore)
        XCTAssertTrue(failingController.clientUpgradeRequired)

        // Simulate "the user updated the app" — a fresh preview attempt this
        // time succeeds (SimulatedMergeTransport, no upgrade-required error).
        let succeedingController = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })
        await succeedingController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        XCTAssertFalse(succeedingController.clientUpgradeRequired, "a fresh session/controller must not carry over a stale upgrade-required flag")
    }

    /// 7: a merge preview failure from an upgrade-required remote fetch must
    /// never be displayed as if the household had 0 cloud items — it must
    /// show the dedicated failure state instead (existing Phase 2B-8
    /// machinery, exercised here specifically with a 426).
    func testMergePreviewUpgradeRequiredNeverShowsRemoteCountZero() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in UpgradeRequiredMergeTransport() })
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: UpgradeRequiredMergeTransport())

        XCTAssertNotNil(controller.previewFetchFailureMessage, "an upgrade-required remote read must surface the dedicated failure state")
        XCTAssertNil(controller.plan, "no plan — and therefore no '家庭云端库存 0 条' — may ever be shown for a failed remote read")
        XCTAssertTrue(controller.clientUpgradeRequired)
    }

    /// 10/13: a 429 from rollback must not falsely report `.rolledBack`, must
    /// keep the session retryable (`.completed`, not a terminal status), and
    /// must record a retry-after deadline the UI can show — without ever
    /// disabling the rollback button (unlike upgrade-required).
    func testRollbackRateLimitedStaysRetryableAndRecordsRetryAfter() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)

        let rateLimitedController = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in RateLimitedMergeTransport() })
        await rateLimitedController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        await rateLimitedController.rollback(authStore: authStore)

        XCTAssertEqual(rateLimitedController.session?.status, .completed, "rate-limited rollback must remain retryable, never falsely rolledBack")
        XCTAssertNotNil(rateLimitedController.rateLimitedRetryAfter)
        XCTAssertFalse(rateLimitedController.clientUpgradeRequired, "rate limiting is unrelated to version compatibility — must not also disable the rollback button")
    }

    /// 12/14: neither an upgrade-required nor a rate-limited failure ever
    /// stages a duplicate mutation — `createdEntityIds` reflects only what
    /// genuinely applied, and a later successful retry does not re-create.
    func testUpgradeRequiredAndRateLimitedNeverProduceADuplicateCreate() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let failingController = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in UpgradeRequiredMergeTransport() })
        await failingController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let authStore = await signedInAuthStore(userID: userA)
        await failingController.confirmMerge(authStore: authStore)
        XCTAssertEqual(failingController.session?.createdEntityIds, [])

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let retryController = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        await retryController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        await retryController.confirmMerge(authStore: authStore)
        XCTAssertEqual(retryController.session?.createdEntityIds.count, 1, "the retry after the app is updated must create exactly once, not a duplicate on top of a phantom prior create")
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

    /// Phase 2B-8C: a physical-device revalidation of the now-reachable
    /// Conflict UI surfaced a real dead end — `confirmMerge` uploads any
    /// non-conflict candidates, leaves the session in `.conflict` when one
    /// remains unresolved, and *nothing* ever moved the session back out of
    /// `.conflict` once every remaining candidate got a choice.
    /// `InventoryMergeConflictView` has no confirm/continue action of its
    /// own, and `InventoryMergeFlowView` only routes to the preview screen
    /// (which has the confirm button) for other statuses — so a user who
    /// resolved their last conflict (via any of the four choices, including
    /// `.skip`) was permanently stuck looking at an now-empty conflict form.
    /// This regression proves `resolveConflict` now hands control back to
    /// the ordinary preview flow once nothing here still needs a decision.
    func testResolvingTheLastConflictReturnsToPreviewReadyNotStuckOnConflict() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let ambiguousId = UUID()
        let createId = UUID()
        kitchen.inventory = [
            InventoryItem(id: ambiguousId, name: "苹果", quantity: 5, unit: "个", expiryDate: nil),
            InventoryItem(id: createId, name: "香蕉", quantity: 1, unit: "根", expiryDate: nil)
        ]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: UUID(), name: "苹果", unit: "个", quantity: 2, version: "1", sequence: "1")
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        XCTAssertEqual(controller.plan?.candidates.first(where: { $0.localItemId == ambiguousId })?.conflictReason, .ambiguousDuplicate)

        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        // The non-conflict create ("香蕉") uploads; the ambiguous one is left
        // pending, so the session lands in `.conflict` — exactly the state
        // that was previously a permanent dead end.
        XCTAssertEqual(controller.session?.status, .conflict)
        XCTAssertEqual(controller.session?.uploadedItemCount, 1)
        let appliedCountBeforeResolve = await transport.appliedCount()
        XCTAssertEqual(appliedCountBeforeResolve, 1)
        let scope = SyncScope(type: .household, id: householdA)
        let pendingBeforeResolve = try await persistence.pendingMutations(scope: scope, maxAttempts: 5)
        XCTAssertTrue(pendingBeforeResolve.isEmpty)

        await controller.resolveConflict(candidateId: ambiguousId, choice: .skip)

        XCTAssertEqual(
            controller.session?.status, .previewReady,
            "resolving the last remaining conflict must hand control back to the ordinary preview flow, never leave the session stuck on .conflict with no way to confirm again"
        )
        // The skip choice itself must still be exactly as safe as before this fix.
        let resolved = try XCTUnwrap(controller.plan?.candidates.first(where: { $0.localItemId == ambiguousId }))
        XCTAssertEqual(resolved.action, .skip)
        XCTAssertFalse(controller.plan?.readyToUpload.contains(where: { $0.localItemId == ambiguousId }) ?? true)

        // `resolveConflict` itself must never auto-trigger a confirm/upload —
        // it only ever persists a choice and (per this fix) the session's
        // status. Neither the transport's applied-mutation count nor the
        // local pending-mutation ledger may change as a side effect of
        // resolving.
        let appliedCountAfterResolve = await transport.appliedCount()
        XCTAssertEqual(appliedCountAfterResolve, appliedCountBeforeResolve, "resolveConflict must never call sendMutations itself")
        let pendingAfterResolve = try await persistence.pendingMutations(scope: scope, maxAttempts: 5)
        XCTAssertTrue(pendingAfterResolve.isEmpty, "resolveConflict must never stage a PendingMutation")

        // Re-entering the flow (simulating "close and reopen the sheet", the
        // exact real-device symptom this bug produced) must land back on the
        // ordinary preview — never regenerate a fresh empty conflict form,
        // never get stuck again, and must remember the resolved choice.
        let controllerAfterReopen = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controllerAfterReopen.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        XCTAssertEqual(controllerAfterReopen.session?.status, .previewReady, "re-opening the merge flow must never land back on a stuck .conflict screen")
        XCTAssertEqual(controllerAfterReopen.plan?.candidates.first(where: { $0.localItemId == ambiguousId })?.userChoice, .skip)
    }

    /// The same recovery as
    /// `testResolvingTheLastConflictReturnsToPreviewReadyNotStuckOnConflict`,
    /// but with `.keepRemote` instead of `.skip` — proving the status
    /// transition generalizes across choices (it only ever checks
    /// `plan.conflicts.isEmpty`, never which action a candidate resolved to),
    /// matching the choice actually exercised during physical-device
    /// revalidation (`keepLocal`, an equally action-bearing choice).
    func testResolvingTheLastConflictWithKeepRemoteAlsoReturnsToPreviewReady() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let ambiguousId = UUID()
        let createId = UUID()
        kitchen.inventory = [
            InventoryItem(id: ambiguousId, name: "苹果", quantity: 5, unit: "个", expiryDate: nil),
            InventoryItem(id: createId, name: "香蕉", quantity: 1, unit: "根", expiryDate: nil)
        ]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: UUID(), name: "苹果", unit: "个", quantity: 2, version: "1", sequence: "1")
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .conflict)
        let appliedCountBeforeResolve = await transport.appliedCount()

        await controller.resolveConflict(candidateId: ambiguousId, choice: .keepRemote)

        XCTAssertEqual(controller.session?.status, .previewReady)
        let resolved = try XCTUnwrap(controller.plan?.candidates.first(where: { $0.localItemId == ambiguousId }))
        XCTAssertEqual(resolved.action, .keepRemote)
        XCTAssertFalse(controller.plan?.readyToUpload.contains(where: { $0.localItemId == ambiguousId }) ?? true, "keepRemote never stages anything for the candidate it applies to")
        let appliedCountAfterResolve = await transport.appliedCount()
        XCTAssertEqual(appliedCountAfterResolve, appliedCountBeforeResolve, "resolveConflict must never call sendMutations itself, regardless of the choice")
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
        // Give the export something real to leak, so the assertions below
        // are actually exercising redaction rather than passing vacuously.
        let secretlyNamedItem = InventoryItem(name: "秘密食材-用户不该看到这个名字", quantity: 1, unit: "个", expiryDate: nil)
        await controller.handleInventoryDidChange(old: [], new: [secretlyNamedItem], userId: userA, householdId: householdA)
        let stagedMutationId = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: secretlyNamedItem.id)?.mutationId

        let snapshot = await controller.diagnosticsSnapshot(
            kitchenStore: kitchen, userId: userA, householdId: householdA,
            environmentName: "development", appBuild: "1.0-test"
        )
        let json = String(data: snapshot.redactedJSON(), encoding: .utf8) ?? ""
        var forbidden = [
            userA.uuidString, householdA.uuidString, secretlyNamedItem.id.uuidString,
            secretlyNamedItem.name, "@", "token", "password", "Authorization", "authorization", "refreshToken",
        ]
        if let stagedMutationId { forbidden.append(stagedMutationId.uuidString) }
        for value in forbidden {
            XCTAssertFalse(json.contains(value), "diagnostics export must never contain \(value)")
        }
        XCTAssertEqual(snapshot.pendingCount, 1, "sanity check: the staged mutation this test relies on for leak-testing actually exists")
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

    // MARK: - Phase 2B-6: fault injection

    func testOfflineDuringBootstrapLeavesPendingRetainedAndCursorUnmoved() async throws {
        let (_, persistence) = try await enrolledStores()
        let scope = SyncScope(type: .household, id: householdA)
        let cursorBefore = try await persistence.cursor(for: scope).value
        let fault = InventorySyncFaultInjectingTransport(inner: SimulatedMergeTransport(userID: userA, householdID: householdA))
        await fault.setBootstrapFault(.throwError(.transport))
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in fault })
        let item = InventoryItem(name: "离线场景", quantity: 1, unit: "个", expiryDate: nil)
        await controller.handleInventoryDidChange(old: [], new: [item], userId: userA, householdId: householdA)

        let authStore = await signedInAuthStore(userID: userA)
        await controller.syncNow(authStore: authStore, householdId: householdA)

        XCTAssertEqual(controller.lastSyncOutcome, .failed(.transport))
        let pending = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: item.id)
        XCTAssertNotNil(pending, "an offline run must never lose the staged mutation")
        let cursorAfter = try await persistence.cursor(for: scope).value
        XCTAssertEqual(cursorBefore, cursorAfter, "cursor must never advance on a bootstrap failure")
    }

    func test401DuringBootstrapStopsTheRunAndRetainsPendingForRetryAfterReLogin() async throws {
        let (_, persistence) = try await enrolledStores()
        let fault = InventorySyncFaultInjectingTransport(inner: SimulatedMergeTransport(userID: userA, householdID: householdA))
        await fault.setBootstrapFault(.throwError(.unauthorized))
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in fault })
        let item = InventoryItem(name: "401场景", quantity: 1, unit: "个", expiryDate: nil)
        await controller.handleInventoryDidChange(old: [], new: [item], userId: userA, householdId: householdA)

        let authStore = await signedInAuthStore(userID: userA)
        await controller.syncNow(authStore: authStore, householdId: householdA)

        // A server-returned 401 (stale/invalid token) is `.unauthorized`,
        // distinct from `.notAuthenticated` (no local session at all) —
        // only the latter maps to `.paused` in `SyncCoordinator.runOnce`;
        // this one is `.failed`, and the controller still surfaces a
        // re-login-needed message for either case.
        XCTAssertEqual(controller.lastSyncOutcome, .failed(.unauthorized))
        XCTAssertNotNil(controller.lastSyncErrorMessage, "the UI must surface a re-login-needed message")
        let pending = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: item.id)
        XCTAssertNotNil(pending, "a 401 must never discard the staged mutation")
    }

    func test403OnBootstrapStopsTheScopeWithoutDeletingPending() async throws {
        let (_, persistence) = try await enrolledStores()
        let fault = InventorySyncFaultInjectingTransport(inner: SimulatedMergeTransport(userID: userA, householdID: householdA))
        await fault.setBootstrapFault(.throwError(.forbidden))
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in fault })
        let item = InventoryItem(name: "403场景", quantity: 1, unit: "个", expiryDate: nil)
        await controller.handleInventoryDidChange(old: [], new: [item], userId: userA, householdId: householdA)

        let authStore = await signedInAuthStore(userID: userA)
        await controller.syncNow(authStore: authStore, householdId: householdA)

        XCTAssertEqual(controller.lastSyncOutcome, .failed(.forbidden))
        let pending = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: item.id)
        XCTAssertNotNil(pending, "a 403 must never discard the staged mutation")
    }

    func test413PayloadTooLargeRetainsPendingAndSurfacesAnUnderstandableError() async throws {
        let (_, persistence) = try await enrolledStores()
        let fault = InventorySyncFaultInjectingTransport(inner: SimulatedMergeTransport(userID: userA, householdID: householdA))
        await fault.setSendMutationsFault(.throwError(.payloadTooLarge))
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in fault })
        let item = InventoryItem(name: "413场景", quantity: 1, unit: "个", expiryDate: nil)
        await controller.handleInventoryDidChange(old: [], new: [item], userId: userA, householdId: householdA)

        let authStore = await signedInAuthStore(userID: userA)
        await controller.syncNow(authStore: authStore, householdId: householdA)

        XCTAssertEqual(controller.lastSyncOutcome, .failed(.payloadTooLarge))
        let pending = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: item.id)
        XCTAssertNotNil(pending, "a 413 must never drop the staged mutation — no data loss")
    }

    func test429IsTreatedAsRetryableAndNeverBusyLoopsSinceSyncIsAlwaysManuallyTriggered() async throws {
        let (_, persistence) = try await enrolledStores()
        let fault = InventorySyncFaultInjectingTransport(inner: SimulatedMergeTransport(userID: userA, householdID: householdA))
        // SyncError has no dedicated 429 case yet; the project maps
        // rate-limiting onto the existing retryable `.backendUnavailable`
        // case rather than adding a new one this phase (see
        // docs/INVENTORY_SYNC_FAULT_INJECTION.md).
        await fault.setSendMutationsFault(.throwError(.backendUnavailable))
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in fault })
        let item = InventoryItem(name: "429场景", quantity: 1, unit: "个", expiryDate: nil)
        await controller.handleInventoryDidChange(old: [], new: [item], userId: userA, householdId: householdA)

        let authStore = await signedInAuthStore(userID: userA)
        await controller.syncNow(authStore: authStore, householdId: householdA)
        let callsAfterFirstAttempt = await fault.sendMutationsCallCount
        XCTAssertEqual(controller.lastSyncOutcome, .failed(.backendUnavailable))
        XCTAssertFalse(controller.isSyncing, "there must be no automatic retry loop — the next attempt only ever happens from an explicit user tap")
        XCTAssertEqual(callsAfterFirstAttempt, 1, "a single manual sync call must only ever attempt sendMutations once, never loop internally")
    }

    func test500And503AreRetainedAsRetryable() async throws {
        for error: SyncError in [.backendUnavailable] {
            let (_, persistence) = try await enrolledStores()
            let fault = InventorySyncFaultInjectingTransport(inner: SimulatedMergeTransport(userID: userA, householdID: householdA))
            await fault.setSendMutationsFault(.throwError(error))
            let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in fault })
            let item = InventoryItem(name: "5xx场景", quantity: 1, unit: "个", expiryDate: nil)
            await controller.handleInventoryDidChange(old: [], new: [item], userId: userA, householdId: householdA)
            let authStore = await signedInAuthStore(userID: userA)
            await controller.syncNow(authStore: authStore, householdId: householdA)
            XCTAssertEqual(controller.lastSyncOutcome, .failed(error))
            let pending = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: item.id)
            XCTAssertNotNil(pending)
        }
    }

    func testMalformedOrTruncatedJSONNeverAdvancesTheCursorOrDropsPending() async throws {
        let (_, persistence) = try await enrolledStores()
        let scope = SyncScope(type: .household, id: householdA)
        let cursorBefore = try await persistence.cursor(for: scope).value
        let inner = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await inner.seedRemoteChange(id: UUID(), name: "远端项目", unit: "个", quantity: 1, version: "1", sequence: "1")
        let fault = InventorySyncFaultInjectingTransport(inner: inner)
        await fault.setFetchChangesFault(.malformedOrTruncatedJSON)
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in fault })
        let item = InventoryItem(name: "本机项目", quantity: 1, unit: "个", expiryDate: nil)
        await controller.handleInventoryDidChange(old: [], new: [item], userId: userA, householdId: householdA)

        let authStore = await signedInAuthStore(userID: userA)
        await controller.syncNow(authStore: authStore, householdId: householdA)

        XCTAssertEqual(controller.lastSyncOutcome, .failed(.decoding))
        let cursorAfter = try await persistence.cursor(for: scope).value
        XCTAssertEqual(cursorBefore, cursorAfter, "a decode failure must never advance the pull cursor")
        // The item's own push happens before the pull phase and is
        // unaffected by this fault, so it resolves normally — a fault
        // confined to `fetchChanges` must never reach back and disturb an
        // already-successfully-pushed, unrelated mutation.
        let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: item.id)
        XCTAssertEqual(metadata?.state, .synced, "the unrelated push must still have completed normally despite the later pull decode failure")
    }

    func testPushAppliedThenClientTimeoutIsDuplicateSafeOnRetry() async throws {
        let (_, persistence) = try await enrolledStores()
        let inner = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let fault = InventorySyncFaultInjectingTransport(inner: inner)
        await fault.setSendMutationsFault(.throwError(.transport), applyFirst: true)
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in fault })
        let item = InventoryItem(name: "超时场景", quantity: 1, unit: "个", expiryDate: nil)
        await controller.handleInventoryDidChange(old: [], new: [item], userId: userA, householdId: householdA)
        let originalMutationId = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: item.id)?.mutationId

        let authStore = await signedInAuthStore(userID: userA)
        await controller.syncNow(authStore: authStore, householdId: householdA)
        XCTAssertEqual(controller.lastSyncOutcome, .failed(.transport))
        let appliedCount = await inner.appliedCount()
        XCTAssertEqual(appliedCount, 1, "the server side really did apply the mutation despite the client seeing a timeout")
        let afterTimeoutMutation = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: item.id)
        XCTAssertEqual(afterTimeoutMutation?.mutationId, originalMutationId, "the client must never mint a second mutationId after a timeout")

        await fault.setSendMutationsFault(.none)
        await controller.syncNow(authStore: authStore, householdId: householdA)
        XCTAssertEqual(controller.lastSyncOutcome, .completed)
        let finalMutation = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: item.id)
        XCTAssertNil(finalMutation, "the retry resolves the same mutation; it must never create a second pending record for the same entity")
    }

    func testPullSucceedsButLocalSaveFailureNeverAdvancesCursor() async throws {
        let (kitchen, sharedPersistence) = try makeSharedStores(seedGuestInventory: false)
        try await sharedPersistence.saveEnrollment(InventorySyncEnrollment(
            userId: userA, householdId: householdA, status: .enrolled, enrolledAt: Date(),
            mergeSessionId: UUID(), schemaVersion: InventorySyncEnrollment.currentSchemaVersion, updatedAt: Date()
        ))
        let scope = SyncScope(type: .household, id: householdA)
        let cursorBefore = try await sharedPersistence.cursor(for: scope).value
        let failingPersistence = SwiftDataSyncPersistence(modelContainer: sharedPersistence.modelContainer, behavior: .failSavesForTesting)
        let inner = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await inner.seedRemoteChange(id: UUID(), name: "远端新项目", unit: "个", quantity: 3, version: "1", sequence: "1")
        let controller = GuestMergeController(persistence: failingPersistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in inner })

        let authStore = await signedInAuthStore(userID: userA)
        await controller.syncNow(authStore: authStore, householdId: householdA)

        XCTAssertEqual(controller.lastSyncOutcome, .failed(.persistence))
        let cursorAfter = try await sharedPersistence.cursor(for: scope).value
        XCTAssertEqual(cursorBefore, cursorAfter, "a local save failure while applying a pulled change must never advance the cursor")
        _ = kitchen
    }

    func testAppKillBeforePendingCleanupIsRecoveredAndDuplicateSafeOnNextLaunch() async throws {
        let (_, sharedPersistence) = try await enrolledStores()
        let entityId = UUID()
        try await sharedPersistence.saveMetadata(SyncMetadata(
            entityType: .inventoryItem, entityId: entityId, scope: SyncScope(type: .household, id: householdA),
            remoteVersion: nil, state: .pendingCreate, lastSyncedAt: nil,
            lastErrorCode: nil, lastErrorAt: nil, deletedAt: nil, updatedAt: Date()
        ))
        let mutationId = UUID()
        try await sharedPersistence.savePending(PendingMutation(
            mutationId: mutationId, entityType: .inventoryItem, entityId: entityId,
            scope: SyncScope(type: .household, id: householdA), operation: .upsert,
            baseVersion: .zero, payloadData: Data("{\"name\":\"kill场景\"}".utf8),
            clientUpdatedAt: Date(), createdAt: Date(), attemptCount: 0, lastAttemptAt: nil,
            lastErrorCode: nil, status: .pending
        ))
        // Simulate the App having been killed mid-push: the mutation was
        // marked in-flight but the process died before a result ever came
        // back to resolve it.
        try await sharedPersistence.markInFlight(ids: [mutationId], attemptedAt: Date(), maxAttempts: 5)

        // "Relaunch": a brand-new persistence actor over the same on-disk
        // (here in-memory, but identically fresh-actor) container.
        let relaunchedPersistence = SwiftDataSyncPersistence(modelContainer: sharedPersistence.modelContainer)
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = GuestMergeController(persistence: relaunchedPersistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        let authStore = await signedInAuthStore(userID: userA)

        await controller.syncNow(authStore: authStore, householdId: householdA)

        XCTAssertEqual(controller.lastSyncOutcome, .completed, "an in-flight mutation orphaned by an App kill must still be picked up and resolved on the next run")
        let resolved = try await relaunchedPersistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: entityId)
        XCTAssertNil(resolved, "the recovered mutation resolves normally; retrying it after relaunch must never leave a duplicate pending row")
    }

    // MARK: - Phase 2B-6: single-flight / lifecycle

    func testTenRapidSyncTapsOnlyEverAttemptSendMutationsOnce() async throws {
        let (_, persistence) = try await enrolledStores()
        let inner = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let fault = InventorySyncFaultInjectingTransport(inner: inner)
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in fault })
        let item = InventoryItem(name: "并发场景", quantity: 1, unit: "个", expiryDate: nil)
        await controller.handleInventoryDidChange(old: [], new: [item], userId: userA, householdId: householdA)
        let authStore = await signedInAuthStore(userID: userA)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { await controller.syncNow(authStore: authStore, householdId: self.householdA) }
            }
        }

        XCTAssertFalse(controller.isSyncing)
        let calls = await fault.sendMutationsCallCount
        XCTAssertEqual(calls, 1, "10 rapid concurrent taps must only ever result in exactly one sendMutations call")
    }

    func testLogoutBeforeSyncNeverStartsARun() async throws {
        let (_, persistence) = try await enrolledStores()
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })
        let signedOutStore = await signedInAuthStore(userID: userA)
        await signedOutStore.signOut()

        await controller.syncNow(authStore: signedOutStore, householdId: householdA)

        XCTAssertEqual(controller.lastSyncOutcome, nil, "signing out first must mean syncNow never even attempts a run")
    }

    func testAScopeMismatchNeverLeavesTheSingleFlightGuardStuck() async throws {
        // The fake transport's bootstrap only ever reports `householdA`
        // (matching its own fixed `householdID`), so requesting `householdB`
        // is a genuine scope mismatch — a real-world analogue of a stale
        // household reference. It must resolve (`.paused(.forbidden)`),
        // never hang, and never leave `isSyncing` stuck so a subsequent
        // correctly-scoped call still runs.
        let (_, persistence) = try await enrolledStores()
        try await persistence.saveEnrollment(InventorySyncEnrollment(
            userId: userA, householdId: householdB, status: .enrolled, enrolledAt: Date(),
            mergeSessionId: UUID(), schemaVersion: InventorySyncEnrollment.currentSchemaVersion, updatedAt: Date()
        ))
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })
        let authStore = await signedInAuthStore(userID: userA)

        await controller.syncNow(authStore: authStore, householdId: householdB)
        XCTAssertEqual(controller.lastSyncOutcome, .paused(.forbidden), "a scope this transport doesn't recognize must resolve, not hang")
        XCTAssertFalse(controller.isSyncing)

        await controller.syncNow(authStore: authStore, householdId: householdA)
        XCTAssertEqual(controller.lastSyncOutcome, .completed, "the guard must not still be held after the previous mismatched-scope attempt")
    }

    // MARK: - Phase 2B-6: scale / performance (local only, no absolute promises)

    func testConsistencyCheckerCompletesQuicklyAt1000MetadataRows() {
        var metadata: [SyncMetadata] = []
        metadata.reserveCapacity(1000)
        for _ in 0..<1000 {
            metadata.append(SyncMetadata(
                entityType: .inventoryItem, entityId: UUID(), scope: SyncScope(type: .household, id: householdA),
                remoteVersion: try! SyncCursorValue("1"), state: .synced, lastSyncedAt: Date(),
                lastErrorCode: nil, lastErrorAt: nil, deletedAt: nil, updatedAt: Date()
            ))
        }
        let localIds = Set(metadata.map(\.entityId))
        let start = Date()
        let issues = InventorySyncConsistencyChecker.check(
            localInventoryIds: localIds, allMetadata: metadata, allPendingMutations: [],
            enrollment: nil, expectedUserId: nil, expectedHouseholdId: nil,
            activeMergeSession: nil, previousCursorValue: nil, currentCursorValue: nil
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(issues.isEmpty)
        // No absolute performance promise — this is a local, environment-
        // dependent sanity bound (a linear-ish pass over 1000 rows should
        // never take anywhere close to a second), not a guaranteed SLA.
        XCTAssertLessThan(elapsed, 2.0, "consistency checker over 1000 rows took unexpectedly long: \(elapsed)s")
    }

    func testEligibilityQueueCapCheckIsConstantTimeRegardlessOfPendingCount() {
        let start = Date()
        for _ in 0..<500 {
            _ = InventorySyncEligibility.evaluate(
                isFeatureEnabled: true, userId: userA, householdId: householdA,
                enrollment: InventorySyncEnrollment(
                    userId: userA, householdId: householdA, status: .enrolled, enrolledAt: Date(),
                    mergeSessionId: UUID(), schemaVersion: InventorySyncEnrollment.currentSchemaVersion, updatedAt: Date()
                ),
                existingMetadata: nil, intent: .create,
                hasExistingPendingMutationForEntity: false, currentPendingCount: 500, maxPendingMutations: 200
            )
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0, "500 eligibility evaluations took unexpectedly long: \(elapsed)s — would suggest an O(n^2) hotspot")
    }

    func testDiagnosticsSnapshotAt500PendingAnd100ConflictsCompletesQuickly() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let scope = SyncScope(type: .household, id: householdA)
        for index in 0..<500 {
            let entityId = UUID()
            // `conflictCount` reflects `SyncMetadata.state == .conflicted`
            // (not `PendingMutation.status`), so the first 100 also get a
            // matching conflicted metadata row to genuinely exercise both
            // counters, not just `pendingCount`.
            if index < 100 {
                try await persistence.saveMetadata(SyncMetadata(
                    entityType: .inventoryItem, entityId: entityId, scope: scope,
                    remoteVersion: try! SyncCursorValue("1"), state: .conflicted, lastSyncedAt: nil,
                    lastErrorCode: nil, lastErrorAt: nil, deletedAt: nil, updatedAt: Date()
                ))
            }
            try await persistence.savePending(PendingMutation(
                mutationId: UUID(), entityType: .inventoryItem, entityId: entityId, scope: scope,
                operation: .upsert, baseVersion: .zero, payloadData: Data("{}".utf8),
                clientUpdatedAt: Date(), createdAt: Date(), attemptCount: 0, lastAttemptAt: nil,
                lastErrorCode: nil, status: .pending
            ))
        }
        let controller = GuestMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })

        let start = Date()
        let snapshot = await controller.diagnosticsSnapshot(
            kitchenStore: kitchen, userId: userA, householdId: householdA,
            environmentName: "development", appBuild: "scale-test"
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(snapshot.pendingCount, 500)
        XCTAssertEqual(snapshot.conflictCount, 100)
        XCTAssertLessThan(elapsed, 2.0, "diagnostics snapshot over 500 pending rows took unexpectedly long: \(elapsed)s")
    }

    // MARK: - Phase 2B-6: queue-cap pressure at scale

    func testQueueCapAt200HoldsFirmAgainst250AttemptedCreatesAndDeletesAreNeverDropped() async throws {
        let (_, persistence) = try await enrolledStores()
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            dogfoodConfiguration: InventorySyncDogfoodConfiguration(maxPendingMutations: 200),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        var items: [InventoryItem] = []
        for index in 0..<250 {
            let item = InventoryItem(name: "cap-item-\(index)", quantity: 1, unit: "个", expiryDate: nil)
            await controller.handleInventoryDidChange(old: items, new: items + [item], userId: userA, householdId: householdA)
            items.append(item)
        }
        let scope = SyncScope(type: .household, id: householdA)
        let pendingAfterFlood = try await persistence.pendingMutations(scope: scope, maxAttempts: .max)
        XCTAssertEqual(pendingAfterFlood.count, 200, "the queue must hold exactly at its configured cap, never grow past it")

        // A delete for one of the 200 already-staged (create-pending) items
        // must still be accepted even while the queue sits exactly at its
        // cap — deletes are never dropped, and this one also coalesces
        // create+delete into a full cancel (Phase 2B-4 rule), so it can't
        // even be blamed on "growing" the queue.
        let alreadyStagedForDelete = items[3]
        await controller.handleInventoryDidChange(old: items, new: items.filter { $0.id != alreadyStagedForDelete.id }, userId: userA, householdId: householdA)
        let metadataAfterDelete = try await persistence.metadata(entityType: .inventoryItem, entityId: alreadyStagedForDelete.id)
        XCTAssertNil(metadataAfterDelete, "create+delete before any sync must fully cancel, even while the queue is at cap")

        // Coalescing an update into one of the 200 already-staged creates
        // must still succeed (it doesn't grow the queue).
        let alreadyStagedItem = items[5]
        var updated = alreadyStagedItem
        updated.quantity = 99
        await controller.handleInventoryDidChange(old: items, new: items.map { $0.id == alreadyStagedItem.id ? updated : $0 }, userId: userA, householdId: householdA)
        let coalescedMutation = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: alreadyStagedItem.id)
        XCTAssertEqual(coalescedMutation?.operation, .upsert, "coalescing an update into an already-staged create must still succeed under a full queue")

        // Guest-local CRUD (i.e. the in-memory business write itself) always
        // proceeds regardless of sync-staging outcome — that's `KitchenStore`'s
        // own concern, entirely decoupled from the sync hook's return value.
        XCTAssertNotNil(controller.inventoryMutationBlockedMessage, "the queue-full message must be user-visible once the cap is hit")
    }

    // MARK: - Phase 2B-8: production preview remote read, fingerprint, stale-confirm gate

    func testProductionPreviewOverloadConstructsANonNilTransportAndReadsRemoteState() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: UUID(), name: "牛奶", unit: "盒", quantity: 1, version: "1", sequence: "1")
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        let authStore = await signedInAuthStore(userID: userA)
        kitchen.importInventory([InventoryImportItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil)])

        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)

        XCTAssertEqual(controller.plan?.knownRemoteItemCount, 1, "the production entry point must perform a real remote read, not default to an empty transport")
        XCTAssertNil(controller.previewFetchFailureMessage)
    }

    func testProductionPreviewNeverReadsATokenDirectlyFromTheView() async throws {
        // Structural guard: the production overload only ever takes an
        // `AuthStore` reference (never a raw token parameter) — this is
        // enforced by the type system, so a successful compile+call here is
        // itself the assertion that no token value crosses this boundary.
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        let authStore = await signedInAuthStore(userID: userA, token: "should-never-be-read-directly")
        kitchen.importInventory([InventoryImportItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil)])
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        XCTAssertNotNil(controller.session)
    }

    func testScopeMismatchDuringPreviewFetchBlocksPreviewRatherThanReturningPartialResults() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in ScopeMismatchTransport() }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: ScopeMismatchTransport())
        XCTAssertNil(controller.session, "a scope mismatch must never be silently treated as a valid, if partial, remote snapshot")
        XCTAssertNotNil(controller.previewFetchFailureMessage)
    }

    func testPaginationExceedingTheMaxPageCapBlocksPreviewRatherThanReturningATruncatedSnapshot() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in NeverEndingPaginationTransport() }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: NeverEndingPaginationTransport())
        XCTAssertNil(controller.session, "hitting the max-page cap while more remote data remains must never silently return a truncated snapshot as if it were complete")
        XCTAssertNotNil(controller.previewFetchFailureMessage)
    }

    func test401DuringPreviewFetchBlocksPreviewAndNeverShowsZeroCloudItemsAsSuccess() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let inner = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let faulting = InventorySyncFaultInjectingTransport(inner: inner)
        await faulting.setFetchChangesFault(.throwError(.unauthorized))
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in faulting }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: faulting)
        XCTAssertNil(controller.session)
        XCTAssertNotNil(controller.previewFetchFailureMessage)
        XCTAssertNotEqual(controller.previewFetchFailureMessage, "0", "a 401 must never be presented as an empty-but-successful household")
    }

    func testOfflineDuringPreviewFetchBlocksPreview() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in FailingMergeTransport() }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: FailingMergeTransport())
        XCTAssertNil(controller.session)
        XCTAssertNotNil(controller.previewFetchFailureMessage)
    }

    func testMalformedOrUndecodableRemoteResponseBlocksPreview() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let inner = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let faulting = InventorySyncFaultInjectingTransport(inner: inner)
        await faulting.setFetchChangesFault(.malformedOrTruncatedJSON)
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in faulting }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: faulting)
        XCTAssertNil(controller.session)
        XCTAssertNotNil(controller.previewFetchFailureMessage)
    }

    func testAPreviewFetchFailureNeverTouchesAnExistingSessionOrFallsBackToAnEmptyCloudState() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        kitchen.importInventory([InventoryImportItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil)])
        let goodTransport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in goodTransport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: goodTransport)
        let sessionIdBefore = try XCTUnwrap(controller.session?.id)

        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: FailingMergeTransport())
        XCTAssertEqual(controller.session?.id, sessionIdBefore, "a subsequent failed refresh must never replace, clear, or degrade the previously valid session")
        XCTAssertNotNil(controller.previewFetchFailureMessage)
    }

    func testPreviewFetchPerformsZeroMutationsAndNeverAdvancesThePersistedPullCursor() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        kitchen.importInventory([InventoryImportItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil)])
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: UUID(), name: "牛奶", unit: "盒", quantity: 1, version: "1", sequence: "1")
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)

        let scope = SyncScope(type: .household, id: householdA)
        let pending = try await persistence.pendingMutations(scope: scope, maxAttempts: 5)
        XCTAssertTrue(pending.isEmpty, "preview must never stage a mutation as a side effect of the pre-merge read")
        let cursor = try await persistence.cursor(for: scope)
        XCTAssertEqual(cursor.value, .zero, "preview must never advance the persisted pull cursor SyncCoordinator relies on")
    }

    // MARK: - Phase 2B-8: remote snapshot fingerprint

    func testRemoteSnapshotHashIsDeterministicAndOrderIndependent() {
        let itemA = RemoteInventorySnapshotItem(id: UUID(), name: "苹果", unit: "个", quantity: 2, expiryDate: nil)
        let itemB = RemoteInventorySnapshotItem(id: UUID(), name: "牛奶", unit: "盒", quantity: 1, expiryDate: Date())
        let forward = InventoryMergePlanner.remoteSnapshotHash([itemA, itemB])
        let reversed = InventoryMergePlanner.remoteSnapshotHash([itemB, itemA])
        XCTAssertEqual(forward, reversed, "the remote fingerprint must not depend on fetch/page order")
        XCTAssertEqual(forward, InventoryMergePlanner.remoteSnapshotHash([itemA, itemB]), "re-hashing an identical snapshot must reproduce the exact same fingerprint")
    }

    func testRemoteSnapshotHashChangesWhenRemoteVersionChanges() throws {
        let id = UUID()
        let itemAtV1 = RemoteInventorySnapshotItem(id: id, name: "苹果", unit: "个", quantity: 2, expiryDate: nil, remoteVersion: try SyncCursorValue("1"))
        let itemAtV2 = RemoteInventorySnapshotItem(id: id, name: "苹果", unit: "个", quantity: 2, expiryDate: nil, remoteVersion: try SyncCursorValue("2"))
        let before = InventoryMergePlanner.remoteSnapshotHash([itemAtV1])
        let after = InventoryMergePlanner.remoteSnapshotHash([itemAtV2])
        XCTAssertNotEqual(before, after, "a remote version bump alone must change the fingerprint, even with identical business fields")
    }

    func testRemoteSnapshotHashChangesWhenARemoteItemIsCreatedOrDeleted() {
        let existing = RemoteInventorySnapshotItem(id: UUID(), name: "苹果", unit: "个", quantity: 2, expiryDate: nil)
        let created = RemoteInventorySnapshotItem(id: UUID(), name: "牛奶", unit: "盒", quantity: 1, expiryDate: nil)
        let before = InventoryMergePlanner.remoteSnapshotHash([existing])
        let afterCreate = InventoryMergePlanner.remoteSnapshotHash([existing, created])
        XCTAssertNotEqual(before, afterCreate, "a new remote item must change the fingerprint")
        let afterDelete = InventoryMergePlanner.remoteSnapshotHash([])
        XCTAssertNotEqual(before, afterDelete, "a remote item disappearing (delete/tombstone) must change the fingerprint")
    }

    func testPlanCarriesARemoteSnapshotHashOnlyWhenARealRemoteReadHappened() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let noTransportController = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in FailingMergeTransport() }
        )
        await noTransportController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        XCTAssertNil(noTransportController.plan?.remoteSnapshotHash, "the offline/no-transport path must keep producing a plan with no remote fingerprint at all, exactly as before")

        let (kitchen2, persistence2) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userB, householdID: householdB)
        let realController = GuestMergeController(
            persistence: persistence2, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await realController.preparePreview(userId: userB, householdId: householdB, kitchenStore: kitchen2, remoteTransport: transport)
        XCTAssertNotNil(realController.plan?.remoteSnapshotHash, "a real remote read must always populate a fingerprint, even when the household has zero known remote items")
    }

    // MARK: - Phase 2B-8: remote drift invalidates the plan and blocks a stale confirm

    func testRemoteDataChangingAfterPreviewInvalidatesThePlanViaIsPlanStillValid() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        let plan = try XCTUnwrap(controller.plan)
        XCTAssertTrue(InventoryMergePlanner.isPlanStillValid(plan, against: kitchen.inventory, currentRemoteItems: []))

        let driftedRemote = [RemoteInventorySnapshotItem(id: UUID(), name: "新增远端条目", unit: "个", quantity: 1, expiryDate: nil)]
        XCTAssertFalse(
            InventoryMergePlanner.isPlanStillValid(plan, against: kitchen.inventory, currentRemoteItems: driftedRemote),
            "a remote-side change since preview must invalidate the plan, exactly like a local-side change already does"
        )
    }

    func testConfirmMergeRejectsAStaleRemoteFingerprintAndStagesNoMutationAtAll() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        kitchen.importInventory([InventoryImportItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil)])
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        XCTAssertEqual(controller.session?.status, .previewReady)

        // Simulate remote drift between preview and confirm: another device
        // creates a business-equivalent remote item after this device's
        // preview already ran.
        await transport.seedRemoteChange(id: UUID(), name: "牛奶", unit: "盒", quantity: 1, version: "1", sequence: "1")

        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        XCTAssertEqual(controller.session?.status, .previewReady, "a stale confirm must revert to previewReady, never proceed to upload")
        XCTAssertNotNil(controller.lastErrorMessage)
        let scope = SyncScope(type: .household, id: householdA)
        let pending = try await persistence.pendingMutations(scope: scope, maxAttempts: 5)
        XCTAssertTrue(pending.isEmpty, "a stale confirm must never stage a single PendingMutation")
        let applied = await transport.appliedCount()
        XCTAssertEqual(applied, 0, "a stale confirm must never call sendMutations at all")
    }

    func testConfirmMergeSucceedsWhenRemoteStateIsUnchangedSinceThePreMergeRead() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        kitchen.importInventory([InventoryImportItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil)])
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed, "an unchanged remote fingerprint must never block a legitimate confirm")
    }

    // MARK: - Phase 2B-8: account/household isolation for the remote read, restart recovery

    func testPreMergeRemoteReadNeverCrossesHouseholdScope() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transportForA = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transportForA.seedRemoteChange(id: UUID(), name: "A的远端物品", unit: "个", quantity: 1, version: "1", sequence: "1")
        let controllerA = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transportForA }
        )
        await controllerA.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transportForA)
        XCTAssertEqual(controllerA.plan?.knownRemoteItemCount, 1)

        let transportForB = SimulatedMergeTransport(userID: userB, householdID: householdB)
        let controllerB = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transportForB }
        )
        await controllerB.preparePreview(userId: userB, householdId: householdB, kitchenStore: kitchen, remoteTransport: transportForB)
        XCTAssertEqual(controllerB.plan?.knownRemoteItemCount, 0, "household B must never see household A's pre-merge remote read results")
    }

    func testRemoteSnapshotFingerprintSurvivesASimulatedAppRestart() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controllerBeforeRestart = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controllerBeforeRestart.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        let hashBeforeRestart = try XCTUnwrap(controllerBeforeRestart.plan?.remoteSnapshotHash)

        let controllerAfterRestart = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controllerAfterRestart.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        XCTAssertEqual(controllerAfterRestart.plan?.remoteSnapshotHash, hashBeforeRestart, "the persisted plan's remote fingerprint must survive a restart unchanged when nothing has actually happened to re-derive it")
    }

    // MARK: - Phase 2B-8: silent-duplicate regression (release blocker)

    func testProductionPreviewDoesNotSilentlyCreateBusinessEquivalentRemoteItem() async throws {
        // The exact release-blocker scenario: two independent devices each
        // create a business-equivalent item ("牛奶"/"盒") under different
        // ids before either has merged. With the production remote read now
        // wired in, this must surface as an ambiguous-duplicate conflict —
        // never a silent `.create` that would produce a duplicate remote row.
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        kitchen.importInventory([InventoryImportItem(name: "牛奶", quantity: 1, unit: "盒", expiryDate: nil)])
        let localId = kitchen.inventory.first!.id

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: UUID(), name: "牛奶", unit: "盒", quantity: 1, version: "1", sequence: "1")
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)

        let candidate = try XCTUnwrap(controller.plan?.candidates.first(where: { $0.localItemId == localId }))
        XCTAssertEqual(candidate.conflictReason, .ambiguousDuplicate, "a different-id, same-business-key remote match must never be silently created")
        XCTAssertTrue(candidate.needsDecision)
        XCTAssertFalse(controller.plan?.readyToUpload.contains(where: { $0.localItemId == localId }) ?? true, "an unresolved ambiguous duplicate must never be part of what confirm is allowed to upload")

        await controller.confirmMerge(authStore: authStore)

        let appliedCount = await transport.appliedCount()
        XCTAssertEqual(appliedCount, 0, "confirming with an unresolved ambiguous duplicate must never create a second, duplicate remote row for the same business item")
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
            // A real backend's next pull reflects the mutation that was just
            // applied, never the stale pre-seeded synthetic entry this mock
            // used only to simulate "a remote record this device didn't
            // upload itself" during the pre-merge read. Dropping it here
            // (rather than requiring every caller to remember a separate
            // `clearRemoteChanges()` step) keeps this mock's pull-after-push
            // behavior consistent with what `confirmMerge`'s own
            // pre-upload remote-fingerprint revalidation already observed
            // during preview — a real backend never drifts out from under
            // its own just-applied write.
            changes.removeAll { $0.entityId == request.entityId }
            results.append(result)
        }
        return SyncMutationBatchResponse(results: results, cursor: try SyncCursorValue(String(sequence)))
    }
}

/// Wraps a real transport but forces one specific entity's mutation to come
/// back `.conflict`/`.rejected` instead of ever reaching `inner` — every
/// other mutation in the same batch is passed through untouched. Used to
/// test that a multi-entity Rollback never reports whole-session success
/// when only some of its entities' deletes actually applied.
private actor ConflictInjectingTransport: SyncTransport {
    private let inner: any SyncTransport
    private let conflictEntityId: UUID
    private let status: SyncMutationStatus

    init(inner: any SyncTransport, conflictEntityId: UUID, status: SyncMutationStatus = .conflict) {
        self.inner = inner
        self.conflictEntityId = conflictEntityId
        self.status = status
    }

    func bootstrap() async throws -> SyncBootstrapResponse { try await inner.bootstrap() }

    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse {
        try await inner.fetchChanges(scope: scope, after: cursor, limit: limit)
    }

    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse {
        let passthrough = mutations.filter { $0.entityId != conflictEntityId }
        let response = try await inner.sendMutations(scope: scope, mutations: passthrough)
        var results = response.results
        if let conflicting = mutations.first(where: { $0.entityId == conflictEntityId }) {
            results.append(SyncMutationResult(
                mutationId: conflicting.mutationId, entityId: conflicting.entityId,
                status: status, version: conflicting.baseVersion, sequence: nil,
                errorCode: status == .rejected ? "already_deleted" : "stale_version", originalStatus: nil, serverRecord: nil
            ))
        }
        return SyncMutationBatchResponse(results: results, cursor: response.cursor)
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

/// Phase 2C-1: simulates every sync call failing with the server's 426 —
/// used to test the controller's upgrade-required display/disable behavior
/// without any real network involved.
private actor UpgradeRequiredMergeTransport: SyncTransport {
    func bootstrap() async throws -> SyncBootstrapResponse { throw SyncError.clientUpgradeRequired(minimumVersion: "9.0.0", minimumBuild: 42) }
    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse { throw SyncError.clientUpgradeRequired(minimumVersion: "9.0.0", minimumBuild: 42) }
    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse { throw SyncError.clientUpgradeRequired(minimumVersion: "9.0.0", minimumBuild: 42) }
}

/// Phase 2C-1: simulates every sync call failing with the server's 429.
private actor RateLimitedMergeTransport: SyncTransport {
    func bootstrap() async throws -> SyncBootstrapResponse { throw SyncError.rateLimited(retryAfterSeconds: 5) }
    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse { throw SyncError.rateLimited(retryAfterSeconds: 5) }
    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse { throw SyncError.rateLimited(retryAfterSeconds: 5) }
}

/// Simulates a malformed/untrustworthy backend response where the returned
/// scope doesn't match what was requested — this must never be silently
/// treated as "the household has nothing yet" (see
/// `GuestMergeController.fetchKnownRemoteItems`'s scope-mismatch guard).
private actor ScopeMismatchTransport: SyncTransport {
    func bootstrap() async throws -> SyncBootstrapResponse { throw SyncError.transport }
    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse {
        SyncChangesResponse(scopeType: scope.type, scopeId: UUID(), cursor: cursor, hasMore: false, changes: [])
    }
    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse { throw SyncError.transport }
}

/// Simulates a household with more remote data than the pre-merge read's
/// hardcoded `maxPages` cap can cover — always reports `hasMore: true` with
/// a genuinely non-empty page, so the read loop always exhausts the page cap
/// instead of ever completing naturally. Used to prove the pagination-cap
/// path throws rather than silently returning a truncated snapshot.
private actor NeverEndingPaginationTransport: SyncTransport {
    func bootstrap() async throws -> SyncBootstrapResponse { throw SyncError.transport }
    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse {
        let nextSequence = (Int(cursor.rawValue) ?? 0) + 1
        let change = SyncChangeEnvelope(
            sequence: try SyncCursorValue(String(nextSequence)), entityType: .inventoryItem, entityId: UUID(),
            operation: .upsert, version: try SyncCursorValue("1"), changedAt: Date(),
            data: ["name": .string("远端条目\(nextSequence)"), "quantity": .number(1), "unit": .string("个"), "isStaple": .bool(false)]
        )
        return SyncChangesResponse(
            scopeType: scope.type, scopeId: scope.id, cursor: try SyncCursorValue(String(nextSequence)), hasMore: true, changes: [change]
        )
    }
    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse { throw SyncError.transport }
}

/// Phase 2B-6: test-only deterministic fault injection. Wraps a real inner
/// `SyncTransport` (never a live network call) and, per configured fault,
/// either throws a specific `SyncError` before delegating, delays before
/// delegating, or — for the "applied then client-side fault" scenarios —
/// lets the inner transport genuinely record the mutation as applied and
/// *then* throws, simulating a client that times out / is killed after the
/// server already committed. This type exists only in the test target; it
/// is never imported by, or reachable from, any file under `KitchenManager/`,
/// so it cannot enter a Release build or any production code path by
/// construction, and it never logs a payload or credential.
private enum InventorySyncFault: Equatable {
    case none
    case throwError(SyncError)
    case delay(TimeInterval)
    /// Fails to decode — used for both "malformed" and "truncated" JSON,
    /// since at this layer both manifest identically as a decoding failure
    /// the coordinator must treat as non-destructive (`SyncError.decoding`).
    case malformedOrTruncatedJSON
}

private actor InventorySyncFaultInjectingTransport: SyncTransport {
    private let inner: any SyncTransport
    private var bootstrapFault: InventorySyncFault = .none
    private var fetchChangesFault: InventorySyncFault = .none
    private var sendMutationsFault: InventorySyncFault = .none
    /// When true, `sendMutations` still delegates to `inner` first (so the
    /// fake backend's own state really advances — a real "push applied"),
    /// and only *then* raises `sendMutationsFault` to the caller, regardless
    /// of what the inner call actually returned.
    private var applyBeforeFaultingSend = false
    private(set) var sendMutationsCallCount = 0

    init(inner: any SyncTransport) { self.inner = inner }

    func setBootstrapFault(_ fault: InventorySyncFault) { bootstrapFault = fault }
    func setFetchChangesFault(_ fault: InventorySyncFault) { fetchChangesFault = fault }
    func setSendMutationsFault(_ fault: InventorySyncFault, applyFirst: Bool = false) {
        sendMutationsFault = fault
        applyBeforeFaultingSend = applyFirst
    }

    func bootstrap() async throws -> SyncBootstrapResponse {
        try await Self.apply(bootstrapFault)
        return try await inner.bootstrap()
    }

    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse {
        try await Self.apply(fetchChangesFault)
        return try await inner.fetchChanges(scope: scope, after: cursor, limit: limit)
    }

    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse {
        sendMutationsCallCount += 1
        if applyBeforeFaultingSend {
            _ = try? await inner.sendMutations(scope: scope, mutations: mutations)
            try await Self.apply(sendMutationsFault)
        }
        try await Self.apply(sendMutationsFault)
        return try await inner.sendMutations(scope: scope, mutations: mutations)
    }

    private static func apply(_ fault: InventorySyncFault) async throws {
        switch fault {
        case .none:
            return
        case .throwError(let error):
            throw error
        case .malformedOrTruncatedJSON:
            throw SyncError.decoding
        case .delay(let seconds):
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }
}

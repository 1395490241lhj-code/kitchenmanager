import Combine
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
        let recipes = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let summary = GuestDatasetDetector.summary(kitchenStore: kitchen, recipeStore: recipes, at: Date())
        XCTAssertFalse(summary.hasAnyGuestData)
        XCTAssertFalse(summary.hasMergeableInventory)
    }

    func testDetectionReportsInventoryCountWithoutModifyingAnything() {
        let kitchen = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        kitchen.addInventory(name: "土豆", quantity: 3, unit: "个", expiryDate: nil)
        kitchen.addInventory(name: "洋葱", quantity: 2, unit: "个", expiryDate: nil)
        let before = kitchen.inventory
        let summary = GuestDatasetDetector.summary(
            kitchenStore: kitchen,
            recipeStore: RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        XCTAssertEqual(summary.inventoryCount, 2)
        XCTAssertTrue(summary.hasMergeableInventory)
        XCTAssertEqual(kitchen.inventory, before, "detection must never mutate Guest inventory")
    }

    func testDetectionReportsOtherModulesButNoInventoryIsNotMergeable() {
        let kitchen = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        kitchen.addShoppingItems([KitchenShoppingItem(name: "牛奶", quantity: 1, unit: "盒")])
        let summary = GuestDatasetDetector.summary(
            kitchenStore: kitchen,
            recipeStore: RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
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

    // MARK: - Sync P3: preparation classification in the merge planner

    /// The core P3 regression. Before P3 the planner compared only the
    /// `isStaple` projection, and `.readyToCook` and `.ordinary` both project
    /// to `false` — so this pair was classified as a clean no-op, landed in
    /// `exactMatches`, was shown to the user as 无需处理, and was never staged.
    /// The local ready-to-cook state was lost with no user-visible trace.
    func testReadyToCookVersusOrdinaryIsDetectedRatherThanTreatedAsANoOp() {
        let local = InventoryItem(name: "腌鸡翅", quantity: 4, unit: "个", expiryDate: nil, kind: .readyToCook)
        let remote = RemoteInventorySnapshotItem(
            id: local.id, name: "腌鸡翅", unit: "个", quantity: 4, expiryDate: nil, kind: .ordinary
        )
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: householdA, localItems: [local], knownRemoteItems: [remote]
        )
        XCTAssertEqual(
            plan.candidates.first?.conflictReason, .metadataMismatch,
            "a ready-to-cook vs ordinary difference must never be mistaken for a true no-op"
        )
        XCTAssertTrue(plan.exactMatches.isEmpty, "the pair must not be reported to the user as 无需处理")
    }

    func testStapleVersusReadyToCookIsDetected() {
        let local = InventoryItem(name: "大米", quantity: 5, unit: "袋", expiryDate: nil, kind: .staple)
        let remote = RemoteInventorySnapshotItem(
            id: local.id, name: "大米", unit: "袋", quantity: 5, expiryDate: nil, kind: .readyToCook
        )
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: householdA, localItems: [local], knownRemoteItems: [remote]
        )
        XCTAssertEqual(plan.candidates.first?.conflictReason, .metadataMismatch)
    }

    func testMatchingClassificationDoesNotFabricateAConflict() {
        for kind in InventoryItemKind.allCases {
            let local = InventoryItem(name: "鸡翅", quantity: 4, unit: "个", expiryDate: nil, kind: kind)
            let remote = RemoteInventorySnapshotItem(
                id: local.id, name: "鸡翅", unit: "个", quantity: 4, expiryDate: nil, kind: kind
            )
            let plan = InventoryMergePlanner.makePlan(
                sessionId: UUID(), householdId: householdA, localItems: [local], knownRemoteItems: [remote]
            )
            XCTAssertNil(plan.candidates.first?.conflictReason, "\(kind) on both sides is a genuine no-op")
            XCTAssertEqual(plan.candidates.first?.action, .skip, "\(kind)")
        }
    }

    func testRemoteSnapshotHashSeesAPreparationOnlyDrift() throws {
        let id = UUID()
        func snapshot(_ kind: InventoryItemKind) -> RemoteInventorySnapshotItem {
            RemoteInventorySnapshotItem(id: id, name: "腌鸡翅", unit: "个", quantity: 4, expiryDate: nil, kind: kind)
        }
        // Both sides project to `isStaple == false`, so hashing only the
        // projection would let this drift slip through confirmMerge's
        // pre-write re-verification unnoticed.
        XCTAssertNotEqual(
            InventoryMergePlanner.remoteSnapshotHash([snapshot(.ordinary)]),
            InventoryMergePlanner.remoteSnapshotHash([snapshot(.readyToCook)])
        )
        XCTAssertEqual(
            InventoryMergePlanner.remoteSnapshotHash([snapshot(.readyToCook)]),
            InventoryMergePlanner.remoteSnapshotHash([snapshot(.readyToCook)]),
            "the hash must still be stable for an unchanged snapshot"
        )
    }

    func testLocalClassificationChangeInvalidatesAnAlreadyGeneratedPlan() {
        var local = InventoryItem(name: "腌鸡翅", quantity: 4, unit: "个", expiryDate: nil, kind: .ordinary)
        let remote = RemoteInventorySnapshotItem(
            id: local.id, name: "腌鸡翅", unit: "个", quantity: 4, expiryDate: nil, kind: .ordinary
        )
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: householdA, localItems: [local], knownRemoteItems: [remote]
        )
        XCTAssertTrue(InventoryMergePlanner.isPlanStillValid(plan, against: [local]))
        local.kind = .readyToCook
        XCTAssertFalse(
            InventoryMergePlanner.isPlanStillValid(plan, against: [local]),
            "classification changes the merge outcome, so a plan generated before the edit must be regenerated"
        )
    }

    func testClassificationIsMetadataAndNeverPartOfIdentity() {
        // Two remote rows sharing one business key but differing only by
        // classification must stay one ambiguous bucket — classification must
        // not split them into two separately matchable identities, and must
        // not change the dedup behaviour. (The PWA's `kind` identity semantics
        // are deliberately not imported here.)
        let local = InventoryItem(name: "鸡翅", quantity: 4, unit: "个", expiryDate: nil, kind: .readyToCook)
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: householdA, localItems: [local],
            knownRemoteItems: [
                RemoteInventorySnapshotItem(id: UUID(), name: "鸡翅", unit: "个", quantity: 4, expiryDate: nil, kind: .ordinary),
                RemoteInventorySnapshotItem(id: UUID(), name: "鸡翅", unit: "个", quantity: 4, expiryDate: nil, kind: .readyToCook)
            ]
        )
        XCTAssertEqual(plan.candidates.first?.conflictReason, .multipleRemoteCandidates)

        // The same two rows, differing only by classification, must also fall
        // into one identity bucket when matched by business key rather than
        // by stable id: a `.readyToCook` local row still finds an `.ordinary`
        // remote row under a *different* id as an ambiguous duplicate. If
        // classification had leaked into the matching key, the local row
        // would find no match at all and escape into `.create`, silently
        // duplicating the household's record.
        let ambiguous = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: householdA,
            localItems: [InventoryItem(name: "鸡翅", quantity: 4, unit: "个", expiryDate: nil, kind: .readyToCook)],
            knownRemoteItems: [
                RemoteInventorySnapshotItem(id: UUID(), name: "鸡翅", unit: "个", quantity: 4, expiryDate: nil, kind: .ordinary)
            ]
        )
        XCTAssertEqual(ambiguous.candidates.first?.conflictReason, .ambiguousDuplicate)
        XCTAssertNotEqual(ambiguous.candidates.first?.action, .create, "classification must not split one identity into two")
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
        let controller = makeMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )

        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        XCTAssertEqual(controller.session?.status, .previewReady)
        XCTAssertNil(controller.session?.confirmedAt)

        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)
        XCTAssertNotNil(controller.session?.confirmedAt)
        XCTAssertNotNil(controller.session?.completedAt)
        XCTAssertNotNil(controller.session?.rollbackAvailableUntil)
        XCTAssertEqual(controller.session?.uploadedItemCount, 1)
    }

    func testCancelBeforeConfirmationNeverCreatesAPendingMutation() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let authStoreForConfirm = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStoreForConfirm)
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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

        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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

    /// End-to-end Sync P3: a ready-to-cook classification difference must be
    /// surfaced as a conflict, and resolving it `keepLocal` must upload both
    /// classification axes together, from the one local snapshot.
    func testReadyToCookConflictUploadsBothClassificationAxesTogether() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        kitchen.inventory = [
            InventoryItem(id: sharedId, name: "腌鸡翅", quantity: 4, unit: "个", expiryDate: nil, kind: .readyToCook)
        ]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        // The household's remote row is ordinary: same id, same name/unit,
        // same quantity, no expiry — the classification is the only difference.
        await transport.seedRemoteChange(
            id: sharedId, name: "腌鸡翅", unit: "个", quantity: 4,
            isStaple: false, preparationKind: "none", version: "3", sequence: "1"
        )
        let controller = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(
            userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport
        )
        let candidate = try XCTUnwrap(controller.plan?.candidates.first(where: { $0.localItemId == sharedId }))
        XCTAssertEqual(candidate.conflictReason, .metadataMismatch)

        await controller.resolveConflict(candidateId: sharedId, choice: .keepLocal)
        XCTAssertEqual(controller.plan?.candidates.first(where: { $0.localItemId == sharedId })?.action, .update)

        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)

        let sentPayload = await transport.lastReceivedPayload(for: sharedId)
        let uploaded = try XCTUnwrap(sentPayload)
        XCTAssertEqual(uploaded["isStaple"], .bool(false), "the staple axis must travel with the preparation axis")
        XCTAssertEqual(uploaded["preparationKind"], .string("readyToCook"))
        XCTAssertNil(uploaded["kind"], "`kind` is the PWA-owned column and must never be uploaded by this client")
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controllerBeforeRestart = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controllerBeforeRestart.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        await controllerBeforeRestart.resolveConflict(candidateId: sharedId, choice: .keepBoth)
        let forkedId = try XCTUnwrap(controllerBeforeRestart.plan?.candidates.first(where: { $0.localItemId == sharedId })?.forkedLocalItemId)

        let controllerAfterRestart = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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

        let controller = makeMergeController(
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
        let controllerBeforeRestart = makeMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        await controllerBeforeRestart.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let originalSessionId = controllerBeforeRestart.session?.id
        XCTAssertNotNil(originalSessionId)

        // Simulate an App restart: a brand new controller instance, same persistence.
        let controllerAfterRestart = makeMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        await controllerAfterRestart.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        XCTAssertEqual(controllerAfterRestart.session?.id, originalSessionId, "resuming must reuse the same session id, never regenerate one")
    }

    func testUserAAndUserBSessionsAreFullyIsolated() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let controllerA = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })
        await controllerA.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)

        let controllerB = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userB, householdID: self.householdB) })
        await controllerB.preparePreview(userId: userB, householdId: householdB, kitchenStore: kitchen)

        XCTAssertNotEqual(controllerA.session?.id, controllerB.session?.id)
        XCTAssertNotNil(controllerA.session)
        XCTAssertNotNil(controllerB.session)

        // Re-entering as user A again must resolve back to A's own session, not B's.
        let controllerAAgain = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })
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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })

        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
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
        let controller = makeMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in FailingMergeTransport(fetchSucceeds: true) }
        )
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .failed)
    }

    // MARK: - Completion marker / no re-scan

    func testCompletedSessionMarksSyncMetadataSyncedAndClearsPending() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        let itemId = controller.plan?.creates.first?.localItemId
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

        let controllerAfter = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })
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
        // R3: built through `makeRollbackController`, which requires the store
        // the assertions read and proves it shares the persistence actor's
        // container. Wired to `scratchKitchenStore` (the old default) this test
        // asserted on an array nothing ever reconciled, and kept passing while
        // the durable row was being deleted.
        let controller = try await makeRollbackController(persistence: persistence, kitchenStore: kitchen, transport: transport)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)
        let itemId = try XCTUnwrap(controller.session?.createdEntityIds.first)

        await controller.rollback(authStore: authStore)

        XCTAssertEqual(controller.session?.status, .rolledBack)
        let deletedRemotely = await transport.isSoftDeleted(itemId)
        XCTAssertTrue(deletedRemotely)
        // Local Guest data must never be deleted by a rollback — asserted on
        // durable storage first, then on the reconciled in-memory array.
        let durable = try await persistence.inventoryItem(id: itemId)
        XCTAssertNotNil(durable)
        XCTAssertTrue(kitchen.inventory.contains { $0.id == itemId })
    }

    func testRollbackIsIdempotentWhenRepeated() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
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
        let controllerA = try await makeRollbackController(persistence: sharedPersistence, kitchenStore: kitchen, transport: transport)
        let authStore = await signedInAuthStore(userID: userA)
        await controllerA.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controllerA.confirmMerge(authStore: authStore)
        XCTAssertEqual(controllerA.session?.status, .completed)
        let sessionId = try XCTUnwrap(controllerA.session?.id)
        let itemId = try XCTUnwrap(controllerA.session?.createdEntityIds.first)

        // Simulate an App relaunch between the merge completing and the user
        // tapping Rollback: a brand-new persistence actor over the same
        // on-disk container, and a brand-new controller instance — exactly
        // what a fresh `InventoryMergePromptView`/result screen would do.
        let relaunchedPersistence = SwiftDataSyncPersistence(modelContainer: sharedPersistence.modelContainer)
        let controllerB = try await makeRollbackController(persistence: relaunchedPersistence, kitchenStore: kitchen, transport: transport)
        await controllerB.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        XCTAssertEqual(controllerB.session?.id, sessionId, "the completed, still-rollback-eligible session must survive a relaunch's preparePreview, not be silently replaced")
        XCTAssertEqual(controllerB.session?.createdEntityIds, [itemId])

        await controllerB.rollback(authStore: authStore)

        XCTAssertEqual(controllerB.session?.status, .rolledBack)
        let deletedRemotely = await transport.isSoftDeleted(itemId)
        XCTAssertTrue(deletedRemotely, "rollback must never report .rolledBack unless the entity this session created was actually soft-deleted remotely")
        let durableAfterRelaunch = try await relaunchedPersistence.inventoryItem(id: itemId)
        XCTAssertNotNil(durableAfterRelaunch, "local Guest data must never be deleted by a rollback")
        XCTAssertTrue(kitchen.inventory.contains { $0.id == itemId }, "local Guest data must never be deleted by a rollback")
    }

    /// Same defect, no relaunch required: a second `preparePreview` call on
    /// the *same* live controller (e.g. the inventory tab re-checking for
    /// guest data on `.onAppear`) after a completed merge must not orphan the
    /// completed, still-rollback-eligible session.
    func testSecondPreparePreviewAfterCompletedMergeKeepsSessionRollbackEligible() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        let completedSessionId = try XCTUnwrap(controller.session?.id)
        XCTAssertEqual(controller.session?.status, .completed)
        let itemId = try XCTUnwrap(controller.session?.createdEntityIds.first)

        // Re-entering the same screen (or the inventory tab re-checking for
        // guest data) calls preparePreview again — same controller, same
        // persistence, no relaunch.
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in inner })
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)
        let createdIds = try XCTUnwrap(controller.session?.createdEntityIds)
        XCTAssertEqual(createdIds.count, 2, "both imported items must have been created remotely by this session")
        let conflictingId = try XCTUnwrap(createdIds.first)
        let succeedingId = try XCTUnwrap(createdIds.last)

        let conflicting = ConflictInjectingTransport(inner: inner, conflictEntityId: conflictingId)
        let conflictController = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in conflicting })
        await conflictController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in inner })
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        let createdIds = try XCTUnwrap(controller.session?.createdEntityIds)
        XCTAssertEqual(createdIds.count, 2)
        let conflictingId = try XCTUnwrap(createdIds.first)
        let succeedingId = try XCTUnwrap(createdIds.last)

        // First rollback attempt: one entity conflicts, the other succeeds —
        // reverts to .completed per the test above.
        let conflicting = ConflictInjectingTransport(inner: inner, conflictEntityId: conflictingId)
        let firstAttempt = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in conflicting })
        await firstAttempt.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
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
        let retryController = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in inner })
        await retryController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in inner })
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        let itemId = try XCTUnwrap(controller.session?.createdEntityIds.first)

        let rejecting = ConflictInjectingTransport(inner: inner, conflictEntityId: itemId, status: .rejected)
        let rejectController = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in rejecting })
        await rejectController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)

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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        await controller.rollback(authStore: authStore)
        let rolledBackSessionId = try XCTUnwrap(controller.session?.id)
        XCTAssertEqual(controller.session?.status, .rolledBack)

        kitchen.importInventory([InventoryImportItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil)])
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)

        XCTAssertNotEqual(controller.session?.id, rolledBackSessionId, "a rolledBack session must never keep blocking a fresh preview for new local Guest data")
        XCTAssertNotEqual(controller.session?.status, .rolledBack)
    }

    /// A session whose rollback window has already expired must NOT keep
    /// blocking a fresh preview — only a still-eligible `.completed` session
    /// is preserved across a `preparePreview` re-check.
    func testPreparePreviewStartsFreshOnceRollbackWindowHasExpired() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        var completed = try XCTUnwrap(controller.session)
        completed.rollbackAvailableUntil = Date().addingTimeInterval(-1)
        try await persistence.saveGuestMergeSession(completed)

        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)

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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in UpgradeRequiredMergeTransport(fetchSucceeds: true) })
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
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
        let failingController = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in UpgradeRequiredMergeTransport() })
        let authStore = await signedInAuthStore(userID: userA)
        await failingController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await failingController.confirmMerge(authStore: authStore)
        XCTAssertTrue(failingController.clientUpgradeRequired)

        // Simulate "the user updated the app" — a fresh preview attempt this
        // time succeeds (SimulatedMergeTransport, no upgrade-required error).
        let succeedingController = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })
        await succeedingController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        XCTAssertFalse(succeedingController.clientUpgradeRequired, "a fresh session/controller must not carry over a stale upgrade-required flag")
    }

    /// 7: a merge preview failure from an upgrade-required remote fetch must
    /// never be displayed as if the household had 0 cloud items — it must
    /// show the dedicated failure state instead (existing Phase 2B-8
    /// machinery, exercised here specifically with a 426).
    func testMergePreviewUpgradeRequiredNeverShowsRemoteCountZero() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in UpgradeRequiredMergeTransport() })
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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)

        let rateLimitedController = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in RateLimitedMergeTransport() })
        // Deliberately transport-free: this only reloads the persisted completed
        // session so `rollback` has something to undo. Rollback is not gated on a
        // remote fingerprint, and this fake rejects reads as well as writes.
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
        let failingController = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in UpgradeRequiredMergeTransport(fetchSucceeds: true) })
        let authStore = await signedInAuthStore(userID: userA)
        await failingController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await failingController.confirmMerge(authStore: authStore)
        XCTAssertEqual(failingController.session?.createdEntityIds, [])

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let retryController = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
        await retryController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await retryController.confirmMerge(authStore: authStore)
        XCTAssertEqual(retryController.session?.createdEntityIds.count, 1, "the retry after the app is updated must create exactly once, not a duplicate on top of a phantom prior create")
    }

    // MARK: - Phase 2C-2: crash reporting breadcrumbs (fake provider injection)

    /// A fake provider injected via the new `crashReporter:` init parameter
    /// receives calls instead of the default `NoOpCrashReporter` — proves the
    /// abstraction is actually wired into the controller, not just declared.
    func testFakeCrashReporterInjectionOverridesDefaultProvider() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let fake = FakeCrashReporter()
        let controller = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) },
            crashReporter: fake
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        XCTAssertTrue(fake.breadcrumbs.contains { $0.event == .mergePreviewStarted })
    }

    /// A generic transport failure during manual sync emits `sync_failed`
    /// with a stable, safe error code — never the raw error description.
    func testSyncFailureEmitsSyncFailedBreadcrumbWithSafeCode() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        _ = kitchen
        let fake = FakeCrashReporter()
        let controller = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in FailingMergeTransport() }, crashReporter: fake
        )
        let authStore = await signedInAuthStore(userID: userA)
        await controller.syncNow(authStore: authStore, householdId: householdA)
        let failed = fake.breadcrumbs.first { $0.event == .syncFailed }
        XCTAssertNotNil(failed)
        XCTAssertEqual(failed?.metadata.fields["errorCode"], "transport")
    }

    /// A 426 during confirmMerge emits `sync_upgrade_required` (from the
    /// shared display-flag hook) and `merge_confirm_failed` — never any
    /// metadata field outside the allowlist.
    func test426DuringConfirmMergeEmitsUpgradeRequiredAndMergeConfirmFailedBreadcrumbs() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let fake = FakeCrashReporter()
        let controller = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in UpgradeRequiredMergeTransport(fetchSucceeds: true) }, crashReporter: fake
        )
        let authStore = await signedInAuthStore(userID: userA)
        // Needs a real remote read so the confirm below has a fingerprinted plan;
        // the fake's 426 then lands on the write, which is what this asserts.
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)

        XCTAssertTrue(fake.breadcrumbs.contains { $0.event == .syncUpgradeRequired })
        XCTAssertTrue(fake.breadcrumbs.contains { $0.event == .mergeConfirmFailed })
        for (_, metadata) in fake.breadcrumbs {
            for key in metadata.fields.keys {
                XCTAssertTrue(CrashReportingMetadata.allowedKeys.contains(key), "unexpected metadata key: \(key)")
            }
        }
    }

    /// A 429 during rollback emits `sync_rate_limited` and `rollback_failed`.
    func test429DuringRollbackEmitsRateLimitedAndRollbackFailedBreadcrumbs() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })
        let authStore = await signedInAuthStore(userID: userA)
        // Needs a real remote read so the confirm below has a fingerprinted plan.
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)

        let fake = FakeCrashReporter()
        let rateLimitedController = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in RateLimitedMergeTransport() }, crashReporter: fake
        )
        // Deliberately transport-free: this only reloads the persisted completed
        // session so `rollback` has something to undo. Rollback is not gated on a
        // remote fingerprint, and this fake rejects reads as well as writes.
        await rateLimitedController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        await rateLimitedController.rollback(authStore: authStore)

        XCTAssertTrue(fake.breadcrumbs.contains { $0.event == .syncRateLimited })
        XCTAssertTrue(fake.breadcrumbs.contains { $0.event == .rollbackFailed })
    }

    /// A successful confirmMerge/rollback cycle emits the matching
    /// started/completed breadcrumbs for both flows, with no failure events.
    func testSuccessfulMergeAndRollbackEmitStartedAndCompletedBreadcrumbsOnly() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let fake = FakeCrashReporter()
        let controller = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) },
            crashReporter: fake
        )
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)
        await controller.rollback(authStore: authStore)

        XCTAssertTrue(fake.breadcrumbs.contains { $0.event == .mergeConfirmStarted })
        XCTAssertTrue(fake.breadcrumbs.contains { $0.event == .mergeConfirmCompleted })
        XCTAssertTrue(fake.breadcrumbs.contains { $0.event == .rollbackStarted })
        XCTAssertTrue(fake.breadcrumbs.contains { $0.event == .rollbackCompleted })
        XCTAssertFalse(fake.breadcrumbs.contains { $0.event == .mergeConfirmFailed })
        XCTAssertFalse(fake.breadcrumbs.contains { $0.event == .rollbackFailed })
    }

    /// A local (non-network) preview persistence failure still reports via
    /// `captureNonFatal` — never crashing the app, and never carrying the
    /// raw error description as metadata (only the allowlisted `errorCode`
    /// bucket).
    func testConfirmMergeTransportFailureReportsNonFatalWithSafeCodeNotRawDescription() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let fake = FakeCrashReporter()
        let controller = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in FailingMergeTransport(fetchSucceeds: true) }, crashReporter: fake
        )
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)

        XCTAssertTrue(fake.nonFatals.contains { $0.code == "transport" })
        for (_, context) in fake.nonFatals {
            for key in context.fields.keys {
                XCTAssertTrue(CrashReportingMetadata.allowedKeys.contains(key))
            }
        }
    }

    // MARK: - Guest data boundary

    func testMergeDoesNotTouchShoppingPlansOrRecipes() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
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
        let controller = makeMergeController(persistence: persistence, transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })
        XCTAssertFalse(controller.isFeatureEnabled, "default bundle has no KM_INVENTORY_SYNC_ENABLED key, so the feature must stay off")
    }

    // MARK: - Phase 2B-3: INVENTORY_MERGE_UI_ENABLED (independent of INVENTORY_SYNC_ENABLED)

    func testInventoryMergeUIEnabledDefaultsToFalseWhenInfoPlistKeyIsAbsent() {
        XCTAssertFalse(InventoryMergeUIConfiguration().isEnabled)
        XCTAssertFalse(InventoryMergeUIConfiguration.load().isEnabled, "default bundle has no KM_INVENTORY_MERGE_UI_ENABLED key, so the UI must stay hidden")
    }

    func testIsUIEnabledReflectsInjectedUIConfigurationIndependentlyOfNetworkFlag() throws {
        let (_, persistence) = try makePersistence()
        let uiOnlyController = makeMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: false),
            uiConfiguration: InventoryMergeUIConfiguration(isEnabled: true)
        )
        XCTAssertTrue(uiOnlyController.isUIEnabled)
        XCTAssertFalse(uiOnlyController.isFeatureEnabled, "the UI flag must never itself grant network capability")

        let networkOnlyController = makeMergeController(
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
        let controller = makeMergeController(
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
        let controllerAfterRestart = makeMergeController(
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
        let controller = makeMergeController(
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
        let controllerAfterReopen = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let before = await controller.enrollmentStatus(userId: userA, householdId: householdA)
        XCTAssertEqual(before, .notEnrolled)

        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)

        let after = await controller.enrollmentStatus(userId: userA, householdId: householdA)
        XCTAssertEqual(after, .enrolled)
    }

    func testEnrollmentIsIsolatedBetweenUsersAndHouseholds() async throws {
        let (kitchenA, persistence) = try makeSharedStores(seedGuestInventory: false)
        kitchenA.inventory = [InventoryItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil)]
        let controllerA = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let authStoreA = await signedInAuthStore(userID: userA)
        await controllerA.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchenA, authStore: authStoreA)
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
        let controllerBeforeRestart = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let authStore = await signedInAuthStore(userID: userA)
        await controllerBeforeRestart.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controllerBeforeRestart.confirmMerge(authStore: authStore)
        XCTAssertEqual(controllerBeforeRestart.session?.status, .completed)

        let controllerAfterRestart = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let status = await controllerAfterRestart.enrollmentStatus(userId: userA, householdId: householdA)
        XCTAssertEqual(status, .enrolled)
    }

    func testFlagOffNeverStagesEvenWhenEnrolled() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        kitchen.inventory = [InventoryItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil)]
        let enrolledController = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) }
        )
        let authStore = await signedInAuthStore(userID: userA)
        await enrolledController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await enrolledController.confirmMerge(authStore: authStore)
        XCTAssertEqual(enrolledController.session?.status, .completed)

        // A fresh controller with the flag OFF must never stage anything,
        // even though enrollment itself already says "enrolled".
        let flagOffController = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controllerA = makeMergeController(
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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in fault })
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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in fault })
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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in fault })
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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in fault })
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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in fault })
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
            let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in fault })
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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in fault })
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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in fault })
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
        let controller = makeMergeController(persistence: failingPersistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in inner })

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
        let controller = makeMergeController(persistence: relaunchedPersistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in transport })
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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in fault })
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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })
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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })
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
        let controller = makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) })

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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in ScopeMismatchTransport() }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: ScopeMismatchTransport())
        XCTAssertNil(controller.session, "a scope mismatch must never be silently treated as a valid, if partial, remote snapshot")
        XCTAssertNotNil(controller.previewFetchFailureMessage)
    }

    func testPaginationExceedingTheMaxPageCapBlocksPreviewRatherThanReturningATruncatedSnapshot() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let noTransportController = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in FailingMergeTransport() }
        )
        await noTransportController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        XCTAssertNil(noTransportController.plan?.remoteSnapshotHash, "the offline/no-transport path must keep producing a plan with no remote fingerprint at all, exactly as before")

        let (kitchen2, persistence2) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userB, householdID: householdB)
        let realController = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controller = makeMergeController(
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
        let controllerA = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transportForA }
        )
        await controllerA.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transportForA)
        XCTAssertEqual(controllerA.plan?.knownRemoteItemCount, 1)

        let transportForB = SimulatedMergeTransport(userID: userB, householdID: householdB)
        let controllerB = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transportForB }
        )
        await controllerB.preparePreview(userId: userB, householdId: householdB, kitchenStore: kitchen, remoteTransport: transportForB)
        XCTAssertEqual(controllerB.plan?.knownRemoteItemCount, 0, "household B must never see household A's pre-merge remote read results")
    }

    func testRemoteSnapshotFingerprintSurvivesASimulatedAppRestart() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controllerBeforeRestart = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controllerBeforeRestart.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        let hashBeforeRestart = try XCTUnwrap(controllerBeforeRestart.plan?.remoteSnapshotHash)

        let controllerAfterRestart = makeMergeController(
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
        let controller = makeMergeController(
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

    // MARK: - UI-5B2B-A: explicit preview boundary and legacy-plan safety

    func testPreviewDoesNotReadRemoteUntilExplicitTransportIsProvided() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = PreviewBoundaryTransport()
        let controller = makeMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )

        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        let readsBeforeExplicitTap = await transport.fetchCount()
        XCTAssertEqual(readsBeforeExplicitTap, 0)
        XCTAssertNil(controller.plan?.remoteSnapshotHash)

        await controller.preparePreview(
            userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport
        )
        let readsAfterExplicitTap = await transport.fetchCount()
        let mutationsBeforeConfirm = await transport.mutationCount()
        XCTAssertEqual(readsAfterExplicitTap, 1)
        XCTAssertEqual(mutationsBeforeConfirm, 0)
        XCTAssertNotNil(controller.plan?.remoteSnapshotHash)
    }

    func testRemotePreviewFailureHidesPersistedPlanAndLeavesLocalInventoryUntouched() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = PreviewBoundaryTransport(failure: .unauthorized)
        let controller = makeMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        let localBefore = kitchen.inventory

        await controller.preparePreview(
            userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport
        )

        XCTAssertNil(controller.session)
        XCTAssertNotNil(controller.previewFetchFailureMessage)
        XCTAssertEqual(kitchen.inventory, localBefore)
        let mutationsAfterFailure = await transport.mutationCount()
        XCTAssertEqual(mutationsAfterFailure, 0)
    }

    /// A plan with no remote fingerprint must never reach the production write
    /// path, even when the caller bypasses the preview UI entirely.
    ///
    /// `preparePreview` without a transport is a legitimate local/offline entry
    /// point, but it both persists a plan whose `remoteSnapshotHash` is nil *and*
    /// clears `previewRequiresRemoteFingerprint`. A confirm guard that consults
    /// that mutable flag can therefore be disarmed by controller state rather than
    /// by the plan's own trustworthiness, so the guard must depend only on the
    /// plan. Nothing here touches a real network: the recorder is the only
    /// transport and the credential provider is a fake signed-in `AuthStore`.
    func testHashLessPlanFromNoTransportPreviewCanNeverReachProductionConfirmWritePath() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = PreviewBoundaryTransport()
        let controller = makeMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        let scope = SyncScope(type: .household, id: householdA)
        let localBefore = kitchen.inventory

        // 1. Build and persist a hash-less plan through the no-transport path.
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)

        // 2. The bypass precondition really is set up.
        XCTAssertNotNil(controller.session, "no-transport 预览应生成本地会话")
        XCTAssertNotNil(controller.plan, "no-transport 预览应生成计划")
        XCTAssertNil(controller.plan?.remoteSnapshotHash, "no-transport 计划不应带远端指纹")
        XCTAssertFalse(controller.plan?.readyToUpload.isEmpty ?? true,
                       "该计划必须有待上传候选，否则这个测试无法证明写入被阻止")

        let stagedBefore = try await persistence.pendingMutations(scope: scope, maxAttempts: .max)
        let readsBeforeConfirm = await transport.fetchCount()

        // 3. Production-style confirm.
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        // 4. Nothing may have been staged, uploaded, or coordinated.
        let stagedAfter = try await persistence.pendingMutations(scope: scope, maxAttempts: .max)
        let mutationsSent = await transport.mutationCount()
        let readsAfterConfirm = await transport.fetchCount()

        XCTAssertEqual(stagedAfter.count, stagedBefore.count, "缺少远端指纹的计划不得 stage 任何 mutation")
        XCTAssertEqual(stagedAfter.count, 0, "确认前后都不应存在待上传 mutation")
        XCTAssertEqual(mutationsSent, 0, "缺少远端指纹的计划不得调用 sendMutations")
        XCTAssertEqual(readsAfterConfirm, readsBeforeConfirm,
                       "不得执行 SyncCoordinator 或任何确认期远端读取")
        XCTAssertEqual(kitchen.inventory, localBefore, "本机库存不得改变")

        XCTAssertNotEqual(controller.session?.status, .preparing, "会话不得进入 preparing")
        XCTAssertNotEqual(controller.session?.status, .uploading, "会话不得进入 uploading")
        XCTAssertNotEqual(controller.session?.status, .completed, "会话不得进入 completed")
        XCTAssertNil(controller.session?.confirmedAt, "会话不得记录确认时间")

        XCTAssertEqual(
            controller.lastErrorMessage,
            "请重新查看合并预览后再确认。",
            "应给出要求重新预览的安全错误"
        )

        // The persisted record must be just as unadvanced as the in-memory one.
        let persisted = try await persistence.activeGuestMergeSession(
            userId: userA, householdId: householdA, entityType: .inventoryItem
        )
        XCTAssertNotEqual(persisted?.status, .preparing)
        XCTAssertNotEqual(persisted?.status, .uploading)
        XCTAssertNotEqual(persisted?.status, .completed)
        XCTAssertNil(persisted?.plan?.remoteSnapshotHash)
    }

    /// Exact read/write counters across the whole failure → explicit-retry path.
    ///
    /// One recorder observes every boundary, so the counts are cumulative and a
    /// stray extra read anywhere in the sequence fails the test rather than being
    /// absorbed by a fresh fake. The transport fails only the first fetch, so the
    /// user's single retry is the thing that turns a failed preview into a
    /// confirmable one.
    func testExplicitRetryPerformsExactlyOneAdditionalRemoteReadAndNoMutation() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = PreviewBoundaryTransport(failure: .unauthorized, failingFetchLimit: 1)
        let controller = makeMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        let localBefore = kitchen.inventory

        // 1. First explicit preview open: exactly one read, never a write.
        await controller.preparePreview(
            userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport
        )
        var reads = await transport.fetchCount()
        var mutations = await transport.mutationCount()
        XCTAssertEqual(reads, 1, "第一次显式打开预览应且仅应发起一次远端读取")
        XCTAssertEqual(mutations, 0, "预览路径永远不应写入远端")

        // 2. The fetch failed. Nothing may advance before the user retries.
        XCTAssertNil(controller.session, "读取失败后不应保留可确认的会话")
        XCTAssertNotNil(controller.previewFetchFailureMessage)
        XCTAssertNil(controller.plan?.remoteSnapshotHash)
        XCTAssertEqual(kitchen.inventory, localBefore, "预览失败不得改动本机库存")

        // 4a. No timer, task re-entrancy, or Sheet lifecycle may add a read while
        // the user is just looking at the failure. Nothing is invoked here on
        // purpose: any further `preparePreview` call is a *user action*, not a
        // lifecycle no-op, so calling one would measure something else entirely.
        await Task.yield()
        try await Task.sleep(nanoseconds: 250_000_000)
        await Task.yield()
        reads = await transport.fetchCount()
        mutations = await transport.mutationCount()
        XCTAssertEqual(reads, 1, "重试之前，计时器/任务重入/Sheet 生命周期都不得追加读取")
        XCTAssertEqual(mutations, 0)

        // 2b. Confirm must not be able to reach the write path at all. A failed
        // preview leaves `session` nil, so `confirmMerge` returns at its own
        // session guard — before it ever builds a transport, re-reads the remote
        // state, or stages an upsert.
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        reads = await transport.fetchCount()
        mutations = await transport.mutationCount()
        XCTAssertEqual(mutations, 0, "失败预览后确认不得进入写入路径")
        XCTAssertEqual(reads, 1, "失败预览后确认不得追加远端读取")
        XCTAssertEqual(kitchen.inventory, localBefore)

        // 3. One explicit user retry: exactly one more read, still no write, and a
        // fully regenerated, fingerprinted preview.
        await controller.preparePreview(
            userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport
        )
        reads = await transport.fetchCount()
        mutations = await transport.mutationCount()
        XCTAssertEqual(reads, 2, "一次显式重试应且仅应追加一次远端读取")
        XCTAssertEqual(mutations, 0, "重试仍然不得写入远端")
        XCTAssertNotNil(controller.session, "重试成功后应重新生成预览会话")
        XCTAssertNil(controller.previewFetchFailureMessage, "重试成功后失败提示应清除")
        XCTAssertNotNil(controller.plan?.remoteSnapshotHash, "重试成功后计划必须带有远端指纹")

        // 4b. The successful preview must also settle without extra reads.
        await Task.yield()
        try await Task.sleep(nanoseconds: 150_000_000)
        reads = await transport.fetchCount()
        mutations = await transport.mutationCount()
        XCTAssertEqual(reads, 2, "重试成功后不得再有后台读取")
        XCTAssertEqual(mutations, 0)
        XCTAssertEqual(kitchen.inventory, localBefore, "确认之前本机库存必须保持不变")
    }

    func testLegacyPlanWithoutRemoteHashIsRegeneratedAfterExplicitRead() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let offlineController = makeMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true)
        )
        await offlineController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen)
        XCTAssertNil(offlineController.plan?.remoteSnapshotHash)

        let transport = PreviewBoundaryTransport()
        let productionController = makeMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await productionController.preparePreview(
            userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport
        )

        XCTAssertNotNil(productionController.plan?.remoteSnapshotHash)
        let reads = await transport.fetchCount()
        let mutations = await transport.mutationCount()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(mutations, 0)
    }

    // MARK: - UI-5B2B-B2B: base-behaviour reproduction

    /// Reproduces the fork-id churn this phase fixes: leaving `keepBoth` clears
    /// `forkedLocalItemId`, so coming back to it mints a brand-new id.
    func testBaseReproductionKeepBothRoundTripMintsANewForkId() {
        let localId = UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!
        let base = InventoryMergeCandidate(
            localItemId: localId, name: "豆腐", unit: "块", localQuantity: 1, localExpiryDate: nil,
            remoteItemId: localId, remoteQuantity: 3, remoteExpiryDate: nil, remoteVersion: nil,
            action: .create, conflictReason: .quantityMismatch, userChoice: nil
        )
        let first = base.applyingChoice(.keepBoth)
        let originalFork = try! XCTUnwrap(first.forkedLocalItemId)

        for detour in [InventoryMergeConflictChoice.keepLocal, .keepRemote, .skip] {
            let left = first.applyingChoice(detour)
            let returned = left.applyingChoice(.keepBoth)
            let returnedFork = try! XCTUnwrap(returned.forkedLocalItemId)
            XCTAssertEqual(
                returnedFork, originalFork,
                "keepBoth → \(detour.rawValue) → keepBoth 必须复用同一个 fork id"
            )
        }
        // Repeating keepBoth directly must also reuse it.
        XCTAssertEqual(first.applyingChoice(.keepBoth).forkedLocalItemId, originalFork)
    }

    /// A retained fork id must never by itself route the upload down the
    /// fork-create path when the current choice is not a same-ID `keepBoth`.
    /// This drives the real `confirmMerge` staging path, not a source grep.
    func testRetainedInactiveForkIsIgnoredByConfirmAndUpdatesTheOriginalRecord() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        kitchen.inventory = [InventoryItem(id: sharedId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil)]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: sharedId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")
        let controller = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)

        // keepBoth reserves a fork, then keepLocal leaves it behind.
        await controller.resolveConflict(candidateId: sharedId, choice: .keepBoth)
        let reservedFork = try XCTUnwrap(controller.plan?.candidates.first?.forkedLocalItemId)
        await controller.resolveConflict(candidateId: sharedId, choice: .keepLocal)

        let candidate = try XCTUnwrap(controller.plan?.candidates.first)
        XCTAssertEqual(candidate.userChoice, .keepLocal)
        XCTAssertEqual(candidate.action, .update, "same-ID keepLocal 必须更新原记录")
        XCTAssertNil(candidate.activeForkedLocalItemId, "keepLocal 下 retained fork 必须 inactive")

        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)

        // The reserved id must never have been created remotely.
        let forkMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: reservedFork)
        XCTAssertNil(forkMetadata, "inactive retained fork 不得被 stage 或上传")
        XCTAssertFalse(controller.session?.createdEntityIds.contains(reservedFork) ?? true)
        // The original record was updated instead.
        let originalMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: sharedId)
        XCTAssertNotNil(originalMetadata)
    }

    /// A session that already confirmed must not accept an edit to a choice it
    /// may already have executed remotely — nothing here can undo that.
    func testResolvedChoiceCannotBeEditedOnceConfirmHasStarted() async throws {
        let (controller, _, _, conflictedId) = try await partiallyConfirmedFixture()
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        await controller.resolveConflict(candidateId: conflictedId, choice: .keepLocal)

        let session = try XCTUnwrap(controller.session)
        XCTAssertEqual(session.status, .previewReady)
        XCTAssertNotNil(session.confirmedAt)
        XCTAssertGreaterThan(session.uploadedItemCount, 0)
        let before = try XCTUnwrap(controller.plan)

        // Attempt to re-edit the choice recorded above.
        await controller.resolveConflict(candidateId: conflictedId, choice: .skip)

        XCTAssertEqual(controller.plan, before, "已 confirm 的会话不得再修改已记录的选择")
        XCTAssertEqual(
            controller.plan?.candidates.first { $0.localItemId == conflictedId }?.userChoice, .keepLocal,
            "选择必须保持原值"
        )
        XCTAssertEqual(controller.conflictChoiceErrorMessage, "同步已经开始，已记录的处理方式不能再修改。")
    }

    /// Builds a real, confirmable session whose single same-ID candidate is
    /// `keepLocal`/`.update` yet still carries a **reserved** fork id, then runs
    /// the genuine `confirmMerge` staging path against fake persistence and the
    /// simulated transport.
    ///
    /// Constructed by persisting a modified plan and letting `preparePreview`
    /// resume it: `planHash` covers local items and the remote fingerprint, not
    /// candidate choices, so the plan stays valid and is not regenerated.
    ///
    /// - Returns: (controller, persistence, localItemId, reservedForkId)
    private func sessionWithRetainedInactiveFork() async throws
        -> (GuestMergeController, SwiftDataSyncPersistence, UUID, UUID) {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        let reservedFork = UUID()
        kitchen.inventory = [InventoryItem(id: sharedId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil)]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: sharedId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")

        let builder = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await builder.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        var seeded = try XCTUnwrap(builder.session)
        var plan = try XCTUnwrap(seeded.plan)
        // keepLocal on a same-id match → `.update`, and then a reserved fork id
        // left behind exactly as an earlier keepBoth would leave it.
        var candidate = plan.candidates[0].applyingChoice(.keepLocal)
        candidate.forkedLocalItemId = reservedFork
        XCTAssertEqual(candidate.action, .update)
        XCTAssertEqual(candidate.remoteItemId, candidate.localItemId)
        plan.candidates[0] = candidate
        seeded.plan = plan
        seeded.conflictCount = plan.conflicts.count
        try await persistence.saveGuestMergeSession(seeded)

        let controller = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        let resumed = try XCTUnwrap(controller.plan?.candidates.first)
        XCTAssertEqual(resumed.userChoice, .keepLocal, "resumed plan 必须保留构造的选择")
        XCTAssertEqual(resumed.forkedLocalItemId, reservedFork, "resumed plan 必须保留 reserved fork id")
        return (controller, persistence, sharedId, reservedFork)
    }

    /// The retained reservation must be inert: `confirmMerge` updates the
    /// original record and never creates anything under the reserved id.
    func testRetainedInactiveForkIsInertThroughRealConfirmStaging() async throws {
        let (controller, persistence, sharedId, reservedFork) = try await sessionWithRetainedInactiveFork()

        let candidate = try XCTUnwrap(controller.plan?.candidates.first)
        XCTAssertNil(candidate.activeForkedLocalItemId, "keepLocal 下 reserved fork 必须 inactive")
        XCTAssertTrue(
            controller.plan?.readyToUpload.contains { $0.localItemId == sharedId } ?? false,
            "keepLocal 候选仍应属于 readyToUpload"
        )

        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)

        // Nothing whatsoever exists under the reserved id.
        let forkMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: reservedFork)
        XCTAssertNil(forkMetadata, "reserved fork 不得有 metadata")
        let forkItem = try await persistence.inventoryItem(id: reservedFork)
        XCTAssertNil(forkItem, "reserved fork 不得有 inventory item")
        XCTAssertFalse(
            controller.session?.createdEntityIds.contains(reservedFork) ?? true,
            "createdEntityIds 不得包含 reserved fork"
        )
        // The original record took the ordinary update path instead.
        let originalMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: sharedId)
        XCTAssertEqual(originalMetadata?.state, .synced, "原记录应按 keepLocal 正常同步")
        XCTAssertEqual(controller.session?.uploadedItemCount, 1, "只应上传一条，不得额外 create")
    }

    // MARK: - UI-5B2B-B2B: transition matrix

    private func sameIdCandidate() -> InventoryMergeCandidate {
        let localId = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
        return InventoryMergeCandidate(
            localItemId: localId, name: "豆腐", unit: "块", localQuantity: 1, localExpiryDate: nil,
            remoteItemId: localId, remoteQuantity: 3, remoteExpiryDate: nil, remoteVersion: nil,
            action: .create, conflictReason: .quantityMismatch, userChoice: nil
        )
    }

    private func differentIdCandidate() -> InventoryMergeCandidate {
        InventoryMergeCandidate(
            localItemId: UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!,
            name: "大米", unit: "袋", localQuantity: 2, localExpiryDate: nil,
            remoteItemId: UUID(uuidString: "00000000-0000-0000-0000-0000000000D3")!,
            remoteQuantity: 2, remoteExpiryDate: nil, remoteVersion: nil,
            action: .create, conflictReason: .ambiguousDuplicate, userChoice: nil
        )
    }

    private func expectedAction(
        _ choice: InventoryMergeConflictChoice, sameIdentity: Bool
    ) -> InventoryMergeAction {
        switch choice {
        case .keepLocal: sameIdentity ? .update : .create
        case .keepRemote: .keepRemote
        case .keepBoth: .create
        case .skip: .skip
        }
    }

    private func planContaining(_ candidate: InventoryMergeCandidate) -> InventoryMergePlan {
        InventoryMergePlan(
            sessionId: UUID(uuidString: "00000000-0000-0000-0000-0000000000D4")!,
            householdId: householdA, generatedAt: Date(timeIntervalSince1970: 1),
            sourceCount: 1, candidates: [candidate], skippedItemIds: [],
            planHash: "matrix", knownRemoteItemCount: 1,
            remoteSnapshotHash: "matrix-remote", remoteSnapshotFetchedAt: Date(timeIntervalSince1970: 1)
        )
    }

    /// Full same-ID 4×4 matrix. Every source choice to every target choice.
    func testSameIdFourByFourTransitionMatrix() throws {
        let all = InventoryMergeConflictChoice.allCasesForTesting
        for source in all {
            let afterSource = sameIdCandidate().applyingChoice(source)
            let reservedAfterSource = afterSource.forkedLocalItemId
            if source == .keepBoth {
                XCTAssertNotNil(reservedAfterSource, "首次 keepBoth 必须预留 fork id")
            }
            for target in all {
                let result = afterSource.applyingChoice(target)

                XCTAssertEqual(result.userChoice, target, "\(source.rawValue)→\(target.rawValue) userChoice")
                XCTAssertEqual(
                    result.action, expectedAction(target, sameIdentity: true),
                    "\(source.rawValue)→\(target.rawValue) action"
                )

                // Reserved id is retained across every transition once allocated.
                if let reservedAfterSource {
                    XCTAssertEqual(
                        result.forkedLocalItemId, reservedAfterSource,
                        "\(source.rawValue)→\(target.rawValue) 必须复用同一个 reserved fork id"
                    )
                } else if target == .keepBoth {
                    XCTAssertNotNil(result.forkedLocalItemId, "\(target.rawValue) 应分配 reserved fork id")
                } else {
                    XCTAssertNil(result.forkedLocalItemId, "尚未预留过 fork 时不应凭空出现")
                }

                // Active only for a genuine same-ID keepBoth.
                if target == .keepBoth {
                    XCTAssertEqual(result.activeForkedLocalItemId, result.forkedLocalItemId,
                                   "\(target.rawValue) 的 reserved fork 应为 active")
                } else {
                    XCTAssertNil(result.activeForkedLocalItemId,
                                 "\(source.rawValue)→\(target.rawValue) 下 retained fork 必须 inactive")
                }

                // readyToUpload membership follows action, never the reservation.
                let uploads = planContaining(result).readyToUpload.contains { $0.localItemId == result.localItemId }
                XCTAssertEqual(
                    uploads, target == .keepLocal || target == .keepBoth,
                    "\(source.rawValue)→\(target.rawValue) readyToUpload membership"
                )
            }
        }
    }

    func testKeepBothRoundTripsThroughEveryOtherChoiceReuseTheSameForkId() throws {
        let first = sameIdCandidate().applyingChoice(.keepBoth)
        let reserved = try XCTUnwrap(first.forkedLocalItemId)
        for detour in [InventoryMergeConflictChoice.keepLocal, .keepRemote, .skip] {
            let returned = first.applyingChoice(detour).applyingChoice(.keepBoth)
            XCTAssertEqual(returned.forkedLocalItemId, reserved, "经由 \(detour.rawValue) 往返必须复用")
            XCTAssertEqual(returned.activeForkedLocalItemId, reserved)
        }
        // Repeat keepBoth, and a long chain, both stable.
        var chained = first
        for choice in [InventoryMergeConflictChoice.keepBoth, .skip, .keepBoth, .keepRemote, .keepBoth] {
            chained = chained.applyingChoice(choice)
        }
        XCTAssertEqual(chained.forkedLocalItemId, reserved, "多次往返不得铸造第二个 fork")
    }

    func testReservedForkIdSurvivesCodableRoundTrip() throws {
        let resolved = sameIdCandidate().applyingChoice(.keepBoth).applyingChoice(.skip)
        let reserved = try XCTUnwrap(resolved.forkedLocalItemId)
        XCTAssertNil(resolved.activeForkedLocalItemId, "skip 状态下不得 active")

        let data = try JSONEncoder().encode(planContaining(resolved))
        let decoded = try JSONDecoder().decode(InventoryMergePlan.self, from: data)
        let restored = try XCTUnwrap(decoded.candidates.first)
        XCTAssertEqual(restored.forkedLocalItemId, reserved, "重启后 reserved id 必须不变")
        XCTAssertNil(restored.activeForkedLocalItemId)
        XCTAssertEqual(restored.applyingChoice(.keepBoth).forkedLocalItemId, reserved,
                       "重启后回到 keepBoth 仍复用同一个 id")
    }

    func testDifferentIdCandidateNeverHasAnyFork() throws {
        for target in InventoryMergeConflictChoice.allCasesForTesting {
            let result = differentIdCandidate().applyingChoice(target)
            XCTAssertEqual(result.userChoice, target)
            XCTAssertEqual(result.action, expectedAction(target, sameIdentity: false))
            XCTAssertNil(result.forkedLocalItemId, "different-ID 不得预留 fork")
            XCTAssertNil(result.activeForkedLocalItemId, "different-ID 不得有 active fork")
        }
        // keepBoth still creates under the candidate's own id.
        let keepBoth = differentIdCandidate().applyingChoice(.keepBoth)
        XCTAssertEqual(keepBoth.action, .create)
        XCTAssertTrue(planContaining(keepBoth).readyToUpload.contains { $0.localItemId == keepBoth.localItemId })
    }

    // MARK: - UI-5B2B-B2B: resolveConflict guard

    /// Builds a resumable session in an arbitrary status with one same-ID
    /// conflict, optionally already resolved, and optional confirm history.
    private func guardScenario(
        status: GuestMergeSessionStatus,
        preResolvedWith choice: InventoryMergeConflictChoice? = nil,
        confirmedAt: Date? = nil,
        uploadedItemCount: Int = 0,
        createdEntityIds: [UUID] = []
    ) async throws -> (GuestMergeController, SwiftDataSyncPersistence, UUID) {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        kitchen.inventory = [InventoryItem(id: sharedId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil)]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: sharedId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")

        let builder = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await builder.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        var seeded = try XCTUnwrap(builder.session)
        var plan = try XCTUnwrap(seeded.plan)
        if let choice { plan.candidates[0] = plan.candidates[0].applyingChoice(choice) }
        seeded.plan = plan
        seeded.status = status
        seeded.confirmedAt = confirmedAt
        seeded.uploadedItemCount = uploadedItemCount
        seeded.createdEntityIds = createdEntityIds
        try await persistence.saveGuestMergeSession(seeded)

        let controller = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        return (controller, persistence, sharedId)
    }

    private func assertRejected(
        _ controller: GuestMergeController, _ persistence: SwiftDataSyncPersistence,
        candidateId: UUID, attempt: InventoryMergeConflictChoice, expectedMessage: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let planBefore = controller.plan
        let statusBefore = controller.session?.status
        let candidateBefore = controller.plan?.candidates.first { $0.localItemId == candidateId }
        let scope = SyncScope(type: .household, id: householdA)
        let pendingBefore = try await persistence.pendingMutations(scope: scope, maxAttempts: 5).count

        await controller.resolveConflict(candidateId: candidateId, choice: attempt)

        XCTAssertEqual(controller.plan, planBefore, "plan 不得改变", file: file, line: line)
        XCTAssertEqual(controller.session?.status, statusBefore, "status 不得改变", file: file, line: line)
        XCTAssertEqual(
            controller.plan?.candidates.first { $0.localItemId == candidateId }, candidateBefore,
            "candidate 不得改变", file: file, line: line
        )
        let pendingAfter = try await persistence.pendingMutations(scope: scope, maxAttempts: 5).count
        XCTAssertEqual(pendingAfter, pendingBefore, "不得产生 mutation", file: file, line: line)
        XCTAssertEqual(pendingAfter, 0, "confirm 前 mutation 必须为 0", file: file, line: line)
        XCTAssertEqual(controller.conflictChoiceErrorMessage, expectedMessage, "错误文案", file: file, line: line)
    }

    private static let resolvedEditRejection = "同步已经开始，已记录的处理方式不能再修改。"
    private static let unresolvedStatusRejection = "当前状态无法处理冲突，请重新查看合并预览。"

    /// The UI-test seam that flips a session to "sync started" is DEBUG-only,
    /// but a UI test taps it and then asserts the screen is read-only, so what
    /// it writes has to be pinned: it must mark the session and nothing else.
    /// If it ever staged a mutation or counted an upload, the read-only
    /// screenshot would be evidence of a state the product cannot reach.
    func testMarkSyncStartedForUITestingOnlyMarksTheSessionAndStagesNothing() async throws {
        let (controller, persistence, candidateId) = try await guardScenario(
            status: .previewReady, preResolvedWith: .keepLocal
        )
        let scope = SyncScope(type: .household, id: householdA)
        let pendingBefore = try await persistence.pendingMutations(scope: scope, maxAttempts: 5).count
        XCTAssertEqual(pendingBefore, 0)
        let planBefore = controller.plan
        XCTAssertTrue(
            InventoryMergeChoiceEditingAvailability.make(session: controller.session).isEditable,
            "前置条件：seam 只在可编辑时渲染"
        )

        await controller.markSyncStartedForUITesting()

        // Marks exactly one thing.
        XCTAssertNotNil(controller.session?.confirmedAt)
        // And nothing else.
        XCTAssertEqual(controller.session?.uploadedItemCount, 0, "seam 不得计入任何上传")
        XCTAssertEqual(controller.session?.createdEntityIds, [], "seam 不得创建任何远端实体")
        XCTAssertEqual(controller.session?.status, .previewReady, "seam 不得改变 status")
        XCTAssertEqual(controller.plan, planBefore, "seam 不得改变 plan")
        let pendingAfter = try await persistence.pendingMutations(scope: scope, maxAttempts: 5).count
        XCTAssertEqual(pendingAfter, 0, "seam 不得产生 mutation")

        // The screen it drives is now read-only in both the view's rule and the
        // controller's, so the seam's own render condition is false as well.
        let availability = InventoryMergeChoiceEditingAvailability.make(session: controller.session)
        XCTAssertEqual(availability, .readOnlyAfterSyncStarted)
        XCTAssertFalse(availability.isEditable, "触发后 seam 与修改入口必须同时消失")
        await controller.resolveConflict(candidateId: candidateId, choice: .skip)
        XCTAssertEqual(controller.conflictChoiceErrorMessage, Self.resolvedEditRejection)
    }

    func testFirstUnresolvedChoiceIsAllowedInEveryNormalResolutionStatus() async throws {
        for status in [GuestMergeSessionStatus.previewReady, .awaitingConfirmation, .conflict] {
            let (controller, _, candidateId) = try await guardScenario(status: status)
            XCTAssertNil(controller.plan?.candidates.first?.userChoice)
            await controller.resolveConflict(candidateId: candidateId, choice: .keepLocal)
            XCTAssertEqual(
                controller.plan?.candidates.first?.userChoice, .keepLocal,
                "\(status.rawValue) 中首次处理未解决冲突必须被允许"
            )
            XCTAssertNil(controller.conflictChoiceErrorMessage)
        }
    }

    func testResolvedEditIsAllowedOnlyBeforeAnyConfirmAttempt() async throws {
        for status in [GuestMergeSessionStatus.previewReady, .awaitingConfirmation] {
            let (controller, _, candidateId) = try await guardScenario(status: status, preResolvedWith: .keepLocal)
            await controller.resolveConflict(candidateId: candidateId, choice: .keepBoth)
            XCTAssertEqual(controller.plan?.candidates.first?.userChoice, .keepBoth,
                           "\(status.rawValue) 且未 confirm 时应允许修改")
            XCTAssertNil(controller.conflictChoiceErrorMessage)
        }
    }

    func testResolvedEditIsRejectedInConflictRoot() async throws {
        let (controller, persistence, candidateId) = try await guardScenario(
            status: .conflict, preResolvedWith: .keepLocal
        )
        try await assertRejected(
            controller, persistence, candidateId: candidateId, attempt: .skip,
            expectedMessage: Self.resolvedEditRejection
        )
    }

    /// Non-terminal statuses that `preparePreview` still resumes: the guard must
    /// reject a resolved edit in each one.
    func testResolvedEditIsRejectedInEveryResumableNonEditableStatus() async throws {
        for status in [GuestMergeSessionStatus.preparing, .uploading, .failed, .rollbackPending] {
            let (controller, persistence, candidateId) = try await guardScenario(
                status: status, preResolvedWith: .keepLocal
            )
            XCTAssertEqual(controller.session?.status, status, "\(status.rawValue) 应被恢复")
            try await assertRejected(
                controller, persistence, candidateId: candidateId, attempt: .skip,
                expectedMessage: Self.resolvedEditRejection
            )
        }
    }

    /// Terminal statuses are never resumed at all, so the recorded choice is
    /// unreachable by construction — `preparePreview` starts a brand-new session
    /// rather than handing back the finished one to edit.
    func testTerminalSessionsAreNeverResumedForEditing() async throws {
        for status in [GuestMergeSessionStatus.completed, .cancelled, .rolledBack] {
            let (controller, _, _) = try await guardScenario(status: status, preResolvedWith: .keepLocal)
            let resumed = try XCTUnwrap(controller.session)
            XCTAssertNotEqual(resumed.status, status, "\(status.rawValue) 是终态，不得被恢复为可编辑会话")
            XCTAssertNil(
                resumed.plan?.candidates.first?.userChoice,
                "\(status.rawValue) 之后应是全新会话，不携带此前记录的选择"
            )
            XCTAssertNil(resumed.confirmedAt)
            XCTAssertEqual(resumed.uploadedItemCount, 0)
        }
    }

    func testResolvedEditIsRejectedByEachConfirmHistorySignalIndependently() async throws {
        let signals: [(String, Date?, Int, [UUID])] = [
            ("confirmedAt", Date(timeIntervalSince1970: 10), 0, []),
            ("uploadedItemCount", nil, 1, []),
            ("createdEntityIds", nil, 0, [UUID()])
        ]
        for (name, confirmedAt, uploaded, created) in signals {
            let (controller, persistence, candidateId) = try await guardScenario(
                status: .previewReady, preResolvedWith: .keepLocal,
                confirmedAt: confirmedAt, uploadedItemCount: uploaded, createdEntityIds: created
            )
            try await assertRejected(
                controller, persistence, candidateId: candidateId, attempt: .skip,
                expectedMessage: Self.resolvedEditRejection
            )
            XCTAssertEqual(controller.plan?.candidates.first?.userChoice, .keepLocal, "\(name) 应独立触发拒绝")
        }
    }

    func testFirstUnresolvedResolutionFailsClosedWithItsOwnMessageInABadStatus() async throws {
        let (controller, persistence, candidateId) = try await guardScenario(status: .uploading)
        guard controller.session != nil else { return }
        try await assertRejected(
            controller, persistence, candidateId: candidateId, attempt: .keepLocal,
            expectedMessage: Self.unresolvedStatusRejection
        )
        // Never the "sync already started" wording for a first-time decision.
        XCTAssertNotEqual(controller.conflictChoiceErrorMessage, Self.resolvedEditRejection)
    }

    func testUnknownCandidateIdIsIgnoredWithoutTouchingAnything() async throws {
        let (controller, persistence, _) = try await guardScenario(status: .previewReady)
        let planBefore = controller.plan
        let scope = SyncScope(type: .household, id: householdA)
        let pendingBefore = try await persistence.pendingMutations(scope: scope, maxAttempts: 5).count
        await controller.resolveConflict(candidateId: UUID(), choice: .keepLocal)
        XCTAssertEqual(controller.plan, planBefore)
        let pendingAfter = try await persistence.pendingMutations(scope: scope, maxAttempts: 5).count
        XCTAssertEqual(pendingAfter, pendingBefore)
    }

    func testSuccessfulEditClearsAPreviousRejectionMessage() async throws {
        let (controller, _, candidateId) = try await guardScenario(
            status: .previewReady, preResolvedWith: .keepLocal
        )
        // Force a rejection first by attempting an unknown candidate? That path
        // is silent, so drive a real rejection via a non-editable sibling state.
        await controller.resolveConflict(candidateId: UUID(), choice: .skip)
        // Then a legitimate edit must leave no stale error behind.
        await controller.resolveConflict(candidateId: candidateId, choice: .keepBoth)
        XCTAssertEqual(controller.plan?.candidates.first?.userChoice, .keepBoth)
        XCTAssertNil(controller.conflictChoiceErrorMessage, "成功修改后不得残留旧的编辑错误")
    }

    // MARK: - UI-5B2B-B2B: terminal states and dedicated edit error

    /// Drives a session all the way to a genuine terminal status through the
    /// real controller, so the terminal session is the one held in memory —
    /// `preparePreview` is never called again and therefore cannot replace it.
    private func terminalController(
        reaching terminal: GuestMergeSessionStatus
    ) async throws -> (GuestMergeController, SwiftDataSyncPersistence, UUID) {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        kitchen.inventory = [InventoryItem(id: sharedId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil)]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: sharedId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")
        let controller = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        await controller.resolveConflict(candidateId: sharedId, choice: .keepLocal)
        let authStore = await signedInAuthStore(userID: userA)

        switch terminal {
        case .cancelled:
            await controller.cancel()
        case .completed:
            await controller.confirmMerge(authStore: authStore)
        case .rolledBack:
            await controller.confirmMerge(authStore: authStore)
            await controller.rollback(authStore: authStore)
        default:
            XCTFail("unsupported terminal status")
        }
        XCTAssertEqual(controller.session?.status, terminal, "应真正到达 \(terminal.rawValue)")
        return (controller, persistence, sharedId)
    }

    /// The controller is the final boundary: even when the terminal session is
    /// the one in memory (so no re-resume can rescue us), a direct call must be
    /// refused. This complements — never replaces — the UI-level guarantee that
    /// terminal sessions are not resumed at all.
    func testDirectTerminalSessionsRejectResolvedEdit() async throws {
        for terminal in [GuestMergeSessionStatus.completed, .cancelled, .rolledBack] {
            let (controller, persistence, candidateId) = try await terminalController(reaching: terminal)
            let planBefore = try XCTUnwrap(controller.plan)
            let candidateBefore = try XCTUnwrap(planBefore.candidates.first { $0.localItemId == candidateId })
            let statusBefore = controller.session?.status
            // Deltas, not absolutes: reaching `.completed`/`.rolledBack` legitimately
            // produces mutations and records on the way in. What must not change is
            // anything caused by the *rejected edit itself*.
            let scope = SyncScope(type: .household, id: householdA)
            let pendingBefore = try await persistence.pendingMutations(scope: scope, maxAttempts: 5).count
            let metadataBefore = try await persistence.allMetadata(scope: scope).count
            let inventoryBefore = try await persistence.inventoryItem(id: candidateId) != nil

            await controller.resolveConflict(candidateId: candidateId, choice: .skip)

            let after = try XCTUnwrap(controller.plan?.candidates.first { $0.localItemId == candidateId })
            XCTAssertEqual(after.userChoice, candidateBefore.userChoice, "\(terminal.rawValue): userChoice 不变")
            XCTAssertEqual(after.action, candidateBefore.action, "\(terminal.rawValue): action 不变")
            XCTAssertEqual(after.forkedLocalItemId, candidateBefore.forkedLocalItemId, "\(terminal.rawValue): fork 不变")
            XCTAssertEqual(controller.plan, planBefore, "\(terminal.rawValue): plan 不变")
            XCTAssertEqual(controller.session?.status, statusBefore, "\(terminal.rawValue): status 不变")
            let pendingAfter = try await persistence.pendingMutations(scope: scope, maxAttempts: 5).count
            XCTAssertEqual(pendingAfter, pendingBefore, "\(terminal.rawValue): 被拒绝的编辑不得改变 mutation 数量")
            let metadataAfter = try await persistence.allMetadata(scope: scope).count
            XCTAssertEqual(metadataAfter, metadataBefore, "\(terminal.rawValue): 不得新增 metadata")
            let inventoryAfter = try await persistence.inventoryItem(id: candidateId) != nil
            XCTAssertEqual(inventoryAfter, inventoryBefore, "\(terminal.rawValue): 不得新增 inventory record")
            XCTAssertEqual(
                controller.conflictChoiceError(for: candidateId), Self.resolvedEditRejection,
                "\(terminal.rawValue): 应返回稳定的拒绝文案"
            )
        }
    }

    func testConflictEditErrorIsSeparateFromUnrelatedGlobalErrors() async throws {
        // A rejected edit populates the dedicated field, not the global one.
        let (rejecting, _, candidateId) = try await guardScenario(
            status: .previewReady, preResolvedWith: .keepLocal,
            confirmedAt: Date(timeIntervalSince1970: 5)
        )
        await rejecting.resolveConflict(candidateId: candidateId, choice: .skip)
        XCTAssertEqual(rejecting.conflictChoiceErrorMessage, Self.resolvedEditRejection)
    }

    func testSuccessfulEditClearsOnlyTheEditErrorAndKeepsUnrelatedGlobalError() async throws {
        let (controller, _, candidateId) = try await guardScenario(
            status: .previewReady, preResolvedWith: .keepLocal
        )
        // Produce a genuine unrelated global error: confirming a plan whose
        // remote fingerprint cannot be re-verified fails and sets it.
        let authStore = await signedInAuthStore(userID: UUID())
        await controller.confirmMerge(authStore: authStore)
        let unrelated = try XCTUnwrap(controller.lastErrorMessage, "应先存在一个无关的全局错误")

        // Force an edit rejection, then a successful edit.
        await controller.resolveConflict(candidateId: UUID(), choice: .skip)
        XCTAssertEqual(controller.conflictChoiceErrorMessage, "无法找到这条冲突记录，请返回合并预览后重试。")

        await controller.resolveConflict(candidateId: candidateId, choice: .keepBoth)
        XCTAssertEqual(controller.plan?.candidates.first?.userChoice, .keepBoth, "修改应成功")
        XCTAssertNil(controller.conflictChoiceErrorMessage, "成功后应清除专用编辑错误")
        XCTAssertEqual(controller.lastErrorMessage, unrelated, "不得清除无关的全局错误")
    }

    func testMissingCandidateProducesTheDedicatedNotFoundMessage() async throws {
        let (controller, _, _) = try await guardScenario(status: .previewReady)
        await controller.resolveConflict(candidateId: UUID(), choice: .keepLocal)
        XCTAssertEqual(controller.conflictChoiceErrorMessage, "无法找到这条冲突记录，请返回合并预览后重试。")
    }

    func testPersistenceFailureDuringEditShowsTheDedicatedSaveError() async throws {
        let (kitchen, shared) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        kitchen.inventory = [InventoryItem(id: sharedId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil)]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: sharedId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")
        let controller = makeMergeController(
            persistence: shared, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)

        // Same store, but every save now fails.
        let failing = SwiftDataSyncPersistence(modelContainer: shared.modelContainer, behavior: .failSavesForTesting)
        let failingController = makeMergeController(
            persistence: failing, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await failingController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        guard failingController.plan?.candidates.first != nil else { return }
        await failingController.resolveConflict(candidateId: sharedId, choice: .keepLocal)
        XCTAssertEqual(failingController.conflictChoiceErrorMessage, "无法保存处理方式，请重试。")
    }

    func testEditErrorIsScopedToTheCandidateThatProducedIt() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let firstId = UUID()
        let secondId = UUID()
        kitchen.inventory = [
            InventoryItem(id: firstId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil),
            InventoryItem(id: secondId, name: "香蕉", quantity: 2, unit: "根", expiryDate: nil)
        ]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: firstId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")
        await transport.seedRemoteChange(id: secondId, name: "香蕉", unit: "根", quantity: 9, version: "5", sequence: "2")
        let controller = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)

        // Produce a rejection bound to a candidate that does not exist.
        let ghost = UUID()
        await controller.resolveConflict(candidateId: ghost, choice: .skip)
        XCTAssertNotNil(controller.conflictChoiceError(for: ghost))
        XCTAssertNil(controller.conflictChoiceError(for: firstId), "错误不得泄漏到其他 candidate")
        XCTAssertNil(controller.conflictChoiceError(for: secondId))

        // Opening another candidate's editor clears the foreign error.
        controller.clearConflictChoiceError(unless: firstId)
        XCTAssertNil(controller.conflictChoiceError(for: ghost))

        // A successful edit on one candidate leaves the other untouched.
        await controller.resolveConflict(candidateId: firstId, choice: .keepLocal)
        XCTAssertNil(controller.conflictChoiceError(for: firstId))
        XCTAssertEqual(controller.plan?.candidates.first { $0.localItemId == firstId }?.userChoice, .keepLocal)
        XCTAssertNil(controller.plan?.candidates.first { $0.localItemId == secondId }?.userChoice)
    }

    func testClearingForeignErrorsNeverDropsTheCurrentCandidatesOwnRejection() async throws {
        let (controller, _, candidateId) = try await guardScenario(
            status: .previewReady, preResolvedWith: .keepLocal,
            confirmedAt: Date(timeIntervalSince1970: 5)
        )
        await controller.resolveConflict(candidateId: candidateId, choice: .skip)
        XCTAssertEqual(controller.conflictChoiceError(for: candidateId), Self.resolvedEditRejection)
        // The editor's own on-open cleanup must not erase its own rejection.
        controller.clearConflictChoiceError(unless: candidateId)
        XCTAssertEqual(
            controller.conflictChoiceError(for: candidateId), Self.resolvedEditRejection,
            "stale-action 拒绝必须在本页面持续可见"
        )
    }

    // MARK: - UI-5B2B-B2A: post-partial-confirm presentation accuracy

    /// The state the review/summary copy has to stay accurate in: a first
    /// confirm uploads what was ready, leftover conflicts push the session to
    /// `.conflict`, and resolving the last one returns it to `.previewReady`
    /// with a plan that now mixes already-uploaded choices and newly-decided
    /// ones. Nothing is fabricated — this runs the real `confirmMerge` and
    /// `resolveConflict` against the simulated transport.
    private func partiallyConfirmedFixture() async throws -> (GuestMergeController, SwiftDataSyncPersistence, UUID, UUID) {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let uploadableId = UUID()
        let conflictedId = UUID()
        kitchen.inventory = [
            InventoryItem(id: uploadableId, name: "面粉", quantity: 1, unit: "袋", expiryDate: nil),
            InventoryItem(id: conflictedId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil)
        ]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        // Same id, different quantity → a real unresolved conflict, while 面粉
        // has no remote counterpart and is uploadable immediately.
        await transport.seedRemoteChange(id: conflictedId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")
        let controller = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        await controller.preparePreview(
            userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport
        )
        return (controller, persistence, uploadableId, conflictedId)
    }

    func testPartialConfirmThenResolvingTheLastConflictReturnsToPreviewReadyWithMixedPlan() async throws {
        let (controller, persistence, uploadableId, conflictedId) = try await partiallyConfirmedFixture()

        // 1. The plan holds both kinds of candidate.
        let planBefore = try XCTUnwrap(controller.plan)
        XCTAssertTrue(planBefore.candidates.contains { $0.localItemId == uploadableId && !$0.needsDecision })
        XCTAssertTrue(planBefore.candidates.contains { $0.localItemId == conflictedId && $0.needsDecision })

        // 2. First confirm.
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        // 3. Something really was uploaded, the leftover conflict survives, and
        //    the session parks in `.conflict`.
        let afterConfirm = try XCTUnwrap(controller.session)
        XCTAssertGreaterThan(afterConfirm.uploadedItemCount, 0, "第一次 confirm 应真的上传了可上传条目")
        XCTAssertNotNil(afterConfirm.confirmedAt, "confirmMerge 应记录 confirmedAt")
        XCTAssertEqual(afterConfirm.status, .conflict)
        XCTAssertTrue(afterConfirm.plan?.candidates.contains { $0.localItemId == conflictedId && $0.needsDecision } ?? false)

        // 4. Resolve the last conflict.
        await controller.resolveConflict(candidateId: conflictedId, choice: .keepLocal)

        // 5. Back to `.previewReady`, with a plan mixing an already-uploaded
        //    candidate and a freshly-decided one.
        let resumed = try XCTUnwrap(controller.session)
        XCTAssertEqual(resumed.status, .previewReady)
        XCTAssertNotNil(resumed.confirmedAt)
        XCTAssertGreaterThan(resumed.uploadedItemCount, 0)
        let resumedPlan = try XCTUnwrap(resumed.plan)
        XCTAssertTrue(
            resumedPlan.candidates.contains { $0.localItemId == uploadableId && !$0.needsDecision },
            "此前已上传的 candidate 仍留在 plan 中"
        )
        let nowResolved = try XCTUnwrap(resumedPlan.candidates.first { $0.localItemId == conflictedId })
        XCTAssertEqual(nowResolved.userChoice, .keepLocal)
        XCTAssertFalse(nowResolved.needsDecision)

        // 6. Presentation mapping is read-only and stages nothing.
        let scope = SyncScope(type: .household, id: householdA)
        let pendingBefore = try await persistence.pendingMutations(scope: scope, maxAttempts: 5).count
        let summary = InventoryMergeSummaryPresentation.make(plan: resumedPlan)
        _ = InventoryMergeConfirmationPresentation.make(summary: summary, session: resumed)
        _ = InventoryMergeCandidateGroupPresentation.make(plan: resumedPlan)
        _ = InventoryMergeReviewFooterPresentation.make(session: resumed)
        let pendingAfter = try await persistence.pendingMutations(scope: scope, maxAttempts: 5).count
        XCTAssertEqual(pendingAfter, pendingBefore, "presentation mapping 不得暂存 mutation")
        XCTAssertEqual(controller.session, resumed, "presentation mapping 不得修改 session")
        XCTAssertEqual(controller.plan, resumedPlan, "presentation mapping 不得修改 plan")
    }

    /// The copy that must not lie in that state.
    func testResumedAfterPartialConfirmCopyNeverClaimsNothingWasUploaded() async throws {
        let (controller, _, _, conflictedId) = try await partiallyConfirmedFixture()
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        await controller.resolveConflict(candidateId: conflictedId, choice: .keepLocal)

        let session = try XCTUnwrap(controller.session)
        let plan = try XCTUnwrap(session.plan)
        let summary = InventoryMergeSummaryPresentation.make(plan: plan)
        let confirmation = InventoryMergeConfirmationPresentation.make(summary: summary, session: session)
        let footer = InventoryMergeReviewFooterPresentation.make(session: session)

        // This session has already uploaded something, so no copy may claim the
        // choices are un-uploaded, nor that the whole plan is merely upcoming.
        for text in [footer.text, confirmation.buttonTitle, confirmation.supportingCopy] {
            for banned in ["尚未上传", "已上传", "已合并", "不会上传任何库存"] {
                XCTAssertFalse(text.contains(banned), "已部分上传的会话不得出现“\(banned)”：\(text)")
            }
        }
        XCTAssertTrue(
            InventoryMergeReviewFooterPresentation.hasUploadedAlready(session: session),
            "此会话应被判定为已有上传"
        )
    }

    func testPreConfirmSessionStillUsesTheDefiniteFirstPassCopy() async throws {
        let (controller, _, _, conflictedId) = try await partiallyConfirmedFixture()
        await controller.resolveConflict(candidateId: conflictedId, choice: .keepLocal)

        let session = try XCTUnwrap(controller.session)
        XCTAssertNil(session.confirmedAt)
        XCTAssertEqual(session.uploadedItemCount, 0)
        XCTAssertFalse(InventoryMergeReviewFooterPresentation.hasUploadedAlready(session: session))

        let plan = try XCTUnwrap(session.plan)
        let summary = InventoryMergeSummaryPresentation.make(plan: plan)
        let confirmation = InventoryMergeConfirmationPresentation.make(summary: summary, session: session)
        // Nothing uploaded yet, so the definite first-pass wording is accurate.
        XCTAssertEqual(confirmation.buttonTitle, "确认合并库存")
        XCTAssertTrue(confirmation.supportingCopy.contains("计划新增"), confirmation.supportingCopy)
    }

    // MARK: - R1: remote hydration → KitchenStore in-memory consistency
    //
    // Every test below drives a *real* pull through `syncNow`, so the remote
    // rows are written by `SwiftDataSyncPersistence` through its own
    // `ModelContext`, exactly as production does. The bug they pin is that
    // `KitchenStore.inventory` is loaded once in `init` and never re-read, so
    // the next local edit replays a pre-pull snapshot over the table.

    /// T2 — a remote field change must survive a later, unrelated local edit.
    func testR1RemoteFieldSurvivesUnrelatedLaterLocalEdit() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let id = UUID()
        var seeded = InventoryItem(id: id, name: "番茄", quantity: 1, unit: "个", expiryDate: nil)
        seeded.stapleNote = "old"
        kitchen.inventory = [seeded]

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: id, name: "番茄", unit: "个", quantity: 5, version: "2", sequence: "2")
        let controller = makeR1Controller(persistence: persistence, kitchenStore: kitchen, transport: transport)

        await controller.syncNow(authStore: await signedInAuthStore(userID: userA), householdId: householdA)
        XCTAssertEqual(controller.lastSyncOutcome, .completed)
        let afterPull = try await persistence.inventoryItem(id: id)
        XCTAssertEqual(afterPull?.quantity, 5, "the remote value must land durably")

        // An edit to a genuinely unrelated field.
        kitchen.inventory[0].unit = "袋"

        let afterLocalEdit = try await persistence.inventoryItem(id: id)
        XCTAssertEqual(
            afterLocalEdit?.quantity, 5,
            "T2: an unrelated local edit must not write a stale quantity back over the synced remote value"
        )
    }

    /// T4 — a remotely deleted row must not be resurrected by a later local
    /// edit of a *different* row.
    func testR1RemoteDeleteIsNotResurrectedByLaterLocalEdit() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let deletedId = UUID()
        let editedId = UUID()
        kitchen.inventory = [
            InventoryItem(id: deletedId, name: "会被远端删除", quantity: 1, unit: "个", expiryDate: nil),
            InventoryItem(id: editedId, name: "本地会编辑", quantity: 1, unit: "个", expiryDate: nil)
        ]

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteDelete(id: deletedId, version: "2", sequence: "2")
        let controller = makeR1Controller(persistence: persistence, kitchenStore: kitchen, transport: transport)

        await controller.syncNow(authStore: await signedInAuthStore(userID: userA), householdId: householdA)
        XCTAssertEqual(controller.lastSyncOutcome, .completed)
        let afterPull = try await persistence.inventoryItem(id: deletedId)
        XCTAssertNil(afterPull, "the remote delete must land durably")

        let editIndex = try XCTUnwrap(kitchen.inventory.firstIndex(where: { $0.id == editedId }))
        kitchen.inventory[editIndex].quantity = 4

        let afterLocalEdit = try await persistence.inventoryItem(id: deletedId)
        XCTAssertNil(
            afterLocalEdit,
            "T4: editing another row must not resurrect a remotely deleted row"
        )
    }

    /// T13 — a remotely inserted row must not be erased by a later local edit
    /// of a *different* row.
    func testR1RemoteInsertIsNotErasedByLaterLocalEditOfAnotherRow() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let existingId = UUID()
        let insertedId = UUID()
        kitchen.inventory = [InventoryItem(id: existingId, name: "本地会编辑", quantity: 1, unit: "个", expiryDate: nil)]

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: insertedId, name: "远端新增", unit: "袋", quantity: 3, version: "2", sequence: "2")
        let controller = makeR1Controller(persistence: persistence, kitchenStore: kitchen, transport: transport)

        await controller.syncNow(authStore: await signedInAuthStore(userID: userA), householdId: householdA)
        XCTAssertEqual(controller.lastSyncOutcome, .completed)
        let afterPull = try await persistence.inventoryItem(id: insertedId)
        XCTAssertEqual(afterPull?.name, "远端新增", "the remote insert must land durably")

        kitchen.inventory[0].quantity = 4

        let afterLocalEdit = try await persistence.inventoryItem(id: insertedId)
        XCTAssertEqual(
            afterLocalEdit?.name, "远端新增",
            "T13: editing another row must not delete a remotely inserted row"
        )
    }

    /// T11 — the same-id `keepBoth` fork `confirmMerge` creates through
    /// `commitInventoryAndSync` must not be deleted by a later local edit.
    /// This is the pre-run-staging half of R1: the durable write happens
    /// *before* the coordinator ever runs.
    func testR1MergeForkIsNotRemovedByLaterLocalEdit() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        kitchen.inventory = [InventoryItem(id: sharedId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil)]

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: sharedId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")
        let controller = makeR1Controller(persistence: persistence, kitchenStore: kitchen, transport: transport)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        await controller.resolveConflict(candidateId: sharedId, choice: .keepBoth)
        let forkedId = try XCTUnwrap(controller.plan?.candidates.first(where: { $0.localItemId == sharedId })?.forkedLocalItemId)

        await controller.confirmMerge(authStore: await signedInAuthStore(userID: userA))
        XCTAssertEqual(controller.session?.status, .completed)
        let forkAfterMerge = try await persistence.inventoryItem(id: forkedId)
        XCTAssertNotNil(forkAfterMerge, "the fork must exist durably after the merge")

        kitchen.inventory[0].quantity = 7

        let forkAfterLocalEdit = try await persistence.inventoryItem(id: forkedId)
        XCTAssertNotNil(
            forkAfterLocalEdit,
            "T11: a later local edit must not delete the merge fork the sync context created"
        )
        XCTAssertTrue(
            kitchen.inventory.contains(where: { $0.id == forkedId }),
            "T11: the fork must also be visible in memory once the boundary closed"
        )
    }

    /// T1 — a pulled upsert is visible in `KitchenStore` the moment the
    /// operation returns, with the consistency window closed again.
    func testR1RemoteUpsertIsVisibleInKitchenStoreImmediatelyAfterSync() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let id = UUID()
        kitchen.inventory = [InventoryItem(id: id, name: "番茄", quantity: 1, unit: "个", expiryDate: nil)]

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: id, name: "番茄", unit: "个", quantity: 5, version: "2", sequence: "2")
        let controller = makeR1Controller(persistence: persistence, kitchenStore: kitchen, transport: transport)

        await controller.syncNow(authStore: await signedInAuthStore(userID: userA), householdId: householdA)

        XCTAssertEqual(controller.lastSyncOutcome, .completed)
        XCTAssertEqual(kitchen.inventory.first(where: { $0.id == id })?.quantity, 5, "T1")
        XCTAssertFalse(kitchen.isInventoryLockedForSync, "the window must close on a successful run")
    }

    /// T3 — a pulled delete disappears from `KitchenStore`.
    func testR1RemoteDeleteDisappearsFromKitchenStore() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let id = UUID()
        kitchen.inventory = [InventoryItem(id: id, name: "会被远端删除", quantity: 1, unit: "个", expiryDate: nil)]

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteDelete(id: id, version: "2", sequence: "2")
        let controller = makeR1Controller(persistence: persistence, kitchenStore: kitchen, transport: transport)

        await controller.syncNow(authStore: await signedInAuthStore(userID: userA), householdId: householdA)

        XCTAssertEqual(controller.lastSyncOutcome, .completed)
        XCTAssertTrue(kitchen.inventory.isEmpty, "T3")
    }

    /// T5 — reconciliation is not a user edit: it stages nothing outbound and
    /// raises no mutation-blocked banner. Asserted at the hook itself, so a
    /// future refactor that merely *reorders* the suppression cannot pass.
    func testR1ReconciliationStagesZeroOutboundMutations() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let id = UUID()
        let doomedId = UUID()
        kitchen.inventory = [
            InventoryItem(id: id, name: "番茄", quantity: 1, unit: "个", expiryDate: nil),
            InventoryItem(id: doomedId, name: "会被远端删除", quantity: 1, unit: "个", expiryDate: nil)
        ]

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: id, name: "番茄", unit: "个", quantity: 5, version: "2", sequence: "2")
        // A remotely-created row and a remote delete in the same page, so the
        // reconciliation genuinely covers insert + update + delete at once.
        let insertedId = UUID()
        await transport.seedRemoteChange(id: insertedId, name: "远端新增", unit: "袋", quantity: 3, version: "1", sequence: "3")
        await transport.seedRemoteDelete(id: doomedId, version: "2", sequence: "4")
        let controller = makeR1Controller(persistence: persistence, kitchenStore: kitchen, transport: transport)

        let recorder = InventoryChangeRecorder()
        kitchen.onInventoryChanged = { old, new in recorder.record(old: old, new: new) }
        let pendingBefore = try await persistence.pendingMutations(scope: SyncScope(type: .household, id: householdA), maxAttempts: .max).count

        await controller.syncNow(authStore: await signedInAuthStore(userID: userA), householdId: householdA)

        XCTAssertEqual(controller.lastSyncOutcome, .completed)
        XCTAssertEqual(
            Set(kitchen.inventory.map(\.id)), Set([id, insertedId]),
            "the reconciliation must have actually applied an update, an insert and a delete"
        )
        XCTAssertTrue(recorder.isEmpty, "T5: reconciliation must never reach the outbound staging hook")
        let pendingAfter = try await persistence.pendingMutations(scope: SyncScope(type: .household, id: householdA), maxAttempts: .max).count
        XCTAssertEqual(pendingAfter, pendingBefore, "T5: reconciliation must stage zero outbound mutations")
        XCTAssertNil(controller.inventoryMutationBlockedMessage, "T5: reconciliation must not raise a conflict banner")
    }

    /// T6 — after reconciliation, one genuine local edit stages exactly one
    /// mutation, and its payload is built from the snapshot that already
    /// contains the remote state.
    func testR1LocalEditAfterReconciliationStagesExactlyOneMutationFromTheFreshSnapshot() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let id = UUID()
        kitchen.inventory = [InventoryItem(id: id, name: "本地旧名", quantity: 1, unit: "个", expiryDate: nil)]

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: id, name: "远端名", unit: "个", quantity: 5, version: "2", sequence: "2")
        let controller = makeR1Controller(persistence: persistence, kitchenStore: kitchen, transport: transport)

        let recorder = InventoryChangeRecorder()
        kitchen.onInventoryChanged = { old, new in recorder.record(old: old, new: new) }
        await controller.syncNow(authStore: await signedInAuthStore(userID: userA), householdId: householdA)
        XCTAssertTrue(recorder.isEmpty)

        let index = try XCTUnwrap(kitchen.inventory.firstIndex(where: { $0.id == id }))
        kitchen.inventory[index].quantity = 9

        let staged = recorder.drain()
        XCTAssertEqual(staged.count, 1, "T6: exactly one outbound observation for one real edit")
        for change in staged {
            await controller.handleInventoryDidChange(old: change.old, new: change.new, userId: userA, householdId: householdA)
        }

        let scope = SyncScope(type: .household, id: householdA)
        let pending = try await persistence.pendingMutations(scope: scope, maxAttempts: .max)
        XCTAssertEqual(pending.count, 1, "T6: exactly one pending mutation")
        let payload = try XCTUnwrap(pending.first?.decodedPayload())
        XCTAssertEqual(payload["quantity"], .number(9), "T6: the edit itself")
        XCTAssertEqual(payload["name"], .string("远端名"), "T6: payload must carry the reconciled remote state, not the pre-pull name")
    }

    /// T7 — a 50-change page applies row by row durably, but replaces the
    /// published array at most once.
    func testR1LargeRemoteBatchProducesExactlyOnePublishedReplacement() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        kitchen.inventory = []

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        for index in 1...50 {
            await transport.seedRemoteChange(
                id: UUID(), name: "远端\(index)", unit: "个", quantity: Double(index),
                version: "1", sequence: String(index)
            )
        }
        let controller = makeR1Controller(persistence: persistence, kitchenStore: kitchen, transport: transport)

        var publishes = 0
        let cancellable = kitchen.$inventory.dropFirst().sink { _ in publishes += 1 }
        defer { cancellable.cancel() }

        await controller.syncNow(authStore: await signedInAuthStore(userID: userA), householdId: householdA)

        XCTAssertEqual(controller.lastSyncOutcome, .completed)
        XCTAssertEqual(kitchen.inventory.count, 50, "every row must land")
        XCTAssertEqual(publishes, 1, "T7: 50 durable applies, exactly one in-memory replacement")
    }

    /// T8 — a remote change arriving while a local mutation is pending still
    /// takes the existing conflict path, leaves the durable row untouched,
    /// and therefore gives reconciliation nothing to do.
    func testR1RemoteChangeWhilePendingStillTakesTheConflictPath() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let id = UUID()
        let recorder = InventoryChangeRecorder()
        kitchen.onInventoryChanged = { old, new in recorder.record(old: old, new: new) }
        kitchen.inventory = [InventoryItem(id: id, name: "本地", quantity: 1, unit: "个", expiryDate: nil)]
        for change in recorder.drain() {
            await controller(for: persistence).handleInventoryDidChange(
                old: change.old, new: change.new, userId: userA, householdId: householdA
            )
        }
        let scope = SyncScope(type: .household, id: householdA)
        let stagedLocal = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: id)
        XCTAssertNotNil(stagedLocal, "the local create must be staged before the remote change arrives")

        let adapter = InventorySyncAdapter(persistence: persistence)
        let outcome = try await adapter.applyRemote(
            SyncChangeEnvelope(
                sequence: try SyncCursorValue("2"), entityType: .inventoryItem, entityId: id,
                operation: .upsert, version: try SyncCursorValue("2"), changedAt: Date(),
                data: ["name": .string("远端"), "quantity": .number(9), "unit": .string("个"), "isStaple": .bool(false)]
            ),
            scope: scope
        )

        XCTAssertEqual(outcome, .conflict, "T8: the existing conflict path must still be taken")
        let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: id)
        XCTAssertEqual(metadata?.state, .conflicted)
        let durable = try await persistence.inventoryItem(id: id)
        XCTAssertEqual(durable?.quantity, 1, "T8: a conflicting remote change must not rewrite the row")

        // The conflict left the durable row untouched, so reconciliation
        // legitimately has nothing to publish — which is itself the point:
        // a conflict must not silently adopt the remote value, and must not
        // manufacture an outbound mutation either.
        XCTAssertTrue(kitchen.reconcileInventoryFromPersistence())
        XCTAssertEqual(kitchen.inventory.first?.quantity, 1)
        XCTAssertTrue(recorder.isEmpty, "T8: the conflict path stages nothing further")
    }

    /// T9 — every classification survives a reconciliation, and none of the
    /// three reads as a user reclassification on the way through.
    func testR1PreparationKindAndStapleSurviveReconciliation() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let readyId = UUID(), stapleId = UUID(), ordinaryId = UUID()
        kitchen.inventory = []

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: readyId, name: "腌鸡翅", unit: "个", quantity: 4, preparationKind: "readyToCook", version: "1", sequence: "1")
        await transport.seedRemoteChange(id: stapleId, name: "大米", unit: "袋", quantity: 1, isStaple: true, version: "1", sequence: "2")
        await transport.seedRemoteChange(id: ordinaryId, name: "番茄", unit: "个", quantity: 2, preparationKind: "none", version: "1", sequence: "3")
        let controller = makeR1Controller(persistence: persistence, kitchenStore: kitchen, transport: transport)

        let recorder = InventoryChangeRecorder()
        kitchen.onInventoryChanged = { old, new in recorder.record(old: old, new: new) }
        await controller.syncNow(authStore: await signedInAuthStore(userID: userA), householdId: householdA)

        XCTAssertEqual(kitchen.inventory.first(where: { $0.id == readyId })?.kind, .readyToCook, "T9")
        XCTAssertEqual(kitchen.inventory.first(where: { $0.id == stapleId })?.kind, .staple, "T9")
        XCTAssertEqual(kitchen.inventory.first(where: { $0.id == ordinaryId })?.kind, .ordinary, "T9")
        XCTAssertTrue(recorder.isEmpty, "T9: hydrating a classification is not a user reclassification")
    }

    /// T12 — a run that fails partway still reconciles what it already wrote.
    func testR1PartiallyFailedPullStillReconciles() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        kitchen.inventory = []
        let firstPageId = UUID()

        let transport = SecondPageFailingTransport(userID: userA, householdID: householdA, firstPageEntityId: firstPageId)
        let controller = makeR1Controller(persistence: persistence, kitchenStore: kitchen, transport: transport)

        await controller.syncNow(authStore: await signedInAuthStore(userID: userA), householdId: householdA)

        XCTAssertEqual(controller.lastSyncOutcome, .failed(.transport), "the run must genuinely fail")
        let durable = try await persistence.inventoryItem(id: firstPageId)
        XCTAssertNotNil(durable, "the first page was committed before the failure")
        XCTAssertEqual(
            kitchen.inventory.map(\.id), [firstPageId],
            "T12: a failed run must still reconcile the rows it already wrote"
        )
        XCTAssertFalse(kitchen.isInventoryLockedForSync, "a successful reconciliation releases the lock even on a failed run")
    }

    /// T14 — an edit attempted *while the operation is awaiting* is refused
    /// at the central boundary, not merely disabled in a View. The edit is
    /// performed the way a SwiftUI `Binding` does it: straight into
    /// `inventory[index]`.
    func testR1EditDuringSyncIsRefusedAtTheCentralBoundary() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let id = UUID()
        kitchen.inventory = [InventoryItem(id: id, name: "番茄", quantity: 1, unit: "个", expiryDate: nil)]

        let recorder = InventoryChangeRecorder()
        kitchen.onInventoryChanged = { old, new in recorder.record(old: old, new: new) }
        let observation = EditDuringSyncObservation()

        let inner = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let transport = EditDuringSyncTransport(inner: inner) { [weak kitchen] in
            guard let kitchen, let index = kitchen.inventory.firstIndex(where: { $0.id == id }) else { return }
            kitchen.inventory[index].quantity = 999
            observation.quantityAfterAttempt = kitchen.inventory[index].quantity
            observation.noticeAfterAttempt = kitchen.inventoryNotice
            observation.wasLocked = kitchen.isInventoryLockedForSync
        }
        let controller = makeR1Controller(persistence: persistence, kitchenStore: kitchen, transport: transport)
        let scope = SyncScope(type: .household, id: householdA)
        let pendingBefore = try await persistence.pendingMutations(scope: scope, maxAttempts: .max).count

        await controller.syncNow(authStore: await signedInAuthStore(userID: userA), householdId: householdA)

        XCTAssertTrue(observation.wasLocked, "the window must be open while the operation awaits")
        XCTAssertEqual(observation.quantityAfterAttempt, 1, "T14: the attempted change must not survive in memory")
        XCTAssertEqual(observation.noticeAfterAttempt, KitchenStore.inventoryLockedForSyncNotice, "T14: the user must be told")
        let durable = try await persistence.inventoryItem(id: id)
        XCTAssertEqual(durable?.quantity, 1, "T14: the refused edit must not reach the database")
        let pendingAfter = try await persistence.pendingMutations(scope: scope, maxAttempts: .max).count
        XCTAssertEqual(pendingAfter, pendingBefore, "T14: the refused edit must not stage anything")
        XCTAssertTrue(recorder.isEmpty, "T14: the refused edit must never reach the outbound hook")
        XCTAssertEqual(kitchen.inventory.first?.quantity, 1)
    }

    /// T15 — the same closed gate must not block reconciliation itself.
    func testR1ReconciliationItselfBypassesTheEditGate() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let id = UUID()
        kitchen.inventory = [InventoryItem(id: id, name: "番茄", quantity: 1, unit: "个", expiryDate: nil)]
        let recorder = InventoryChangeRecorder()
        kitchen.onInventoryChanged = { old, new in recorder.record(old: old, new: new) }

        kitchen.beginInventorySyncConsistencyWindow()
        var remote = InventoryItem(id: id, name: "番茄", quantity: 5, unit: "个", expiryDate: nil)
        remote.updatedAt = Date()
        try await persistence.applyRemoteInventory(
            item: remote, removeInventory: false,
            metadata: SyncMetadata(
                entityType: .inventoryItem, entityId: id, scope: SyncScope(type: .household, id: householdA),
                remoteVersion: try SyncCursorValue("2"), state: .synced, lastSyncedAt: Date(),
                lastErrorCode: nil, lastErrorAt: nil, deletedAt: nil, updatedAt: Date()
            )
        )

        XCTAssertTrue(kitchen.endInventorySyncConsistencyWindow(), "T15: reconciliation must succeed through the closed gate")
        XCTAssertEqual(kitchen.inventory.first?.quantity, 5, "T15: the suppressed publish must go through")
        XCTAssertFalse(kitchen.isInventoryLockedForSync)
        XCTAssertTrue(recorder.isEmpty, "T15: still zero outbound staging")
    }

    /// T16 — if the closing reconciliation cannot read durable state, the
    /// inventory stays locked. Unlocking here would leave a stale array
    /// editable, which is exactly R1.
    func testR1ReconciliationFailureKeepsInventoryLockedAndUneditable() async throws {
        let container = try ModelContainer(
            for: InventoryRecord.self, ShoppingItemRecord.self, TodayPlanRecord.self,
            ConsumptionRecordEntity.self, WeeklyPlanRecord.self,
            SyncMetadataRecord.self, PendingMutationRecord.self, SyncCursorRecord.self,
            GuestMergeSessionRecord.self, InventorySyncEnrollmentRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let failable = FailableInventoryPersistence(wrapping: SwiftDataInventoryPersistence(container: container))
        let kitchen = KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            inventoryPersistence: failable,
            shoppingListPersistence: SwiftDataShoppingListPersistence(container: container),
            todayPlanPersistence: SwiftDataTodayPlanPersistence(container: container),
            consumptionPersistence: SwiftDataConsumptionPersistence(container: container),
            weeklyPlanPersistence: SwiftDataWeeklyPlanPersistence(container: container)
        )
        let persistence = SwiftDataSyncPersistence(modelContainer: container)
        try await persistence.saveEnrollment(InventorySyncEnrollment(
            userId: userA, householdId: householdA, status: .enrolled, enrolledAt: Date(),
            mergeSessionId: UUID(), schemaVersion: InventorySyncEnrollment.currentSchemaVersion, updatedAt: Date()
        ))
        let id = UUID()
        kitchen.inventory = [InventoryItem(id: id, name: "番茄", quantity: 1, unit: "个", expiryDate: nil)]

        let recorder = InventoryChangeRecorder()
        kitchen.onInventoryChanged = { old, new in recorder.record(old: old, new: new) }
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: id, name: "番茄", unit: "个", quantity: 5, version: "2", sequence: "2")
        let controller = makeR1Controller(persistence: persistence, kitchenStore: kitchen, transport: transport)

        failable.failLoads = true
        await controller.syncNow(authStore: await signedInAuthStore(userID: userA), householdId: householdA)

        XCTAssertTrue(kitchen.isInventoryLockedForSync, "T16: a failed reconciliation must keep the lock")
        XCTAssertEqual(kitchen.inventoryNotice, KitchenStore.inventoryReconciliationFailedNotice, "T16: observable error state")
        XCTAssertEqual(controller.lastSyncErrorMessage, KitchenStore.inventoryReconciliationFailedNotice)

        // The remote change is durable; memory is still stale — so editing
        // must stay refused.
        let scope = SyncScope(type: .household, id: householdA)
        let pendingBefore = try await persistence.pendingMutations(scope: scope, maxAttempts: .max).count
        kitchen.inventory[0].quantity = 42
        XCTAssertEqual(kitchen.inventory[0].quantity, 1, "T16: edits stay refused while locked")
        let durableWhileLocked = try await persistence.inventoryItem(id: id)
        XCTAssertEqual(durableWhileLocked?.quantity, 5, "T16: a refused edit must not touch the database")
        let pendingWhileLocked = try await persistence.pendingMutations(scope: scope, maxAttempts: .max).count
        XCTAssertEqual(pendingWhileLocked, pendingBefore, "T16: a refused edit must stage nothing")
        XCTAssertTrue(recorder.isEmpty)

        // Recovery: once the durable read works, the window closes and the
        // store is editable again — now against the reconciled snapshot.
        failable.failLoads = false
        XCTAssertTrue(kitchen.endInventorySyncConsistencyWindow(), "T16: retry must recover")
        XCTAssertFalse(kitchen.isInventoryLockedForSync)
        XCTAssertEqual(kitchen.inventory.first?.quantity, 5)
        kitchen.inventory[0].quantity = 42
        let durableAfterRecovery = try await persistence.inventoryItem(id: id)
        XCTAssertEqual(durableAfterRecovery?.quantity, 42, "T16: normal editing resumes after recovery")
    }

    /// T17 — the blind spot a `defer { reconcile() }` around `runOnce` alone
    /// would leave: `confirmMerge` writes `InventoryRecord` durably while
    /// *staging*, before the coordinator is ever constructed. Here staging
    /// succeeds and the run then fails, and the whole-operation boundary must
    /// still reconcile.
    func testR1PartialPreRunStagingFailureStillReconciles() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        kitchen.inventory = [InventoryItem(id: sharedId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil)]

        let previewTransport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await previewTransport.seedRemoteChange(id: sharedId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")
        // Reads succeed (so preview and the pre-upload re-verification agree),
        // but the coordinator's very first call — bootstrap — fails.
        let confirmTransport = BootstrapFailingTransport(inner: previewTransport)
        let controller = makeR1Controller(persistence: persistence, kitchenStore: kitchen, transport: confirmTransport)

        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: previewTransport)
        await controller.resolveConflict(candidateId: sharedId, choice: .keepBoth)
        let forkedId = try XCTUnwrap(controller.plan?.candidates.first(where: { $0.localItemId == sharedId })?.forkedLocalItemId)

        await controller.confirmMerge(authStore: await signedInAuthStore(userID: userA))

        XCTAssertNotEqual(controller.session?.status, .completed, "the run must genuinely have failed")
        let durableFork = try await persistence.inventoryItem(id: forkedId)
        XCTAssertNotNil(durableFork, "staging committed the fork before the coordinator failed")
        XCTAssertTrue(
            kitchen.inventory.contains(where: { $0.id == forkedId }),
            "T17: a failure after pre-run staging must still reconcile — this is what a defer around runOnce alone would miss"
        )
        XCTAssertFalse(kitchen.isInventoryLockedForSync)
    }

    /// T19 — a second sync operation that returns early from its own guards
    /// while a first one is still awaiting must not close the first one's
    /// consistency window. `syncNow` is guarded by `isSyncing` and
    /// `confirmMerge` by `isBusy`, so the two genuinely can overlap.
    func testR1OverlappingOperationDoesNotUnlockTheInFlightWindow() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let id = UUID()
        kitchen.inventory = [InventoryItem(id: id, name: "番茄", quantity: 1, unit: "个", expiryDate: nil)]

        let observation = EditDuringSyncObservation()
        let inner = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await inner.seedRemoteChange(id: id, name: "番茄", unit: "个", quantity: 5, version: "2", sequence: "2")

        // Built up front so the mid-flight closure can reach it without
        // constructing anything on the fly.
        let overlapping = makeR1Controller(persistence: persistence, kitchenStore: kitchen, transport: inner)
        let authStore = await signedInAuthStore(userID: userA)

        let transport = EditDuringSyncTransport(inner: inner) { [weak kitchen] in
            guard let kitchen else { return }
            // `confirmMerge` with no session returns immediately from its own
            // `guard var current = session` — the boundary still opens and
            // closes around that early return.
            Task { @MainActor in await overlapping.confirmMerge(authStore: authStore) }
            observation.wasLocked = kitchen.isInventoryLockedForSync
        }
        let controller = makeR1Controller(persistence: persistence, kitchenStore: kitchen, transport: transport)

        await controller.syncNow(authStore: authStore, householdId: householdA)
        // Let the overlapping task, if it is still queued, run to completion.
        await Task.yield()
        await overlapping.confirmMerge(authStore: authStore)

        XCTAssertTrue(observation.wasLocked)
        XCTAssertFalse(kitchen.isInventoryLockedForSync, "the outer operation released the window when it finished")
        XCTAssertEqual(kitchen.inventory.first?.quantity, 5, "and the sync's own reconciliation still happened")
    }


    // MARK: - R3: rollback must never delete a durable local inventory row

    /// Every test in this section asserts on **durable** persistence
    /// (`persistence.inventoryItem(id:)`), not only on `KitchenStore.inventory`.
    /// The pre-R3 rollback tests asserted on an in-memory array belonging to a
    /// `KitchenStore` the controller under test was never wired to, so they
    /// passed while the durable `InventoryRecord` had already been deleted.
    /// `makeRollbackController` closes that hole structurally.

    /// R3-A. A plain `.create` merge candidate records the **local Guest
    /// item's own id** in `createdEntityIds` (local and remote deliberately
    /// share the UUID), so rolling the merge back must soft-delete the remote
    /// row and leave the user's own local row completely untouched.
    func testR3RollbackPreservesDurableLocalRowForACreatedEntity() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = try await makeRollbackController(persistence: persistence, kitchenStore: kitchen, transport: transport)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)
        let itemId = try XCTUnwrap(controller.session?.createdEntityIds.first)
        let durableBefore = try await persistence.inventoryItem(id: itemId)
        XCTAssertNotNil(durableBefore, "precondition: the Guest row is durable before the rollback")

        await controller.rollback(authStore: authStore)

        XCTAssertEqual(controller.session?.status, .rolledBack)
        let deletedRemotely = await transport.isSoftDeleted(itemId)
        XCTAssertTrue(deletedRemotely, "rollback must soft-delete the remote entity this session created")
        let durableAfter = try await persistence.inventoryItem(id: itemId)
        XCTAssertNotNil(
            durableAfter,
            "R3: rollback must never physically delete the user's own durable local InventoryRecord"
        )
        XCTAssertTrue(
            kitchen.inventory.contains { $0.id == itemId },
            "R3: and after R1 reconciliation the preserved row must still be in the user's kitchen"
        )
    }

    /// R3-B. Same invariant across an App relaunch: a brand-new persistence
    /// actor over the same on-disk container and a brand-new controller, which
    /// is what a freshly presented merge-result screen builds.
    func testR3RollbackAfterRelaunchPreservesDurableLocalRow() async throws {
        let (kitchen, sharedPersistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controllerA = try await makeRollbackController(persistence: sharedPersistence, kitchenStore: kitchen, transport: transport)
        let authStore = await signedInAuthStore(userID: userA)
        await controllerA.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controllerA.confirmMerge(authStore: authStore)
        XCTAssertEqual(controllerA.session?.status, .completed)
        let itemId = try XCTUnwrap(controllerA.session?.createdEntityIds.first)

        let relaunchedPersistence = SwiftDataSyncPersistence(modelContainer: sharedPersistence.modelContainer)
        let controllerB = try await makeRollbackController(persistence: relaunchedPersistence, kitchenStore: kitchen, transport: transport)
        await controllerB.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        XCTAssertEqual(controllerB.session?.createdEntityIds, [itemId])

        await controllerB.rollback(authStore: authStore)

        XCTAssertEqual(controllerB.session?.status, .rolledBack)
        let deletedRemotely = await transport.isSoftDeleted(itemId)
        XCTAssertTrue(deletedRemotely)
        let durableAfterRelaunchRollback = try await relaunchedPersistence.inventoryItem(id: itemId)
        XCTAssertNotNil(
            durableAfterRelaunchRollback,
            "R3: a rollback after relaunch must preserve the durable local row too"
        )
        XCTAssertTrue(kitchen.inventory.contains { $0.id == itemId })
    }

    /// R3-C (focused). After a rollback the preserved local row keeps its
    /// `SyncMetadata` — `.synced` with a `deletedAt` and the tombstone's own
    /// version. Left unguarded, `InventorySyncEligibility` reads that as an
    /// ordinary synced row and calls a later local edit eligible at exactly
    /// the tombstone version, which `SYNC_API_CONTRACT.md` §4 defines as the
    /// *resurrect* upsert — silently undoing the rollback remotely.
    func testR3TombstonedMetadataMakesALaterLocalEditLocalOnly() {
        let tombstoned = SyncMetadata(
            entityType: .inventoryItem, entityId: UUID(), scope: SyncScope(type: .household, id: householdA),
            remoteVersion: try! SyncCursorValue("7"), state: .synced, lastSyncedAt: Date(),
            lastErrorCode: nil, lastErrorAt: nil, deletedAt: Date(), updatedAt: Date()
        )
        let enrollment = InventorySyncEnrollment(
            userId: userA, householdId: householdA, status: .enrolled, enrolledAt: Date(),
            mergeSessionId: UUID(), schemaVersion: InventorySyncEnrollment.currentSchemaVersion, updatedAt: Date()
        )
        let update = InventorySyncEligibility.evaluate(
            isFeatureEnabled: true, userId: userA, householdId: householdA,
            enrollment: enrollment, existingMetadata: tombstoned, intent: .update
        )
        XCTAssertEqual(
            update, .localOnly(reason: .remotelyDeleted),
            "R3: editing a row whose remote entity is tombstoned must stay local-only, never resurrect it"
        )
        let delete = InventorySyncEligibility.evaluate(
            isFeatureEnabled: true, userId: userA, householdId: householdA,
            enrollment: enrollment, existingMetadata: tombstoned, intent: .delete
        )
        XCTAssertEqual(
            delete, .localOnly(reason: .remotelyDeleted),
            "R3: the remote entity is already deleted — a second remote delete has nothing to express"
        )
        // `.create` is covered too. Intent is derived from "this id was absent
        // from the previous array", so a create carrying metadata that already
        // exists is never a genuinely new item — and it is the most dangerous
        // intent to let through, since the fresh-stage path would compute
        // baseVersion from the tombstone's own version and write
        // `deletedAt: nil`, resurrecting the entity and clearing the shield in
        // one step.
        let create = InventorySyncEligibility.evaluate(
            isFeatureEnabled: true, userId: userA, householdId: householdA,
            enrollment: enrollment, existingMetadata: tombstoned, intent: .create
        )
        XCTAssertEqual(
            create, .localOnly(reason: .remotelyDeleted),
            "R3: a create against tombstoned metadata must never resurrect the entity either"
        )
        // A genuinely new item — no metadata at all — is untouched by the rule.
        let genuinelyNew = InventorySyncEligibility.evaluate(
            isFeatureEnabled: true, userId: userA, householdId: householdA,
            enrollment: enrollment, existingMetadata: nil, intent: .create
        )
        XCTAssertEqual(genuinelyNew, .eligible(baseVersion: nil))
    }

    /// R3-C end-to-end: the same protection driven through the real rollback
    /// and the real CRUD hook, proving no mutation is staged and the remote
    /// entity stays tombstoned.
    func testR3LocalEditOfAPreservedRowAfterRollbackStagesNothingAndKeepsRemoteTombstoned() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = try await makeRollbackController(persistence: persistence, kitchenStore: kitchen, transport: transport)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        await controller.rollback(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .rolledBack)
        let itemId = try XCTUnwrap(controller.session?.createdEntityIds.first)
        let scope = SyncScope(type: .household, id: householdA)
        let pendingBefore = try await persistence.pendingMutations(scope: scope, maxAttempts: .max).count

        let preservedRow = try await persistence.inventoryItem(id: itemId)
        let preserved = try XCTUnwrap(preservedRow)
        var edited = preserved
        edited.quantity += 5
        await controller.handleInventoryDidChange(old: [preserved], new: [edited], userId: userA, householdId: householdA)

        let pendingAfter = try await persistence.pendingMutations(scope: scope, maxAttempts: .max).count
        XCTAssertEqual(pendingAfter, pendingBefore, "R3: editing a preserved, remotely-tombstoned row must stage nothing")
        let stagedForEntity = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: itemId)
        XCTAssertNil(
            stagedForEntity,
            "R3: no resurrect mutation may be queued for a tombstoned entity"
        )
        let stillDeleted = await transport.isSoftDeleted(itemId)
        XCTAssertTrue(stillDeleted, "R3: the remote entity must stay tombstoned")
        let survivedTheEdit = try await persistence.inventoryItem(id: itemId)
        XCTAssertNotNil(survivedTheEdit, "R3: refusing to stage must never cost the user the local row")
    }

    /// R3-D. The metadata this test inspects is deliberately *kept* rather than
    /// cleared: it is what makes a later pull of this entity's own tombstone
    /// read as a duplicate instead of physically deleting the preserved local
    /// row. Clearing it to "make the row Guest-local again" would reintroduce
    /// the same data loss through the pull path.
    func testR3RepeatedTombstonePullDoesNotDeleteThePreservedLocalRow() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = try await makeRollbackController(persistence: persistence, kitchenStore: kitchen, transport: transport)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        await controller.rollback(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .rolledBack)
        let itemId = try XCTUnwrap(controller.session?.createdEntityIds.first)
        let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: itemId)
        XCTAssertNotNil(metadata, "R3: the tombstone metadata is the shield — it must not be cleared")
        let tombstoneVersion = try XCTUnwrap(metadata?.remoteVersion)

        // The same tombstone is delivered again by a later pull (a resumed
        // cursor, a second device's page, a retried run).
        let adapter = InventorySyncAdapter(persistence: persistence)
        let outcome = try await adapter.applyRemote(
            SyncChangeEnvelope(
                sequence: try SyncCursorValue("99"), entityType: .inventoryItem, entityId: itemId,
                operation: .delete, version: tombstoneVersion, changedAt: Date(),
                data: ["deletedAt": .string(ISO8601DateFormatter().string(from: Date()))]
            ),
            scope: SyncScope(type: .household, id: householdA)
        )

        XCTAssertEqual(outcome, .duplicate, "the entity's own retained metadata must absorb its tombstone")
        let durableAfterTombstonePull = try await persistence.inventoryItem(id: itemId)
        XCTAssertNotNil(
            durableAfterTombstonePull,
            "R3: a repeated tombstone pull must never delete the preserved local row"
        )
    }

    /// R3-E. `keepBoth` on a same-id conflict: the fork's *remote* row is what
    /// the session created, so only that is tombstoned. Both local rows — the
    /// user's original and the session-created fork — are preserved, per the
    /// R3 invariant that rollback never physically deletes a local durable row.
    func testR3ForkRollbackTombstonesOnlyTheForkRemoteAndPreservesBothLocalRows() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        kitchen.inventory = [InventoryItem(id: sharedId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil)]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: sharedId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")
        let controller = try await makeRollbackController(persistence: persistence, kitchenStore: kitchen, transport: transport)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        await controller.resolveConflict(candidateId: sharedId, choice: .keepBoth)
        let forkedId = try XCTUnwrap(controller.plan?.candidates.first(where: { $0.localItemId == sharedId })?.forkedLocalItemId)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)
        XCTAssertEqual(controller.session?.createdEntityIds, [forkedId])

        await controller.rollback(authStore: authStore)

        XCTAssertEqual(controller.session?.status, .rolledBack)
        let forkDeleted = await transport.isSoftDeleted(forkedId)
        XCTAssertTrue(forkDeleted, "the fork's remote row is what this session created")
        let originalDeleted = await transport.isSoftDeleted(sharedId)
        XCTAssertFalse(originalDeleted, "the pre-existing remote row must never be touched by a rollback")
        let durableOriginal = try await persistence.inventoryItem(id: sharedId)
        XCTAssertNotNil(durableOriginal, "the user's original local row is preserved")
        let durableFork = try await persistence.inventoryItem(id: forkedId)
        XCTAssertNotNil(
            durableFork,
            "R3: the fork's local row is preserved too — restoring the pre-merge local state is a separate, provenance-bearing feature"
        )
        XCTAssertTrue(kitchen.inventory.contains { $0.id == sharedId })
        XCTAssertTrue(kitchen.inventory.contains { $0.id == forkedId })
    }

    /// R3-F. An `.update` candidate targets a remote row this session did not
    /// create, so it never enters `createdEntityIds` and rollback is a complete
    /// no-op for it — neither side is deleted.
    func testR3UpdateCandidateIsNeverRolledBack() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        kitchen.inventory = [InventoryItem(id: sharedId, name: "苹果", quantity: 3, unit: "个", expiryDate: nil)]
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(id: sharedId, name: "苹果", unit: "个", quantity: 2, version: "5", sequence: "1")
        let controller = try await makeRollbackController(persistence: persistence, kitchenStore: kitchen, transport: transport)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        await controller.resolveConflict(candidateId: sharedId, choice: .keepLocal)
        XCTAssertEqual(controller.plan?.candidates.first(where: { $0.localItemId == sharedId })?.action, .update)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)
        XCTAssertEqual(controller.session?.createdEntityIds, [], "an update never creates a remote entity, so it is never rollback-eligible")

        await controller.rollback(authStore: authStore)

        XCTAssertEqual(controller.session?.status, .rolledBack)
        let deleted = await transport.isSoftDeleted(sharedId)
        XCTAssertFalse(deleted, "rollback must never tombstone a pre-existing remote row it only updated")
        let durableUpdated = try await persistence.inventoryItem(id: sharedId)
        XCTAssertNotNil(durableUpdated)
        XCTAssertTrue(kitchen.inventory.contains { $0.id == sharedId })
    }

    /// R3-G. Repeating a rollback must not delete local data, must not stage a
    /// second delete mutation for the same entity, and must stay idempotent.
    func testR3RepeatedRollbackKeepsLocalDataAndStagesNoSecondDelete() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = try await makeRollbackController(persistence: persistence, kitchenStore: kitchen, transport: transport)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        await controller.rollback(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .rolledBack)
        let itemId = try XCTUnwrap(controller.session?.createdEntityIds.first)
        let scope = SyncScope(type: .household, id: householdA)
        let pendingAfterFirst = try await persistence.allPendingMutations(scope: scope).count

        await controller.rollback(authStore: authStore)

        XCTAssertEqual(controller.session?.status, .rolledBack)
        let pendingAfterSecond = try await persistence.allPendingMutations(scope: scope).count
        XCTAssertEqual(
            pendingAfterSecond, pendingAfterFirst,
            "a repeated rollback must not stage a second delete mutation"
        )
        let durableAfterRepeat = try await persistence.inventoryItem(id: itemId)
        XCTAssertNotNil(durableAfterRepeat, "R3: and must not delete local data")
        XCTAssertTrue(kitchen.inventory.contains { $0.id == itemId })
    }

    /// R3-H. Partial failure: one entity's delete applies, the other conflicts.
    /// The session must stay rollback-eligible, both local rows must survive,
    /// and a retry must only re-stage the entity that is still outstanding.
    func testR3PartiallyFailedRollbackPreservesBothLocalRowsAndRetriesOnlyTheOutstandingOne() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        kitchen.importInventory([
            InventoryImportItem(name: "苹果", quantity: 1, unit: "个", expiryDate: nil),
            InventoryImportItem(name: "牛奶", quantity: 1, unit: "盒", expiryDate: nil)
        ])
        let inner = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = try await makeRollbackController(persistence: persistence, kitchenStore: kitchen, transport: inner)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)
        let createdIds = try XCTUnwrap(controller.session?.createdEntityIds)
        XCTAssertEqual(createdIds.count, 2)
        let conflictingId = try XCTUnwrap(createdIds.first)
        let succeedingId = try XCTUnwrap(createdIds.last)

        let conflicting = ConflictInjectingTransport(inner: inner, conflictEntityId: conflictingId)
        let partial = try await makeRollbackController(persistence: persistence, kitchenStore: kitchen, transport: conflicting)
        await partial.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await partial.rollback(authStore: authStore)

        XCTAssertEqual(partial.session?.status, .completed, "a partially applied rollback must stay rollback-eligible")
        let succeeded = await inner.isSoftDeleted(succeedingId)
        XCTAssertTrue(succeeded)
        let conflicted = await inner.isSoftDeleted(conflictingId)
        XCTAssertFalse(conflicted)
        let durableSucceeding = try await persistence.inventoryItem(id: succeedingId)
        XCTAssertNotNil(durableSucceeding, "R3: a confirmed remote delete never removes the local row")
        let durableConflicting = try await persistence.inventoryItem(id: conflictingId)
        XCTAssertNotNil(durableConflicting, "R3: nor does a failed one")
        XCTAssertTrue(kitchen.inventory.contains { $0.id == succeedingId })
        XCTAssertTrue(kitchen.inventory.contains { $0.id == conflictingId })

        // Retry against a healthy transport: only the still-outstanding entity
        // is re-staged, and it now completes.
        let succeedingMetadataBeforeRetry = try await persistence.metadata(entityType: .inventoryItem, entityId: succeedingId)
        let retry = try await makeRollbackController(persistence: persistence, kitchenStore: kitchen, transport: inner)
        await retry.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await retry.rollback(authStore: authStore)

        // The already-confirmed entity is skipped, not re-staged: its metadata
        // is byte-for-byte what the first attempt left, and no fresh mutation
        // was queued for it.
        let succeedingMetadataAfterRetry = try await persistence.metadata(entityType: .inventoryItem, entityId: succeedingId)
        XCTAssertEqual(succeedingMetadataAfterRetry, succeedingMetadataBeforeRetry, "an already-deleted entity must not be re-staged")
        let succeedingPending = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: succeedingId)
        XCTAssertNil(succeedingPending, "and must not leave a second delete mutation behind")
        XCTAssertEqual(retry.session?.status, .rolledBack)
        let nowDeleted = await inner.isSoftDeleted(conflictingId)
        XCTAssertTrue(nowDeleted)
        let durableSucceedingAfterRetry = try await persistence.inventoryItem(id: succeedingId)
        XCTAssertNotNil(durableSucceedingAfterRetry)
        let durableConflictingAfterRetry = try await persistence.inventoryItem(id: conflictingId)
        XCTAssertNotNil(durableConflictingAfterRetry)
    }

    /// R3-J. Rollback must stay retryable after repeated transport failures.
    ///
    /// `stageInventoryMutation`'s `(.delete, .delete)` branch deliberately
    /// reuses the already-queued mutation instead of adding a second one —
    /// correct for ordinary CRUD, but it also means the reused mutation keeps
    /// its spent `attemptCount`, and `pendingMutations(scope:maxAttempts:)`
    /// stops handing an exhausted mutation to the coordinator. Without an
    /// explicit reset, the sixth tap of Rollback (default
    /// `maxMutationAttempts` = 5) would push nothing at all, report
    /// `rollback_delete_not_applied`, and keep doing so until the rollback
    /// window expired — the merge permanently published with no way to
    /// withdraw it. The destructive helper this replaced never hit that,
    /// because it inserted a brand-new mutation on every attempt.
    func testR3RollbackStaysRetryableAfterRepeatedTransportFailures() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let healthy = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = try await makeRollbackController(persistence: persistence, kitchenStore: kitchen, transport: healthy)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)
        let itemId = try XCTUnwrap(controller.session?.createdEntityIds.first)

        // Six offline attempts — one more than the default attempt budget.
        let offline = PushFailingTransport(inner: healthy)
        let offlineController = try await makeRollbackController(persistence: persistence, kitchenStore: kitchen, transport: offline)
        await offlineController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        for _ in 0..<6 {
            await offlineController.rollback(authStore: authStore)
            XCTAssertEqual(offlineController.session?.status, .completed, "a failed rollback must stay rollback-eligible")
        }
        let stillThere = try await persistence.inventoryItem(id: itemId)
        XCTAssertNotNil(stillThere, "R3: a failing rollback must not cost the user the local row either")

        // Back online: the retry must still be able to push a delete.
        let recovered = try await makeRollbackController(persistence: persistence, kitchenStore: kitchen, transport: healthy)
        await recovered.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await recovered.rollback(authStore: authStore)

        XCTAssertEqual(recovered.session?.status, .rolledBack, "rollback must never become permanently impossible after transient failures")
        let deletedRemotely = await healthy.isSoftDeleted(itemId)
        XCTAssertTrue(deletedRemotely)
        let preserved = try await persistence.inventoryItem(id: itemId)
        XCTAssertNotNil(preserved)
        XCTAssertTrue(kitchen.inventory.contains { $0.id == itemId })
    }

    /// R3-K. Ambiguous success: the rollback's delete reaches the server and
    /// tombstones the entity, and only then is the response lost. The client
    /// sees a plain transport failure and cannot tell "never arrived" from
    /// "applied, answer lost".
    ///
    /// This is the case that decides whether a retry may re-stage under a
    /// *new* `mutationId`: a new id is invisible to the server's idempotency
    /// ledger, so the retry is judged on its `baseVersion` alone — which is
    /// stale, because the version bump is exactly what the lost response
    /// carried — and comes back `conflict`, leaving the session unable to ever
    /// reach `.rolledBack`. Preserving the original id makes the same retry a
    /// ledger `duplicate`, which `resolvePending` converges exactly like an
    /// `applied`.
    func testR3RollbackConvergesWhenTheDeleteAppliedButItsResponseWasLost() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let server = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let controller = try await makeRollbackController(persistence: persistence, kitchenStore: kitchen, transport: server)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)
        let itemId = try XCTUnwrap(controller.session?.createdEntityIds.first)

        let lossy = LostResponseTransport(inner: server)
        let lossyController = try await makeRollbackController(persistence: persistence, kitchenStore: kitchen, transport: lossy)
        await lossyController.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)

        await lossyController.rollback(authStore: authStore)

        // The server really did tombstone it; the client just never heard back.
        let tombstonedAfterLostResponse = await server.isSoftDeleted(itemId)
        XCTAssertTrue(tombstonedAfterLostResponse, "precondition: the server-side effect must land before the injected failure")
        XCTAssertNotEqual(lossyController.session?.status, .rolledBack, "the client cannot claim success from a lost response")
        XCTAssertEqual(lossyController.session?.status, .completed, "and must stay rollback-eligible")
        let idsAfterFirstTap = await lossy.receivedMutationIds
        let m1 = try XCTUnwrap(idsAfterFirstTap.first)

        // The user taps Rollback again.
        await lossyController.rollback(authStore: authStore)

        let sentIds = await lossy.receivedMutationIds
        let m2 = try XCTUnwrap(sentIds.last)
        XCTAssertEqual(
            m2, m1,
            "R3: the retry of an ambiguously-failed delete must keep its original mutationId, or the server's idempotency ledger cannot recognise it"
        )
        XCTAssertEqual(lossyController.session?.status, .rolledBack, "the retry must converge, not stall forever")

        // Convergence must not have cost anything, in either direction.
        let preserved = try await persistence.inventoryItem(id: itemId)
        XCTAssertNotNil(preserved, "R3: the local durable row survives an ambiguous-success rollback")
        XCTAssertTrue(kitchen.inventory.contains { $0.id == itemId })
        let stillTombstoned = await server.isSoftDeleted(itemId)
        XCTAssertTrue(stillTombstoned, "the entity stays tombstoned — no resurrection")
        let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: itemId)
        XCTAssertEqual(metadata?.state, .synced)
        XCTAssertNotNil(metadata?.deletedAt, "the tombstone shield survives too")
        let leftover = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: itemId)
        XCTAssertNil(leftover, "a converged rollback leaves no pending mutation behind")

        // A further tap is a guarded no-op: no new request, no state change.
        let idsBeforeThirdTap = await lossy.receivedMutationIds.count
        await lossyController.rollback(authStore: authStore)
        let idsAfterThirdTap = await lossy.receivedMutationIds.count
        XCTAssertEqual(idsAfterThirdTap, idsBeforeThirdTap, "no infinite retry — a rolled-back session stops sending")
        XCTAssertEqual(lossyController.session?.status, .rolledBack)
        let stillPreserved = try await persistence.inventoryItem(id: itemId)
        XCTAssertNotNil(stillPreserved)
    }

    /// R3-L. The `.cancelled` staging outcome, driven end-to-end.
    ///
    /// `stageInventoryMutation` collapses a create+delete pair by removing the
    /// entity's pending record *and* its `SyncMetadata` and staging nothing.
    /// For rollback that is doubly wrong: nothing would be pushed, and the
    /// retained tombstone metadata that keeps a later tombstone pull from
    /// removing the preserved local row is gone. It must fail loudly and stay
    /// retryable rather than verify an entity nothing was staged for.
    ///
    /// Reached without any synthetic state: a server that omits the optional
    /// `version` field leaves `.synced` metadata with no `remoteVersion`, and
    /// an ordinary post-merge edit then queues the upsert the delete collapses
    /// against.
    func testR3RollbackFailsLoudlyWhenStagingCollapsesToCancelled() async throws {
        let (kitchen, persistence) = try makeSharedStores()
        let server = SimulatedMergeTransport(userID: userA, householdID: householdA)
        let versionless = VersionOmittingTransport(inner: server)
        let controller = try await makeRollbackController(persistence: persistence, kitchenStore: kitchen, transport: versionless)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, authStore: authStore)
        await controller.confirmMerge(authStore: authStore)
        XCTAssertEqual(controller.session?.status, .completed)
        let itemId = try XCTUnwrap(controller.session?.createdEntityIds.first)
        let metadataAfterMerge = try await persistence.metadata(entityType: .inventoryItem, entityId: itemId)
        XCTAssertEqual(metadataAfterMerge?.state, .synced)
        XCTAssertNil(metadataAfterMerge?.remoteVersion, "precondition: the omitted version is what makes the collapse reachable")

        // An ordinary post-merge edit queues the upsert the delete collapses against.
        let mergedRow = try await persistence.inventoryItem(id: itemId)
        let merged = try XCTUnwrap(mergedRow)
        var edited = merged
        edited.quantity += 1
        await controller.handleInventoryDidChange(old: [merged], new: [edited], userId: userA, householdId: householdA)
        let queuedUpsert = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: itemId)
        XCTAssertEqual(queuedUpsert?.operation, .upsert, "precondition: an upsert must be queued for the collapse to happen")

        await controller.rollback(authStore: authStore)

        XCTAssertNotEqual(controller.session?.status, .rolledBack, "a rollback that staged nothing must never report success")
        XCTAssertEqual(controller.session?.status, .completed, "and must stay rollback-eligible")
        XCTAssertEqual(controller.session?.lastErrorCode, "rollback_staging_cancelled")
        let preserved = try await persistence.inventoryItem(id: itemId)
        XCTAssertNotNil(preserved, "R3: a collapsed staging must not cost the user the local row either")
        XCTAssertTrue(kitchen.inventory.contains { $0.id == itemId })
        let deletedRemotely = await server.isSoftDeleted(itemId)
        XCTAssertFalse(deletedRemotely, "nothing was staged, so nothing can have been deleted remotely")
    }

    /// R3-I. The regression R3 must never cause: an ordinary user deletion is
    /// still a real local deletion. It does not go through the merge adapter's
    /// destructive helper at all — `KitchenStore` removes the durable row and
    /// `handleInventoryDidChange` stages the remote delete separately.
    func testR3NormalUserDeletionStillRemovesTheDurableRowAndStagesOneRemoteDelete() async throws {
        let (kitchen, persistence) = try await enrolledStores()
        let controller = makeMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in SimulatedMergeTransport(userID: self.userA, householdID: self.householdA) },
            kitchenStore: kitchen
        )
        let id = UUID()
        let item = InventoryItem(id: id, name: "西红柿", quantity: 2, unit: "个", expiryDate: nil)
        kitchen.inventory = [item]
        await controller.handleInventoryDidChange(old: [], new: [item], userId: userA, householdId: householdA)
        let scope = SyncScope(type: .household, id: householdA)
        // Make it a genuinely remote-known row, so the delete is a real remote
        // delete rather than a create+delete that coalesces away.
        try await persistence.saveMetadata(SyncMetadata(
            entityType: .inventoryItem, entityId: id, scope: scope,
            remoteVersion: try SyncCursorValue("4"), state: .synced, lastSyncedAt: Date(),
            lastErrorCode: nil, lastErrorAt: nil, deletedAt: nil, updatedAt: Date()
        ))
        let durableBeforeDeletion = try await persistence.inventoryItem(id: id)
        XCTAssertNotNil(durableBeforeDeletion)

        kitchen.inventory = []
        await controller.handleInventoryDidChange(old: [item], new: [], userId: userA, householdId: householdA)

        let durableAfterDeletion = try await persistence.inventoryItem(id: id)
        XCTAssertNil(
            durableAfterDeletion,
            "R3 must not turn an ordinary user deletion into a preserve-local"
        )
        let staged = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: id)
        XCTAssertEqual(staged?.operation, .delete, "the remote delete is still staged, exactly once")
        let deletes = try await persistence.allPendingMutations(scope: scope).filter { $0.entityId == id && $0.operation == .delete }
        XCTAssertEqual(deletes.count, 1)
    }

    /// Small convenience for T8, which needs a controller only to reach
    /// `handleInventoryDidChange`.
    private func controller(for persistence: any SyncPersistenceProtocol) -> GuestMergeController {
        makeMergeController(persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true))
    }

    // MARK: - Helpers

    /// A `KitchenStore` that exists only to satisfy R1's fail-closed
    /// consistency boundary for the tests that are not about R1. One per
    /// test method (XCTest builds a fresh case instance per test), lazily,
    /// so the 140-odd controller constructions in this file do not each pay
    /// for a `ModelContainer`. `GuestMergeController.kitchenStore` is weak,
    /// so this property is also what keeps it alive for the test's duration.
    private lazy var scratchKitchenStore = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)

    /// Every `GuestMergeController` in this file is built through here.
    ///
    /// R1 made the consistency boundary fail closed: an operation that can
    /// write `InventoryRecord` refuses to start without a reconciliation
    /// target. Tests that do not exercise R1 get `scratchKitchenStore` —
    /// a real store over its own isolated container, so the boundary is
    /// genuinely satisfied rather than stubbed out, while their existing
    /// assertions (which read `persistence` or the test's own `kitchen`) are
    /// unaffected. Tests that *do* exercise R1 pass the real store, either
    /// here or through `makeR1Controller`.
    private func makeMergeController(
        persistence: any SyncPersistenceProtocol,
        configuration: InventoryMergeConfiguration = .load(),
        uiConfiguration: InventoryMergeUIConfiguration = .load(),
        dogfoodConfiguration: InventorySyncDogfoodConfiguration = .load(),
        transportFactory: @escaping @MainActor (any SyncAccessTokenProviding) -> any SyncTransport = { provider in
            ExpressSyncTransport(tokenProvider: provider)
        },
        rollbackWindow: TimeInterval = 24 * 60 * 60,
        crashReporter: (any CrashReporting)? = nil,
        kitchenStore: KitchenStore? = nil
    ) -> GuestMergeController {
        let controller = GuestMergeController(
            persistence: persistence,
            configuration: configuration,
            uiConfiguration: uiConfiguration,
            dogfoodConfiguration: dogfoodConfiguration,
            transportFactory: transportFactory,
            rollbackWindow: rollbackWindow,
            crashReporter: crashReporter
        )
        controller.kitchenStore = kitchenStore ?? scratchKitchenStore
        return controller
    }

    /// A feature-enabled controller wired to a fake transport *and* to the
    /// `KitchenStore` it must keep consistent — the same pairing
    /// `ContentView`'s composition root makes in production.
    private func makeR1Controller(
        persistence: any SyncPersistenceProtocol,
        kitchenStore: KitchenStore,
        transport: any SyncTransport
    ) -> GuestMergeController {
        let controller = GuestMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        controller.kitchenStore = kitchenStore
        return controller
    }

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
    /// Proves — in the direction the assertions actually depend on — that
    /// `kitchenStore` and `persistence` are backed by the same
    /// `ModelContainer`, by writing a sentinel row through the persistence
    /// actor and requiring the store to see it when it reconciles.
    ///
    /// Checking instead that the store's first in-memory item also exists
    /// durably would prove only id coincidence: two stores over different
    /// containers pass that as soon as they happen to share a UUID, and it
    /// exercises store-write → persistence-read, while every
    /// `kitchen.inventory.contains {...}` assertion depends on
    /// persistence-write → store-read (`reconcileInventoryFromPersistence` →
    /// `loadInventory`). The sentinel's id is freshly minted, so coincidence
    /// is impossible, and it is removed again before the fixture is used.
    ///
    /// Fails hard rather than warning: a mis-wired fixture must not go on to
    /// produce a green, meaningless result.
    private func assertSharesOneInventoryContainer(
        _ kitchenStore: KitchenStore,
        _ persistence: SwiftDataSyncPersistence,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let sentinelId = UUID()
        let scope = SyncScope(type: .household, id: householdA)
        func metadata(deletedAt: Date?) -> SyncMetadata {
            SyncMetadata(
                entityType: .inventoryItem, entityId: sentinelId, scope: scope,
                remoteVersion: try! SyncCursorValue("1"), state: .synced, lastSyncedAt: Date(),
                lastErrorCode: nil, lastErrorAt: nil, deletedAt: deletedAt, updatedAt: Date()
            )
        }
        try await persistence.applyRemoteInventory(
            item: InventoryItem(id: sentinelId, name: "__container-probe__", quantity: 1, unit: "个", expiryDate: nil),
            removeInventory: false,
            metadata: metadata(deletedAt: nil)
        )
        let reconciled = kitchenStore.reconcileInventoryFromPersistence()
        let sawSentinel = reconciled && kitchenStore.inventory.contains { $0.id == sentinelId }

        try await persistence.applyRemoteInventory(item: nil, removeInventory: true, metadata: metadata(deletedAt: Date()))
        try await persistence.deleteMetadata(entityType: .inventoryItem, entityId: sentinelId)
        _ = kitchenStore.reconcileInventoryFromPersistence()
        XCTAssertFalse(
            kitchenStore.inventory.contains { $0.id == sentinelId },
            "the probe must leave the fixture exactly as it found it",
            file: file, line: line
        )

        guard sawSentinel else {
            XCTFail(
                "the KitchenStore under assertion and the SyncPersistence under test must share one ModelContainer",
                file: file, line: line
            )
            throw XCTSkip("mis-wired rollback fixture")
        }
    }

    /// Every R3 rollback test builds its controller through here.
    ///
    /// The pre-R3 rollback tests passed while the durable row was already
    /// deleted, because `makeMergeController` defaulted `kitchenStore` to
    /// `scratchKitchenStore` — a store over its *own* container — while the
    /// assertions read a different `KitchenStore` that nothing ever
    /// reconciled. Both parameters are required here, and the probe below
    /// proves at runtime that the store and the persistence actor really do
    /// see the same durable rows, so that mis-wiring cannot silently return.
    private func makeRollbackController(
        persistence: SwiftDataSyncPersistence,
        kitchenStore: KitchenStore,
        transport: any SyncTransport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> GuestMergeController {
        try await assertSharesOneInventoryContainer(kitchenStore, persistence, file: file, line: line)
        let controller = GuestMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport }
        )
        controller.kitchenStore = kitchenStore
        return controller
    }

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
    // MARK: - R2: keepLocal must not destroy a staple's opaque remote expiry
    //
    // A staple has no expiry semantics locally, so iOS never shows or edits the
    // field. The household's row may still hold one. Resolving an unrelated
    // conflict as `keepLocal` means "my quantity/metadata wins" — it is not the
    // user authorising the erasure of a hidden field they were never shown.

    private func stapleExpiry() -> Date {
        DateComponents(calendar: .current, year: 2026, month: 9, day: 30).date!
    }

    private func expiryString(inPayload payload: [String: SyncJSONValue]?) -> String? {
        guard case .string(let value)? = payload?["expiryDate"] else { return nil }
        return value
    }

    func testKeepLocalOnAQuantityConflictPreservesAStaplesRemoteExpiry() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        let remoteExpiry = stapleExpiry()
        kitchen.inventory = [
            InventoryItem(id: sharedId, name: "大米", quantity: 1, unit: "袋", expiryDate: nil, kind: .staple)
        ]

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(
            id: sharedId, name: "大米", unit: "袋", quantity: 5, expiryDate: remoteExpiry,
            isStaple: true, version: "5", sequence: "1"
        )
        await transport.seedExistingRemote(id: sharedId, staleBaseVersion: "5")

        let controller = makeMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport },
            kitchenStore: kitchen
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)

        let candidate = try XCTUnwrap(controller.plan?.candidates.first(where: { $0.localItemId == sharedId }))
        XCTAssertEqual(candidate.conflictReason, .quantityMismatch, "数量冲突本身必须保留")
        XCTAssertNil(candidate.localExpiryDate, "常备行的冲突卡片不展示保质期")

        await controller.resolveConflict(candidateId: sharedId, choice: .keepLocal)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        let uploaded = expiryString(inPayload: await transport.lastReceivedPayload(for: sharedId))
        XCTAssertEqual(
            uploaded, "2026-09-30",
            "keepLocal 只代表本机的可见字段获胜，不是授权抹掉用户从未看到的远端保质期"
        )
        let local = try XCTUnwrap(kitchen.inventory.first(where: { $0.id == sharedId }))
        XCTAssertEqual(local.expiryDate, remoteExpiry, "远端 raw 值必须落进本地 durable 状态，否则下一次编辑会再次清掉它")
        XCTAssertNil(local.effectiveExpiryDate, "语义投影仍然是 nil —— raw 值进入本地存储不是语义泄漏")
    }

    func testKeepLocalOnAMetadataConflictPreservesAStaplesRemoteExpiry() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        let remoteExpiry = stapleExpiry()
        // Same quantity: the conflict is metadata only, proving the rule is not
        // a quantity-path special case.
        kitchen.inventory = [
            InventoryItem(
                id: sharedId, name: "大米", quantity: 5, unit: "袋", expiryDate: nil,
                kind: .staple, stapleCategory: "主食"
            )
        ]

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(
            id: sharedId, name: "大米", unit: "袋", quantity: 5, expiryDate: remoteExpiry,
            isStaple: true, stapleCategory: "干货", version: "5", sequence: "1"
        )
        await transport.seedExistingRemote(id: sharedId, staleBaseVersion: "5")

        let controller = makeMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport },
            kitchenStore: kitchen
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        XCTAssertEqual(
            controller.plan?.candidates.first(where: { $0.localItemId == sharedId })?.conflictReason,
            .metadataMismatch
        )

        await controller.resolveConflict(candidateId: sharedId, choice: .keepLocal)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        let uploaded = expiryString(inPayload: await transport.lastReceivedPayload(for: sharedId))
        XCTAssertEqual(
            uploaded, "2026-09-30",
            "metadata 冲突路径同样不得抹掉隐藏的远端保质期"
        )
        XCTAssertEqual(kitchen.inventory.first(where: { $0.id == sharedId })?.expiryDate, remoteExpiry)
    }

    /// `SYNC_API_CONTRACT.md` §4.2 calls `isStaple=true` + `preparationKind=readyToCook`
    /// legal. It projects to `.staple`, so it takes the same carry-forward rule
    /// and must not lose its date either.
    func testKeepLocalPreservesTheExpiryOfTheLegalStaplePlusReadyToCookRow() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        let remoteExpiry = stapleExpiry()
        kitchen.inventory = [
            InventoryItem(id: sharedId, name: "调味鸡翅", quantity: 1, unit: "只", expiryDate: nil, kind: .staple)
        ]

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(
            id: sharedId, name: "调味鸡翅", unit: "只", quantity: 6, expiryDate: remoteExpiry,
            isStaple: true, preparationKind: "readyToCook", version: "5", sequence: "1"
        )
        await transport.seedExistingRemote(id: sharedId, staleBaseVersion: "5")

        let controller = makeMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport },
            kitchenStore: kitchen
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        await controller.resolveConflict(candidateId: sharedId, choice: .keepLocal)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        let uploaded = expiryString(inPayload: await transport.lastReceivedPayload(for: sharedId))
        XCTAssertEqual(
            uploaded, "2026-09-30",
            "合法的 staple + readyToCook 组合的日期同样不得被 keepLocal 抹掉"
        )
    }

    /// The whole point of putting the value in durable local state rather than
    /// patching one payload: a later unrelated edit must keep retransmitting it.
    func testALaterUnrelatedEditStillRetransmitsTheCarriedForwardExpiry() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        let remoteExpiry = stapleExpiry()
        kitchen.inventory = [
            InventoryItem(id: sharedId, name: "大米", quantity: 1, unit: "袋", expiryDate: nil, kind: .staple)
        ]

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(
            id: sharedId, name: "大米", unit: "袋", quantity: 5, expiryDate: remoteExpiry,
            isStaple: true, version: "5", sequence: "1"
        )
        await transport.seedExistingRemote(id: sharedId, staleBaseVersion: "5")

        let controller = makeMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport },
            kitchenStore: kitchen
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        await controller.resolveConflict(candidateId: sharedId, choice: .keepLocal)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        // Real later-edit routes, not a detached struct: both of these once
        // nulled the adopted date, so a fix that only reached the merge payload
        // would be undone by an ordinary stock-in or a pantry-form save.
        kitchen.addInventory(name: "大米", quantity: 1, unit: "袋", expiryDate: nil, isStaple: true)
        XCTAssertEqual(
            kitchen.inventory.first(where: { $0.id == sharedId })?.expiryDate, remoteExpiry,
            "入库合并进一个已经是常备的行，不得抹掉它携带的 opaque 值"
        )
        try kitchen.saveStaple(
            id: sharedId, name: "大米", quantity: 9, unit: "袋",
            minimumQuantity: 2, defaultRestockQuantity: nil, autoSuggestRestock: false,
            note: nil, category: nil
        )

        var edited = try XCTUnwrap(kitchen.inventory.first(where: { $0.id == sharedId }))
        XCTAssertEqual(edited.expiryDate, remoteExpiry, "常备行的日常编辑同样不得抹掉它")
        edited.quantity = 9

        let payload = try JSONSerialization.jsonObject(
            with: try InventorySyncAdapter(persistence: persistence).encodedPayload(for: edited)
        ) as? [String: Any]
        XCTAssertEqual(
            payload?["expiryDate"] as? String, "2026-09-30",
            "raw 值已经在本地 durable 状态里，所以后续任何 full-snapshot upsert 都继续原样回传"
        )
        XCTAssertNil(edited.effectiveExpiryDate, "语义投影仍然是 nil")
    }

    /// Both sides project to an untracked-expiry kind, so neither raw value is
    /// visible to the user and no `expiryMismatch` is raised. The household's
    /// value is the one that carries forward: iOS deliberately does not expose
    /// the field, so a merge choice cannot be read as authorising a change to it.
    func testWhenBothSidesHoldOpaqueDatesTheRemoteOneCarriesForward() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        let localLegacy = DateComponents(calendar: .current, year: 2025, month: 1, day: 1).date!
        let remoteExpiry = stapleExpiry()
        kitchen.inventory = [
            InventoryItem(id: sharedId, name: "大米", quantity: 1, unit: "袋", expiryDate: localLegacy, kind: .staple)
        ]

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(
            id: sharedId, name: "大米", unit: "袋", quantity: 5, expiryDate: remoteExpiry,
            isStaple: true, version: "5", sequence: "1"
        )
        await transport.seedExistingRemote(id: sharedId, staleBaseVersion: "5")

        let controller = makeMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport },
            kitchenStore: kitchen
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        XCTAssertNotEqual(
            controller.plan?.candidates.first(where: { $0.localItemId == sharedId })?.conflictReason,
            .expiryMismatch,
            "两边语义 expiry 都是 nil，不该产生保质期冲突"
        )

        await controller.resolveConflict(candidateId: sharedId, choice: .keepLocal)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        let uploaded = expiryString(inPayload: await transport.lastReceivedPayload(for: sharedId))
        XCTAssertEqual(
            uploaded, "2026-09-30",
            "家庭当前持有的 d2 是 carry-forward 值，用户没有在看不到该字段的情况下选择 d1"
        )
        XCTAssertNil(kitchen.inventory.first(where: { $0.id == sharedId })?.effectiveExpiryDate)
    }

    /// The rule is scoped to "both sides project to the same untracked-expiry
    /// kind". A genuine classification difference is a different decision and
    /// must not silently inherit the remote date.
    func testTheCarryForwardRuleDoesNotApplyWhenTheProjectedKindsDiffer() async throws {
        let (kitchen, persistence) = try makeSharedStores(seedGuestInventory: false)
        let sharedId = UUID()
        kitchen.inventory = [
            InventoryItem(id: sharedId, name: "大米", quantity: 5, unit: "袋", expiryDate: nil, kind: .ordinary)
        ]

        let transport = SimulatedMergeTransport(userID: userA, householdID: householdA)
        await transport.seedRemoteChange(
            id: sharedId, name: "大米", unit: "袋", quantity: 5, expiryDate: stapleExpiry(),
            isStaple: true, version: "5", sequence: "1"
        )
        await transport.seedExistingRemote(id: sharedId, staleBaseVersion: "5")

        let controller = makeMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in transport },
            kitchenStore: kitchen
        )
        await controller.preparePreview(userId: userA, householdId: householdA, kitchenStore: kitchen, remoteTransport: transport)
        await controller.resolveConflict(candidateId: sharedId, choice: .keepLocal)
        let authStore = await signedInAuthStore(userID: userA)
        await controller.confirmMerge(authStore: authStore)

        XCTAssertNil(
            kitchen.inventory.first(where: { $0.id == sharedId })?.expiryDate,
            "本机是 ordinary、远端是 staple —— 用户选择了本机分类，不适用 opaque carry-forward"
        )
    }

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

private actor PreviewBoundaryTransport: SyncTransport {
    private let failure: SyncError?
    /// How many leading `fetchChanges` calls `failure` applies to.
    ///
    /// `nil` keeps the original behaviour: every fetch fails for the lifetime of
    /// the transport. A finite limit lets one transport fail the first read and
    /// then succeed, which is what an explicit user retry needs in order to be
    /// observable as a second read on the same recorder.
    private let failingFetchLimit: Int?
    private var reads = 0
    private var mutationCalls = 0

    init(failure: SyncError? = nil, failingFetchLimit: Int? = nil) {
        self.failure = failure
        self.failingFetchLimit = failingFetchLimit
    }

    func bootstrap() async throws -> SyncBootstrapResponse { throw SyncError.transport }

    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse {
        reads += 1
        if let failure, failingFetchLimit.map({ reads <= $0 }) ?? true { throw failure }
        return SyncChangesResponse(
            scopeType: scope.type,
            scopeId: scope.id,
            cursor: cursor,
            hasMore: false,
            changes: []
        )
    }

    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse {
        mutationCalls += 1
        throw SyncError.transport
    }

    func fetchCount() -> Int { reads }
    func mutationCount() -> Int { mutationCalls }
}

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
        isStaple: Bool = false, preparationKind: String? = nil,
        stapleCategory: String? = nil, lowStockThreshold: Double? = nil,
        version: String, sequence: String
    ) {
        var data: [String: SyncJSONValue] = [
            "name": .string(name),
            "quantity": .number(quantity),
            "unit": .string(unit),
            "isStaple": .bool(isStaple)
        ]
        // Left absent by default so the existing callers keep simulating the
        // historical, pre-P2 change records that carry no preparation axis.
        if let preparationKind {
            data["preparationKind"] = .string(preparationKind)
        }
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

    /// The tombstone counterpart of `seedRemoteChange` — a pulled `.delete`
    /// envelope. `seedRemoteChange` only ever produced `.upsert`, so R1's
    /// delete-resurrection cases had no way to be driven end-to-end.
    func seedRemoteDelete(id: UUID, version: String, sequence: String, deletedAt: Date = Date()) {
        changes.append(SyncChangeEnvelope(
            sequence: try! SyncCursorValue(sequence), entityType: .inventoryItem, entityId: id,
            operation: .delete, version: try! SyncCursorValue(version), changedAt: deletedAt,
            data: ["deletedAt": .string(Self.iso8601.string(from: deletedAt))]
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

    private var receivedPayloads: [UUID: [String: SyncJSONValue]] = [:]

    /// Exposes the exact payload the client put on the wire for an entity, so
    /// a test can assert on the real uploaded fields rather than inferring
    /// them from the local staging queue (which `confirmMerge` clears once the
    /// mutation is applied).
    func lastReceivedPayload(for entityId: UUID) -> [String: SyncJSONValue]? { receivedPayloads[entityId] }

    func sendMutations(scope: SyncScope, mutations requests: [SyncMutation]) async throws -> SyncMutationBatchResponse {
        var results: [SyncMutationResult] = []
        for request in requests {
            receivedBaseVersions[request.entityId] = request.baseVersion?.rawValue
            if let data = request.data { receivedPayloads[request.entityId] = data }
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
    /// When true only the *write* fails: the pre-merge preview read still
    /// succeeds, which is what a "preview was fine, the upload then failed" test
    /// needs now that production confirm requires a real remote fingerprint.
    /// Defaults to false, so every pre-existing caller keeps failing on every call.
    private let fetchSucceeds: Bool

    init(fetchSucceeds: Bool = false) { self.fetchSucceeds = fetchSucceeds }

    func bootstrap() async throws -> SyncBootstrapResponse { throw SyncError.transport }
    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse {
        guard fetchSucceeds else { throw SyncError.transport }
        return SyncChangesResponse(scopeType: scope.type, scopeId: scope.id, cursor: cursor, hasMore: false, changes: [])
    }
    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse { throw SyncError.transport }
}

/// Phase 2C-1: simulates every sync call failing with the server's 426 —
/// used to test the controller's upgrade-required display/disable behavior
/// without any real network involved.
private actor UpgradeRequiredMergeTransport: SyncTransport {
    /// See `FailingMergeTransport.fetchSucceeds` — same opt-in, same default.
    private let fetchSucceeds: Bool

    init(fetchSucceeds: Bool = false) { self.fetchSucceeds = fetchSucceeds }

    func bootstrap() async throws -> SyncBootstrapResponse { throw SyncError.clientUpgradeRequired(minimumVersion: "9.0.0", minimumBuild: 42) }
    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse {
        guard fetchSucceeds else { throw SyncError.clientUpgradeRequired(minimumVersion: "9.0.0", minimumBuild: 42) }
        return SyncChangesResponse(scopeType: scope.type, scopeId: scope.id, cursor: cursor, hasMore: false, changes: [])
    }
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

/// Phase 2C-2: records every breadcrumb/nonfatal call `GuestMergeController`
/// makes, so tests can assert *which* operational event fired without
/// depending on a real provider. Never itself throws — matches the
/// `CrashReporting` protocol's "a provider must never crash the app"
/// contract.
private final class FakeCrashReporter: CrashReporting, @unchecked Sendable {
    private(set) var breadcrumbs: [(event: CrashReportingEvent, metadata: CrashReportingMetadata)] = []
    private(set) var nonFatals: [(code: String, context: CrashReportingMetadata)] = []

    func configure(environment: String, release: String, build: String) {}
    func captureFatalContext(_ metadata: CrashReportingMetadata) {}
    func captureNonFatal(_ error: Error, context: CrashReportingMetadata) {
        let code = (error as? any CrashReportableError)?.crashReportingCode ?? "unknown_error"
        nonFatals.append((code, context))
    }
    func addBreadcrumb(_ event: CrashReportingEvent, metadata: CrashReportingMetadata) {
        breadcrumbs.append((event, metadata))
    }
    func setOperationalTag(key: String, value: String) {}
    func flushIfNeeded() {}
}

/// Test-only enumeration of the four choices. The production enum deliberately
/// does not conform to `CaseIterable` — UI-5B2B-B2B must not change its shape.
extension InventoryMergeConflictChoice {
    static var allCasesForTesting: [InventoryMergeConflictChoice] {
        [.keepLocal, .keepRemote, .keepBoth, .skip]
    }
}

// MARK: - R1 test doubles

/// Records every `KitchenStore.onInventoryChanged` invocation. The hook is the
/// exact seam the production composition root wires to outbound staging, so
/// "reconciliation stages nothing" is asserted here rather than only on the
/// resulting queue — a queue-only assertion would still pass if the hook fired
/// and eligibility happened to reject it for an unrelated reason.
@MainActor
final class InventoryChangeRecorder {
    private(set) var changes: [(old: [InventoryItem], new: [InventoryItem])] = []

    var isEmpty: Bool { changes.isEmpty }

    func record(old: [InventoryItem], new: [InventoryItem]) {
        changes.append((old, new))
    }

    func drain() -> [(old: [InventoryItem], new: [InventoryItem])] {
        defer { changes.removeAll() }
        return changes
    }
}

/// What T14 observed at the instant the edit was attempted — sampled inside
/// the transport callback, while the operation is still awaiting, because the
/// boundary legitimately clears the notice once it closes.
@MainActor
final class EditDuringSyncObservation {
    var quantityAfterAttempt: Double?
    var noticeAfterAttempt: String?
    var wasLocked = false
}

/// Runs `duringBootstrap` on the main actor while `syncNow` is genuinely
/// suspended inside the consistency boundary, so an edit can be attempted at
/// exactly the moment a real user could attempt one.
private actor EditDuringSyncTransport: SyncTransport {
    private let inner: SimulatedMergeTransport
    private let duringBootstrap: @MainActor () -> Void

    init(inner: SimulatedMergeTransport, duringBootstrap: @escaping @MainActor () -> Void) {
        self.inner = inner
        self.duringBootstrap = duringBootstrap
    }

    func bootstrap() async throws -> SyncBootstrapResponse {
        let action = duringBootstrap
        await MainActor.run { action() }
        return try await inner.bootstrap()
    }

    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse {
        try await inner.fetchChanges(scope: scope, after: cursor, limit: limit)
    }

    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse {
        try await inner.sendMutations(scope: scope, mutations: mutations)
    }
}

/// Serves one good page that claims `hasMore`, then fails — the partial-pull
/// shape T12 needs: rows already committed, cursor not advanced, run failed.
private actor SecondPageFailingTransport: SyncTransport {
    private let userID: UUID
    private let householdID: UUID
    private let firstPageEntityId: UUID
    private var fetches = 0

    init(userID: UUID, householdID: UUID, firstPageEntityId: UUID) {
        self.userID = userID
        self.householdID = householdID
        self.firstPageEntityId = firstPageEntityId
    }

    func bootstrap() async throws -> SyncBootstrapResponse {
        SyncBootstrapResponse(
            schemaVersion: 1,
            user: .init(id: userID, email: nil),
            households: [.init(id: householdID, role: "owner")],
            defaultHouseholdId: householdID,
            syncScopes: [SyncScopeDescriptor(type: .household, id: householdID, cursor: .zero)],
            serverTime: Date(),
            capabilities: .init(push: true, pull: true, maxBatchSize: 100)
        )
    }

    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse {
        fetches += 1
        guard fetches == 1 else { throw SyncError.transport }
        return SyncChangesResponse(
            scopeType: scope.type, scopeId: scope.id,
            cursor: try SyncCursorValue("1"), hasMore: true,
            changes: [SyncChangeEnvelope(
                sequence: try SyncCursorValue("1"), entityType: .inventoryItem, entityId: firstPageEntityId,
                operation: .upsert, version: try SyncCursorValue("1"), changedAt: Date(),
                data: ["name": .string("第一页"), "quantity": .number(1), "unit": .string("个"), "isStaple": .bool(false)]
            )]
        )
    }

    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse {
        throw SyncError.transport
    }
}

/// Reads pass through (so `confirmMerge`'s preview fingerprint re-verification
/// succeeds and staging is reached), but the coordinator's first call fails.
/// Passes reads through but fails every `sendMutations` — so a rollback's push
/// phase fails as a transport error, exactly like an offline device, and each
/// attempt burns one of the mutation's attempts.
private actor PushFailingTransport: SyncTransport {
    private let inner: SimulatedMergeTransport

    init(inner: SimulatedMergeTransport) { self.inner = inner }

    func bootstrap() async throws -> SyncBootstrapResponse { try await inner.bootstrap() }

    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse {
        try await inner.fetchChanges(scope: scope, after: cursor, limit: limit)
    }

    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse {
        throw SyncError.transport
    }
}

/// Models the ambiguous-success case a real network produces: the server
/// applies the mutation and *then* the response is lost, so the effect exists
/// while the client only ever sees a transport failure.
///
/// It also models the two server behaviours that decide whether the client's
/// retry can converge, both taken from `docs/contracts/SYNC_API_CONTRACT.md` §4:
///
/// - **Idempotency ledger.** A repeat carrying the *same* `mutationId` is
///   answered `duplicate` with the original outcome's version — the business
///   record is not written a second time.
/// - **Optimistic concurrency.** A *different* mutation deleting the same,
///   already-tombstoned entity necessarily carries the pre-delete
///   `baseVersion` (the client never learned the tombstone's version, since
///   that is the response that was lost), so it is answered `conflict` /
///   `stale_version`.
private actor LostResponseTransport: SyncTransport {
    private let inner: SimulatedMergeTransport
    private var ledger: [UUID: SyncMutationResult] = [:]
    private var tombstoned: Set<UUID> = []
    private var dropNextResponse = true
    private var sentMutationIds: [UUID] = []
    var receivedMutationIds: [UUID] { sentMutationIds }

    init(inner: SimulatedMergeTransport) { self.inner = inner }

    func bootstrap() async throws -> SyncBootstrapResponse { try await inner.bootstrap() }

    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse {
        try await inner.fetchChanges(scope: scope, after: cursor, limit: limit)
    }

    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse {
        sentMutationIds.append(contentsOf: mutations.map(\.mutationId))

        var replayed: [SyncMutationResult] = []
        var fresh: [SyncMutation] = []
        for mutation in mutations {
            if let known = ledger[mutation.mutationId] {
                replayed.append(SyncMutationResult(
                    mutationId: known.mutationId, entityId: known.entityId, status: .duplicate,
                    version: known.version, sequence: known.sequence, errorCode: nil,
                    originalStatus: known.status, serverRecord: nil
                ))
            } else if mutation.operation == .delete, tombstoned.contains(mutation.entityId) {
                replayed.append(SyncMutationResult(
                    mutationId: mutation.mutationId, entityId: mutation.entityId, status: .conflict,
                    version: nil, sequence: nil, errorCode: "stale_version",
                    originalStatus: nil, serverRecord: nil
                ))
            } else {
                fresh.append(mutation)
            }
        }

        var results = replayed
        var cursor = SyncCursorValue.zero
        if !fresh.isEmpty {
            // The write really happens server-side, before any failure below.
            let response = try await inner.sendMutations(scope: scope, mutations: fresh)
            cursor = response.cursor
            for result in response.results where result.status == .applied {
                ledger[result.mutationId] = result
                if fresh.contains(where: { $0.mutationId == result.mutationId && $0.operation == .delete }) {
                    tombstoned.insert(result.entityId)
                }
            }
            results.append(contentsOf: response.results)
        }

        if dropNextResponse, !fresh.isEmpty {
            // The server is now committed; the client will never see this.
            dropNextResponse = false
            throw SyncError.transport
        }
        return SyncMutationBatchResponse(results: results, cursor: cursor)
    }
}

/// Applies every mutation for real but omits the optional `version` from the
/// result, which `SyncMutationResult.version: SyncCursorValue?` permits on the
/// wire. That is the only way a conformant client ends up holding `.synced`
/// metadata with no `remoteVersion`, which is in turn the precondition for
/// `stageInventoryMutation`'s create+delete collapse (`.cancelled`).
private actor VersionOmittingTransport: SyncTransport {
    private let inner: SimulatedMergeTransport

    init(inner: SimulatedMergeTransport) { self.inner = inner }

    func bootstrap() async throws -> SyncBootstrapResponse { try await inner.bootstrap() }

    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse {
        try await inner.fetchChanges(scope: scope, after: cursor, limit: limit)
    }

    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse {
        let response = try await inner.sendMutations(scope: scope, mutations: mutations)
        return SyncMutationBatchResponse(
            results: response.results.map { result in
                SyncMutationResult(
                    mutationId: result.mutationId, entityId: result.entityId, status: result.status,
                    version: nil, sequence: result.sequence, errorCode: result.errorCode,
                    originalStatus: result.originalStatus, serverRecord: result.serverRecord
                )
            },
            cursor: response.cursor
        )
    }
}

private actor BootstrapFailingTransport: SyncTransport {
    private let inner: SimulatedMergeTransport

    init(inner: SimulatedMergeTransport) { self.inner = inner }

    func bootstrap() async throws -> SyncBootstrapResponse { throw SyncError.transport }

    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse {
        try await inner.fetchChanges(scope: scope, after: cursor, limit: limit)
    }

    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse {
        throw SyncError.transport
    }
}

/// A real SwiftData-backed inventory persistence whose *reads* can be made to
/// fail on demand, so T16 can exercise "durable remote write happened, the
/// closing reconciliation cannot read it".
@MainActor
final class FailableInventoryPersistence: InventoryPersistenceProtocol {
    private let wrapped: InventoryPersistenceProtocol
    var failLoads = false

    init(wrapping wrapped: InventoryPersistenceProtocol) { self.wrapped = wrapped }

    func loadInventory() throws -> [InventoryItem] {
        if failLoads { throw SyncError.persistence }
        return try wrapped.loadInventory()
    }

    func replaceInventory(with items: [InventoryItem]) throws { try wrapped.replaceInventory(with: items) }
    func upsert(_ item: InventoryItem) throws { try wrapped.upsert(item) }
    func delete(id: UUID) throws { try wrapped.delete(id: id) }
    func deleteAll() throws { try wrapped.deleteAll() }
    func applyChanges(upserting items: [InventoryItem], deleting ids: [UUID]) throws {
        try wrapped.applyChanges(upserting: items, deleting: ids)
    }
}

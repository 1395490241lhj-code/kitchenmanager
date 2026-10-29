import XCTest
import SwiftData
import Combine
@testable import KitchenManager

@MainActor
final class PreparedPortionGroupingPersistenceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "prepared-pr2-persistence-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func bundle() throws -> KitchenPersistenceBundle {
        try KitchenPersistenceFactory.bundle(container: container())
    }
    private func container() throws -> ModelContainer {
        try KitchenPersistenceFactory.makeContainer(configuration: ModelConfiguration(url: directory.appending(path: "kitchen.store")))
    }
    private func persistence(_ b: KitchenPersistenceBundle) throws -> SwiftDataPreparedComponentPersistence {
        try XCTUnwrap(b.preparedComponents as? SwiftDataPreparedComponentPersistence)
    }
    private func groups() throws -> [PreparedComponent] {
        let source = try PreparedSourceSnapshot(id: UUID(), name: "鸡肉", initialMassDecigrams: 8_000, initialPortionCount: 4)
        return try [3, 1].map { count in
            PreparedComponent(name: "鸡肉", portionsRemaining: count, state: .prepped, storage: .frozen,
                preparedAt: Date(timeIntervalSince1970: 100), expiryDate: Date(timeIntervalSince1970: 200),
                grouping: try PreparedPortionGrouping(source: source, massPerPortionDecigrams: 2_000))
        }
    }
    func testGroupedReplaceUpsertDeleteAndRestartKeepEveryField() throws {
        let b = try bundle(); let p = try persistence(b); let original = try groups()
        try p.replaceComponents(with: original)
        XCTAssertEqual(try p.loadComponents(), original)
        XCTAssertEqual(try bundle().preparedComponents.loadComponents(), original)
        var edit = original[0]; edit.name = "改名"
        try p.upsert(edit)
        XCTAssertEqual(try bundle().preparedComponents.loadComponents(), [edit, original[1]])
        try p.delete(id: original[1].id)
        XCTAssertEqual(try bundle().preparedComponents.loadComponents(), [edit])
    }
    func testDuplicateIDsRejectedBeforeDictionaryCanCoalesceThem() throws {
        let p = try persistence(bundle()); let original = try groups()
        try p.replaceComponents(with: original)
        XCTAssertThrowsError(try p.replaceComponents(with: [original[0], original[0]]))
        XCTAssertEqual(try p.loadComponents(), original)
        XCTAssertEqual(try bundle().preparedComponents.loadComponents(), original)
    }
    func testUpsertCannotExceedSourceBucket() throws {
        let p = try persistence(bundle()); let original = try groups()
        try p.replaceComponents(with: original)
        var extra = original[1]; extra.id = UUID()
        XCTAssertThrowsError(try p.upsert(extra))
        XCTAssertEqual(try bundle().preparedComponents.loadComponents(), original)
    }
    func testCorruptBlobMakesLoadAndEveryMutationFailClosed() throws {
        let b = try bundle(); let p = try persistence(b); let original = try groups()
        try p.replaceComponents(with: original)
        let raw = ModelContext(p.container)
        let row = try XCTUnwrap(raw.fetch(FetchDescriptor<PreparedComponentRecord>()).first)
        row.portionGroupingData = Data("not-json".utf8); try raw.save()
        XCTAssertThrowsError(try p.loadComponents())
        XCTAssertThrowsError(try p.replaceComponents(with: []))
        XCTAssertThrowsError(try p.upsert(original[0]))
        XCTAssertThrowsError(try p.delete(id: original[0].id))
        XCTAssertThrowsError(try p.deleteAll())
        XCTAssertEqual(try ModelContext(p.container).fetchCount(FetchDescriptor<PreparedComponentRecord>()), 2)
    }
    func testCorruptLoadKeepsStoreUnavailableAndCannotClearOrPublish() throws {
        let b = try bundle(); let p = try persistence(b); let original = try groups()
        try p.replaceComponents(with: original)
        let context = ModelContext(p.container)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<PreparedComponentRecord>()).first)
        row.portionGroupingData = Data("broken".utf8); try context.save()
        let suite = "prepared-pr2-unavailable-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KitchenStore(userDefaults: defaults, persistence: b)
        XCTAssertTrue(store.isPreparedComponentUnavailable)
        XCTAssertEqual(store.consumePreparedPortion(id: original[0].id), .failure(.unavailable))
        XCTAssertFalse(store.clearAllLocalData())
        XCTAssertThrowsError(try store.reloadPreparedComponents().get())
        XCTAssertTrue(store.isPreparedComponentUnavailable)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PreparedComponentRecord>()), 2)
    }
    func testVersionedRecordDecodeNeverFallsBackToLegacy() throws {
        let b = try bundle(); let p = try persistence(b); let original = try groups()
        try p.replaceComponents(with: original)
        let context = ModelContext(p.container)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<PreparedComponentRecord>()).first)
        let metadata = try XCTUnwrap(original[0].grouping)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        object["version"] = 99
        row.portionGroupingData = try JSONSerialization.data(withJSONObject: object); try context.save()
        XCTAssertThrowsError(try row.decodePreparedComponent())
        XCTAssertThrowsError(try bundle().preparedComponents.loadComponents())
    }
    func testIndividuallyValidConflictingSourceBlobsFailCollectionLoad() throws {
        let b = try bundle(); let p = try persistence(b); let original = try groups()
        try p.replaceComponents(with: original)
        let context = ModelContext(p.container)
        let rows = try context.fetch(FetchDescriptor<PreparedComponentRecord>())
        let row = try XCTUnwrap(rows.first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(row.portionGroupingData)) as? [String: Any])
        var source = try XCTUnwrap(object["source"] as? [String: Any])
        source["name"] = "同一来源的矛盾原名"; object["source"] = source
        row.portionGroupingData = try JSONSerialization.data(withJSONObject: object); try context.save()
        for row in rows { XCTAssertNoThrow(try row.decodePreparedComponent()) }
        XCTAssertThrowsError(try bundle().preparedComponents.loadComponents()) { error in
            XCTAssertEqual(error as? PreparedGroupingValidationError, .inconsistentSource)
        }
    }

    func testIndividuallyValidRowsExceedingOriginalBucketFailCollectionLoad() throws {
        let b = try bundle(); let p = try persistence(b); let original = try groups()
        try p.replaceComponents(with: original)
        let context = ModelContext(p.container)
        let rows = try context.fetch(FetchDescriptor<PreparedComponentRecord>())
        let row = try XCTUnwrap(rows.first { $0.portionsRemaining == 1 })
        row.portionsRemaining = 2; try context.save()
        for row in rows { XCTAssertNoThrow(try row.decodePreparedComponent()) }
        XCTAssertThrowsError(try p.loadComponents()) { error in
            XCTAssertEqual(error as? PreparedGroupingValidationError, .invalidAllocation)
        }
    }

    func testPaddedNamesRoundTripAndAllowConsecutiveWritesWithoutReload() throws {
        for grouped in [false, true] {
            let p = try persistence(bundle())
            var original = try groups()
            if !grouped { for i in original.indices { original[i].grouping = nil } }
            original[0].name = " 鸡肉 "
            original[0] = try JSONDecoder().decode(PreparedComponent.self, from: JSONEncoder().encode(original[0]))
            try p.replaceComponents(with: original)
            var edit = original[0]; edit.expiryDate = edit.expiryDate.addingTimeInterval(10)
            XCTAssertNoThrow(try p.upsert(edit), "no intervening load or other writer")
            XCTAssertNoThrow(try p.delete(id: original[1].id))
            XCTAssertEqual(try bundle().preparedComponents.loadComponents(), [edit])
        }
    }

    private final class ClearFailureWeekly: WeeklyPlanPersistenceProtocol {
        let base: WeeklyPlanPersistenceProtocol
        init(base: WeeklyPlanPersistenceProtocol) { self.base = base }
        func loadPlan() throws -> WeeklyMealPlan? { try base.loadPlan() }
        func replacePlan(with plan: WeeklyMealPlan?) throws { try base.replacePlan(with: plan) }
        func deleteAll() throws { throw NSError(domain: "synthetic-clear", code: 1) }
    }

    func testFailedClearCompensatesAllLinkedMetadataAcrossRestart() throws {
        let b = try bundle(); let p = try persistence(b); let original = try groups()
        try p.replaceComponents(with: original)
        let suite = "prepared-pr2-clear-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KitchenStore(userDefaults: defaults, inventoryPersistence: b.inventory,
            shoppingListPersistence: b.shoppingList, todayPlanPersistence: b.todayPlan,
            consumptionPersistence: b.consumption, weeklyPlanPersistence: ClearFailureWeekly(base: b.weeklyPlan),
            preparedComponentPersistence: p, specialPlanPersistence: b.specialPlans)
        XCTAssertFalse(store.clearAllLocalData())
        XCTAssertEqual(store.preparedComponents, original)
        XCTAssertEqual(try p.loadComponents(), original)
        XCTAssertEqual(try bundle().preparedComponents.loadComponents(), original)
    }

    func testFailedReplacementWithDeletionAndInsertionPreservesOriginalGroups() throws {
        let p = try persistence(bundle()); let original = try groups()
        try p.replaceComponents(with: original)
        var kept = original[0]; kept.portionsRemaining = 2
        var added = original[1]; added.id = UUID()
        let proposed = [kept, added]
        p.failNextReplaceSaveForTesting = NSError(domain: "synthetic", code: 1)
        XCTAssertThrowsError(try p.replaceComponents(with: proposed))
        XCTAssertEqual(try p.loadComponents(), original)
        XCTAssertEqual(try bundle().preparedComponents.loadComponents(), original)
        try p.replaceComponents(with: proposed)
        XCTAssertEqual(try bundle().preparedComponents.loadComponents(), proposed)
    }

    func testStalePersistenceSnapshotCannotOverwriteAnotherWriter() throws {
        let b = try bundle(); let first = try persistence(b); let original = try groups()
        try first.replaceComponents(with: original)
        let stale = try persistence(bundle()); _ = try stale.loadComponents()
        var changed = original; changed[0].portionsRemaining = 2
        try first.replaceComponents(with: changed)
        XCTAssertThrowsError(try stale.replaceComponents(with: original))
        XCTAssertEqual(try bundle().preparedComponents.loadComponents(), changed)
        _ = try stale.loadComponents()
        XCTAssertNoThrow(try stale.replaceComponents(with: changed))
    }
    func testFailedSaveRollsBackLinkedRowsAndAllowsOneRetry() throws {
        let p = try persistence(bundle()); let original = try groups()
        try p.replaceComponents(with: original)
        var proposed = original; proposed[0].portionsRemaining = 2
        p.failNextReplaceSaveForTesting = NSError(domain: "synthetic", code: 1)
        XCTAssertThrowsError(try p.replaceComponents(with: proposed))
        XCTAssertEqual(try p.loadComponents(), original)
        XCTAssertEqual(try bundle().preparedComponents.loadComponents(), original)
        try p.replaceComponents(with: proposed)
        XCTAssertEqual(try bundle().preparedComponents.loadComponents(), proposed)
    }
    func testExistingEditorCannotDetachGroupingOrRewriteGroupedQuantity() throws {
        let b = try bundle(); let p = try persistence(b); let original = try groups()
        try p.replaceComponents(with: original)
        let suite = "prepared-pr2-editor-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KitchenStore(userDefaults: defaults, persistence: b)
        for kind in 0..<3 {
            try p.replaceComponents(with: original)
            try store.reloadPreparedComponents().get()
            var draft = original[0]
            if kind == 0 { draft.grouping = nil }
            if kind == 1 { draft.portionsRemaining = 2 }
            if kind == 2 { draft.storage = .refrigerated }
            XCTAssertEqual(store.updatePreparedComponent(draft, expected: original[0]), .failure(.staleRecord))
        }
        XCTAssertEqual(try p.loadComponents(), original)
        XCTAssertEqual(store.preparedComponents, original)
    }
    func testStorePersistsBeforePublishingAndRejectsStaleEditor() throws {
        let b = try bundle(); let p = try persistence(b); let original = try groups()
        try p.replaceComponents(with: original)
        let suite = "prepared-pr2-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KitchenStore(userDefaults: defaults, persistence: b)
        var seen: [[PreparedComponent]] = []; var diskAtPublish: [[PreparedComponent]] = []
        let observation = store.$preparedComponents.dropFirst().sink { value in
            seen.append(value); diskAtPublish.append((try? self.bundle().preparedComponents.loadComponents()) ?? [])
        }
        defer { observation.cancel() }
        p.failNextReplaceSaveForTesting = NSError(domain: "synthetic", code: 1)
        XCTAssertEqual(store.consumePreparedPortion(id: original[0].id), .failure(.saveFailed))
        XCTAssertTrue(seen.isEmpty)
        XCTAssertEqual(store.preparedComponents, original)
        XCTAssertEqual(store.consumePreparedPortion(id: original[0].id), .success(original[0]))
        var expected = original; expected[0].portionsRemaining = 2
        XCTAssertEqual(seen, [expected]); XCTAssertEqual(diskAtPublish, [expected])
        XCTAssertEqual(store.updatePreparedComponent(original[0], expected: original[0]), .failure(.staleRecord))
    }
}

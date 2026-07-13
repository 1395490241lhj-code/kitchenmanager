import XCTest
@testable import KitchenManager

@MainActor
final class ConsumptionPersistenceTests: XCTestCase {
    private func makePersistence() throws -> SwiftDataConsumptionPersistence {
        try SwiftDataConsumptionPersistence(isStoredInMemoryOnly: true)
    }

    private func makeItem(
        inventoryID: UUID = UUID(),
        name: String = "番茄",
        previous: Double = 5,
        consumed: Double = 2,
        resulting: Double = 3
    ) -> InventoryConsumptionRecordItem {
        InventoryConsumptionRecordItem(
            inventoryItemID: inventoryID,
            ingredientName: name,
            consumedQuantity: consumed,
            unit: "个",
            previousQuantity: previous,
            resultingQuantity: resulting
        )
    }

    private func makeRecord(
        id: UUID = UUID(),
        date: Date = Date(timeIntervalSince1970: 1_700_000_000),
        recipeID: String? = "recipe-1",
        recipeName: String = "番茄炒蛋",
        planIDs: [UUID] = [UUID()],
        items: [InventoryConsumptionRecordItem]? = nil,
        isUndone: Bool = false
    ) -> InventoryConsumptionRecord {
        InventoryConsumptionRecord(
            id: id,
            date: date,
            recipeID: recipeID,
            recipeName: recipeName,
            planIDs: planIDs,
            items: items ?? [makeItem()],
            isUndone: isUndone
        )
    }

    private func makeStore(
        defaults: UserDefaults,
        bundle: KitchenPersistenceBundle
    ) -> KitchenStore {
        KitchenStore(
            userDefaults: defaults,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList,
            todayPlanPersistence: bundle.todayPlan,
            consumptionPersistence: bundle.consumption
        )
    }

    func testEmptyDatabaseLoadsEmpty() throws {
        XCTAssertEqual(try makePersistence().loadRecords(), [])
    }

    func testUpsertRoundTripsEveryBusinessFieldIncludingAllEntries() throws {
        let persistence = try makePersistence()
        let first = makeItem(name: "番茄")
        let second = makeItem(name: "鸡蛋", previous: 3, consumed: 1, resulting: 2)
        let record = makeRecord(items: [first, second], isUndone: true)
        try persistence.upsert(record)
        XCTAssertEqual(try persistence.loadRecords(), [record])
    }

    func testUpsertUpdatesSameIDInsteadOfDuplicating() throws {
        let persistence = try makePersistence()
        let id = UUID()
        try persistence.upsert(makeRecord(id: id, recipeName: "第一次"))
        try persistence.upsert(makeRecord(id: id, recipeName: "更新后", isUndone: true))
        let loaded = try persistence.loadRecords()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].recipeName, "更新后")
        XCTAssertTrue(loaded[0].isUndone)
    }

    func testReplacePreservesStableNewestFirstOrderAndRemovesMissingRecords() throws {
        let persistence = try makePersistence()
        let newest = makeRecord(recipeName: "最新")
        let middle = makeRecord(recipeName: "中间")
        let oldest = makeRecord(recipeName: "最早")
        try persistence.replaceRecords(with: [newest, middle, oldest])
        XCTAssertEqual(try persistence.loadRecords().map(\.id), [newest.id, middle.id, oldest.id])
        try persistence.replaceRecords(with: [oldest, newest])
        XCTAssertEqual(try persistence.loadRecords().map(\.id), [oldest.id, newest.id])
    }

    func testDeleteAndDeleteAll() throws {
        let persistence = try makePersistence()
        let first = makeRecord(recipeName: "第一条")
        let second = makeRecord(recipeName: "第二条")
        try persistence.replaceRecords(with: [first, second])
        try persistence.delete(id: first.id)
        XCTAssertEqual(try persistence.loadRecords(), [second])
        try persistence.deleteAll()
        XCTAssertTrue(try persistence.loadRecords().isEmpty)
    }

    func testLegacyMigrationPreservesUndoneEntriesAndLegacyJSON() throws {
        let persistence = try makePersistence()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let legacy = [makeRecord(items: [makeItem(), makeItem(name: "鸡蛋")], isUndone: true)]
        let data = try JSONEncoder().encode(legacy)
        defaults.set(data, forKey: ConsumptionMigration.legacyRecordsKey)
        let migrated = try ConsumptionMigration.migrateIfNeeded(userDefaults: defaults, persistence: persistence)
        XCTAssertEqual(migrated, legacy)
        XCTAssertTrue(defaults.bool(forKey: ConsumptionMigration.completionKey))
        XCTAssertEqual(defaults.data(forKey: ConsumptionMigration.legacyRecordsKey), data)
    }

    func testMigrationIsIdempotentAndExistingSameIDWins() throws {
        let persistence = try makePersistence()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let sharedID = UUID()
        let persisted = makeRecord(id: sharedID, recipeName: "SwiftData 优先")
        let legacyOnly = makeRecord(recipeName: "旧数据补充")
        try persistence.upsert(persisted)
        defaults.set(try JSONEncoder().encode([makeRecord(id: sharedID, recipeName: "旧数据"), legacyOnly]), forKey: ConsumptionMigration.legacyRecordsKey)
        _ = try ConsumptionMigration.migrateIfNeeded(userDefaults: defaults, persistence: persistence)
        _ = try ConsumptionMigration.migrateIfNeeded(userDefaults: defaults, persistence: persistence)
        let records = try persistence.loadRecords()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first(where: { $0.id == sharedID })?.recipeName, "SwiftData 优先")
    }

    func testMigrationFailureKeepsLegacyAndDoesNotMarkComplete() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let data = try JSONEncoder().encode([makeRecord()])
        defaults.set(data, forKey: ConsumptionMigration.legacyRecordsKey)
        XCTAssertThrowsError(try ConsumptionMigration.migrateIfNeeded(userDefaults: defaults, persistence: FailingTestConsumptionPersistence()))
        XCTAssertFalse(defaults.bool(forKey: ConsumptionMigration.completionKey))
        XCTAssertEqual(defaults.data(forKey: ConsumptionMigration.legacyRecordsKey), data)
    }

    func testStoreRestartUndoAndRepeatedUndoPersist() throws {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var store = makeStore(defaults: defaults, bundle: bundle)
        store.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)
        let itemID = try XCTUnwrap(store.inventory.first?.id)
        let draft = InventoryConsumptionDraft(
            id: "tomato", ingredientName: "番茄", normalizedName: "番茄", requiredQuantity: 2,
            requiredUnit: "个", matchedInventoryID: itemID, currentQuantity: 5, consumedQuantity: 2,
            resultingQuantity: 3, isSelected: true, warning: nil, sourceRecipeNames: ["菜"]
        )
        let record = store.applyConsumption([draft], planIDs: [UUID()], recipeID: "recipe", recipeName: "菜")
        XCTAssertEqual(store.inventory.first?.quantity, 3)
        store = makeStore(defaults: defaults, bundle: bundle)
        XCTAssertEqual(store.consumptionRecords, [record])
        store.undoConsumption(record)
        XCTAssertEqual(store.inventory.first?.quantity, 5)
        store.undoConsumption(record)
        let restarted = makeStore(defaults: defaults, bundle: bundle)
        XCTAssertTrue(try XCTUnwrap(restarted.consumptionRecords.first).isUndone)
        XCTAssertEqual(restarted.inventory.first?.quantity, 5)
    }

    func testApplyFailureRollsBackInventoryAndDoesNotPublishRecord() throws {
        let inventory = InventoryPersistenceFactory.isolatedInMemory()
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            inventoryPersistence: inventory,
            shoppingListPersistence: bundle.shoppingList,
            todayPlanPersistence: bundle.todayPlan,
            consumptionPersistence: FailingTestConsumptionPersistence()
        )
        store.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)
        let itemID = try XCTUnwrap(store.inventory.first?.id)
        let draft = InventoryConsumptionDraft(
            id: "tomato", ingredientName: "番茄", normalizedName: "番茄", requiredQuantity: 2,
            requiredUnit: "个", matchedInventoryID: itemID, currentQuantity: 5, consumedQuantity: 2,
            resultingQuantity: 3, isSelected: true, warning: nil, sourceRecipeNames: ["菜"]
        )
        _ = store.applyConsumption([draft], planIDs: [], recipeID: nil, recipeName: "菜")
        XCTAssertEqual(store.inventory.first?.quantity, 5)
        XCTAssertTrue(store.consumptionRecords.isEmpty)
        XCTAssertEqual(try inventory.loadInventory().first?.quantity, 5)
    }

    func testUndoFailureDoesNotMarkRecordUndoneOrChangeInventory() throws {
        let inventory = InventoryPersistenceFactory.isolatedInMemory()
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let record = makeRecord()
        let stock = InventoryItem(id: record.items[0].inventoryItemID, name: "番茄", quantity: 3, unit: "个", expiryDate: nil)
        try inventory.replaceInventory(with: [stock])
        defaults.set(try JSONEncoder().encode([record]), forKey: ConsumptionMigration.legacyRecordsKey)
        let store = KitchenStore(
            userDefaults: defaults,
            inventoryPersistence: inventory,
            shoppingListPersistence: bundle.shoppingList,
            todayPlanPersistence: bundle.todayPlan,
            consumptionPersistence: FailingTestConsumptionPersistence()
        )
        store.undoConsumption(record)
        XCTAssertEqual(store.inventory.first?.quantity, 3)
        XCTAssertFalse(store.consumptionRecords.first?.isUndone ?? true)
        XCTAssertEqual(try inventory.loadInventory().first?.quantity, 3)
    }

    func testBackupRestorePersistsUndoneRecordsAndClearRemovesThem() throws {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = makeStore(defaults: defaults, bundle: bundle)
        let record = makeRecord(isUndone: true)
        let payload = KitchenBackupPayload(inventory: [], plans: [], shoppingItems: [], weeklyPlan: nil, consumptionRecords: [record])
        let data = try JSONEncoder().encode(payload)
        try store.restoreBackupData(data)
        XCTAssertEqual(try bundle.consumption.loadRecords(), [record])
        XCTAssertEqual(makeStore(defaults: defaults, bundle: bundle).consumptionRecords, [record])
        store.clearAllLocalData()
        XCTAssertTrue(try bundle.consumption.loadRecords().isEmpty)
    }
}

@MainActor
private final class FailingTestConsumptionPersistence: ConsumptionPersistenceProtocol {
    struct ExpectedFailure: Error {}
    func loadRecords() throws -> [InventoryConsumptionRecord] { throw ExpectedFailure() }
    func replaceRecords(with records: [InventoryConsumptionRecord]) throws { throw ExpectedFailure() }
    func upsert(_ record: InventoryConsumptionRecord) throws { throw ExpectedFailure() }
    func delete(id: UUID) throws { throw ExpectedFailure() }
    func deleteAll() throws { throw ExpectedFailure() }
}

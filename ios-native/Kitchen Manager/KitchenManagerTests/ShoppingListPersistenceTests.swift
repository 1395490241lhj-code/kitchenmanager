import Combine
import Foundation
import XCTest
@testable import KitchenManager

@MainActor
final class ShoppingListPersistenceTests: XCTestCase {
    private func makePersistence() throws -> SwiftDataShoppingListPersistence {
        try SwiftDataShoppingListPersistence(isStoredInMemoryOnly: true)
    }

    private func makeItem(
        id: UUID = UUID(),
        name: String = "鸡蛋",
        quantity: Double = 6,
        isDone: Bool = false
    ) -> KitchenShoppingItem {
        KitchenShoppingItem(
            id: id,
            name: name,
            quantity: quantity,
            unit: "个",
            source: "来自常备货架",
            isDone: isDone,
            remark: "买散养的"
        )
    }

    func testEmptyDatabaseLoadsEmpty() throws {
        XCTAssertEqual(try makePersistence().loadShoppingItems(), [])
    }

    func testUpsertRoundTripsEveryBusinessField() throws {
        let persistence = try makePersistence()
        let item = makeItem(isDone: true)
        try persistence.upsert(item)
        XCTAssertEqual(try persistence.loadShoppingItems(), [item])
    }

    func testUpsertUpdatesSameIDInsteadOfDuplicating() throws {
        let persistence = try makePersistence()
        let id = UUID()
        try persistence.upsert(makeItem(id: id, quantity: 2))
        try persistence.upsert(makeItem(id: id, quantity: 9, isDone: true))
        let loaded = try persistence.loadShoppingItems()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.quantity, 9)
        XCTAssertEqual(loaded.first?.isDone, true)
    }

    func testReplaceDeduplicatesSameIDUsingLatestSnapshot() throws {
        let persistence = try makePersistence()
        let id = UUID()
        try persistence.replaceShoppingItems(with: [
            makeItem(id: id, quantity: 2),
            makeItem(id: id, quantity: 9)
        ])
        XCTAssertEqual(try persistence.loadShoppingItems().map(\.quantity), [9])
    }

    func testSameNameDifferentIDsRemainSeparate() throws {
        let persistence = try makePersistence()
        try persistence.replaceShoppingItems(with: [makeItem(), makeItem()])
        XCTAssertEqual(try persistence.loadShoppingItems().count, 2)
    }

    func testReplacePreservesStableArrayOrderAndRemovesMissingRecords() throws {
        let persistence = try makePersistence()
        let first = makeItem(name: "牛奶")
        let second = makeItem(name: "鸡蛋", isDone: true)
        let third = makeItem(name: "番茄")
        try persistence.replaceShoppingItems(with: [first, second, third])
        XCTAssertEqual(try persistence.loadShoppingItems().map(\.id), [first.id, second.id, third.id])
        try persistence.replaceShoppingItems(with: [third, first])
        XCTAssertEqual(try persistence.loadShoppingItems().map(\.id), [third.id, first.id])
    }

    func testDeleteAndDeleteAll() throws {
        let persistence = try makePersistence()
        let first = makeItem(name: "鸡蛋")
        let second = makeItem(name: "牛奶")
        try persistence.replaceShoppingItems(with: [first, second])
        try persistence.delete(id: first.id)
        XCTAssertEqual(try persistence.loadShoppingItems(), [second])
        try persistence.deleteAll()
        XCTAssertTrue(try persistence.loadShoppingItems().isEmpty)
    }

    func testLegacyMigrationPreservesDoneSourceRemarkAndOldJSON() throws {
        let persistence = try makePersistence()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let legacy = [makeItem(isDone: true)]
        let data = try JSONEncoder().encode(legacy)
        defaults.set(data, forKey: ShoppingListMigration.legacyShoppingKey)

        let migrated = try ShoppingListMigration.migrateIfNeeded(
            userDefaults: defaults,
            persistence: persistence
        )

        XCTAssertEqual(migrated, legacy)
        XCTAssertTrue(defaults.bool(forKey: ShoppingListMigration.completionKey))
        XCTAssertEqual(defaults.data(forKey: ShoppingListMigration.legacyShoppingKey), data)
    }

    func testMigrationIsIdempotent() throws {
        let persistence = try makePersistence()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(try JSONEncoder().encode([makeItem()]), forKey: ShoppingListMigration.legacyShoppingKey)
        _ = try ShoppingListMigration.migrateIfNeeded(userDefaults: defaults, persistence: persistence)
        _ = try ShoppingListMigration.migrateIfNeeded(userDefaults: defaults, persistence: persistence)
        XCTAssertEqual(try persistence.loadShoppingItems().count, 1)
    }

    func testMigrationKeepsSwiftDataSameIDAndAddsMissingLegacyID() throws {
        let persistence = try makePersistence()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let sharedID = UUID()
        let persisted = makeItem(id: sharedID, quantity: 10)
        try persistence.upsert(persisted)
        defaults.set(
            try JSONEncoder().encode([
                makeItem(id: sharedID, quantity: 1),
                makeItem(name: "牛奶")
            ]),
            forKey: ShoppingListMigration.legacyShoppingKey
        )
        let migrated = try ShoppingListMigration.migrateIfNeeded(
            userDefaults: defaults,
            persistence: persistence
        )
        XCTAssertEqual(migrated.count, 2)
        XCTAssertEqual(migrated.first(where: { $0.id == sharedID })?.quantity, 10)
    }

    func testMigrationFailureKeepsLegacyAndDoesNotMarkComplete() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let data = try JSONEncoder().encode([makeItem()])
        defaults.set(data, forKey: ShoppingListMigration.legacyShoppingKey)
        let persistence = FailingTestShoppingListPersistence()
        XCTAssertThrowsError(
            try ShoppingListMigration.migrateIfNeeded(
                userDefaults: defaults,
                persistence: persistence
            )
        )
        XCTAssertFalse(defaults.bool(forKey: ShoppingListMigration.completionKey))
        XCTAssertEqual(defaults.data(forKey: ShoppingListMigration.legacyShoppingKey), data)
    }

    func testStoreAddEditToggleDeleteClearAndRestartPersist() throws {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = KitchenStore(
            userDefaults: defaults,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList
        )
        store.addShopping(name: "鸡蛋", quantity: 2, unit: "个", remark: "新鲜")
        store.shoppingItems[0].remark = "本地蛋"
        store.toggleShopping(store.shoppingItems[0])
        store.addShopping(name: "牛奶", quantity: 1, unit: "盒")
        store.deleteShopping(store.shoppingItems[1].id)
        let restarted = KitchenStore(
            userDefaults: defaults,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList
        )
        XCTAssertEqual(restarted.shoppingItems.count, 1)
        XCTAssertEqual(restarted.shoppingItems[0].remark, "本地蛋")
        XCTAssertTrue(restarted.shoppingItems[0].isDone)
        restarted.clearCompletedShopping()
        XCTAssertTrue(try bundle.shoppingList.loadShoppingItems().isEmpty)
    }

    func testBatchAddPublishesAndPersistsOnlyFinalSnapshotOnce() {
        let inventory = InventoryPersistenceFactory.isolatedInMemory()
        let shopping = CountingShoppingListPersistence()
        let store = KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            inventoryPersistence: inventory,
            shoppingListPersistence: shopping
        )
        let baselineWrites = shopping.replaceCallCount
        var publishedCounts: [Int] = []
        let cancellable = store.$shoppingItems.sink { publishedCounts.append($0.count) }
        store.addShoppingItems([
            makeItem(name: "鸡蛋"),
            makeItem(name: "牛奶"),
            makeItem(name: "番茄")
        ])
        cancellable.cancel()
        XCTAssertEqual(publishedCounts, [0, 3])
        XCTAssertEqual(shopping.replaceCallCount - baselineWrites, 1)
    }

    func testStockInCompletedPersistsInventoryAndRemovesOnlyCompletedShopping() throws {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = KitchenStore(
            userDefaults: defaults,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList
        )
        store.addShoppingItems([
            makeItem(name: "鸡蛋", quantity: 2, isDone: true),
            makeItem(name: "牛奶", quantity: 1, isDone: false)
        ])
        store.stockInCompletedShopping()
        XCTAssertEqual(store.inventory.map(\.name), ["鸡蛋"])
        XCTAssertEqual(store.shoppingItems.map(\.name), ["牛奶"])

        let restarted = KitchenStore(
            userDefaults: defaults,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList
        )
        XCTAssertEqual(restarted.inventory.map(\.name), ["鸡蛋"])
        XCTAssertEqual(restarted.shoppingItems.map(\.name), ["牛奶"])
    }

    func testStockInShoppingFailureRollsBackInventoryAndKeepsShoppingInMemory() throws {
        let inventory = InventoryPersistenceFactory.isolatedInMemory()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let completed = makeItem(isDone: true)
        defaults.set(try JSONEncoder().encode([completed]), forKey: ShoppingListMigration.legacyShoppingKey)
        let store = KitchenStore(
            userDefaults: defaults,
            inventoryPersistence: inventory,
            shoppingListPersistence: FailingTestShoppingListPersistence()
        )
        store.stockInCompletedShopping()
        XCTAssertTrue(try inventory.loadInventory().isEmpty)
        XCTAssertEqual(store.shoppingItems, [completed])
    }

    func testBackupRestorePersistsShoppingAndKeepsBackupShape() throws {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = KitchenStore(
            userDefaults: defaults,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList
        )
        let item = makeItem(isDone: true)
        let payload = KitchenBackupPayload(
            inventory: [],
            plans: [],
            shoppingItems: [item],
            weeklyPlan: nil,
            consumptionRecords: []
        )
        let data = try JSONEncoder().encode(payload)
        try store.restoreBackupData(data)
        XCTAssertEqual(try bundle.shoppingList.loadShoppingItems(), [item])
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let restarted = KitchenStore(
            userDefaults: defaults,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList
        )
        XCTAssertEqual(restarted.shoppingItems, [item])
    }

    func testClearAllLocalDataClearsBothSwiftDataModels() throws {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList
        )
        store.addInventory(name: "番茄", quantity: 1, unit: "个", expiryDate: nil)
        store.addShopping(name: "牛奶")
        store.clearAllLocalData()
        XCTAssertTrue(try bundle.inventory.loadInventory().isEmpty)
        XCTAssertTrue(try bundle.shoppingList.loadShoppingItems().isEmpty)
    }
}

@MainActor
private final class CountingShoppingListPersistence: ShoppingListPersistenceProtocol {
    var items: [KitchenShoppingItem] = []
    var replaceCallCount = 0
    func loadShoppingItems() throws -> [KitchenShoppingItem] { items }
    func replaceShoppingItems(with items: [KitchenShoppingItem]) throws {
        replaceCallCount += 1
        self.items = items
    }
    func upsert(_ item: KitchenShoppingItem) throws {}
    func delete(id: UUID) throws {}
    func deleteAll() throws { items = [] }
}

@MainActor
private final class FailingTestShoppingListPersistence: ShoppingListPersistenceProtocol {
    struct ExpectedFailure: Error {}
    func loadShoppingItems() throws -> [KitchenShoppingItem] { throw ExpectedFailure() }
    func replaceShoppingItems(with items: [KitchenShoppingItem]) throws { throw ExpectedFailure() }
    func upsert(_ item: KitchenShoppingItem) throws { throw ExpectedFailure() }
    func delete(id: UUID) throws { throw ExpectedFailure() }
    func deleteAll() throws { throw ExpectedFailure() }
}

import Foundation
import XCTest
@testable import KitchenManager

@MainActor
final class InventoryPersistenceTests: XCTestCase {
    private func makePersistence() throws -> SwiftDataInventoryPersistence {
        try SwiftDataInventoryPersistence(isStoredInMemoryOnly: true)
    }

    private func makeItem(
        id: UUID = UUID(),
        name: String = "鸡蛋",
        quantity: Double = 6
    ) -> InventoryItem {
        InventoryItem(
            id: id,
            name: name,
            quantity: quantity,
            unit: "个",
            expiryDate: Date(timeIntervalSince1970: 2_000_000),
            isStaple: true,
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_500_000),
            lowStockThreshold: 4,
            defaultRestockQuantity: 12,
            autoSuggestRestock: true,
            stapleNote: "早餐",
            stapleCategory: "蛋奶",
            stapleTrackingMode: .quantity,
            stapleAvailabilityStatus: .low
        )
    }

    func testEmptyDatabaseLoadsEmpty() throws {
        XCTAssertEqual(try makePersistence().loadInventory(), [])
    }

    func testUpsertRoundTripsEveryInventoryField() throws {
        let persistence = try makePersistence()
        let item = makeItem()
        try persistence.upsert(item)
        XCTAssertEqual(try persistence.loadInventory(), [item])
    }

    func testUpsertUpdatesSameIDInsteadOfDuplicating() throws {
        let persistence = try makePersistence()
        let id = UUID()
        try persistence.upsert(makeItem(id: id, quantity: 2))
        try persistence.upsert(makeItem(id: id, quantity: 9))
        let loaded = try persistence.loadInventory()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.quantity, 9)
    }

    func testReplaceDeduplicatesSameIDUsingLatestSnapshot() throws {
        let persistence = try makePersistence()
        let id = UUID()
        try persistence.replaceInventory(with: [
            makeItem(id: id, quantity: 2),
            makeItem(id: id, quantity: 9)
        ])
        let loaded = try persistence.loadInventory()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.quantity, 9)
    }

    func testSameNameWithDifferentIDsRemainsSeparate() throws {
        let persistence = try makePersistence()
        try persistence.replaceInventory(with: [makeItem(), makeItem()])
        XCTAssertEqual(try persistence.loadInventory().count, 2)
    }

    func testDeleteAndDeleteAll() throws {
        let persistence = try makePersistence()
        let first = makeItem(name: "鸡蛋")
        let second = makeItem(name: "牛奶")
        try persistence.replaceInventory(with: [first, second])
        try persistence.delete(id: first.id)
        XCTAssertEqual(try persistence.loadInventory().map(\.id), [second.id])
        try persistence.deleteAll()
        XCTAssertTrue(try persistence.loadInventory().isEmpty)
    }

    func testReplaceRemovesRecordsMissingFromFinalSnapshot() throws {
        let persistence = try makePersistence()
        let kept = makeItem(name: "鸡蛋")
        try persistence.replaceInventory(with: [kept, makeItem(name: "牛奶")])
        try persistence.replaceInventory(with: [kept])
        XCTAssertEqual(try persistence.loadInventory(), [kept])
    }

    func testStoreRestartReadsSameSwiftDataContainer() throws {
        let persistence = try makePersistence()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let firstStore = KitchenStore(userDefaults: defaults, inventoryPersistence: persistence)
        firstStore.addInventory(name: "番茄", quantity: 2, unit: "个", expiryDate: nil)
        let secondStore = KitchenStore(userDefaults: defaults, inventoryPersistence: persistence)
        XCTAssertEqual(secondStore.inventory, firstStore.inventory)
    }

    func testLegacyMigrationPreservesDataAndWritesMarkerWithoutDeletingJSON() throws {
        let persistence = try makePersistence()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let legacy = [makeItem()]
        let legacyData = try JSONEncoder().encode(legacy)
        defaults.set(legacyData, forKey: InventoryMigration.legacyInventoryKey)

        let migrated = try InventoryMigration.migrateIfNeeded(
            userDefaults: defaults,
            persistence: persistence
        )

        XCTAssertEqual(migrated, legacy)
        XCTAssertTrue(defaults.bool(forKey: InventoryMigration.completionKey))
        XCTAssertEqual(defaults.data(forKey: InventoryMigration.legacyInventoryKey), legacyData)
    }

    func testMigrationIsIdempotent() throws {
        let persistence = try makePersistence()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(try JSONEncoder().encode([makeItem()]), forKey: InventoryMigration.legacyInventoryKey)
        _ = try InventoryMigration.migrateIfNeeded(userDefaults: defaults, persistence: persistence)
        _ = try InventoryMigration.migrateIfNeeded(userDefaults: defaults, persistence: persistence)
        XCTAssertEqual(try persistence.loadInventory().count, 1)
    }

    func testMigrationKeepsSwiftDataVersionForSameIDAndAddsMissingLegacyID() throws {
        let persistence = try makePersistence()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let sharedID = UUID()
        let persisted = makeItem(id: sharedID, quantity: 10)
        let duplicateLegacy = makeItem(id: sharedID, quantity: 1)
        let missingLegacy = makeItem(name: "牛奶")
        try persistence.upsert(persisted)
        defaults.set(
            try JSONEncoder().encode([duplicateLegacy, missingLegacy]),
            forKey: InventoryMigration.legacyInventoryKey
        )

        let migrated = try InventoryMigration.migrateIfNeeded(
            userDefaults: defaults,
            persistence: persistence
        )

        XCTAssertEqual(migrated.count, 2)
        XCTAssertEqual(migrated.first(where: { $0.id == sharedID })?.quantity, 10)
    }

    func testMigrationFailureDoesNotMarkCompleteOrDeleteLegacyData() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let legacyData = try JSONEncoder().encode([makeItem()])
        defaults.set(legacyData, forKey: InventoryMigration.legacyInventoryKey)
        let persistence = FailingTestInventoryPersistence()

        XCTAssertThrowsError(
            try InventoryMigration.migrateIfNeeded(
                userDefaults: defaults,
                persistence: persistence
            )
        )
        XCTAssertFalse(defaults.bool(forKey: InventoryMigration.completionKey))
        XCTAssertEqual(defaults.data(forKey: InventoryMigration.legacyInventoryKey), legacyData)
    }

    func testBackupRestoreWritesInventoryIntoSwiftData() throws {
        let persistence = try makePersistence()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = KitchenStore(userDefaults: defaults, inventoryPersistence: persistence)
        let item = makeItem()
        let payload = KitchenBackupPayload(
            inventory: [item],
            plans: [],
            shoppingItems: [],
            weeklyPlan: nil,
            consumptionRecords: []
        )
        try store.restoreBackupData(JSONEncoder().encode(payload))

        XCTAssertEqual(try persistence.loadInventory(), [item])
        let restarted = KitchenStore(userDefaults: defaults, inventoryPersistence: persistence)
        XCTAssertEqual(restarted.inventory, [item])
    }

    func testClearAllLocalDataClearsSwiftDataInventory() throws {
        let persistence = try makePersistence()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = KitchenStore(userDefaults: defaults, inventoryPersistence: persistence)
        store.addInventory(name: "番茄", quantity: 1, unit: "个", expiryDate: nil)
        store.clearAllLocalData()
        XCTAssertTrue(try persistence.loadInventory().isEmpty)
    }
}

@MainActor
private final class FailingTestInventoryPersistence: InventoryPersistenceProtocol {
    struct ExpectedFailure: Error {}
    func loadInventory() throws -> [InventoryItem] { throw ExpectedFailure() }
    func replaceInventory(with items: [InventoryItem]) throws { throw ExpectedFailure() }
    func upsert(_ item: InventoryItem) throws { throw ExpectedFailure() }
    func delete(id: UUID) throws { throw ExpectedFailure() }
    func deleteAll() throws { throw ExpectedFailure() }
}

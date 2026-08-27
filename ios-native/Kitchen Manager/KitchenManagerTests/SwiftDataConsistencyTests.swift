import XCTest
@testable import KitchenManager

@MainActor
final class SwiftDataConsistencyTests: XCTestCase {
    private func weeklyPlan() -> WeeklyMealPlan {
        WeeklyMealPlan(
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            days: [WeeklyMealPlanDay(dayIndex: 0, meals: [])],
            shoppingItems: [], servings: 2, summary: "一致性测试",
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
    }

    private func store(_ defaults: UserDefaults, _ bundle: KitchenPersistenceBundle) -> KitchenStore {
        KitchenStore(
            userDefaults: defaults,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList,
            todayPlanPersistence: bundle.todayPlan,
            consumptionPersistence: bundle.consumption,
            weeklyPlanPersistence: bundle.weeklyPlan,
            preparedComponentPersistence: bundle.preparedComponents
        )
    }

    private func preparedComponent() -> PreparedComponent {
        PreparedComponent(
            name: "卤鸡腿", portionsRemaining: 5, state: .cooked, storage: .refrigerated,
            preparedAt: Date(timeIntervalSince1970: 1_700_000_100),
            expiryDate: Date(timeIntervalSince1970: 1_700_300_100)
        )
    }

    func testCompletedMarkersWithEmptyTablesRecoverEveryLegacyModule() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let inventory = InventoryItem(name: "鸡蛋", quantity: 6, unit: "个", expiryDate: nil)
        let shopping = KitchenShoppingItem(name: "牛奶", quantity: 1, unit: "盒")
        let plan = MealPlanItem(recipeID: "recipe", recipeName: "番茄炒蛋")
        let consumption = InventoryConsumptionRecord(
            id: UUID(), date: Date(), recipeID: "recipe", recipeName: "番茄炒蛋",
            planIDs: [plan.id], items: [], isUndone: false
        )
        let weekly = weeklyPlan()
        defaults.set(try JSONEncoder().encode([inventory]), forKey: InventoryMigration.legacyInventoryKey)
        defaults.set(try JSONEncoder().encode([shopping]), forKey: ShoppingListMigration.legacyShoppingKey)
        defaults.set(try JSONEncoder().encode([plan]), forKey: TodayPlanMigration.legacyPlansKey)
        defaults.set(try JSONEncoder().encode([consumption]), forKey: ConsumptionMigration.legacyRecordsKey)
        defaults.set(try JSONEncoder().encode(weekly), forKey: WeeklyPlanMigration.legacyKey)
        [InventoryMigration.completionKey, ShoppingListMigration.completionKey,
         TodayPlanMigration.completionKey, ConsumptionMigration.completionKey,
         WeeklyPlanMigration.completionKey].forEach { defaults.set(true, forKey: $0) }

        let restored = store(defaults, bundle)
        XCTAssertEqual(restored.inventory, [inventory])
        XCTAssertEqual(restored.shoppingItems, [shopping])
        XCTAssertEqual(restored.plans, [plan])
        XCTAssertEqual(restored.consumptionRecords, [consumption])
        XCTAssertEqual(restored.weeklyPlan, weekly)
    }

    func testClearAllDeletesSixModulesAndLegacyFallbackDoesNotResurrect() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let current = store(defaults, bundle)
        current.addInventory(name: "鸡蛋", quantity: 2, unit: "个", expiryDate: nil)
        current.addShopping(name: "牛奶")
        current.addPlan(recipe: Recipe.samples[0])
        current.saveWeeklyPlan(weeklyPlan())
        current.addPreparedComponent(preparedComponent())
        XCTAssertFalse(current.preparedComponents.isEmpty, "the sixth module really has data to clear")
        current.clearAllLocalData()

        let restarted = store(defaults, bundle)
        XCTAssertTrue(restarted.inventory.isEmpty)
        XCTAssertTrue(restarted.shoppingItems.isEmpty)
        XCTAssertTrue(restarted.plans.isEmpty)
        XCTAssertTrue(restarted.consumptionRecords.isEmpty)
        XCTAssertNil(restarted.weeklyPlan)
        XCTAssertTrue(restarted.preparedComponents.isEmpty)
    }

    /// Clear-all rolls every module back when any delete fails. The prepared
    /// components have to take part in the rollback too, not just the delete.
    func testClearAllFailureRollsBackPreparedComponents() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        struct ClearFailure: Error {}
        let store = KitchenStore(
            userDefaults: defaults,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList,
            todayPlanPersistence: bundle.todayPlan,
            consumptionPersistence: bundle.consumption,
            // Fails during the clear, after prepared components were deleted.
            weeklyPlanPersistence: FailingWeeklyPlanPersistence(ClearFailure()),
            preparedComponentPersistence: bundle.preparedComponents
        )
        let batch = preparedComponent()
        store.addPreparedComponent(batch)
        store.addInventory(name: "鸡蛋", quantity: 2, unit: "个", expiryDate: nil)

        store.clearAllLocalData()

        XCTAssertEqual(store.preparedComponents, [batch], "in-memory state is untouched by a failed clear")
        XCTAssertEqual(
            try bundle.preparedComponents.loadComponents(), [batch],
            "and the persisted batch was restored rather than lost"
        )
        XCTAssertFalse(store.inventory.isEmpty)
    }

    func testFullBackupRestoresSixSwiftDataModulesAcrossRestart() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let inventory = InventoryItem(name: "鸡蛋", quantity: 6, unit: "个", expiryDate: nil)
        let shopping = KitchenShoppingItem(name: "牛奶", isDone: true)
        let plan = MealPlanItem(recipeID: "recipe", recipeName: "番茄炒蛋", servings: 2, isCooked: true)
        let consumption = InventoryConsumptionRecord(
            id: UUID(), date: Date(), recipeID: "recipe", recipeName: "番茄炒蛋",
            planIDs: [plan.id], items: [], isUndone: true
        )
        let weekly = weeklyPlan()
        let batch = preparedComponent()
        let payload = KitchenBackupPayload(
            inventory: [inventory], plans: [plan], shoppingItems: [shopping],
            weeklyPlan: weekly, consumptionRecords: [consumption], preparedComponents: [batch]
        )
        try store(defaults, bundle).restoreBackupData(JSONEncoder().encode(payload))
        let restarted = store(defaults, bundle)
        XCTAssertEqual(restarted.inventory, [inventory])
        XCTAssertEqual(restarted.shoppingItems, [shopping])
        XCTAssertEqual(restarted.plans, [plan])
        XCTAssertEqual(restarted.consumptionRecords, [consumption])
        XCTAssertEqual(restarted.weeklyPlan, weekly)
        XCTAssertEqual(restarted.preparedComponents, [batch])
    }

    /// A backup written before prepared components existed has no such key.
    /// It must restore as an empty collection, not fail the whole file.
    func testABackupWithoutPreparedComponentsRestoresAsEmpty() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let inventory = InventoryItem(name: "鸡蛋", quantity: 6, unit: "个", expiryDate: nil)
        let legacyJSON = """
        {"format":"kitchen-manager-native-backup","version":1,\
        "inventory":[{"id":"\(inventory.id.uuidString)","name":"鸡蛋","quantity":6,"unit":"个","isStaple":false,\
        "autoSuggestRestock":false,"stapleTrackingMode":"quantity","stapleAvailabilityStatus":"available"}],\
        "plans":[],"shoppingItems":[],"consumptionRecords":[]}
        """.replacingOccurrences(of: "\\\n", with: "")

        let store = store(defaults, bundle)
        XCTAssertNoThrow(try store.restoreBackupData(Data(legacyJSON.utf8)))
        XCTAssertEqual(store.inventory.first?.name, "鸡蛋")
        XCTAssertTrue(store.preparedComponents.isEmpty)
    }
}

import XCTest
import SwiftData
@testable import KitchenManager

/// Adding `PreparedComponentRecord` is a real SwiftData schema change, so a
/// fresh install proving nothing. These tests build an on-disk store with the
/// **pre-P1-B** model list — exactly the twelve types `KitchenPersistenceFactory`
/// used at `14d2d86` — fill it with kitchen data, close it, and reopen the same
/// file with the new thirteen-type schema.
///
/// What must hold: the store opens, nothing is destructively reset, every
/// existing module still has its data, and the new collection starts empty.
@MainActor
final class PreparedComponentSchemaUpgradeTests: XCTestCase {
    private var storeURL: URL!

    override func setUpWithError() throws {
        storeURL = FileManager.default.temporaryDirectory
            .appending(path: "prepared-upgrade-\(UUID().uuidString).store")
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-shm", "-wal"] {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            try? FileManager.default.removeItem(at: url)
        }
        storeURL = nil
    }

    /// The model list as it stood before this change. Deliberately spelled out
    /// rather than derived, so the test keeps describing the *old* schema even
    /// as the factory moves on.
    private func makeLegacyContainer() throws -> ModelContainer {
        try ModelContainer(
            for: InventoryRecord.self,
            ShoppingItemRecord.self,
            TodayPlanRecord.self,
            ConsumptionRecordEntity.self,
            WeeklyPlanRecord.self,
            UserRecipeRecord.self,
            RecipePreferenceRecord.self,
            SyncMetadataRecord.self,
            PendingMutationRecord.self,
            SyncCursorRecord.self,
            GuestMergeSessionRecord.self,
            InventorySyncEnrollmentRecord.self,
            configurations: ModelConfiguration(url: storeURL)
        )
    }

    private func makeCurrentContainer() throws -> ModelContainer {
        try ModelContainer(
            for: InventoryRecord.self,
            ShoppingItemRecord.self,
            TodayPlanRecord.self,
            ConsumptionRecordEntity.self,
            WeeklyPlanRecord.self,
            UserRecipeRecord.self,
            RecipePreferenceRecord.self,
            SyncMetadataRecord.self,
            PendingMutationRecord.self,
            SyncCursorRecord.self,
            GuestMergeSessionRecord.self,
            InventorySyncEnrollmentRecord.self,
            PreparedComponentRecord.self,
            configurations: ModelConfiguration(url: storeURL)
        )
    }

    /// Stored, not rebuilt: `WeeklyMealPlanDay.id` defaults to a fresh UUID, so
    /// two calls would never compare equal even when the data round-trips.
    private let weekly = WeeklyMealPlan(
        startDate: Date(timeIntervalSince1970: 1_700_000_000),
        days: [WeeklyMealPlanDay(dayIndex: 0, meals: [])],
        shoppingItems: [], servings: 2, summary: "升级测试",
        createdAt: Date(timeIntervalSince1970: 1_700_000_001)
    )

    private let inventory = InventoryItem(name: "鸡腿", quantity: 6, unit: "只", expiryDate: nil)
    private let shopping = KitchenShoppingItem(name: "牛奶", quantity: 1, unit: "盒")
    private let plan = MealPlanItem(recipeID: "recipe", recipeName: "番茄炒蛋", plannedServings: 2)
    private let recipe = Recipe(
        id: "user-upgrade", title: "升级用户菜谱", cookingTime: 20, difficulty: "简单",
        tags: ["测试"], ingredients: ["鸡腿 2 只"], steps: ["做好"]
    )

    /// Writes one row into every module through the legacy schema, then lets the
    /// container go out of scope so the file is closed before reopening.
    private func seedLegacyStore() throws {
        let legacy = try makeLegacyContainer()
        let consumption = InventoryConsumptionRecord(
            id: UUID(), date: Date(timeIntervalSince1970: 1_700_000_002),
            recipeID: "recipe", recipeName: "番茄炒蛋", planIDs: [plan.id], items: [], isUndone: false
        )
        try SwiftDataInventoryPersistence(container: legacy).replaceInventory(with: [inventory])
        try SwiftDataShoppingListPersistence(container: legacy).replaceShoppingItems(with: [shopping])
        try SwiftDataTodayPlanPersistence(container: legacy).replacePlans(with: [plan])
        try SwiftDataConsumptionPersistence(container: legacy).replaceRecords(with: [consumption])
        try SwiftDataWeeklyPlanPersistence(container: legacy).replacePlan(with: weekly)
        try SwiftDataUserRecipePersistence(container: legacy).replaceRecipes(with: [recipe])
    }

    func testAnExistingStoreOpensUnderTheNewSchema() throws {
        try seedLegacyStore()
        XCTAssertNoThrow(try makeCurrentContainer(), "the upgrade must not fail to open")
    }

    func testEveryExistingModuleSurvivesTheUpgrade() throws {
        try seedLegacyStore()
        let upgraded = try makeCurrentContainer()

        let restoredInventory = try SwiftDataInventoryPersistence(container: upgraded).loadInventory()
        let restoredShopping = try SwiftDataShoppingListPersistence(container: upgraded).loadShoppingItems()
        let restoredPlans = try SwiftDataTodayPlanPersistence(container: upgraded).loadPlans()
        let restoredConsumption = try SwiftDataConsumptionPersistence(container: upgraded).loadRecords()
        let restoredWeekly = try SwiftDataWeeklyPlanPersistence(container: upgraded).loadPlan()
        let restoredRecipes = try SwiftDataUserRecipePersistence(container: upgraded).loadRecipes()

        XCTAssertEqual(restoredInventory, [inventory], "inventory must not be reset")
        XCTAssertEqual(restoredShopping, [shopping])
        XCTAssertEqual(restoredPlans, [plan], "today plan must not be reset")
        XCTAssertEqual(restoredConsumption.count, 1, "consumption history must not be reset")
        XCTAssertEqual(restoredWeekly, weekly, "weekly plan must not be reset")
        XCTAssertEqual(restoredRecipes, [recipe], "user recipes must not be reset")
    }

    func testTheNewCollectionStartsEmptyRatherThanFailingToRead() throws {
        try seedLegacyStore()
        let upgraded = try makeCurrentContainer()

        let components = try SwiftDataPreparedComponentPersistence(container: upgraded).loadComponents()
        XCTAssertTrue(components.isEmpty)
    }

    func testTheUpgradedStoreIsWritableForBothOldAndNewModules() throws {
        try seedLegacyStore()
        let upgraded = try makeCurrentContainer()
        let componentPersistence = SwiftDataPreparedComponentPersistence(container: upgraded)
        let batch = PreparedComponent(
            name: "卤鸡腿", portionsRemaining: 5, state: .cooked, storage: .refrigerated,
            preparedAt: Date(timeIntervalSince1970: 1_700_000_003),
            expiryDate: Date(timeIntervalSince1970: 1_700_300_000)
        )

        try componentPersistence.upsert(batch)
        XCTAssertEqual(try componentPersistence.loadComponents(), [batch])

        // …and the pre-existing modules still take writes afterwards.
        let inventoryPersistence = SwiftDataInventoryPersistence(container: upgraded)
        var updated = inventory
        updated.quantity = 4
        try inventoryPersistence.replaceInventory(with: [updated])
        XCTAssertEqual(try inventoryPersistence.loadInventory().first?.quantity, 4)
    }
}

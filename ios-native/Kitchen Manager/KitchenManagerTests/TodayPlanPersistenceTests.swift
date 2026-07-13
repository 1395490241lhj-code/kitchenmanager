import Combine
import XCTest
@testable import KitchenManager

@MainActor
final class TodayPlanPersistenceTests: XCTestCase {
    private func makePersistence() throws -> SwiftDataTodayPlanPersistence {
        try SwiftDataTodayPlanPersistence(isStoredInMemoryOnly: true)
    }

    private func makePlan(
        id: UUID = UUID(),
        recipeID: String = "recipe-1",
        recipeName: String = "番茄炒蛋",
        date: Date = Date(timeIntervalSince1970: 1_700_000_000),
        servings: Int = 2,
        isCooked: Bool = false
    ) -> MealPlanItem {
        MealPlanItem(
            id: id,
            recipeID: recipeID,
            recipeName: recipeName,
            date: date,
            servings: servings,
            isCooked: isCooked
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

    private func recipe(id: String = "recipe-1", title: String = "番茄炒蛋") -> Recipe {
        Recipe(
            id: id,
            title: title,
            cookingTime: 15,
            difficulty: "简单",
            tags: ["家常菜"],
            ingredients: ["番茄 2 个", "鸡蛋 3 个"],
            seasonings: ["盐 少许"],
            steps: ["炒熟"]
        )
    }

    func testEmptyDatabaseLoadsEmpty() throws {
        XCTAssertEqual(try makePersistence().loadPlans(), [])
    }

    func testUpsertRoundTripsEveryBusinessField() throws {
        let persistence = try makePersistence()
        let plan = makePlan(isCooked: true)
        try persistence.upsert(plan)
        XCTAssertEqual(try persistence.loadPlans(), [plan])
    }

    func testUpsertUpdatesSameIDInsteadOfDuplicating() throws {
        let persistence = try makePersistence()
        let id = UUID()
        try persistence.upsert(makePlan(id: id, servings: 1))
        try persistence.upsert(makePlan(id: id, recipeName: "更新后的菜", servings: 4, isCooked: true))
        let loaded = try persistence.loadPlans()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].recipeName, "更新后的菜")
        XCTAssertEqual(loaded[0].servings, 4)
        XCTAssertTrue(loaded[0].isCooked)
    }

    func testReplacePreservesArrayOrderAndRemovesMissingRecords() throws {
        let persistence = try makePersistence()
        let first = makePlan(recipeID: "a", recipeName: "第一道")
        let second = makePlan(recipeID: "b", recipeName: "第二道")
        let third = makePlan(recipeID: "c", recipeName: "第三道")
        try persistence.replacePlans(with: [first, second, third])
        XCTAssertEqual(try persistence.loadPlans().map(\.id), [first.id, second.id, third.id])
        try persistence.replacePlans(with: [third, first])
        XCTAssertEqual(try persistence.loadPlans().map(\.id), [third.id, first.id])
    }

    func testSameRecipeWithDifferentPlanIDsRemainsSeparate() throws {
        let persistence = try makePersistence()
        let first = makePlan()
        let second = makePlan()
        try persistence.replacePlans(with: [first, second])
        XCTAssertEqual(try persistence.loadPlans().map(\.id), [first.id, second.id])
    }

    func testDeleteAndDeleteAll() throws {
        let persistence = try makePersistence()
        let first = makePlan(recipeID: "a")
        let second = makePlan(recipeID: "b")
        try persistence.replacePlans(with: [first, second])
        try persistence.delete(id: first.id)
        XCTAssertEqual(try persistence.loadPlans(), [second])
        try persistence.deleteAll()
        XCTAssertTrue(try persistence.loadPlans().isEmpty)
    }

    func testLegacyMigrationPreservesAllFieldsOrderAndLegacyJSON() throws {
        let persistence = try makePersistence()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let legacy = [
            makePlan(recipeID: "remote", recipeName: "远程菜", servings: 1),
            makePlan(recipeID: "user", recipeName: "用户菜", servings: 4, isCooked: true)
        ]
        let data = try JSONEncoder().encode(legacy)
        defaults.set(data, forKey: TodayPlanMigration.legacyPlansKey)

        let migrated = try TodayPlanMigration.migrateIfNeeded(
            userDefaults: defaults,
            persistence: persistence
        )

        XCTAssertEqual(migrated, legacy)
        XCTAssertTrue(defaults.bool(forKey: TodayPlanMigration.completionKey))
        XCTAssertEqual(defaults.data(forKey: TodayPlanMigration.legacyPlansKey), data)
    }

    func testMigrationIsIdempotent() throws {
        let persistence = try makePersistence()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(try JSONEncoder().encode([makePlan()]), forKey: TodayPlanMigration.legacyPlansKey)
        _ = try TodayPlanMigration.migrateIfNeeded(userDefaults: defaults, persistence: persistence)
        _ = try TodayPlanMigration.migrateIfNeeded(userDefaults: defaults, persistence: persistence)
        XCTAssertEqual(try persistence.loadPlans().count, 1)
    }

    func testMigrationKeepsSwiftDataSameIDAndAddsMissingLegacyID() throws {
        let persistence = try makePersistence()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let sharedID = UUID()
        let persisted = makePlan(id: sharedID, recipeName: "SwiftData 优先", servings: 8)
        let missing = makePlan(recipeID: "missing", recipeName: "旧计划补充")
        try persistence.upsert(persisted)
        defaults.set(
            try JSONEncoder().encode([
                makePlan(id: sharedID, recipeName: "旧数据", servings: 1),
                missing
            ]),
            forKey: TodayPlanMigration.legacyPlansKey
        )

        let migrated = try TodayPlanMigration.migrateIfNeeded(
            userDefaults: defaults,
            persistence: persistence
        )

        XCTAssertEqual(migrated.count, 2)
        XCTAssertEqual(migrated.first(where: { $0.id == sharedID })?.recipeName, "SwiftData 优先")
        XCTAssertEqual(migrated.first(where: { $0.id == sharedID })?.servings, 8)
        XCTAssertTrue(migrated.contains(where: { $0.id == missing.id }))
    }

    func testMigrationFailureKeepsLegacyAndDoesNotMarkComplete() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let data = try JSONEncoder().encode([makePlan()])
        defaults.set(data, forKey: TodayPlanMigration.legacyPlansKey)
        XCTAssertThrowsError(
            try TodayPlanMigration.migrateIfNeeded(
                userDefaults: defaults,
                persistence: FailingTestTodayPlanPersistence()
            )
        )
        XCTAssertFalse(defaults.bool(forKey: TodayPlanMigration.completionKey))
        XCTAssertEqual(defaults.data(forKey: TodayPlanMigration.legacyPlansKey), data)
    }

    func testStoreAddEditCookUncookDeleteClearAndRestartPersist() throws {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = makeStore(defaults: defaults, bundle: bundle)
        store.addPlan(recipe: recipe(), servings: 3)
        let id = try XCTUnwrap(store.plans.first?.id)
        store.plans[0].recipeName = "改名后"
        store.plans[0].servings = 5
        store.setPlanCooked(id, isCooked: true)
        store.setPlanCooked(id, isCooked: false)

        let restarted = makeStore(defaults: defaults, bundle: bundle)
        XCTAssertEqual(restarted.plans.count, 1)
        XCTAssertEqual(restarted.plans[0].recipeName, "改名后")
        XCTAssertEqual(restarted.plans[0].servings, 5)
        XCTAssertFalse(restarted.plans[0].isCooked)
        restarted.removePlan(restarted.plans[0])
        XCTAssertTrue(try bundle.todayPlan.loadPlans().isEmpty)

        restarted.addPlan(recipe: recipe())
        restarted.plans.removeAll()
        XCTAssertTrue(try bundle.todayPlan.loadPlans().isEmpty)
    }

    func testBatchAddDeduplicatesTodayAndWritesFinalSnapshotOnce() {
        let persistence = CountingTodayPlanPersistence()
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList,
            todayPlanPersistence: persistence
        )
        let baselineWrites = persistence.replaceCallCount
        var publishedCounts: [Int] = []
        let cancellable = store.$plans.sink { publishedCounts.append($0.count) }
        let first = recipe(id: "a", title: "A")
        store.addPlans([(first, 2), (first, 4), (recipe(id: "b", title: "B"), 3)])
        cancellable.cancel()
        XCTAssertEqual(store.plans.map(\.recipeID), ["a", "b"])
        XCTAssertEqual(store.plans.map(\.servings), [2, 3])
        XCTAssertEqual(publishedCounts, [0, 2])
        XCTAssertEqual(persistence.replaceCallCount - baselineWrites, 1)
    }

    func testRestartedPlanGeneratesSameShoppingDraft() throws {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let recipeDefaults = UserDefaults(suiteName: UUID().uuidString)!
        let recipeStore = RecipeStore(userDefaults: recipeDefaults)
        let savedRecipe = recipe()
        try recipeStore.saveUserRecipe(savedRecipe)
        let store = makeStore(defaults: defaults, bundle: bundle)
        store.addPlan(recipe: savedRecipe, servings: 2)
        let generator = ShoppingListGenerator()
        let before = generator.generate(
            source: .todayPlans(store.plans),
            inventory: [],
            existingShoppingItems: [],
            recipeStore: recipeStore
        )
        let restarted = makeStore(defaults: defaults, bundle: bundle)
        let after = generator.generate(
            source: .todayPlans(restarted.plans),
            inventory: [],
            existingShoppingItems: [],
            recipeStore: recipeStore
        )
        XCTAssertEqual(after.recipeCount, before.recipeCount)
        XCTAssertEqual(after.missingItems.map(\.id), before.missingItems.map(\.id))
        XCTAssertEqual(after.missingItems.map(\.requiredQuantity), before.missingItems.map(\.requiredQuantity))

        let generationStore = ShoppingListGenerationStore()
        generationStore.generate(
            source: .todayPlans(restarted.plans),
            kitchenStore: restarted,
            recipeStore: recipeStore
        )
        XCTAssertGreaterThan(generationStore.importSelectedItems(into: restarted), 0)
        let restartedAfterImport = makeStore(defaults: defaults, bundle: bundle)
        XCTAssertFalse(restartedAfterImport.shoppingItems.isEmpty)
        XCTAssertTrue(restartedAfterImport.shoppingItems.allSatisfy { $0.source == "今日计划" })
    }

    func testRestartedPlanCanDriveConsumptionAndCookedStatePersists() throws {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let savedRecipe = recipe()
        try recipeStore.saveUserRecipe(savedRecipe)
        var store = makeStore(defaults: defaults, bundle: bundle)
        store.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)
        store.addPlan(recipe: savedRecipe)
        let planID = try XCTUnwrap(store.plans.first?.id)

        store = makeStore(defaults: defaults, bundle: bundle)
        let confirmation = CookConsumptionStore()
        confirmation.buildDrafts(planIDs: [planID], kitchenStore: store, recipeStore: recipeStore)
        XCTAssertFalse(confirmation.drafts.isEmpty)
        confirmation.confirm(
            planIDs: [planID],
            recipeID: savedRecipe.id,
            recipeName: savedRecipe.title,
            kitchenStore: store,
            recipeStore: recipeStore
        )
        store.setPlanCooked(planID, isCooked: true)

        let restarted = makeStore(defaults: defaults, bundle: bundle)
        XCTAssertLessThan(restarted.inventory.first(where: { $0.name == "番茄" })?.quantity ?? 5, 5)
        XCTAssertEqual(restarted.plans.first(where: { $0.id == planID })?.isCooked, true)
        XCTAssertFalse(restarted.consumptionRecords.isEmpty)
    }

    func testBackupRestorePersistsPlansAndKeepsBackupShape() throws {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = makeStore(defaults: defaults, bundle: bundle)
        let plan = makePlan(isCooked: true)
        let payload = KitchenBackupPayload(
            inventory: [],
            plans: [plan],
            shoppingItems: [],
            weeklyPlan: nil,
            consumptionRecords: []
        )
        let data = try JSONEncoder().encode(payload)
        try store.restoreBackupData(data)
        XCTAssertEqual(try bundle.todayPlan.loadPlans(), [plan])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["plans"])
        let restarted = makeStore(defaults: defaults, bundle: bundle)
        XCTAssertEqual(restarted.plans, [plan])
    }

    func testBackupTodayPlanFailureKeepsAllCurrentMemoryState() throws {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let currentInventory = InventoryItem(name: "鸡蛋", quantity: 2, unit: "个", expiryDate: nil)
        let currentShopping = KitchenShoppingItem(name: "牛奶")
        try bundle.inventory.replaceInventory(with: [currentInventory])
        try bundle.shoppingList.replaceShoppingItems(with: [currentShopping])
        let legacyPlan = makePlan(recipeName: "当前计划")
        defaults.set(try JSONEncoder().encode([legacyPlan]), forKey: TodayPlanMigration.legacyPlansKey)
        let store = KitchenStore(
            userDefaults: defaults,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList,
            todayPlanPersistence: FailingTestTodayPlanPersistence()
        )
        let replacement = KitchenBackupPayload(
            inventory: [],
            plans: [makePlan(recipeName: "备份计划")],
            shoppingItems: [],
            weeklyPlan: nil,
            consumptionRecords: []
        )

        XCTAssertThrowsError(try store.restoreBackupData(JSONEncoder().encode(replacement)))
        XCTAssertEqual(store.inventory, [currentInventory])
        XCTAssertEqual(store.shoppingItems, [currentShopping])
        XCTAssertEqual(store.plans, [legacyPlan])
        XCTAssertEqual(try bundle.inventory.loadInventory(), [currentInventory])
        XCTAssertEqual(try bundle.shoppingList.loadShoppingItems(), [currentShopping])
    }

    func testClearAllLocalDataClearsAllThreeSwiftDataModels() throws {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            bundle: bundle
        )
        store.addInventory(name: "番茄", quantity: 1, unit: "个", expiryDate: nil)
        store.addShopping(name: "牛奶")
        store.addPlan(recipe: recipe())
        store.clearAllLocalData()
        XCTAssertTrue(try bundle.inventory.loadInventory().isEmpty)
        XCTAssertTrue(try bundle.shoppingList.loadShoppingItems().isEmpty)
        XCTAssertTrue(try bundle.todayPlan.loadPlans().isEmpty)
    }
}

@MainActor
private final class CountingTodayPlanPersistence: TodayPlanPersistenceProtocol {
    var plans: [MealPlanItem] = []
    var replaceCallCount = 0
    func loadPlans() throws -> [MealPlanItem] { plans }
    func replacePlans(with items: [MealPlanItem]) throws {
        replaceCallCount += 1
        plans = items
    }
    func upsert(_ item: MealPlanItem) throws {}
    func delete(id: UUID) throws {}
    func deleteAll() throws { plans = [] }
}

@MainActor
private final class FailingTestTodayPlanPersistence: TodayPlanPersistenceProtocol {
    struct ExpectedFailure: Error {}
    func loadPlans() throws -> [MealPlanItem] { throw ExpectedFailure() }
    func replacePlans(with items: [MealPlanItem]) throws { throw ExpectedFailure() }
    func upsert(_ item: MealPlanItem) throws { throw ExpectedFailure() }
    func delete(id: UUID) throws { throw ExpectedFailure() }
    func deleteAll() throws { throw ExpectedFailure() }
}

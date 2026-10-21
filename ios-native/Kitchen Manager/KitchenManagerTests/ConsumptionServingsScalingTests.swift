import XCTest
@testable import KitchenManager

/// CONSUMPTION-1: the shopping list and cooking mode scaled a meal by
/// servings ÷ base yield, while the deduction stayed as written and every row
/// claimed the recipe had no base yield. Deduction now uses the same factor,
/// and the warning appears only when there really is no base to convert from.
@MainActor
final class ConsumptionServingsScalingTests: XCTestCase {
    private let planner = InventoryConsumptionPlanner()
    private let noBaseWarning = "菜谱没有标注份量，用量未按人数换算，请确认"

    private func recipe(base: Int?, ingredients: [String] = ["鸡胸肉 300 克", "鸡蛋 2 个"]) -> Recipe {
        Recipe(id: UUID().uuidString, title: "鸡胸肉炒蛋", cookingTime: nil, difficulty: nil, tags: [],
               ingredients: ingredients, steps: ["炒"], baseServings: base)
    }

    private var inventory: [InventoryItem] {
        [InventoryItem(name: "鸡胸肉", quantity: 1000, unit: "克", expiryDate: nil, createdAt: Date()),
         InventoryItem(name: "鸡蛋", quantity: 12, unit: "个", expiryDate: nil, createdAt: Date())]
    }

    private func draft(_ drafts: [InventoryConsumptionDraft], _ name: String) throws -> InventoryConsumptionDraft {
        try XCTUnwrap(drafts.first { $0.ingredientName == name })
    }

    func testStatedServingsScaleByTheBaseYield() throws {
        let drafts = planner.plan(for: [.init(recipe: recipe(base: 2), servings: 4)], inventory: inventory)
        XCTAssertEqual(try draft(drafts, "鸡胸肉").requiredQuantity, 600)
        XCTAssertEqual(try draft(drafts, "鸡胸肉").consumedQuantity, 600)
        XCTAssertEqual(try draft(drafts, "鸡蛋").requiredQuantity, 4)
        XCTAssertTrue(drafts.allSatisfy { $0.warning == nil })
    }

    func testFewerServingsThanTheBaseDeductLess() throws {
        let drafts = planner.plan(for: [.init(recipe: recipe(base: 4), servings: 1)], inventory: inventory)
        XCTAssertEqual(try draft(drafts, "鸡胸肉").requiredQuantity, 75)
        XCTAssertEqual(try draft(drafts, "鸡蛋").requiredQuantity, 0.5)
    }

    func testCookingAtTheBaseYieldIsAsWrittenWithoutAWarning() throws {
        let drafts = planner.plan(for: [.init(recipe: recipe(base: 2), servings: 2)], inventory: inventory)
        XCTAssertEqual(try draft(drafts, "鸡胸肉").requiredQuantity, 300)
        XCTAssertTrue(drafts.allSatisfy { $0.warning == nil },
                      "a 2-serving recipe cooked for 2 must not claim it has no base yield")
    }

    func testUnstatedServingsAreAsWritten() throws {
        let drafts = planner.plan(for: [.init(recipe: recipe(base: 2), servings: nil)], inventory: inventory)
        XCTAssertEqual(try draft(drafts, "鸡胸肉").requiredQuantity, 300)
        XCTAssertTrue(drafts.allSatisfy { $0.warning == nil })
    }

    func testOnlyAMissingBaseYieldWithAnotherServingCountWarns() throws {
        let scaledWithoutBase = planner.plan(for: [.init(recipe: recipe(base: nil), servings: 4)], inventory: inventory)
        XCTAssertEqual(try draft(scaledWithoutBase, "鸡胸肉").requiredQuantity, 300, "no base: left as written")
        XCTAssertEqual(try draft(scaledWithoutBase, "鸡胸肉").warning, noBaseWarning)

        let oneServingWithoutBase = planner.plan(for: [.init(recipe: recipe(base: nil), servings: 1)], inventory: inventory)
        XCTAssertTrue(oneServingWithoutBase.allSatisfy { $0.warning == nil })
    }

    /// The planned path reads the meal's own target, as the shopping list does.
    func testPlannedMealDeductsForItsPlannedServings() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let kitchen = KitchenStore(
            userDefaults: defaults,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList,
            todayPlanPersistence: bundle.todayPlan,
            consumptionPersistence: bundle.consumption,
            weeklyPlanPersistence: bundle.weeklyPlan,
            preparedComponentPersistence: bundle.preparedComponents
        )
        let recipeStore = RecipeStore(userDefaults: defaults, userRecipePersistence: bundle.userRecipes,
                                      recipePreferencePersistence: bundle.recipePreferences)
        let dish = recipe(base: 2)
        try recipeStore.saveUserRecipe(dish)
        kitchen.addInventory(name: "鸡胸肉", quantity: 1000, unit: "克", expiryDate: nil)
        kitchen.addInventory(name: "鸡蛋", quantity: 12, unit: "个", expiryDate: nil)
        let forFour = MealPlanItem(recipeID: dish.id, recipeName: dish.title, plannedServings: 4)
        let unstated = MealPlanItem(recipeID: dish.id, recipeName: dish.title)
        kitchen.plans = [forFour, unstated]

        let store = CookConsumptionStore()
        store.buildDrafts(target: .plannedMeals(planIDs: [forFour.id], recipe: nil, servings: 1),
                          kitchenStore: kitchen, recipeStore: recipeStore)
        XCTAssertEqual(try draft(store.drafts, "鸡胸肉").requiredQuantity, 600)

        let asWritten = CookConsumptionStore()
        asWritten.buildDrafts(target: .plannedMeals(planIDs: [unstated.id], recipe: nil, servings: 1),
                              kitchenStore: kitchen, recipeStore: recipeStore)
        XCTAssertEqual(try draft(asWritten.drafts, "鸡胸肉").requiredQuantity, 300)
    }

    /// D-047 #3: a Special Plan dish stays as written whatever the headcount.
    func testSpecialPlanDishStaysAsWritten() throws {
        let kitchen = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        kitchen.addInventory(name: "鸡胸肉", quantity: 1000, unit: "克", expiryDate: nil)
        let store = CookConsumptionStore()
        store.buildDrafts(
            target: .specialPlanDish(planID: UUID(), dishID: UUID(), planTitleSnapshot: "聚餐", recipe: recipe(base: 2)),
            kitchenStore: kitchen,
            recipeStore: RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        XCTAssertEqual(try draft(store.drafts, "鸡胸肉").requiredQuantity, 300)
    }
}

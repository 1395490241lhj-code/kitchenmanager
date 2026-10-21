import XCTest
@testable import KitchenManager

/// Opening a Special Plan dish's recipe and cooking it there used to be an
/// unplanned cook: it deducted once with no dish identity, and ticking the dish
/// on the plan afterwards deducted again. The cook now carries the dish (D-047).
@MainActor
final class SpecialPlanDishCookingTests: XCTestCase {
    private var kitchenStore: KitchenStore!
    private var recipeStore: RecipeStore!
    private let dishRecipe = Recipe(
        id: "special-dish-recipe", title: "麻婆豆腐", cookingTime: nil, difficulty: nil,
        tags: [], ingredients: ["豆腐 1盒"], steps: ["炒"]
    )

    override func setUp() {
        super.setUp()
        kitchenStore = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        kitchenStore.addInventory(name: "豆腐", quantity: 5, unit: "盒", expiryDate: nil)
    }

    private func makePlan(usesHomeInventory: Bool) -> SpecialPlan {
        let plan = SpecialPlan(
            title: "周末聚会",
            scheduledAt: Date(),
            usesHomeInventory: usesHomeInventory,
            dishes: [SpecialPlanDish(recipeID: dishRecipe.id, recipeName: dishRecipe.title)]
        )
        kitchenStore.addSpecialPlan(plan)
        return plan
    }

    private func confirm(_ target: CookConsumptionTarget) -> Bool {
        let store = CookConsumptionStore()
        store.buildDrafts(target: target, kitchenStore: kitchenStore, recipeStore: recipeStore)
        return store.confirm(
            target: target, recipeID: dishRecipe.id, recipeName: dishRecipe.title,
            kitchenStore: kitchenStore, recipeStore: recipeStore
        )
    }

    func testCookingFromTheDishRecipeThenTickingTheDishDeductsOnce() throws {
        let plan = makePlan(usesHomeInventory: true)
        let dish = try XCTUnwrap(plan.dishes.first)
        let request = CookingFlowRequest(
            recipe: dishRecipe, plan: nil,
            specialPlanDish: SpecialPlanDishCookingContext(plan: plan, dish: dish)
        )

        // 开始烹饪 on the recipe page, then 完成 in cooking mode.
        let target = try XCTUnwrap(request.specialPlanConsumptionTarget)
        XCTAssertTrue(confirm(target))
        XCTAssertEqual(kitchenStore.completeSpecialPlanDish(planID: plan.id, dishID: dish.id), .completed)
        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 4)
        let record = try XCTUnwrap(kitchenStore.consumptionRecords.first)
        XCTAssertEqual(record.specialPlanDishID, dish.id, "the receipt is keyed to the dish")
        XCTAssertEqual(record.planIDs, [])

        // Later, untick and tick the dish on the plan: the plan's own path.
        _ = kitchenStore.setSpecialPlanDishCookedPersisted(planID: plan.id, dishID: dish.id, isCooked: false)
        XCTAssertTrue(confirm(.specialPlanDish(
            planID: plan.id, dishID: dish.id, planTitleSnapshot: plan.title, recipe: dishRecipe
        )))
        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 4, "勾选菜品不能再扣一次")
        XCTAssertEqual(kitchenStore.consumptionRecords.count, 1)
    }

    func testAnEventAwayFromHomeDeductsNothingFromTheRecipePage() throws {
        let plan = makePlan(usesHomeInventory: false)
        let dish = try XCTUnwrap(plan.dishes.first)
        let request = CookingFlowRequest(
            recipe: dishRecipe, plan: nil,
            specialPlanDish: SpecialPlanDishCookingContext(plan: plan, dish: dish)
        )
        XCTAssertNil(request.specialPlanConsumptionTarget, "same rule as ticking the dish")
    }

    func testAnOrdinaryRecipeCookStaysUnkeyed() {
        let request = CookingFlowRequest(recipe: dishRecipe, plan: nil)
        XCTAssertNil(request.specialPlanDish)
        XCTAssertNil(request.specialPlanConsumptionTarget)
    }
}

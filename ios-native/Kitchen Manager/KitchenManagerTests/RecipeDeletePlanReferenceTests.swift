import XCTest
@testable import KitchenManager

/// RECIPES_LOGIC-8: deleting a user recipe gave no warning that meals still
/// named it. The confirmation now states how many uncooked meals and Special
/// Plan dishes would be left unable to open it.
@MainActor
final class RecipeDeletePlanReferenceTests: XCTestCase {
    private func store() -> KitchenStore {
        KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
                     persistence: KitchenPersistenceFactory.isolatedInMemory())
    }

    func testCountsUncookedMealsAndSpecialPlanDishesNamingTheRecipe() {
        let kitchen = store()
        kitchen.plans = [
            MealPlanItem(recipeID: "user-pork", recipeName: "红烧肉"),
            MealPlanItem(recipeID: "user-pork", recipeName: "红烧肉", date: Date().addingTimeInterval(86_400)),
            MealPlanItem(recipeID: "user-pork", recipeName: "红烧肉", isCooked: true),
            MealPlanItem(recipeID: "other", recipeName: "红烧肉"),
        ]
        kitchen.addSpecialPlan(SpecialPlan(
            title: "聚餐", scheduledAt: Date(),
            dishes: [SpecialPlanDish(recipeID: "user-pork", recipeName: "红烧肉"),
                     SpecialPlanDish(recipeID: "user-pork", recipeName: "红烧肉", isCooked: true)]
        ))

        XCTAssertEqual(kitchen.uncookedPlanReferenceCount(recipeID: "user-pork"), 3,
                       "two uncooked meals and one uncooked dish; cooked rows and other recipes do not count")
    }

    func testAnUnplannedRecipeHasNothingToWarnAbout() {
        XCTAssertEqual(store().uncookedPlanReferenceCount(recipeID: "user-pork"), 0)
    }
}

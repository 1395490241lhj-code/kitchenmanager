import XCTest
@testable import KitchenManager

/// Shopping quantity scaling: recipe base yield + an explicitly planned target.
///
/// Scaling happens only when both numbers are trustworthy. Everything else
/// falls back to the recipe as written, because inventing a denominator or a
/// target produces quantities that look computed but are not.
@MainActor
final class ShoppingScalingTests: XCTestCase {
    private let generator = ShoppingListGenerator()

    private func recipeStore() -> RecipeStore {
        RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func recipe(
        id: String = "r",
        title: String = "菜",
        ingredients: [String],
        baseServings: Int? = nil
    ) -> Recipe {
        Recipe(
            id: id, title: title, cookingTime: nil, difficulty: nil,
            tags: [], ingredients: ingredients, steps: ["做"], baseServings: baseServings
        )
    }

    private func plan(_ recipe: Recipe, plannedServings: Int?) -> MealPlanItem {
        MealPlanItem(
            recipeID: recipe.id, recipeName: recipe.title,
            plannedServings: plannedServings
        )
    }

    private func draft(
        recipes: [Recipe],
        plans: [MealPlanItem],
        inventory: [InventoryItem] = []
    ) -> ShoppingGenerationDraft {
        let store = recipeStore()
        for item in recipes { try? store.saveUserRecipe(item) }
        return generator.generate(
            source: .todayPlans(plans), inventory: inventory,
            existingShoppingItems: [], recipeStore: store
        )
    }

    private func quantity(_ draft: ShoppingGenerationDraft, _ name: String) -> Double? {
        (draft.missingItems + draft.coveredItems)
            .first { $0.displayName.contains(name) }?.requiredQuantity
    }

    // MARK: - The four cases

    func testBaseAndTargetKnownScalesDown() {
        let r = recipe(ingredients: ["牛肉 500 克"], baseServings: 4)
        let d = draft(recipes: [r], plans: [plan(r, plannedServings: 2)])
        XCTAssertEqual(quantity(d, "牛肉"), 250)
    }

    func testBaseAndTargetKnownScalesUp() {
        let r = recipe(ingredients: ["牛肉 500 克"], baseServings: 4)
        let d = draft(recipes: [r], plans: [plan(r, plannedServings: 7)])
        XCTAssertEqual(quantity(d, "牛肉"), 875)
    }

    func testEqualBaseAndTargetLeavesQuantitiesUnchanged() {
        let r = recipe(ingredients: ["牛肉 500 克"], baseServings: 4)
        let d = draft(recipes: [r], plans: [plan(r, plannedServings: 4)])
        XCTAssertEqual(quantity(d, "牛肉"), 500)
    }

    func testKnownBaseWithNoTargetUsesTheRecipeAsWritten() {
        // Must not be read as "target = 1", which would quarter a 4-serving recipe.
        let r = recipe(ingredients: ["牛肉 500 克"], baseServings: 4)
        let d = draft(recipes: [r], plans: [plan(r, plannedServings: nil)])
        XCTAssertEqual(quantity(d, "牛肉"), 500)
        XCTAssertNil(d.missingItems.first?.warning, "no target was stated, so nothing failed to convert")
    }

    func testUnknownBaseWithATargetKeepsQuantitiesAndWarns() {
        let r = recipe(ingredients: ["牛肉 500 克"])
        let d = draft(recipes: [r], plans: [plan(r, plannedServings: 2)])
        XCTAssertEqual(quantity(d, "牛肉"), 500, "no denominator means no scaling")
        XCTAssertTrue(d.missingItems[0].warning?.contains("基准份量") ?? false)
    }

    func testUnknownBaseAndNoTargetIsSilent() {
        let r = recipe(ingredients: ["牛肉 500 克"])
        let d = draft(recipes: [r], plans: [plan(r, plannedServings: nil)])
        XCTAssertEqual(quantity(d, "牛肉"), 500)
        XCTAssertNil(d.missingItems[0].warning)
    }

    // MARK: - Parser boundary

    func testChineseNumeralQuantityScales() {
        let r = recipe(ingredients: ["鸡蛋 两个"], baseServings: 4)
        let d = draft(recipes: [r], plans: [plan(r, plannedServings: 2)])
        XCTAssertEqual(quantity(d, "鸡蛋"), 1)
    }

    func testDecimalQuantityScales() {
        let r = recipe(ingredients: ["油 1.5 汤匙"], baseServings: 4)
        let d = draft(recipes: [r], plans: [plan(r, plannedServings: 2)])
        XCTAssertEqual(quantity(d, "油"), 0.75)
    }

    func testVagueQuantityStaysVague() {
        // A target must never turn 适量 into a number.
        let r = recipe(ingredients: ["盐 适量"], baseServings: 4)
        let d = draft(recipes: [r], plans: [plan(r, plannedServings: 2)])
        XCTAssertNil(quantity(d, "盐"))
    }

    // MARK: - Aggregation before rounding

    func testCountableQuantitiesAreRoundedUpOnceAfterAggregating() {
        // 3 eggs at 1.5x is 4.5 -> 5. Rounding inside the loop would give 5
        // per recipe and compound across recipes.
        let r = recipe(ingredients: ["鸡蛋 3 个"], baseServings: 2)
        let d = draft(recipes: [r], plans: [plan(r, plannedServings: 3)])
        XCTAssertEqual(quantity(d, "鸡蛋"), 5)
    }

    func testTwoRecipesAggregateBeforeRounding() {
        // 1.2 + 1.2 = 2.4 -> 3. Per-recipe ceiling would give 2 + 2 = 4.
        let a = recipe(id: "a", title: "菜甲", ingredients: ["鸡蛋 2.4 个"], baseServings: 2)
        let b = recipe(id: "b", title: "菜乙", ingredients: ["鸡蛋 2.4 个"], baseServings: 2)
        let d = draft(
            recipes: [a, b],
            plans: [plan(a, plannedServings: 1), plan(b, plannedServings: 1)]
        )
        XCTAssertEqual(quantity(d, "鸡蛋"), 3, "aggregate at full precision, round once")
    }

    func testMassIsNotRoundedUp() {
        let r = recipe(ingredients: ["牛肉 500 克"], baseServings: 4)
        let d = draft(recipes: [r], plans: [plan(r, plannedServings: 7)])
        XCTAssertEqual(quantity(d, "牛肉"), 875, "grams keep their exact value")
    }

    // MARK: - Inventory reconciliation

    func testMissingQuantityIsComputedFromTheScaledRequirement() {
        let r = recipe(ingredients: ["牛肉 500 克"], baseServings: 4)
        let d = draft(
            recipes: [r],
            plans: [plan(r, plannedServings: 2)],
            inventory: [InventoryItem(name: "牛肉", quantity: 100, unit: "克", expiryDate: nil)]
        )
        let beef = d.missingItems.first { $0.displayName.contains("牛肉") }
        XCTAssertEqual(beef?.requiredQuantity, 250)
        XCTAssertEqual(beef?.missingQuantity, 150, "250 needed minus 100 on hand")
    }

    // MARK: - Sources that must not scale

    func testWeeklyHouseholdHeadcountNeverScales() {
        let r = recipe(ingredients: ["牛肉 500 克"], baseServings: 4)
        let weekly = WeeklyMealPlan(
            startDate: Date(),
            days: [WeeklyMealPlanDay(dayIndex: 0, meals: [
                WeeklyMealPlanMeal(mealIndex: 0, title: nil, recipes: [
                    WeeklyMealPlanRecipe(
                        id: r.id, title: r.title, ingredients: r.ingredients,
                        seasonings: [], steps: r.steps, tags: [], cookingTime: nil,
                        difficulty: nil, source: .local, existingRecipeID: r.id
                    )
                ])
            ])],
            shoppingItems: [], servings: 6, summary: nil, createdAt: Date()
        )
        let d = generator.generate(
            source: .weeklyPlan(weekly), inventory: [],
            existingShoppingItems: [], recipeStore: recipeStore()
        )
        XCTAssertEqual(
            quantity(d, "牛肉"), 500,
            "6 people at the table is not 6 servings of every dish"
        )
    }

    func testDirectRecipeSourceStaysAsWritten() {
        let r = recipe(ingredients: ["牛肉 500 克"], baseServings: 4)
        let d = generator.generate(
            source: .recipe(r, servings: 1), inventory: [],
            existingShoppingItems: [], recipeStore: recipeStore()
        )
        XCTAssertEqual(quantity(d, "牛肉"), 500)
    }
}

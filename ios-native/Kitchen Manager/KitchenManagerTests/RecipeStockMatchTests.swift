import XCTest
@testable import KitchenManager

@MainActor
final class RecipeStockMatchTests: XCTestCase {
    private func recipe(_ ingredients: [String], seasonings: [String] = ["盐 少许"]) -> Recipe {
        Recipe(id: UUID().uuidString, title: "菜", cookingTime: nil, difficulty: nil, tags: [],
               ingredients: ingredients, seasonings: seasonings, steps: ["步骤"])
    }

    private func item(_ name: String, quantity: Double = 1, unit: String = "个") -> InventoryItem {
        InventoryItem(name: name, quantity: quantity, unit: unit, expiryDate: nil, createdAt: Date())
    }

    func testMissingListsUnmatchedCoreIngredientsInRecipeOrder() {
        let missing = RecipeStockMatch.missingIngredients(
            in: recipe(["番茄 2个", "鸡蛋 3个", "葱 1根"]),
            inventory: [item("鸡蛋")]
        )
        XCTAssertEqual(missing, ["番茄", "葱"])
    }

    func testOutOfStockRowDoesNotCount() {
        let missing = RecipeStockMatch.missingIngredients(
            in: recipe(["番茄 2个"]),
            inventory: [item("番茄", quantity: 0)]
        )
        XCTAssertEqual(missing, ["番茄"])
    }

    func testDuplicateLinesForOneIngredientCountOnce() {
        let missing = RecipeStockMatch.missingIngredients(
            in: recipe(["番茄 2个", "番茄 1个"]),
            inventory: []
        )
        XCTAssertEqual(missing, ["番茄"])
    }

    func testSeasoningsAreNotConsidered() {
        let missing = RecipeStockMatch.missingIngredients(
            in: recipe(["鸡蛋 3个"], seasonings: ["盐 少许", "生抽 1勺"]),
            inventory: [item("鸡蛋")]
        )
        XCTAssertEqual(missing, [])
    }

    func testPerLineAnswerMatchesListAnswer() {
        let r = recipe(["番茄 2个", "鸡蛋 3个"])
        let inventory = [item("鸡蛋")]
        XCTAssertEqual(RecipeStockMatch.isInStock(line: "番茄 2个", inventory: inventory), false)
        XCTAssertEqual(RecipeStockMatch.isInStock(line: "鸡蛋 3个", inventory: inventory), true)
        let missingByLine = r.ingredients.filter { RecipeStockMatch.isInStock(line: $0, inventory: inventory) == false }
        XCTAssertEqual(missingByLine.count, RecipeStockMatch.missingIngredients(in: r, inventory: inventory).count)
    }

    /// Home readiness, the planner and the shared rule must agree: the names the
    /// projection reports missing are exactly the shortfall in its fraction.
    func testHomeProjectionMissingNamesMatchReadinessShortfall() throws {
        let r = recipe(["番茄 2个", "鸡蛋 3个", "葱 1根"])
        let plan = MealPlanItem(recipeID: r.id, recipeName: r.title)
        let inventory = [item("鸡蛋")]

        let readiness = try XCTUnwrap(HomeMealReadinessProjection.readiness(
            plans: [plan], recipes: { $0 == r.id ? r : nil }, inventory: inventory
        ))
        let missing = HomeMealReadinessProjection.missingIngredients(
            plans: [plan], recipes: { $0 == r.id ? r : nil }, inventory: inventory
        )

        XCTAssertEqual(missing.count, readiness.total - readiness.ready)
        XCTAssertEqual(Set(missing), ["番茄", "葱"])
    }

    func testHomeProjectionIsEmptyWithoutResolvableRecipes() {
        let plan = MealPlanItem(recipeID: "gone", recipeName: "已删除")
        XCTAssertEqual(
            HomeMealReadinessProjection.missingIngredients(plans: [plan], recipes: { _ in nil }, inventory: []),
            []
        )
    }
}

import XCTest
@testable import KitchenManager

/// A dish already cooked tonight no longer needs anything from the kitchen, so
/// its ingredients must not keep reading `今晚 · <dish>` on 食材. Found on the
/// simulator: after 完成这一餐 every ingredient of the cooked dish still said
/// `今晚 · 白菜丸子`.
final class InventoryTonightLinkageTests: XCTestCase {
    private func recipe(_ id: String, _ ingredients: [String]) -> Recipe {
        Recipe(id: id, title: id, cookingTime: nil, difficulty: nil,
               tags: [], ingredients: ingredients, steps: [])
    }

    func testCookedDishNoLongerSpeaksForItsIngredients() {
        let cooked = MealPlanItem(recipeID: "meatballs", recipeName: "白菜丸子", isCooked: true)
        let meatballs = recipe("meatballs", ["猪肉 300 克", "白菜 1 颗"])

        let summaries = InventoryTonightLinkage.summaries(plans: [cooked], recipes: { _ in meatballs })

        XCTAssertEqual(summaries, [:])
    }

    func testOnlyDishesStillToCookAreNamedOrCounted() {
        let cooked = MealPlanItem(recipeID: "omelette", recipeName: "番茄炒蛋", isCooked: true)
        let pending = MealPlanItem(recipeID: "soup", recipeName: "蛋花汤")
        let recipes = [
            "omelette": recipe("omelette", ["鸡蛋 2 个", "番茄 1 个"]),
            "soup": recipe("soup", ["鸡蛋 1 个"])
        ]

        let summaries = InventoryTonightLinkage.summaries(plans: [cooked, pending], recipes: { recipes[$0] })

        // Two plans use 鸡蛋, but only one is still to cook: named, not "2 道菜".
        XCTAssertEqual(summaries, ["鸡蛋": "今晚 · 蛋花汤"])
    }
}

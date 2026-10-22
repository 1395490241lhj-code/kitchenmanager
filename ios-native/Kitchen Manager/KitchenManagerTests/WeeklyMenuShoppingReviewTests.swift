import XCTest
@testable import KitchenManager

/// SHOPPING_LOGIC-7: the weekly menu page's 加入买菜清单 added the AI's list
/// directly — any food with some stock was dropped, "1,500 克" became 1 克, and
/// each tap stacked another copy. The button now opens the same review sheet as
/// ⋯ → 生成购物清单, so these pin the rules that sheet applies to a menu.
@MainActor
final class WeeklyMenuShoppingReviewTests: XCTestCase {
    private func menu() -> WeeklyMealPlan {
        WeeklyMealPlan(
            startDate: Calendar.current.startOfDay(for: Date()),
            days: [WeeklyMealPlanDay(dayIndex: 0, meals: [WeeklyMealPlanMeal(mealIndex: 0, title: "晚餐", recipes: [
                WeeklyMealPlanRecipe(id: "w1", title: "香煎鸡胸", ingredients: ["鸡胸肉 2 块", "大米 1500 克"],
                                     steps: ["煎"], tags: [], cookingTime: nil, difficulty: nil, reason: nil,
                                     source: .ai, existingRecipeID: nil)
            ])])],
            // The AI's own list, which the page used to add as-is.
            shoppingItems: [WeeklyMealPlanShoppingItem(name: "鸡胸肉", quantityText: "1", unit: "块", reason: "还缺 1 块")],
            servings: 2, summary: nil, createdAt: Date()
        )
    }

    private func generate(inventory: [InventoryItem], list: [KitchenShoppingItem] = []) -> ShoppingGenerationDraft {
        ShoppingListGenerator().generate(
            source: .weeklyPlan(menu()),
            inventory: inventory,
            existingShoppingItems: list,
            recipeStore: RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
    }

    func testSomeStockLeavesOnlyTheShortfallInsteadOfDroppingTheFood() throws {
        let draft = generate(inventory: [InventoryItem(name: "鸡胸肉", quantity: 1, unit: "块", expiryDate: nil, createdAt: Date())])
        let chicken = try XCTUnwrap(draft.missingItems.first { $0.displayName == "鸡胸肉" })
        XCTAssertEqual(chicken.missingQuantity, 1)
    }

    func testAThousandsQuantityKeepsItsValue() throws {
        let rice = try XCTUnwrap(generate(inventory: []).missingItems.first { $0.displayName == "大米" })
        XCTAssertEqual(rice.missingQuantity, 1500)
    }

    func testReviewingAgainSaysWhatIsAlreadyListed() throws {
        let draft = generate(inventory: [], list: [KitchenShoppingItem(name: "鸡胸肉", quantity: 2, unit: "块")])
        let chicken = try XCTUnwrap(draft.missingItems.first { $0.displayName == "鸡胸肉" })
        XCTAssertEqual(chicken.warning, "买菜清单中已有「鸡胸肉 2 块」；如果已为这道菜加过，可取消勾选")
    }
}

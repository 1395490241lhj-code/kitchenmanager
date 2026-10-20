import XCTest
@testable import KitchenManager

/// CONSUMPTION-8: the 使用量 field committed only on return or focus loss (the
/// decimal pad has no return key), and a cleared field kept showing the
/// planner's estimated remainder while deducting nothing. The field now writes
/// through on every keystroke and a cleared row says it deducts nothing.
@MainActor
final class ConsumedQuantityEntryTests: XCTestCase {
    private func draft(current: Double?, consumed: Double?) -> InventoryConsumptionDraft {
        InventoryConsumptionDraft(
            id: "豆腐|盒", ingredientName: "豆腐", normalizedName: "豆腐", requiredQuantity: 1, requiredUnit: "盒",
            matchedInventoryID: UUID(), currentQuantity: current, consumedQuantity: consumed,
            resultingQuantity: 1, isSelected: true, warning: nil, sourceRecipeNames: ["麻婆豆腐"]
        )
    }

    func testTypedAmountsAreReadAsTheyAreTyped() {
        XCTAssertEqual(InventoryConsumptionDraft.enteredQuantity(from: "0.5"), 0.5)
        XCTAssertEqual(InventoryConsumptionDraft.enteredQuantity(from: "0,5"), 0.5)
        XCTAssertEqual(InventoryConsumptionDraft.enteredQuantity(from: "0."), 0)
        XCTAssertEqual(InventoryConsumptionDraft.enteredQuantity(from: "1500"), 1500)
    }

    func testEmptyOrUnreadableTextIsNoAmount() {
        XCTAssertNil(InventoryConsumptionDraft.enteredQuantity(from: ""))
        XCTAssertNil(InventoryConsumptionDraft.enteredQuantity(from: "  "))
        XCTAssertNil(InventoryConsumptionDraft.enteredQuantity(from: "半"))
        XCTAssertNil(InventoryConsumptionDraft.enteredQuantity(from: "-1"))
    }

    func testRemainderFollowsTheAmountOnScreen() {
        XCTAssertEqual(draft(current: 2, consumed: 0.5).remainingAfterDeduction, 1.5)
        XCTAssertEqual(draft(current: 1, consumed: 3).remainingAfterDeduction, 0)
    }

    func testAClearedAmountShowsNoRemainderInsteadOfTheOldEstimate() {
        XCTAssertNil(draft(current: 2, consumed: nil).remainingAfterDeduction,
                     "the planner's resultingQuantity (1) must not be shown for a row that deducts nothing")
    }

    /// The confirm button reads the drafts directly, so what the field wrote is
    /// what gets deducted.
    func testConfirmDeductsTheEditedAmountAndNothingForAClearedRow() throws {
        let kitchen = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
                                   persistence: KitchenPersistenceFactory.isolatedInMemory())
        let recipes = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        kitchen.addInventory(name: "豆腐", quantity: 2, unit: "盒", expiryDate: nil)
        kitchen.addInventory(name: "牛肉", quantity: 500, unit: "克", expiryDate: nil)
        let dish = Recipe(id: "mapo", title: "麻婆豆腐", cookingTime: nil, difficulty: nil, tags: [],
                          ingredients: ["豆腐 1 盒", "牛肉 100 克"], steps: ["烧"])
        let target = CookConsumptionTarget.directRecipe(recipe: dish, servings: 1)
        let store = CookConsumptionStore()
        store.buildDrafts(target: target, kitchenStore: kitchen, recipeStore: recipes)

        let tofu = try XCTUnwrap(store.drafts.firstIndex { $0.ingredientName == "豆腐" })
        store.drafts[tofu].consumedQuantity = InventoryConsumptionDraft.enteredQuantity(from: "0.5")
        let beef = try XCTUnwrap(store.drafts.firstIndex { $0.ingredientName == "牛肉" })
        store.drafts[beef].consumedQuantity = InventoryConsumptionDraft.enteredQuantity(from: "")
        XCTAssertTrue(store.confirm(target: target, recipeID: dish.id, recipeName: dish.title,
                                    kitchenStore: kitchen, recipeStore: recipes))

        XCTAssertEqual(kitchen.inventory.first { $0.name == "豆腐" }?.quantity, 1.5)
        XCTAssertEqual(kitchen.inventory.first { $0.name == "牛肉" }?.quantity, 500)
    }
}

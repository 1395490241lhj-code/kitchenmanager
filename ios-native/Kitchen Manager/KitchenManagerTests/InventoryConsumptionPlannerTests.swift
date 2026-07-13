import XCTest
@testable import KitchenManager

@MainActor
final class InventoryConsumptionPlannerTests: XCTestCase {
    private let planner = InventoryConsumptionPlanner()

    private func recipe(title: String, ingredients: [String]) -> Recipe {
        Recipe(id: UUID().uuidString, title: title, cookingTime: nil, difficulty: nil, tags: [], ingredients: ingredients, steps: ["步骤"])
    }

    private func item(_ name: String, quantity: Double, unit: String, expiryDate: Date? = nil) -> InventoryItem {
        InventoryItem(name: name, quantity: quantity, unit: unit, expiryDate: expiryDate, createdAt: Date())
    }

    private func input(_ recipe: Recipe, servings: Int = 1) -> InventoryConsumptionPlanner.RecipeConsumptionInput {
        .init(recipe: recipe, servings: servings)
    }

    // MARK: - Normal deduction

    func test_singleRecipe_deductsSingleIngredient() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 2个"]))],
            inventory: [item("番茄", quantity: 5, unit: "个")]
        )
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].requiredQuantity, 2)
        XCTAssertEqual(drafts[0].currentQuantity, 5)
        XCTAssertEqual(drafts[0].consumedQuantity, 2)
        XCTAssertEqual(drafts[0].resultingQuantity, 3)
    }

    func test_singleRecipe_deductsMultipleIngredients() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 2个", "鸡蛋 3个"]))],
            inventory: [item("番茄", quantity: 5, unit: "个"), item("鸡蛋", quantity: 10, unit: "个")]
        )
        XCTAssertEqual(drafts.count, 2)
    }

    func test_multipleRecipes_shareDeductionOfSameIngredient() {
        let drafts = planner.plan(
            for: [
                input(recipe(title: "菜1", ingredients: ["鸡胸肉 300g"])),
                input(recipe(title: "菜2", ingredients: ["鸡胸肉 200g"]))
            ],
            inventory: [item("鸡胸肉", quantity: 1000, unit: "g")]
        )
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].requiredQuantity, 500)
        XCTAssertEqual(drafts[0].resultingQuantity, 500)
    }

    // MARK: - Unit conversion

    func test_inventoryInKg_recipeInGrams_convertsCorrectly() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["面粉 500g"]))],
            inventory: [item("面粉", quantity: 2, unit: "kg")]
        )
        XCTAssertEqual(drafts[0].currentQuantity ?? 0, 2000, accuracy: 0.001)
        XCTAssertEqual(drafts[0].consumedQuantity ?? 0, 500, accuracy: 0.001)
        XCTAssertEqual(drafts[0].resultingQuantity ?? 0, 1500, accuracy: 0.001)
    }

    func test_inventoryInLiters_recipeInMilliliters_convertsCorrectly() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["牛奶 250ml"]))],
            inventory: [item("牛奶", quantity: 1, unit: "l")]
        )
        XCTAssertEqual(drafts[0].currentQuantity ?? 0, 1000, accuracy: 0.001)
        XCTAssertEqual(drafts[0].resultingQuantity ?? 0, 750, accuracy: 0.001)
    }

    func test_sameUnit_noConversionNeeded() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 2个"]))],
            inventory: [item("番茄", quantity: 5, unit: "个")]
        )
        XCTAssertEqual(drafts[0].currentQuantity, 5)
    }

    func test_incompatibleUnits_treatedAsNoMatch_forQuantityPurposes() {
        // Inventory exists under the same normalized name but in an
        // unconvertible unit ("个" vs the recipe's "克"); availableQuantity
        // for that requirement's unit must come back nil rather than a wrong
        // number, and the item is still matched (so the UI can flag it) but
        // with no usable current quantity.
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["鸡蛋 300克"]))],
            inventory: [item("鸡蛋", quantity: 6, unit: "个")]
        )
        XCTAssertEqual(drafts.count, 1)
        XCTAssertNotNil(drafts[0].matchedInventoryID, "still matched by name even though units are incompatible")
        XCTAssertNil(drafts[0].currentQuantity, "no usable quantity when units cannot be converted")
    }

    func test_ingredientWithNoUnit_sumsRawQuantities() {
        // "生菜" (not "盐") on purpose: Recipe's own classifier reclassifies
        // seasoning names like 盐/鱼露 into `.seasonings`, which this planner
        // never reads (only `recipe.ingredients`) — 生菜 stays a normal
        // ingredient so this actually exercises the planner.
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["生菜 少许"]))],
            inventory: [item("生菜", quantity: 1, unit: "包")]
        )
        // "少许" has no numeric quantity/unit, so requiredUnit is nil and
        // availableQuantity sums raw inventory quantities directly.
        XCTAssertEqual(drafts[0].currentQuantity, 1)
    }

    // MARK: - Insufficient inventory

    func test_partialInventory_consumesWhatIsAvailable() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 10个"]))],
            inventory: [item("番茄", quantity: 3, unit: "个")]
        )
        XCTAssertEqual(drafts[0].consumedQuantity, 3)
        XCTAssertEqual(drafts[0].resultingQuantity, 0)
    }

    func test_noInventoryAtAll_setsNotFoundWarning_noMatchedID() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 2个"]))],
            inventory: []
        )
        XCTAssertNil(drafts[0].matchedInventoryID)
        XCTAssertNotNil(drafts[0].warning)
        XCTAssertTrue(drafts[0].warning?.contains("没有找到") ?? false)
    }

    func test_multipleBatches_combineToSatisfyRequirement() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 10个"]))],
            inventory: [
                item("番茄", quantity: 4, unit: "个", expiryDate: DateComponents(calendar: .current, year: 2026, month: 1, day: 5).date),
                item("番茄", quantity: 6, unit: "个", expiryDate: DateComponents(calendar: .current, year: 2026, month: 1, day: 10).date)
            ]
        )
        // `currentQuantity` sums matching batches for display purposes.
        XCTAssertEqual(drafts[0].currentQuantity, 10)
    }

    func test_matchingInventory_picksEarliestExpiringBatchFirst() {
        // InventoryConsumptionPlanner.matchingInventory sorts by remainingDays
        // ascending, so the first-matched (and thus displayed) batch id is
        // the earliest-expiring one — verified against the item ids directly.
        let soonest = item("番茄", quantity: 4, unit: "个", expiryDate: DateComponents(calendar: .current, year: 2026, month: 1, day: 3).date)
        let later = item("番茄", quantity: 6, unit: "个", expiryDate: DateComponents(calendar: .current, year: 2026, month: 1, day: 20).date)
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 2个"]))],
            inventory: [later, soonest]
        )
        XCTAssertEqual(drafts[0].matchedInventoryID, soonest.id, "the earliest-expiring batch must be the one referenced first")
    }

    // MARK: - Name matching (via IngredientNormalizer)

    func test_jiXiongRou_matchesJiXiongRouInventory_exactNormalizedName() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["鸡胸肉 200g"]))],
            inventory: [item("鸡胸肉", quantity: 500, unit: "g")]
        )
        XCTAssertNotNil(drafts[0].matchedInventoryID)
    }

    func test_fanQie_matchesXiHongShiInventory_viaAlias() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 2个"]))],
            inventory: [item("西红柿", quantity: 5, unit: "个")]
        )
        XCTAssertNotNil(drafts[0].matchedInventoryID, "西红柿 normalizes to 番茄, so it must match")
    }

    func test_niuRouJiang_doesNotMatchNiuRouInventory() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["牛肉酱 1勺"]))],
            inventory: [item("牛肉", quantity: 500, unit: "g")]
        )
        XCTAssertNil(drafts[0].matchedInventoryID, "牛肉酱 must not match 牛肉 inventory")
    }

    func test_xiaJiang_doesNotMatchXiaInventory() {
        // "虾酱" (not "鱼露"): "鱼露" is in Recipe's own directSeasoningNames
        // list and gets reclassified into `.seasonings` before this planner
        // ever sees it; "虾酱" is not, so it stays in `.ingredients` and
        // actually exercises the planner's name-matching guard.
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["虾酱 1勺"]))],
            inventory: [item("虾", quantity: 500, unit: "g")]
        )
        XCTAssertNil(drafts[0].matchedInventoryID, "虾酱 must not match 虾 inventory")
    }

    func test_cong_andXiaoCong_matchTheSameInventoryEntry() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["小葱 1根"]))],
            inventory: [item("葱", quantity: 3, unit: "根")]
        )
        XCTAssertNotNil(drafts[0].matchedInventoryID, "小葱 normalizes to 葱")
    }

    // MARK: - Abnormal input

    func test_recipeWithNoIngredients_producesNoDrafts() {
        let drafts = planner.plan(for: [input(recipe(title: "菜", ingredients: []))], inventory: [])
        XCTAssertTrue(drafts.isEmpty)
    }

    func test_inventoryWithZeroQuantity_isNotAvailable_treatedAsNotFound() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 2个"]))],
            inventory: [item("番茄", quantity: 0, unit: "个")]
        )
        XCTAssertNil(drafts[0].matchedInventoryID, "a zero-quantity item is not `isAvailable` and must not match")
    }

    func test_duplicateIngredientLines_mergeIntoOneRequirement() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 2个", "番茄 3个"]))],
            inventory: [item("番茄", quantity: 10, unit: "个")]
        )
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].requiredQuantity, 5)
    }

    func test_vagueQuantityIngredient_setsWarning() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["生菜 适量"]))],
            inventory: [item("生菜", quantity: 1, unit: "包")]
        )
        XCTAssertNotNil(drafts[0].warning)
    }
}

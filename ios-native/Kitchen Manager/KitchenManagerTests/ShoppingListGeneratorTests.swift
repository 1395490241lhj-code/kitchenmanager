import XCTest
@testable import KitchenManager

@MainActor
final class ShoppingListGeneratorTests: XCTestCase {
    private var recipeStore: RecipeStore!
    private let generator = ShoppingListGenerator()

    override func setUp() {
        super.setUp()
        recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    override func tearDown() {
        recipeStore = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func recipe(
        id: String = UUID().uuidString,
        title: String,
        ingredients: [String],
        steps: [String] = ["步骤"]
    ) -> Recipe {
        Recipe(id: id, title: title, cookingTime: nil, difficulty: nil, tags: [], ingredients: ingredients, steps: steps)
    }

    private func item(
        _ name: String,
        quantity: Double,
        unit: String,
        expiryDate: Date? = nil
    ) -> InventoryItem {
        InventoryItem(name: name, quantity: quantity, unit: unit, expiryDate: expiryDate, createdAt: Date())
    }

    private let farPast = DateComponents(calendar: .current, year: 2000, month: 1, day: 1).date!
    private let farFuture = DateComponents(calendar: .current, year: 2999, month: 1, day: 1).date!

    private func generate(
        _ recipe: Recipe,
        servings: Int = 1,
        inventory: [InventoryItem] = [],
        existingShoppingItems: [KitchenShoppingItem] = [],
        includeSeasonings: Bool = false
    ) -> ShoppingGenerationDraft {
        generator.generate(
            source: .recipe(recipe, servings: servings),
            inventory: inventory,
            existingShoppingItems: existingShoppingItems,
            recipeStore: recipeStore,
            includeSeasonings: includeSeasonings
        )
    }

    // MARK: - Single recipe / inventory coverage

    func test_singleRecipe_allIngredientsMissing_noInventory() {
        let draft = generate(recipe(title: "番茄炒蛋", ingredients: ["番茄 2个", "鸡蛋 3个"]))
        XCTAssertEqual(draft.missingItems.count, 2)
        XCTAssertTrue(draft.coveredItems.isEmpty)
    }

    func test_singleRecipe_allIngredientsCovered_sufficientInventory() {
        let draft = generate(
            recipe(title: "番茄炒蛋", ingredients: ["番茄 2个", "鸡蛋 3个"]),
            inventory: [item("番茄", quantity: 5, unit: "个"), item("鸡蛋", quantity: 10, unit: "个")]
        )
        XCTAssertEqual(draft.coveredItems.count, 2)
        XCTAssertTrue(draft.missingItems.isEmpty)
    }

    func test_singleRecipe_partialInventoryCoverage() {
        let draft = generate(
            recipe(title: "番茄炒蛋", ingredients: ["番茄 5个"]),
            inventory: [item("番茄", quantity: 2, unit: "个")]
        )
        XCTAssertEqual(draft.missingItems.count, 1)
        XCTAssertEqual(draft.missingItems[0].missingQuantity, 3)
        XCTAssertEqual(draft.missingItems[0].availableQuantity, 2)
    }

    func test_singleRecipe_inventoryExactlyCoversRequirement() {
        let draft = generate(
            recipe(title: "番茄炒蛋", ingredients: ["番茄 3个"]),
            inventory: [item("番茄", quantity: 3, unit: "个")]
        )
        XCTAssertEqual(draft.coveredItems.count, 1)
        XCTAssertEqual(draft.coveredItems[0].missingQuantity, 0)
    }

    func test_singleRecipe_inventoryExceedsRequirement() {
        let draft = generate(
            recipe(title: "番茄炒蛋", ingredients: ["番茄 2个"]),
            inventory: [item("番茄", quantity: 10, unit: "个")]
        )
        XCTAssertEqual(draft.coveredItems.count, 1)
        XCTAssertEqual(draft.coveredItems[0].availableQuantity, 10)
    }

    func test_expiredInventory_isNotCountedAsAvailable() {
        let draft = generate(
            recipe(title: "番茄炒蛋", ingredients: ["番茄 2个"]),
            inventory: [item("番茄", quantity: 10, unit: "个", expiryDate: farPast)]
        )
        // The expired batch must be excluded entirely, so this behaves as
        // "no inventory at all" -> fully missing, not partially covered.
        XCTAssertEqual(draft.missingItems.count, 1)
        XCTAssertNil(draft.missingItems[0].availableQuantity)
        XCTAssertEqual(draft.missingItems[0].missingQuantity, 2)
    }

    func test_nonExpiredInventory_stillCountsAsAvailable() {
        let draft = generate(
            recipe(title: "番茄炒蛋", ingredients: ["番茄 2个"]),
            inventory: [item("番茄", quantity: 10, unit: "个", expiryDate: farFuture)]
        )
        XCTAssertEqual(draft.coveredItems.count, 1)
    }

    // MARK: - Multi-recipe merge

    func test_twoRecipes_bothNeedChicken_mergedIntoOneRequirement() {
        let draft = generator.generate(
            source: .selectedRecipes([
                recipe(title: "菜1", ingredients: ["鸡胸肉 300g"]),
                recipe(title: "菜2", ingredients: ["鸡胸肉 200g"])
            ], servings: 1),
            inventory: [],
            existingShoppingItems: [],
            recipeStore: recipeStore
        )
        XCTAssertEqual(draft.missingItems.count, 1)
        XCTAssertEqual(draft.missingItems[0].requiredQuantity, 500)
        XCTAssertEqual(draft.missingItems[0].sourceRecipeNames.sorted(), ["菜1", "菜2"])
    }

    func test_twoRecipes_convertibleUnits_mergeIntoCanonicalGrams() {
        let draft = generator.generate(
            source: .selectedRecipes([
                recipe(title: "菜1", ingredients: ["鸡胸肉 500g"]),
                recipe(title: "菜2", ingredients: ["鸡胸肉 0.5kg"])
            ], servings: 1),
            inventory: [],
            existingShoppingItems: [],
            recipeStore: recipeStore
        )
        XCTAssertEqual(draft.missingItems.count, 1, "500g and 0.5kg must merge into a single canonical-gram requirement")
        XCTAssertEqual(draft.missingItems[0].requiredQuantity ?? 0, 1000, accuracy: 0.001)
        XCTAssertEqual(draft.missingItems[0].unit, "克")
    }

    func test_twoRecipes_nonConvertibleUnits_doNotMerge() {
        let draft = generator.generate(
            source: .selectedRecipes([
                recipe(title: "菜1", ingredients: ["鸡蛋 2个"]),
                recipe(title: "菜2", ingredients: ["鸡蛋 300克"])
            ], servings: 1),
            inventory: [],
            existingShoppingItems: [],
            recipeStore: recipeStore
        )
        // "个" and "克" are not convertible, so these must stay as two
        // separate requirements rather than being silently combined.
        XCTAssertEqual(draft.missingItems.count, 2)
        XCTAssertEqual(Set(draft.missingItems.map(\.unit)), Set(["个", "克"]))
    }

    // MARK: - Servings

    func test_servingsOfOne_producesNoServingsWarning() {
        let draft = generate(recipe(title: "菜", ingredients: ["番茄 2个"]), servings: 1)
        XCTAssertNil(draft.missingItems[0].warning)
    }

    func test_servingsOtherThanOne_addsWarning_becauseQuantityIsNotActuallyRescaled() {
        // Documented current behavior (not a bug fixed in this pass — see
        // final report): requesting a serving count other than 1 does NOT
        // scale ingredient quantities. It only adds a warning telling the
        // user to double check, which the warning text itself states
        // explicitly ("用量未按人数换算").
        let draftDoubled = generate(recipe(title: "菜", ingredients: ["番茄 2个"]), servings: 4)
        let draftSingle = generate(recipe(title: "菜", ingredients: ["番茄 2个"]), servings: 1)
        XCTAssertEqual(draftDoubled.missingItems[0].requiredQuantity, draftSingle.missingItems[0].requiredQuantity, "quantity is not rescaled by servings in the current implementation")
        XCTAssertNotNil(draftDoubled.missingItems[0].warning)
        XCTAssertTrue(draftDoubled.missingItems[0].warning?.contains("人数") ?? false)
    }

    func test_missingQuantity_isNeverNegative() {
        let draft = generate(
            recipe(title: "菜", ingredients: ["番茄 2个"]),
            inventory: [item("番茄", quantity: 100, unit: "个")]
        )
        XCTAssertEqual(draft.coveredItems[0].missingQuantity, 0)
    }

    // MARK: - Seasonings toggle

    func test_includeSeasonings_false_excludesSaltAndSoySauce() {
        let recipeWithSeasonings = recipe(title: "菜", ingredients: ["猪肉 300克", "盐 适量", "生抽 1勺"])
        let draft = generate(recipeWithSeasonings, includeSeasonings: false)
        XCTAssertFalse(draft.missingItems.contains { $0.displayName == "盐" })
        XCTAssertFalse(draft.missingItems.contains { $0.displayName == "生抽" })
        XCTAssertTrue(draft.missingItems.contains { $0.displayName == "猪肉" })
    }

    func test_includeSeasonings_true_includesSaltAndSoySauce() {
        let recipeWithSeasonings = recipe(title: "菜", ingredients: ["猪肉 300克", "盐 适量", "生抽 1勺"])
        let draft = generate(recipeWithSeasonings, includeSeasonings: true)
        XCTAssertTrue(draft.missingItems.contains { $0.displayName == "盐" })
        XCTAssertTrue(draft.missingItems.contains { $0.displayName == "生抽" })
    }

    func test_condimentLookingIngredient_doesNotMatchBaseIngredientInInventory() {
        // "牛肉酱" (a processed product) must not be treated as the same
        // ingredient as "牛肉" (fresh beef) sitting in inventory.
        let draft = generate(
            recipe(title: "菜", ingredients: ["牛肉酱 1勺"]),
            inventory: [item("牛肉", quantity: 10, unit: "克")]
        )
        XCTAssertEqual(draft.missingItems.count, 1)
        XCTAssertEqual(draft.missingItems[0].displayName, "牛肉酱")
        XCTAssertNil(draft.missingItems[0].availableQuantity, "牛肉 in inventory must not be matched against 牛肉酱")
    }

    // MARK: - Existing shopping list merge note

    func test_existingPendingShoppingItem_addsPendingMergeNote() {
        let draft = generate(
            recipe(title: "菜", ingredients: ["番茄 3个"]),
            existingShoppingItems: [KitchenShoppingItem(name: "番茄", quantity: 1, unit: "个", isDone: false)]
        )
        XCTAssertNotNil(draft.missingItems[0].warning)
        XCTAssertTrue(draft.missingItems[0].warning?.contains("买菜清单中已有") ?? false)
    }

    func test_doneShoppingItem_doesNotTriggerMergeNote() {
        // Per the current implementation, `existingShoppingItems.first(where: { !$0.isDone && ... })`
        // explicitly excludes completed items from the merge-note check.
        let draft = generate(
            recipe(title: "菜", ingredients: ["番茄 3个"]),
            existingShoppingItems: [KitchenShoppingItem(name: "番茄", quantity: 1, unit: "个", isDone: true)]
        )
        XCTAssertNil(draft.missingItems[0].warning)
    }

    // MARK: - Ordering / stability

    func test_missingItems_areSortedByLocalizedDisplayName() {
        let draft = generate(recipe(title: "菜", ingredients: ["黄瓜 1个", "番茄 1个", "鸡蛋 1个"]))
        XCTAssertEqual(draft.missingItems.map(\.displayName), draft.missingItems.map(\.displayName).sorted { $0.localizedCompare($1) == .orderedAscending })
    }

    func test_generate_isDeterministic_repeatedRunsProduceSameOrder() {
        let testRecipe = recipe(title: "菜", ingredients: ["黄瓜 1个", "番茄 1个", "鸡蛋 1个", "土豆 1个"])
        let first = generate(testRecipe)
        let second = generate(testRecipe)
        XCTAssertEqual(first.missingItems.map(\.displayName), second.missingItems.map(\.displayName))
    }

    // MARK: - No recipes resolved

    func test_emptySelectedRecipes_producesNoFoundWarning() {
        let draft = generator.generate(
            source: .selectedRecipes([], servings: 1),
            inventory: [],
            existingShoppingItems: [],
            recipeStore: recipeStore
        )
        XCTAssertEqual(draft.recipeCount, 0)
        XCTAssertEqual(draft.warnings, ["没有找到可用的菜谱"])
    }
}

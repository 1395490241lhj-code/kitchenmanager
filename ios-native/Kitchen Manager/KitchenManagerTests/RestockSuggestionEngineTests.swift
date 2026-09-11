import XCTest
@testable import KitchenManager

@MainActor
final class RestockSuggestionEngineTests: XCTestCase {
    private var kitchenStore: KitchenStore!
    private var recipeStore: RecipeStore!
    private let engine = RestockSuggestionEngine()

    override func setUp() {
        super.setUp()
        kitchenStore = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    override func tearDown() {
        kitchenStore = nil
        recipeStore = nil
        super.tearDown()
    }

    private func addQuantityStaple(
        name: String,
        quantity: Double,
        threshold: Double,
        defaultRestockQuantity: Double? = nil,
        autoSuggestRestock: Bool = true
    ) {
        try? kitchenStore.saveStaple(
            id: nil,
            name: name,
            quantity: quantity,
            unit: "个",
            minimumQuantity: threshold,
            defaultRestockQuantity: defaultRestockQuantity,
            autoSuggestRestock: autoSuggestRestock,
            note: nil,
            category: nil,
            trackingMode: .quantity
        )
    }

    // MARK: - Quantity-mode threshold behavior

    func test_quantityBelowThreshold_generatesSuggestion() {
        addQuantityStaple(name: "鸡蛋", quantity: 1, threshold: 5)
        let suggestions = engine.generate(kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertTrue(suggestions.contains { $0.name == "鸡蛋" })
    }

    func test_quantityEqualToThreshold_isSufficient_noSuggestion() {
        addQuantityStaple(name: "鸡蛋", quantity: 5, threshold: 5)
        let suggestions = engine.generate(kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertFalse(suggestions.contains { $0.name == "鸡蛋" })
    }

    func test_quantityAboveThreshold_noSuggestion() {
        addQuantityStaple(name: "鸡蛋", quantity: 10, threshold: 5)
        let suggestions = engine.generate(kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertFalse(suggestions.contains { $0.name == "鸡蛋" })
    }

    func test_autoSuggestRestockDisabled_neverSuggestsEvenWhenLow() {
        addQuantityStaple(name: "鸡蛋", quantity: 0, threshold: 5, autoSuggestRestock: false)
        let suggestions = engine.generate(kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertFalse(suggestions.contains { $0.name == "鸡蛋" })
    }

    // MARK: - Status-mode tracking

    func test_statusMode_available_noSuggestion() {
        try? kitchenStore.saveStaple(
            id: nil, name: "葱", quantity: 1, unit: "根", minimumQuantity: nil,
            defaultRestockQuantity: nil, autoSuggestRestock: true, note: nil, category: nil,
            trackingMode: .status, availabilityStatus: .available
        )
        let suggestions = engine.generate(kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertFalse(suggestions.contains { $0.name == "葱" })
    }

    func test_statusMode_low_generatesSuggestion() {
        try? kitchenStore.saveStaple(
            id: nil, name: "葱", quantity: 1, unit: "根", minimumQuantity: nil,
            defaultRestockQuantity: nil, autoSuggestRestock: true, note: nil, category: nil,
            trackingMode: .status, availabilityStatus: .low
        )
        let suggestions = engine.generate(kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertTrue(suggestions.contains { $0.name == "葱" })
    }

    func test_statusMode_missing_generatesSuggestionWithOutOfStockReason() {
        try? kitchenStore.saveStaple(
            id: nil, name: "葱", quantity: 1, unit: "根", minimumQuantity: nil,
            defaultRestockQuantity: nil, autoSuggestRestock: true, note: nil, category: nil,
            trackingMode: .status, availabilityStatus: .missing
        )
        let suggestions = engine.generate(kitchenStore: kitchenStore, recipeStore: recipeStore)
        let suggestion = suggestions.first { $0.name == "葱" }
        XCTAssertNotNil(suggestion)
        XCTAssertEqual(suggestion?.reason, "常备食材已缺货")
    }

    // MARK: - Default restock quantity

    func test_defaultRestockQuantity_isUsedWhenSet() {
        addQuantityStaple(name: "鸡蛋", quantity: 1, threshold: 5, defaultRestockQuantity: 12)
        let suggestion = engine.generate(kitchenStore: kitchenStore, recipeStore: recipeStore).first { $0.name == "鸡蛋" }
        XCTAssertEqual(suggestion?.suggestedQuantity, 12)
    }

    func test_noDefaultRestockQuantity_fallsBackToThresholdGap() {
        addQuantityStaple(name: "鸡蛋", quantity: 1, threshold: 5)
        let suggestion = engine.generate(kitchenStore: kitchenStore, recipeStore: recipeStore).first { $0.name == "鸡蛋" }
        XCTAssertEqual(suggestion?.suggestedQuantity, 4) // 5 - 1
    }

    // MARK: - Multiple staples, no duplicates

    func test_multipleLowStaples_allProduceSuggestions_noDuplicates() {
        addQuantityStaple(name: "鸡蛋", quantity: 0, threshold: 5)
        addQuantityStaple(name: "牛奶", quantity: 0, threshold: 2)
        let suggestions = engine.generate(kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(Set(suggestions.map(\.id)).count, suggestions.count, "no duplicate ids")
    }

    func test_result_isSortedByLocalizedName() {
        addQuantityStaple(name: "牛奶", quantity: 0, threshold: 2)
        addQuantityStaple(name: "鸡蛋", quantity: 0, threshold: 5)
        let suggestions = engine.generate(kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertEqual(suggestions.map(\.name), suggestions.map(\.name).sorted { $0.localizedCompare($1) == .orderedAscending })
    }

    func test_generate_isDeterministic_acrossRepeatedCalls() {
        addQuantityStaple(name: "牛奶", quantity: 0, threshold: 2)
        addQuantityStaple(name: "鸡蛋", quantity: 0, threshold: 5)
        let first = engine.generate(kitchenStore: kitchenStore, recipeStore: recipeStore)
        let second = engine.generate(kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertEqual(first.map(\.name), second.map(\.name))
    }

    // MARK: - justConsumed

    func test_justConsumedItemFullyDepleted_generatesConsumedSuggestion() {
        let record = InventoryConsumptionRecordItem(
            inventoryItemID: UUID(), ingredientName: "番茄", consumedQuantity: 2, unit: "个",
            previousQuantity: 2, resultingQuantity: 0
        )
        let suggestions = engine.generate(kitchenStore: kitchenStore, recipeStore: recipeStore, justConsumed: [record])
        let suggestion = suggestions.first { $0.name == "番茄" }
        XCTAssertNotNil(suggestion)
        XCTAssertEqual(suggestion?.source, .consumed)
    }

    func test_justConsumedItemStillHasStock_doesNotGenerateSuggestion() {
        let record = InventoryConsumptionRecordItem(
            inventoryItemID: UUID(), ingredientName: "番茄", consumedQuantity: 1, unit: "个",
            previousQuantity: 3, resultingQuantity: 2
        )
        let suggestions = engine.generate(kitchenStore: kitchenStore, recipeStore: recipeStore, justConsumed: [record])
        XCTAssertFalse(suggestions.contains { $0.name == "番茄" })
    }

    func test_stapleSuggestion_takesPriorityOverConsumedSuggestion_forSameIngredient() {
        // The staple loop runs first and populates the dictionary; the
        // justConsumed loop explicitly skips keys already present.
        addQuantityStaple(name: "鸡蛋", quantity: 0, threshold: 5)
        let record = InventoryConsumptionRecordItem(
            inventoryItemID: UUID(), ingredientName: "鸡蛋", consumedQuantity: 1, unit: "个",
            previousQuantity: 1, resultingQuantity: 0
        )
        let suggestions = engine.generate(kitchenStore: kitchenStore, recipeStore: recipeStore, justConsumed: [record])
        let matches = suggestions.filter { $0.name == "鸡蛋" }
        XCTAssertEqual(matches.count, 1, "must not duplicate — same normalized key")
        XCTAssertEqual(matches.first?.source, .pantryStaple)
    }

    // MARK: - Existing shopping list items do not suppress suggestions

    func test_existingShoppingListItem_doesNotSuppressStapleSuggestion() {
        // Documented current behavior: RestockSuggestionEngine never checks
        // kitchenStore.shoppingItems for staple/consumed suggestions, so an
        // already-pending shopping item does not filter this list.
        kitchenStore.addShopping(name: "鸡蛋", quantity: 1, unit: "个")
        addQuantityStaple(name: "鸡蛋", quantity: 0, threshold: 5)
        let suggestions = engine.generate(kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertTrue(suggestions.contains { $0.name == "鸡蛋" })
    }

    // MARK: - Scheduled meals come from the plan, never from a generated menu

    @discardableResult
    private func savedRecipe(title: String, ingredients: [String]) -> Recipe {
        let made = Recipe(
            id: UUID().uuidString, title: title, cookingTime: nil, difficulty: nil,
            tags: [], ingredients: ingredients, steps: ["做好"]
        )
        try? recipeStore.saveUserRecipe(made)
        return made
    }

    @discardableResult
    private func schedule(_ recipe: Recipe, inDays offset: Int, cooked: Bool = false) -> MealPlanItem {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let item = MealPlanItem(recipeID: recipe.id, recipeName: recipe.title, date: date, isCooked: cooked)
        kitchenStore.plans.append(item)
        return item
    }

    /// A menu the generator produced and nobody added to the plan.
    private func seedUnaddedMenu(dish: String, ingredient: String) {
        kitchenStore.weeklyPlan = WeeklyMealPlan(
            startDate: Date(),
            days: [WeeklyMealPlanDay(dayIndex: 0, meals: [
                WeeklyMealPlanMeal(mealIndex: 0, title: "晚餐", recipes: [
                    WeeklyMealPlanRecipe(
                        id: UUID().uuidString, title: dish, ingredients: [ingredient], steps: ["炒熟"],
                        tags: [], cookingTime: 10, difficulty: "简单",
                        reason: nil, source: .ai, existingRecipeID: nil
                    )
                ])
            ])],
            shoppingItems: [], servings: 4, summary: nil, createdAt: Date(), materialization: nil
        )
    }

    private func plannedSuggestions() -> [RestockSuggestion] {
        engine.generate(kitchenStore: kitchenStore, recipeStore: recipeStore).filter { $0.source == .plannedMeals }
    }

    func test_generatedMenuNobodyAdded_producesNoScheduledSuggestion() {
        seedUnaddedMenu(dish: "番茄炒蛋", ingredient: "番茄 2 个")
        XCTAssertTrue(plannedSuggestions().isEmpty, "a menu nobody added to the plan is not a schedule")
    }

    func test_plannedMealWithinTheHorizon_producesAForwardLookingSuggestion() {
        schedule(savedRecipe(title: "番茄炒蛋", ingredients: ["番茄 2 个"]), inDays: 0)
        let suggestion = plannedSuggestions().first { $0.name.contains("番茄") }
        XCTAssertEqual(suggestion?.reason, "未来 7 天计划需要")
    }

    func test_plannedMealBeyondTheHorizon_producesNothing() {
        schedule(savedRecipe(title: "番茄炒蛋", ingredients: ["番茄 2 个"]), inDays: 7)
        XCTAssertTrue(plannedSuggestions().isEmpty)
    }

    func test_aMealAlreadyCooked_producesNothing() {
        schedule(savedRecipe(title: "番茄炒蛋", ingredients: ["番茄 2 个"]), inDays: 0, cooked: true)
        XCTAssertTrue(plannedSuggestions().isEmpty)
    }

    func test_removingThePlannedMeal_removesItsSuggestion() {
        let planned = schedule(savedRecipe(title: "番茄炒蛋", ingredients: ["番茄 2 个"]), inDays: 1)
        XCTAssertFalse(plannedSuggestions().isEmpty)

        kitchenStore.plans.removeAll { $0.id == planned.id }
        XCTAssertTrue(plannedSuggestions().isEmpty, "deleting the meal takes its shopping need with it")
    }

    func test_aMenuOnTheScreenChangesNothing_onlyItsPlanEntriesCount() {
        // Exactly the state after materialization: the menu record still
        // exists, and what restock sees is the canonical meals it produced.
        seedUnaddedMenu(dish: "草稿菜", ingredient: "草稿食材 2 个")
        schedule(savedRecipe(title: "已排菜", ingredients: ["排好的食材 2 个"]), inDays: 2)

        let names = plannedSuggestions().map(\.name)
        XCTAssertTrue(names.contains { $0.contains("排好的食材") })
        XCTAssertFalse(names.contains { $0.contains("草稿食材") })
    }

    func test_theSuggestionsDoNotDependOnWhetherAMenuExists() {
        // Nothing in this path reads the menu record or its materialization
        // receipt, so the same plan must produce the same answer either way.
        schedule(savedRecipe(title: "番茄炒蛋", ingredients: ["番茄 2 个"]), inDays: 1)
        let withoutMenu = plannedSuggestions().map(\.name)

        seedUnaddedMenu(dish: "另一道", ingredient: "另一样 1 个")
        XCTAssertEqual(plannedSuggestions().map(\.name), withoutMenu)
    }

    func test_aPlanPointingAtAMissingRecipe_isSkippedRatherThanFatal() {
        kitchenStore.plans.append(
            MealPlanItem(recipeID: "recipe-that-no-longer-exists", recipeName: "消失的菜", date: Date())
        )
        schedule(savedRecipe(title: "番茄炒蛋", ingredients: ["番茄 2 个"]), inDays: 0)

        let names = plannedSuggestions().map(\.name)
        XCTAssertTrue(names.contains { $0.contains("番茄") }, "one broken reference must not take the rest down")
        XCTAssertFalse(names.contains { $0.contains("消失") })
    }

    func test_theSameDishTwiceInOneDay_isCountedTwiceNotRejected() {
        let dish = savedRecipe(title: "番茄炒蛋", ingredients: ["番茄 2 个"])
        schedule(dish, inDays: 0)
        let single = plannedSuggestions().first { $0.name.contains("番茄") }?.suggestedQuantity

        schedule(dish, inDays: 0)
        let doubled = plannedSuggestions().first { $0.name.contains("番茄") }?.suggestedQuantity

        XCTAssertNotNil(single)
        XCTAssertEqual(doubled ?? 0, (single ?? 0) * 2, accuracy: 0.001)
    }

    func test_enoughInStock_meansNothingToBuy() {
        schedule(savedRecipe(title: "番茄炒蛋", ingredients: ["番茄 2 个"]), inDays: 0)
        kitchenStore.addInventory(name: "番茄", quantity: 10, unit: "个", expiryDate: nil)
        XCTAssertTrue(plannedSuggestions().isEmpty, "the shortage maths is unchanged; there is simply no shortage")
    }
}

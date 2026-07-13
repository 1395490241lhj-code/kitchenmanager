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
}

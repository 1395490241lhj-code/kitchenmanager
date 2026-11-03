import XCTest
@testable import KitchenManager

/// Stock with no unit is saved as 「份」, which no recipe unit converts to, so
/// cooking never deducted it and the sheet offered no way to. A row whose
/// stock is all in one such unit now takes an amount in that unit.
@MainActor
final class ManualStockUnitConsumptionTests: XCTestCase {
    private let planner = InventoryConsumptionPlanner()

    private func recipe(title: String, ingredients: [String]) -> Recipe {
        Recipe(id: UUID().uuidString, title: title, cookingTime: nil, difficulty: nil, tags: [], ingredients: ingredients, steps: ["步骤"])
    }

    private func item(_ name: String, quantity: Double, unit: String) -> InventoryItem {
        InventoryItem(name: name, quantity: quantity, unit: unit, expiryDate: nil, createdAt: Date())
    }

    private func plan(_ ingredients: [String], _ inventory: [InventoryItem]) throws -> InventoryConsumptionDraft {
        try XCTUnwrap(planner.plan(for: [.init(recipe: recipe(title: "菜", ingredients: ingredients), servings: 1)], inventory: inventory).first)
    }

    private func stores() -> (KitchenStore, RecipeStore) {
        (KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!),
         RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!))
    }

    // MARK: - Planner

    func test_stockAllInOneUnconvertibleUnit_canBeDeductedByHand() throws {
        let draft = try plan(["番茄 2个"], [item("番茄", quantity: 1, unit: "份"), item("番茄", quantity: 0.5, unit: "份")])

        XCTAssertEqual(draft.manualStockUnit, "份")
        XCTAssertEqual(draft.manualStockQuantity, 1.5)
        XCTAssertTrue(draft.allowsSelection, "the toggle is no longer locked")
        XCTAssertFalse(draft.isSelected, "still off until the user says how much was used")
        XCTAssertNil(draft.consumedQuantity, "no amount is guessed across units")
        XCTAssertNil(draft.currentQuantity, "nothing is available in the recipe's unit")
        XCTAssertEqual(draft.warning, "库存按「份」记，和菜谱单位不同。要扣减，请填写用掉几份。")
    }

    func test_stockInSeveralUnconvertibleUnits_staysOutOfTheDeduction() throws {
        let draft = try plan(["番茄 2个"], [item("番茄", quantity: 1, unit: "份"), item("番茄", quantity: 1, unit: "盒")])

        XCTAssertNil(draft.manualStockUnit, "one amount cannot say how much of each unit was used")
        XCTAssertNil(draft.manualStockQuantity)
        XCTAssertFalse(draft.allowsSelection)
        XCTAssertFalse(draft.isSelected)
        XCTAssertTrue(draft.warning?.contains("无法换算，未扣减") ?? false)
    }

    func test_convertibleStock_hasNoManualUnit() throws {
        let same = try plan(["番茄 2个"], [item("番茄", quantity: 5, unit: "个")])
        XCTAssertNil(same.manualStockUnit)
        XCTAssertNil(same.manualStockQuantity)

        let mixed = try plan(["鸡蛋 2个"], [item("鸡蛋", quantity: 6, unit: "个"), item("鸡蛋", quantity: 1, unit: "盒")])
        XCTAssertNil(mixed.manualStockUnit, "a row that already deducts in the recipe's unit keeps doing so")
        XCTAssertEqual(mixed.consumedQuantity, 2)

        let weight = try plan(["猪肉 200克"], [item("猪肉", quantity: 1, unit: "斤")])
        XCTAssertNil(weight.manualStockUnit)
    }

    func test_statusStapleRow_isUnchanged() throws {
        let (kitchenStore, _) = stores()
        try kitchenStore.saveStaple(
            id: nil, name: "葱", quantity: 0, unit: "份",
            minimumQuantity: nil, defaultRestockQuantity: nil, autoSuggestRestock: true,
            note: nil, category: nil, trackingMode: .status, availabilityStatus: .available
        )
        let draft = try plan(["葱 2根"], kitchenStore.inventory)

        XCTAssertNotNil(draft.statusStapleText)
        XCTAssertNil(draft.manualStockUnit)
        XCTAssertFalse(draft.allowsSelection)
        XCTAssertFalse(draft.isSelected)
    }

    func test_remainingAfterDeduction_readsTheStockUnit() throws {
        var draft = try plan(["番茄 2个"], [item("番茄", quantity: 2, unit: "份")])
        XCTAssertNil(draft.remainingAfterDeduction, "nothing entered, nothing deducted")
        draft.consumedQuantity = 0.5
        XCTAssertEqual(draft.remainingAfterDeduction, 1.5)
    }

    /// UX-3: an amount typed into a manual-unit row says the member means it,
    /// so the row switches on. Clearing it to retype leaves the switch alone.
    func test_typingAnAmountInTheStockUnit_switchesTheRowOn() throws {
        var draft = try plan(["番茄 2个"], [item("番茄", quantity: 2, unit: "份")])
        draft.consumedQuantity = 0
        draft.noteConsumedQuantityEdited()
        XCTAssertFalse(draft.isSelected, "0 is not an amount used")
        draft.consumedQuantity = 1
        draft.noteConsumedQuantityEdited()
        XCTAssertTrue(draft.isSelected, "填了用掉几份，这一行就打开")
        draft.consumedQuantity = nil
        draft.noteConsumedQuantityEdited()
        XCTAssertTrue(draft.isSelected)
    }

    func test_typingInAnOrdinaryRow_leavesItsSwitchAlone() throws {
        var draft = try plan(["番茄 2个"], [item("番茄", quantity: 3, unit: "个")])
        draft.isSelected = false
        draft.consumedQuantity = 1
        draft.noteConsumedQuantityEdited()
        XCTAssertFalse(draft.isSelected, "only the manual-unit row is switched on by typing")
    }

    /// The note under a manual-unit row follows the row, rather than always
    /// saying the unit is why nothing is deducted.
    func test_manualUnitRowNote_followsTheRow() throws {
        var draft = try plan(["番茄 2个"], [item("番茄", quantity: 2, unit: "份")])
        XCTAssertEqual(draft.unconvertibleRowNote, .notDeducted)
        draft.isSelected = true
        XCTAssertEqual(draft.unconvertibleRowNote, .needsAmount)
        draft.consumedQuantity = 0
        XCTAssertEqual(draft.unconvertibleRowNote, .needsAmount)
        draft.consumedQuantity = 0.5
        XCTAssertEqual(draft.unconvertibleRowNote, .remaining(1.5))
    }

    func test_severalUnitsRowNote_isAlwaysNotDeducted() throws {
        var draft = try plan(["番茄 2个"], [item("番茄", quantity: 1, unit: "份"), item("番茄", quantity: 1, unit: "盒")])
        draft.isSelected = true
        draft.consumedQuantity = 1
        XCTAssertEqual(draft.unconvertibleRowNote, .notDeducted)
    }

    // MARK: - Applying

    func test_confirmDeductsTheTypedAmountInTheStockUnit_andUndoRestoresIt() throws {
        let (kitchenStore, recipeStore) = stores()
        let dish = recipe(title: "番茄炒蛋", ingredients: ["番茄 2个"])
        kitchenStore.addInventory(name: "番茄", quantity: 2, unit: "份", expiryDate: nil)
        let store = CookConsumptionStore()
        store.buildDrafts(planIDs: [], recipe: dish, kitchenStore: kitchenStore, recipeStore: recipeStore)
        store.drafts[0].isSelected = true
        store.drafts[0].consumedQuantity = 1

        XCTAssertTrue(store.confirm(planIDs: [], recipeID: dish.id, recipeName: dish.title, kitchenStore: kitchenStore, recipeStore: recipeStore))

        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 1)
        let record = try XCTUnwrap(kitchenStore.consumptionRecords.first)
        XCTAssertEqual(record.items.count, 1)
        XCTAssertEqual(record.items.first?.unit, "份", "recorded in the row's own unit")
        XCTAssertEqual(record.items.first?.consumedQuantity, 1)
        XCTAssertEqual(record.items.first?.previousQuantity, 2)
        XCTAssertEqual(record.items.first?.resultingQuantity, 1)

        XCTAssertEqual(kitchenStore.undoConsumption(record), .undone)
        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 2)
    }

    func test_selectedWithoutAnAmount_deductsNothing() throws {
        let (kitchenStore, recipeStore) = stores()
        let dish = recipe(title: "番茄炒蛋", ingredients: ["番茄 2个"])
        kitchenStore.addInventory(name: "番茄", quantity: 2, unit: "份", expiryDate: nil)
        let store = CookConsumptionStore()
        store.buildDrafts(planIDs: [], recipe: dish, kitchenStore: kitchenStore, recipeStore: recipeStore)
        store.drafts[0].isSelected = true

        XCTAssertTrue(store.confirm(planIDs: [], recipeID: dish.id, recipeName: dish.title, kitchenStore: kitchenStore, recipeStore: recipeStore))

        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 2)
        XCTAssertEqual(kitchenStore.consumptionRecords.first?.items, [])
    }

    /// The 个 batch expires first, so FEFO reaches it first; a 份 amount must
    /// still only come out of the 份 batch.
    func test_manualUnitDeductsOnlyBatchesInThatUnit() throws {
        let (kitchenStore, _) = stores()
        kitchenStore.addInventory(name: "番茄", quantity: 3, unit: "个", expiryDate: Date().addingTimeInterval(86_400))
        kitchenStore.addInventory(name: "番茄", quantity: 2, unit: "份", expiryDate: Date().addingTimeInterval(86_400 * 5))
        var draft = InventoryConsumptionDraft(
            id: "番茄|个", ingredientName: "番茄", normalizedName: "番茄",
            requiredQuantity: 2, requiredUnit: "个", matchedInventoryID: nil,
            currentQuantity: nil, consumedQuantity: 1, resultingQuantity: nil,
            isSelected: true, warning: nil, sourceRecipeNames: ["菜"]
        )
        draft.manualStockUnit = "份"
        draft.manualStockQuantity = 2

        let record = kitchenStore.applyConsumption([draft], planIDs: [], recipeID: nil, recipeName: "菜")

        XCTAssertEqual(kitchenStore.inventory.first { $0.unit == "个" }?.quantity, 3)
        XCTAssertEqual(kitchenStore.inventory.first { $0.unit == "份" }?.quantity, 1)
        XCTAssertEqual(record.items.map(\.unit), ["份"])
    }
}

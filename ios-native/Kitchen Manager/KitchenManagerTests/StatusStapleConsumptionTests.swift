import XCTest
@testable import KitchenManager

/// A status-tracked staple (葱姜蒜盐油 in 有货 / 快没了 / 缺货 mode) holds no real
/// count: its quantity is a placeholder kept at 1 so every `isAvailable` reader
/// sees it as present. Cooking must never deduct that placeholder, or the shelf
/// keeps saying 有货 while matching, shopping and AI call it missing.
@MainActor
final class StatusStapleConsumptionTests: XCTestCase {
    private var kitchen: KitchenStore!
    private var recipes: RecipeStore!

    override func setUp() {
        super.setUp()
        kitchen = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        recipes = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func recipe(_ lines: [String]) -> Recipe {
        Recipe(id: UUID().uuidString, title: "葱油拌面", cookingTime: nil, difficulty: nil,
               tags: [], ingredients: lines, steps: ["拌匀"])
    }

    private func saveStatusStaple(_ name: String, _ status: StapleAvailabilityStatus) throws {
        try kitchen.saveStaple(
            id: nil, name: name, quantity: 0, unit: "份",
            minimumQuantity: nil, defaultRestockQuantity: nil, autoSuggestRestock: true,
            note: nil, category: nil, trackingMode: .status, availabilityStatus: status
        )
    }

    private func staple(_ name: String) throws -> InventoryItem {
        try XCTUnwrap(kitchen.inventory.first { $0.name == name && $0.isStaple })
    }

    /// Builds the sheet the way cooking does and confirms it untouched.
    @discardableResult
    private func cook(_ recipe: Recipe) -> CookConsumptionStore {
        let store = CookConsumptionStore()
        store.buildDrafts(planIDs: [], recipe: recipe, kitchenStore: kitchen, recipeStore: recipes)
        _ = store.confirm(planIDs: [], recipeID: recipe.id, recipeName: recipe.title,
                          kitchenStore: kitchen, recipeStore: recipes)
        return store
    }

    func testCookingANumberWithoutAUnitNeverDeductsAStatusStaple() throws {
        for status in [StapleAvailabilityStatus.available, .low] {
            setUp()
            try saveStatusStaple("葱", status)
            cook(recipe(["面条 200 克", "葱 2"]))
            let 葱 = try staple("葱")
            XCTAssertEqual(葱.quantity, 1, "\(status): the placeholder count is not stock to deduct")
            XCTAssertEqual(葱.stapleAvailabilityStatus, status, "\(status)")
            XCTAssertTrue(葱.isAvailable, "\(status): still present for matching, shopping and AI")
        }
    }

    private func drafts(_ recipe: Recipe) -> [InventoryConsumptionDraft] {
        InventoryConsumptionPlanner().plan(for: [.init(recipe: recipe, servings: nil)], inventory: kitchen.inventory)
    }

    private func row(_ name: String, in drafts: [InventoryConsumptionDraft]) throws -> InventoryConsumptionDraft {
        try XCTUnwrap(drafts.first { $0.ingredientName == name })
    }

    func testAUnitTheStapleIsNotHeldInAndAnUnstatedAmountDeductNothingEither() throws {
        for line in ["葱 2 根", "葱 适量"] {
            setUp()
            try saveStatusStaple("葱", .available)
            cook(recipe(["面条 200 克", line]))
            XCTAssertEqual(try staple("葱").quantity, 1, line)
            XCTAssertTrue(RecipeStockMatch.isInStock("葱", inventory: kitchen.inventory), line)
        }
    }

    /// The sheet says the staple is there and why it is left alone, instead of
    /// 库存中没有找到 or an amount to confirm that would never be deducted.
    func testTheSheetShowsTheStapleAsPresentAndExplainsWhyItIsNotDeducted() throws {
        for (line, status) in [("葱 2", StapleAvailabilityStatus.available), ("葱 适量", .low)] {
            setUp()
            try saveStatusStaple("葱", status)
            let 葱 = try row("葱", in: drafts(recipe([line])))
            XCTAssertEqual(葱.statusStapleText, status.title, line)
            XCTAssertEqual(葱.matchedInventoryID, try staple("葱").id, "\(line): present for every presence reader")
            XCTAssertFalse(葱.isSelected, line)
            XCTAssertNil(葱.consumedQuantity, line)
            let warning = try XCTUnwrap(葱.warning, line)
            XCTAssertTrue(warning.contains("不会自动扣减"), warning)
            XCTAssertFalse(warning.contains("没有找到"), warning)
            XCTAssertFalse(warning.contains("用量不明确"), warning)
        }
    }

    /// 缺货 keeps its placeholder at 0, so it is honestly not in stock — the
    /// existing presence rule, unchanged — and there is nothing to deduct.
    func testAnOutOfStockStatusStapleIsNotInStockAndStaysAtZero() throws {
        try saveStatusStaple("葱", .missing)
        let 葱 = try row("葱", in: drafts(recipe(["葱 2"])))
        XCTAssertNil(葱.matchedInventoryID)
        XCTAssertNil(葱.statusStapleText)
        XCTAssertFalse(RecipeStockMatch.isInStock("葱", inventory: kitchen.inventory))
        cook(recipe(["葱 2"]))
        XCTAssertEqual(try staple("葱").quantity, 0)
        XCTAssertEqual(try staple("葱").stapleAvailabilityStatus, .missing)
    }

    func testAQuantityTrackedStapleAndOrdinaryStockAreDeductedAsBefore() throws {
        try kitchen.saveStaple(
            id: nil, name: "葱", quantity: 3, unit: "根",
            minimumQuantity: nil, defaultRestockQuantity: nil, autoSuggestRestock: true,
            note: nil, category: nil, trackingMode: .quantity, availabilityStatus: .available
        )
        kitchen.addInventory(name: "姜", quantity: 3, unit: "块", expiryDate: nil)
        cook(recipe(["葱 2 根", "姜 1 块"]))
        XCTAssertEqual(try staple("葱").quantity, 1, "a counted staple is real stock")
        XCTAssertEqual(try XCTUnwrap(kitchen.inventory.first { $0.name == "姜" }).quantity, 2)
    }

    /// With a status staple and a counted batch of the same food, only the
    /// batch is counted and deducted, and undo restores exactly that.
    func testMixedStockDeductsOnlyTheCountedBatchAndUndoRestoresIt() throws {
        for line in ["葱 2", "葱 2 根"] {
            setUp()
            try saveStatusStaple("葱", .available)
            kitchen.addInventory(name: "葱", quantity: 3, unit: "根", expiryDate: nil)
            let batchID = try XCTUnwrap(kitchen.inventory.first { $0.name == "葱" && !$0.isStaple }).id

            let 葱 = try row("葱", in: drafts(recipe([line])))
            XCTAssertEqual(葱.currentQuantity, 3, "\(line): the placeholder is not added to the count")
            XCTAssertNil(葱.statusStapleText, line)
            XCTAssertTrue(try XCTUnwrap(葱.warning, line).contains("常备食材按状态记录"), line)

            cook(recipe([line]))
            let record = try XCTUnwrap(kitchen.consumptionRecords.first, line)
            XCTAssertEqual(record.items.map(\.inventoryItemID), [batchID], "\(line): only the counted batch is in the receipt")
            XCTAssertEqual(try XCTUnwrap(kitchen.inventory.first { $0.id == batchID }).quantity, 1, line)
            XCTAssertEqual(try staple("葱").quantity, 1, line)

            XCTAssertEqual(kitchen.undoConsumption(record), .undone, line)
            XCTAssertEqual(try XCTUnwrap(kitchen.inventory.first { $0.id == batchID }).quantity, 3, line)
            XCTAssertEqual(try staple("葱").quantity, 1, line)
            XCTAssertEqual(try staple("葱").stapleAvailabilityStatus, .available, line)
        }
    }

    /// The store refuses too, so a draft built anywhere else cannot reach the
    /// placeholder either.
    func testApplyingAHandBuiltDraftNeverDeductsAStatusStaple() throws {
        try saveStatusStaple("葱", .available)
        let draft = InventoryConsumptionDraft(
            id: "葱|none", ingredientName: "葱", normalizedName: "葱",
            requiredQuantity: 1, requiredUnit: nil, matchedInventoryID: try staple("葱").id,
            currentQuantity: 1, consumedQuantity: 1, resultingQuantity: 0,
            isSelected: true, warning: nil, sourceRecipeNames: ["葱油拌面"]
        )
        let record = kitchen.applyConsumption([draft], planIDs: [], recipeID: nil, recipeName: "葱油拌面")
        XCTAssertTrue(record.items.isEmpty)
        XCTAssertEqual(try staple("葱").quantity, 1)
    }
}

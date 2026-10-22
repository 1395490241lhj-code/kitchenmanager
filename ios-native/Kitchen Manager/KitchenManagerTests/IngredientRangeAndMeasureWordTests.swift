import XCTest
@testable import KitchenManager

/// SHOPPING_LOGIC-5 / RECIPES_LOGIC-6: "鸡蛋 2-3 个" parsed as a food named
/// "鸡蛋 2-" with 3, "蒜 3 瓣" kept the whole line as its name, and scaling a
/// range read "4-3 个". Ranges are one quantity (the upper end) and the common
/// measure words 条/棵/瓣/枚/粒/朵 are units.
final class IngredientRangeAndMeasureWordTests: XCTestCase {
    private func assertParsed(_ line: String, name: String, quantity: Double?, unit: String?,
                              file: StaticString = #filePath, lineNumber: UInt = #line) {
        let parsed = IngredientParser.parse(line)
        XCTAssertEqual(parsed.displayName, name, line, file: file, line: lineNumber)
        XCTAssertEqual(parsed.quantity, quantity, line, file: file, line: lineNumber)
        XCTAssertEqual(parsed.unit, unit, line, file: file, line: lineNumber)
    }

    func testRangesAreOneQuantityAtTheirUpperEnd() {
        assertParsed("鸡蛋 2-3 个", name: "鸡蛋", quantity: 3, unit: "个")
        assertParsed("鸡蛋 2-3个", name: "鸡蛋", quantity: 3, unit: "个")
        assertParsed("生抽 1~2 勺", name: "生抽", quantity: 2, unit: "勺")
        assertParsed("料酒 1～2 勺", name: "料酒", quantity: 2, unit: "勺")
        assertParsed("鸡蛋 2-3", name: "鸡蛋", quantity: 3, unit: nil)
    }

    func testEverydayMeasureWordsAreUnits() {
        assertParsed("蒜 3 瓣", name: "蒜", quantity: 3, unit: "瓣")
        assertParsed("鲈鱼 1 条", name: "鲈鱼", quantity: 1, unit: "条")
        assertParsed("白菜 1 棵", name: "白菜", quantity: 1, unit: "棵")
        assertParsed("鸡蛋 2 枚", name: "鸡蛋", quantity: 2, unit: "枚")
        assertParsed("花椒 20 粒", name: "花椒", quantity: 20, unit: "粒")
        assertParsed("西兰花 1 朵", name: "西兰花", quantity: 1, unit: "朵")
        assertParsed("一条鱼", name: "鱼", quantity: 1, unit: "条")
        assertParsed("蒜三瓣", name: "蒜", quantity: 3, unit: "瓣")
    }

    func testNamesEndingInAMeasureWordAreLeftWhole() {
        assertParsed("油条", name: "油条", quantity: nil, unit: nil)
        assertParsed("蒜瓣", name: "蒜瓣", quantity: nil, unit: nil)
        assertParsed("面条 200 克", name: "面条", quantity: 200, unit: "克")
    }

    /// Only a separator between two digits joins a range; a lone minus is
    /// read exactly as before (quantity 5, see `test_negativeNumber_…`).
    func testALeadingMinusIsStillNotARange() {
        let parsed = IngredientParser.parse("鸡蛋 -5 个")
        XCTAssertEqual(parsed.quantity, 5)
        XCTAssertEqual(parsed.unit, "个")
    }

    func testScalingARangeScalesBothEnds() {
        XCTAssertEqual(RecipeServingScaler.scaledText("鸡蛋 2-3 个", multiplier: 2), "鸡蛋 4-6 个")
        XCTAssertEqual(RecipeServingScaler.scaledText("生抽 1~2 勺", multiplier: 0.5), "生抽 ½~1 勺")
        XCTAssertEqual(RecipeServingScaler.scaledText("鸡蛋 2 个", multiplier: 2), "鸡蛋 4 个")
    }

    /// The parsed name now matches stock, so a range line is not "missing"
    /// when the kitchen has the food.
    @MainActor
    func testARangeLineMatchesStockAndBuysTheUpperEnd() {
        let recipe = Recipe(id: "eggs", title: "炒蛋", cookingTime: nil, difficulty: nil, tags: [],
                            ingredients: ["鸡蛋 2-3 个", "蒜 3 瓣"], steps: ["炒"])
        let draft = ShoppingListGenerator().generate(
            source: .recipe(recipe, servings: 1),
            inventory: [InventoryItem(name: "鸡蛋", quantity: 1, unit: "个", expiryDate: nil, createdAt: Date())],
            existingShoppingItems: [],
            recipeStore: RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        let eggs = draft.missingItems.first { $0.displayName == "鸡蛋" }
        XCTAssertEqual(eggs?.availableQuantity, 1)
        XCTAssertEqual(eggs?.missingQuantity, 2)
        XCTAssertEqual(draft.missingItems.first { $0.displayName == "蒜" }?.unit, "瓣")
    }
}

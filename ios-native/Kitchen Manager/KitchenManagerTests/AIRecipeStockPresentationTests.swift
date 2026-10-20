import XCTest
@testable import KitchenManager

/// The recipe card's kitchen rows and the transcript's recipe grouping are
/// pure projections; these pin their wording and shape without a simulator UI.
@MainActor
final class AIRecipeStockPresentationTests: XCTestCase {
    private func summary(inStock: [String] = [], missing: [String] = [], expiring: [String] = []) -> RecipeStockMatch.Summary {
        RecipeStockMatch.Summary(inStock: inStock, missing: missing, expiring: expiring)
    }

    func testAllPresentRecipeNamesWhatToUseUpWithoutClaimingEnough() {
        let lines = AIRecipeStockPresentation.lines(for: summary(inStock: ["番茄", "鸡蛋"], expiring: ["鸡蛋"]))
        XCTAssertEqual(lines.map(\.kind), [.inStock, .allPresent, .expiring])
        XCTAssertEqual(lines.map(\.text), ["家里有 番茄、鸡蛋", "所需食材已在库 · 用量未核对", "可用掉临期 鸡蛋"])
        XCTAssertEqual(lines[1].spoken, "所需食材已在库，用量未核对")
    }

    /// RecipeStockMatch is presence only. One egg on hand for a six-egg recipe
    /// reads as in stock — and the card must not turn that into 可直接做.
    func testShortQuantityReadsAsPresentAndNeverAsReadyToCook() {
        let recipe = Recipe(id: "omelette", title: "厚蛋烧", cookingTime: nil, difficulty: nil, tags: [],
                            ingredients: ["鸡蛋 6 个"], steps: ["煎"])
        let oneEgg = InventoryItem(name: "鸡蛋", quantity: 1, unit: "个", expiryDate: nil, createdAt: Date())
        let stock = RecipeStockMatch.summary(for: recipe, inventory: [oneEgg], expiring: [])
        XCTAssertEqual(stock.inStock, ["鸡蛋"])
        XCTAssertEqual(stock.missing, [])

        let lines = AIRecipeStockPresentation.lines(for: stock)
        XCTAssertEqual(lines.map(\.text), ["家里有 鸡蛋", "所需食材已在库 · 用量未核对"])
        for line in lines {
            XCTAssertFalse(line.text.contains("可直接做") || line.spoken.contains("可直接做"), line.text)
            XCTAssertFalse(line.text.contains("够") || line.spoken.contains("够"), line.text)
        }
    }

    /// Same 还缺 wording as Home; the screen keeps three names, VoiceOver all.
    func testLongShortfallShowsThreeNamesButSpeaksEveryOne() {
        let lines = AIRecipeStockPresentation.lines(for: summary(missing: ["花生米", "大葱", "生姜", "大蒜"]))
        XCTAssertEqual(lines.map(\.kind), [.missing])
        XCTAssertEqual(lines.first?.text, "还缺 花生米、大葱、生姜 等 4 样")
        XCTAssertEqual(lines.first?.spoken, "还缺花生米、大葱、生姜、大蒜")
    }

    func testNothingJudgeableProducesNoRows() {
        XCTAssertTrue(AIRecipeStockPresentation.lines(for: summary()).isEmpty)
    }

    func testAdjacentRecipesInOneMessageFormOneRun() {
        func recipe(_ title: String) -> AIContentBlock {
            .recipe(AIRecipeBlock(recipe: Recipe(id: title, title: title, cookingTime: nil, difficulty: nil,
                tags: [], ingredients: ["鸡蛋 1 个"], steps: ["炒"]), isTransient: true))
        }
        let text = AIContentBlock.text(.init(text: "试试"))
        let first = recipe("a"), second = recipe("b"), third = recipe("c")
        let runs = AIContentBlockRun.runs([text, first, second, .text(.init(text: "或者")), third])

        XCTAssertEqual(runs.count, 4)
        guard case let .recipes(id, group) = runs[1] else { return XCTFail("adjacent recipes should group") }
        XCTAssertEqual(group.map(\.recipe.title), ["a", "b"])
        XCTAssertEqual(id, first.id, "the group keeps its first block's identity while it grows")
        guard case .single(.recipe) = runs[3] else { return XCTFail("a lone recipe stays a single block") }
    }
}

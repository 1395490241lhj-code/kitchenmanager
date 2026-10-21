import XCTest
@testable import KitchenManager

/// RECIPES_LOGIC-11: emptying an ingredient row dropped it on the next read,
/// the later rows moved up, and the focused field went on editing the next
/// line. Rows now keep their identity while empty.
final class RecipeEditableLinesTests: XCTestCase {
    private func rows(_ text: String) -> [RecipeEditableLine] {
        RecipeEditableLines.rows(for: text)
    }

    func testEmptyingARowKeepsItAndEveryRowsIdentity() {
        var lines = rows("番茄 2 个\n鸡蛋 3 个\n葱 1 根")
        let ids = lines.map(\.id)
        lines[1].text = ""

        let reread = RecipeEditableLines.rows(for: RecipeEditableLines.joined(lines), reusing: lines)
        XCTAssertEqual(reread.map(\.id), ids)
        XCTAssertEqual(reread.map(\.text), ["番茄 2 个", "", "葱 1 根"],
                       "the emptied row stays where it was, so typing goes back into it")
    }

    func testEmptyingTheOnlyRowKeepsTheRow() {
        var lines = rows("鸡蛋 3 个")
        lines[0].text = ""
        let reread = RecipeEditableLines.rows(for: RecipeEditableLines.joined(lines), reusing: lines)
        XCTAssertEqual(reread.count, 1)
        XCTAssertEqual(reread.first?.id, lines.first?.id)
    }

    func testTypingATrailingSpaceIsNotTrimmedAway() {
        var lines = rows("鸡蛋")
        lines[0].text = "鸡蛋 "
        let reread = RecipeEditableLines.rows(for: RecipeEditableLines.joined(lines), reusing: lines)
        XCTAssertEqual(reread.first?.text, "鸡蛋 ")
    }

    func testALineAddedFromOutsideKeepsTheExistingIds() {
        let lines = rows("番茄 2 个\n鸡蛋 3 个")
        let reread = RecipeEditableLines.rows(for: "番茄 2 个\n鸡蛋 3 个\n葱花", reusing: lines)
        XCTAssertEqual(Array(reread.prefix(2).map(\.id)), lines.map(\.id))
        XCTAssertEqual(reread.last?.text, "葱花")
    }

    func testSavingDropsEmptyAndPaddedLines() throws {
        var draft = EditableRecipeDraft()
        draft.title = "番茄炒蛋"
        draft.ingredientsText = "番茄 2 个\n\n鸡蛋 3 个 "
        draft.stepsText = "炒"
        XCTAssertEqual(try draft.makeRecipe().ingredients, ["番茄 2 个", "鸡蛋 3 个"])
    }

    func testMovingARowRemovesItAndAppendsItToTheOtherBucket() {
        let lines = rows("番茄 2 个\n葱花 1 根")
        let moved = RecipeEditableLines.moving(lines[1].id, from: lines, into: "盐 少许")
        XCTAssertEqual(moved.rows.map(\.text), ["番茄 2 个"])
        XCTAssertEqual(moved.otherText, "盐 少许\n葱花 1 根")
    }

    func testMovingALineTheOtherBucketHoldsWordForWordDoesNotDuplicateIt() {
        let lines = rows("葱花 1 根")
        let moved = RecipeEditableLines.moving(lines[0].id, from: lines, into: "葱花 1 根")
        XCTAssertTrue(moved.rows.isEmpty)
        XCTAssertEqual(moved.otherText, "葱花 1 根")
    }
}

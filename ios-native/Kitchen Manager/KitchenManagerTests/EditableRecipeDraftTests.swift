import XCTest
@testable import KitchenManager

@MainActor
final class EditableRecipeDraftTests: XCTestCase {
    private var validDraft: EditableRecipeDraft {
        EditableRecipeDraft(title: "番茄炒蛋", ingredientsText: "番茄\n鸡蛋", stepsText: "切块\n炒熟")
    }

    private func assertEligibility(_ draft: EditableRecipeDraft, expected: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(draft.isSaveEligible, expected, file: file, line: line)
        if expected {
            XCTAssertNoThrow(try draft.makeRecipe(), file: file, line: line)
        } else {
            XCTAssertThrowsError(try draft.makeRecipe(), file: file, line: line)
        }
    }

    func testEmptyTitleIsRejected() {
        var draft = validDraft
        draft.title = ""
        assertEligibility(draft, expected: false)
    }

    func testWhitespaceOnlyTitleIsRejected() {
        var draft = validDraft
        draft.title = " \n\t "
        assertEligibility(draft, expected: false)
    }

    func testNoIngredientsIsRejected() {
        var draft = validDraft
        draft.ingredientsText = ""
        assertEligibility(draft, expected: false)
    }

    func testBlankOnlyIngredientsAreRejected() {
        var draft = validDraft
        draft.ingredientsText = " \n\t "
        assertEligibility(draft, expected: false)
    }

    func testNoStepsIsRejected() {
        var draft = validDraft
        draft.stepsText = ""
        assertEligibility(draft, expected: false)
    }

    func testBlankOnlyStepsAreRejected() {
        var draft = validDraft
        draft.stepsText = " \n\t "
        assertEligibility(draft, expected: false)
    }

    func testMixedBlankAndValidLinesAreAccepted() {
        var draft = validDraft
        draft.title = "  番茄炒蛋  "
        draft.ingredientsText = "\n 番茄 \n \t\n"
        draft.stepsText = "\n1. 切块\n2.\n"
        assertEligibility(draft, expected: true)
    }

    func testFullyValidDraftIsAccepted() {
        assertEligibility(validDraft, expected: true)
    }
}

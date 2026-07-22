import XCTest
@testable import KitchenManager

final class HomeDashboardPresentationTests: XCTestCase {
    func testReminderPrecedesClipboardAndModuleIssues() {
        XCTAssertEqual(
            HomeDashboardPresentation.supplementarySections(
                hasReminder: true,
                showsClipboardPrompt: true,
                hasModuleIssues: true
            ),
            [.reminder, .clipboardPrompt, .moduleIssues]
        )
    }

    func testAbsentPresentationSectionsAreNotInsertedAsPlaceholders() {
        XCTAssertEqual(
            HomeDashboardPresentation.supplementarySections(
                hasReminder: false,
                showsClipboardPrompt: true,
                hasModuleIssues: false
            ),
            [.clipboardPrompt]
        )
    }
}

import XCTest
@testable import KitchenManager

@MainActor
final class HomeDashboardPresentationTests: XCTestCase {
    func testChineseDateDoesNotDependOnCurrentLocale() {
        let date = Date(timeIntervalSince1970: 1_784_678_400)
        XCTAssertEqual(HomeDatePresentation.text(for: date, timeZone: TimeZone(secondsFromGMT: 0)!), "7月22日 星期三")
    }

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

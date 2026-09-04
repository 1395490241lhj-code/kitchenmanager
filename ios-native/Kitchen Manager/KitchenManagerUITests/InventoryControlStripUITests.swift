#if DEBUG
import XCTest

/// The Inventory control layer has to actually filter, not just look
/// interactive. These drive the real controls against the real list.
final class InventoryControlStripUITests: XCTestCase {

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_SEED_INVENTORY_LARGE",
            "UITEST_FORCE_LIGHT_APPEARANCE",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["嫩豆腐"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    func testFilterPickerNarrowsTheListToTheChosenState() {
        let app = launch()

        // 西兰花 is 4 days out: present under 全部, absent under 临期.
        XCTAssertTrue(app.staticTexts["西兰花"].exists)

        let picker = app.segmentedControls["inventory.filter.picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons["临期"].tap()

        XCTAssertTrue(app.staticTexts["嫩豆腐"].waitForExistence(timeout: 3), "1 day out is 临期.")
        XCTAssertFalse(app.staticTexts["西兰花"].exists, "4 days out is not 临期.")

        picker.buttons["全部"].tap()
        XCTAssertTrue(app.staticTexts["西兰花"].waitForExistence(timeout: 3), "Clearing restores the list.")
    }

    @MainActor
    func testTappingACountAppliesItsFilter() {
        let app = launch()

        // The counts are controls: tapping 即将到期 selects that filter.
        let expiring = app.buttons["inventory.summary.expiringSoon"]
        XCTAssertEqual(expiring.label, "2 项即将到期")
        XCTAssertTrue(expiring.isHittable)
        expiring.tap()

        XCTAssertTrue(app.segmentedControls["inventory.filter.picker"].buttons["临期"].isSelected)
        XCTAssertTrue(app.staticTexts["嫩豆腐"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["西兰花"].exists)
    }
}
#endif

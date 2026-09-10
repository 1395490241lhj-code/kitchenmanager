#if DEBUG
import XCTest

/// The Inventory control layer has to actually filter, and has to keep saying
/// so. These drive the real controls against the real list.
///
/// P-3 of the behavior-contract prototype changed two things these tests pin:
/// the read-only count row and the segmented picker became one surface, and the
/// surface stopped disappearing during search.
final class InventoryControlStripUITests: XCTestCase {

    @MainActor
    private func launch(pinSearch: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_SEED_INVENTORY_LARGE",
            "UITEST_FORCE_LIGHT_APPEARANCE",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"
        ] + (pinSearch ? ["UITEST_PIN_INVENTORY_SEARCH"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["嫩豆腐"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func segment(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.segmentedControls["inventory.filter.picker"].buttons[identifier]
    }

    @MainActor
    private func search(_ app: XCUIApplication, _ text: String) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }

    // MARK: - The filter still filters

    @MainActor
    func testFilterPickerNarrowsTheListToTheChosenState() {
        let app = launch()

        // 西兰花 is 4 days out: present under 全部, absent under 临期.
        XCTAssertTrue(app.staticTexts["西兰花"].exists)

        let picker = app.segmentedControls["inventory.filter.picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        segment(app, "inventory.filter.option.expiringSoon").tap()

        XCTAssertTrue(app.staticTexts["嫩豆腐"].waitForExistence(timeout: 3), "1 day out is 临期.")
        XCTAssertFalse(app.staticTexts["西兰花"].exists, "4 days out is not 临期.")

        segment(app, "inventory.filter.option.all").tap()
        XCTAssertTrue(app.staticTexts["西兰花"].waitForExistence(timeout: 3), "Clearing restores the list.")
    }

    // MARK: - One surface, counts on the choices

    @MainActor
    func testEachFilterChoiceCarriesItsOwnCount() {
        let app = launch()

        // The counts are no longer a separate row above the picker: they are
        // part of the choice they describe, which is the only thing they were
        // ever about.
        XCTAssertTrue(segment(app, "inventory.filter.option.expiringSoon").label.contains("2"))
        XCTAssertTrue(segment(app, "inventory.filter.option.all").label.contains("13"))

        // 已过期 is empty in this fixture, so it carries no number — but it is
        // still offerable, because a choice that vanishes moves every other
        // control under the user's finger.
        let expired = segment(app, "inventory.filter.option.expired")
        XCTAssertTrue(expired.exists)
        XCTAssertFalse(expired.label.contains("0"))

        XCTAssertFalse(
            app.buttons["inventory.summary.expiringSoon"].exists,
            "The separate read-only count row is gone with the second surface."
        )
    }

    @MainActor
    func testTappingAFilterChoiceAppliesIt() {
        let app = launch()

        segment(app, "inventory.filter.option.expiringSoon").tap()

        XCTAssertTrue(segment(app, "inventory.filter.option.expiringSoon").isSelected)
        XCTAssertTrue(app.staticTexts["嫩豆腐"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["西兰花"].exists)
    }

    // MARK: - The filter stays visible while searching

    @MainActor
    func testTheFilterRemainsVisibleAndSelectedDuringSearch() {
        let app = launch(pinSearch: true)
        segment(app, "inventory.filter.option.expiringSoon").tap()

        search(app, "豆")

        let picker = app.segmentedControls["inventory.filter.picker"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: 3),
            "Search must not hide the constraint that is still narrowing the list."
        )
        XCTAssertTrue(segment(app, "inventory.filter.option.expiringSoon").isSelected)
        XCTAssertTrue(app.staticTexts["嫩豆腐"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testSearchAndFilterHaveIndependentExits() {
        let app = launch(pinSearch: true)
        segment(app, "inventory.filter.option.expiringSoon").tap()
        search(app, "豆")

        // Clearing the filter must leave the query in place: 嫩豆腐 still
        // matches 豆, and 西兰花 still does not.
        app.buttons["inventory.filter.clear"].tap()
        XCTAssertTrue(segment(app, "inventory.filter.option.all").isSelected)
        XCTAssertTrue(app.staticTexts["嫩豆腐"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["西兰花"].exists, "Clearing the filter did not also clear the search.")
    }

    // MARK: - A constrained empty result names its cause

    @MainActor
    func testAConstrainedNoResultNamesBothConstraintsAndOffersTwoExits() {
        let app = launch(pinSearch: true)
        segment(app, "inventory.filter.option.expiringSoon").tap()

        // 苹果 exists, but it is 14 days out — so the filter, not the query, is
        // what empties this result.
        search(app, "苹果")

        XCTAssertTrue(
            app.staticTexts["没有临期的「苹果」"].waitForExistence(timeout: 3),
            "The message must name the filter as well as the query."
        )
        XCTAssertTrue(app.buttons["inventory.empty.clearFilter"].exists)
        XCTAssertTrue(app.buttons["inventory.empty.clearSearch"].exists)

        app.buttons["inventory.empty.clearFilter"].tap()
        XCTAssertTrue(
            app.staticTexts["苹果"].waitForExistence(timeout: 3),
            "Clearing the filter alone is enough to find it."
        )
    }

    @MainActor
    func testASearchOnlyNoResultBlamesOnlyTheSearch() {
        let app = launch(pinSearch: true)

        search(app, "不存在的食材")

        XCTAssertTrue(app.staticTexts["没有找到「不存在的食材」"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["inventory.empty.clearSearch"].exists)
        XCTAssertFalse(
            app.buttons["inventory.empty.clearFilter"].exists,
            "No filter is active, so there is nothing to offer clearing."
        )
    }
}
#endif

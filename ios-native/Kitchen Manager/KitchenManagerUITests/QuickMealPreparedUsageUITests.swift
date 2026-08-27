import XCTest

/// Drives the prepared-component usage loop on a real Home screen: the row
/// appears, names the batch, says what is left, and taking a portion moves the
/// count without touching anything else on the page.
final class QuickMealPreparedUsageUITests: XCTestCase {
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A quick day with two staples and one cooked batch — the combination that
    /// makes 牛肉青菜饭 stand up.
    private func launchSeeded(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_QUICK_MEAL_PREPARED", "UITEST_FORCE_QUICK_DAY"] + extraArguments
        app.launch()
        XCTAssertTrue(
            app.staticTexts["home.quickMeal.section"].waitForExistence(timeout: 10),
            "the quick slot must be showing before anything else is asserted"
        )
        return app
    }

    private func preparedRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.quickMeal.prepared."))
            .firstMatch
    }

    private func useButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.quickMeal.usePrepared."))
            .firstMatch
    }

    func testTheCardNamesTheBatchAndOffersToUseAPortion() throws {
        let app = launchSeeded()

        // The leading suggestion is the two-component one: eating the batch with
        // rice needs no cooking at all, while adding the greens means a pot. Both
        // are offered; this is the easier one, and it still uses the batch.
        XCTAssertEqual(app.staticTexts["home.quickMeal.title"].label, "牛肉配饭")
        let row = preparedRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.label, "卤牛肉 · 备餐剩 3 份")

        let button = useButton(in: app)
        XCTAssertTrue(button.exists)
        // VoiceOver names the batch, so two rows are never ambiguous.
        XCTAssertEqual(button.label, "使用 1 份卤牛肉")
        XCTAssertGreaterThanOrEqual(button.frame.height, 44, "the action must stay reachable")
        // The neighbouring control had the same shape and the same defect.
        let rotate = app.buttons["home.quickMeal.rotate"]
        if rotate.exists {
            XCTAssertGreaterThanOrEqual(rotate.frame.height, 44, "换一个 must clear the same bar")
        }

        attachScreenshot(of: app, named: "quick-meal-prepared-standard")
    }

    func testOrdinaryInventoryComponentsGetNoProvenanceRow() throws {
        let app = launchSeeded()

        // 米饭 and 上海青 are in the components line but have no row of their own.
        XCTAssertTrue(app.staticTexts["home.quickMeal.components"].exists)
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.quickMeal.prepared."))
        XCTAssertEqual(rows.count, 1, "only the batch gets provenance; a bag of rice does not")
    }

    func testUsingAPortionMovesTheCountAndLeavesTheMealIntact() throws {
        let app = launchSeeded()
        let row = preparedRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.label, "卤牛肉 · 备餐剩 3 份")

        useButton(in: app).tap()

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "卤牛肉 · 备餐剩 2 份"))
                .firstMatch
                .waitForExistence(timeout: 5),
            "the count follows what happened in the kitchen"
        )
        // Still the same meal: two portions left keeps the suggestion standing.
        XCTAssertEqual(app.staticTexts["home.quickMeal.title"].label, "牛肉配饭")
        attachScreenshot(of: app, named: "quick-meal-prepared-after-use")
    }

    func testUsingTheLastPortionRetiresTheMealWithoutStranding() throws {
        let app = launchSeeded()
        XCTAssertTrue(preparedRow(in: app).waitForExistence(timeout: 5))

        // Three portions, three taps.
        for _ in 0..<3 {
            let button = useButton(in: app)
            guard button.exists else { break }
            button.tap()
        }

        // The batch is gone, so the meal it enabled is gone too — and Home says
        // so rather than showing a card built on a batch that no longer exists.
        XCTAssertTrue(
            app.descendants(matching: .any)["home.quickMeal.empty"].waitForExistence(timeout: 5),
            "the empty state takes over; no stale card, no crash from a stale index"
        )
        XCTAssertFalse(preparedRow(in: app).exists)
        XCTAssertTrue(app.staticTexts["home.quickMeal.section"].exists, "the section itself stays put")
        attachScreenshot(of: app, named: "quick-meal-prepared-exhausted")
    }

    func testTheRowReadsCorrectlyInDarkMode() throws {
        let app = launchSeeded(extraArguments: ["UITEST_FORCE_DARK_APPEARANCE"])

        XCTAssertTrue(preparedRow(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(useButton(in: app).exists)
        attachScreenshot(of: app, named: "quick-meal-prepared-dark")
    }

    func testTheRowStaysUsableAtAccessibilitySizes() throws {
        let app = launchSeeded(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])

        let row = preparedRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let button = useButton(in: app)
        XCTAssertTrue(button.exists)
        // The label wraps rather than truncating, and the action keeps its target.
        XCTAssertEqual(row.label, "卤牛肉 · 备餐剩 3 份")
        XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        attachScreenshot(of: app, named: "quick-meal-prepared-accessibility-xxxl")

        // And it still works at that size.
        button.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "卤牛肉 · 备餐剩 2 份"))
                .firstMatch
                .waitForExistence(timeout: 5)
        )
    }
}

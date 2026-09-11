import XCTest

/// Planner-hosted weekly generator: the 更多 entry opens it, a saved draft is
/// truthful about being generated (never 已安排), joining the plan returns to
/// the Planner on the week containing the range start — including a range that
/// crosses two calendar weeks — and cancelling changes nothing.
final class PlannerWeeklyHostUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ state: String) -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_PLANNER_REGRESSION", state,
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"]
        app.launch()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 10), "planner did not open")
        return app
    }

    private func openGenerator(_ app: XCUIApplication) {
        let menu = app.buttons["planner.tools.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "the 更多 menu is missing")
        menu.tap()
        let entry = app.buttons["planner.weekly.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "the menu did not offer the weekly entry")
        // The seeded states always carry a draft, so the entry must describe
        // it as generated and never as scheduled.
        XCTAssertTrue(entry.label.contains("已生成"),
                      "an existing draft must read as generated, got: \(entry.label)")
        XCTAssertFalse(entry.label.contains("已安排"),
                       "the entry must not describe a draft as scheduled")
        entry.tap()
        XCTAssertTrue(app.navigationBars["生成一周菜单"].waitForExistence(timeout: 5),
                      "the generator did not open")
    }

    private func openSavedResult(_ app: XCUIApplication) {
        let saved = app.buttons["查看上次生成的菜单"]
        // The entry sits in the form's last section, which a List only creates
        // on screen; scroll until it exists.
        var attempts = 0
        while !saved.exists && attempts < 10 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "no saved-draft entry on the generator")
        saved.tap()
        XCTAssertTrue(app.navigationBars["生成的菜单"].waitForExistence(timeout: 5),
                      "the result screen did not open")
    }

    private func rangeRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["planner.week.range"].firstMatch
    }

    func testTheMenuOpensTheGeneratorAndDescribesADraftTruthfully() {
        let app = launch("PLANNER_DATA_HOST_WEEKLY")
        openGenerator(app)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(rangeRow(app).waitForExistence(timeout: 5), "planner did not return to its list")
    }

    func testCancellingTheGeneratorChangesNothing() {
        let app = launch("PLANNER_DATA_HOST_WEEKLY")
        let rangeBefore = rangeRow(app).label
        openGenerator(app)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(rangeRow(app).waitForExistence(timeout: 5))
        XCTAssertEqual(rangeRow(app).label, rangeBefore, "a cancelled visit must not move the week")
    }

    func testJoiningTheSavedDraftReturnsToThePlannerOnTheStartWeek() {
        let app = launch("PLANNER_DATA_HOST_WEEKLY")
        openGenerator(app)
        openSavedResult(app)
        let add = app.buttons["weekly.result.materialize"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "the result did not offer 加入用餐计划")
        add.tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 10),
                      "joining must return the member to the Planner")
        let range = rangeRow(app)
        XCTAssertTrue(range.waitForExistence(timeout: 5), "the week list did not reappear")
        XCTAssertTrue(range.label.contains("9月7日") && range.label.contains("9月13日"),
                      "the Planner must reveal the week containing the range start, got: \(range.label)")
    }

    func testACrossWeekRangeRevealsTheStartWeekAndPagesNormally() {
        let app = launch("PLANNER_DATA_HOST_WEEKLY_CROSS")
        openGenerator(app)
        openSavedResult(app)
        let add = app.buttons["weekly.result.materialize"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 10))
        let range = rangeRow(app)
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        // The range starts Saturday 9月12日, inside the week 9月7日 – 9月13日.
        XCTAssertTrue(range.label.contains("9月7日") && range.label.contains("9月13日"),
                      "a cross-week range must reveal its start week, got: \(range.label)")
        app.buttons["切换周"].firstMatch.tap()
        let next = app.buttons["下一周"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), "the week menu did not open")
        next.tap()
        XCTAssertTrue(rangeRow(app).waitForExistence(timeout: 5))
        XCTAssertTrue(rangeRow(app).label.contains("9月14日"),
                      "paging must keep working after the reveal, got: \(rangeRow(app).label)")
    }
}

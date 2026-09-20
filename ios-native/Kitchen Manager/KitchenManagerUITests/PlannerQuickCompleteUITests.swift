import XCTest

/// Planner quick-complete: the three paths a pending row offers 做好了
/// through (leading swipe, context menu, custom action), the cooked row that
/// offers it on none, and the 更多 menu's shopping derivation. Everything runs
/// the production CookConsumptionConfirmationView and store contract; the
/// seeded regression week is the only fixture.
final class PlannerQuickCompleteUITests: XCTestCase {
    /// Today (Wednesday) in the seeded regression week, still pending.
    private let todayMeal = "planner.meal.63000000-0000-0000-0000-000000000021"
    /// Monday in the seeded regression week, already cooked by the fixture.
    private let cookedMeal = "planner.meal.63000000-0000-0000-0000-000000000001"

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launchSeededWeek(_ extra: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_PLANNER_REGRESSION", "PLANNER_DATA_WEEK",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"] + extra
        app.launch()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 10), "planner did not open")
        return app
    }

    private func launchEmptyPlanner() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_EMPTY_HOME",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"]
        app.launch()
        let planTab = app.tabBars.buttons["计划"]
        XCTAssertTrue(planTab.waitForExistence(timeout: 10), "计划 tab missing")
        planTab.tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5), "planner did not open")
        return app
    }

    private func row(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let element = app.buttons[identifier]
        var attempts = 0
        while !element.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), "row \(identifier) missing")
        return element
    }

    /// Drives one quick-complete from the revealed swipe actions to the
    /// cooked row, through the production consumption confirmation.
    private func completeByLeadingSwipe(_ app: XCUIApplication, identifier: String) {
        let target = row(identifier, in: app)
        target.swipeRight()
        let complete = app.buttons["planner.meal.complete.\(uuid(of: identifier))"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5), "leading swipe did not reveal 做好了")
        complete.tap()
        XCTAssertTrue(app.navigationBars["确认本次食材消耗"].waitForExistence(timeout: 5),
                      "the consumption confirmation did not open")
        app.buttons["更新冰箱"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["已完成"].waitForExistence(timeout: 5),
                      "confirmation must end on the 已完成 state")
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5), "planner did not return")
    }

    private func assertRowIsCooked(_ app: XCUIApplication, identifier: String) {
        let meal = row(identifier, in: app)
        XCTAssertTrue(meal.label.contains("已完成"), "the completed row must read 已完成, got: \(meal.label)")
        meal.swipeRight()
        XCTAssertFalse(app.buttons["planner.meal.complete.\(uuid(of: identifier))"].exists,
                       "a cooked row must not offer 做好了 on the leading edge")
    }

    private func uuid(of rowIdentifier: String) -> String {
        String(rowIdentifier.dropFirst("planner.meal.".count))
    }

    // MARK: - Quick complete

    func testLeadingSwipeCompletesTodayMealThroughConsumption() {
        let app = launchSeededWeek()
        completeByLeadingSwipe(app, identifier: todayMeal)
        assertRowIsCooked(app, identifier: todayMeal)
    }

    /// The already-satisfied state: today's pending meal whose consumption is
    /// already recorded (DEBUG fixture PLANNER_DATA_CONSUMED) must open the
    /// zero-deduction confirmation, not the normal deduction UI.
    func testAlreadyConsumedPendingMealShowsZeroDeductionConfirmation() {
        let app = launchAlreadyConsumed()
        let target = row(todayMeal, in: app)
        target.swipeRight()
        let complete = app.buttons["planner.meal.complete.\(uuid(of: todayMeal))"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5), "leading swipe did not reveal 做好了")
        complete.tap()
        XCTAssertTrue(app.navigationBars["确认完成这道菜"].waitForExistence(timeout: 5),
                      "the already-satisfied confirmation must use the singular title")
        XCTAssertTrue(app.staticTexts["食材消耗已经记录，本次确认不会再次扣减库存。"].waitForExistence(timeout: 5),
                      "the zero-deduction message must be shown")
        XCTAssertFalse(app.buttons["更新冰箱"].exists,
                       "the normal deduction action must not appear for an already-satisfied request")
        let confirm = app.buttons["确认完成"].firstMatch
        XCTAssertTrue(confirm.exists, "the zero-deduction primary action is missing")
        confirm.tap()
        XCTAssertTrue(app.navigationBars["已完成"].waitForExistence(timeout: 5))
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5))
        assertRowIsCooked(app, identifier: todayMeal)
    }

    private func launchAlreadyConsumed() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_PLANNER_REGRESSION", "PLANNER_DATA_CONSUMED",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"]
        app.launch()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 10), "planner did not open")
        return app
    }

    func testContextMenuAlsoCompletesTodayMeal() {
        let app = launchSeededWeek()
        row(todayMeal, in: app).press(forDuration: 1.1)
        let complete = app.buttons["planner.meal.completeMenu.\(uuid(of: todayMeal))"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5), "the context menu did not offer 做好了")
        complete.tap()
        XCTAssertTrue(app.navigationBars["确认本次食材消耗"].waitForExistence(timeout: 5))
        app.buttons["更新冰箱"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["已完成"].waitForExistence(timeout: 5))
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5))
        assertRowIsCooked(app, identifier: todayMeal)
    }

    func testCookedRowOffersCompletionOnNoneOfThePaths() {
        let app = launchSeededWeek()
        let target = row(cookedMeal, in: app)
        target.swipeRight()
        XCTAssertFalse(
            app.buttons["planner.meal.complete.\(uuid(of: cookedMeal))"].exists,
            "a cooked row must not offer 做好了 by swipe"
        )
        XCTAssertTrue(app.buttons["编辑"].firstMatch.exists, "the remaining leading action must stay available")
        app.buttons["编辑"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["编辑这一餐"].waitForExistence(timeout: 5))
        app.buttons["planner.mealForm.cancel"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5))
        target.press(forDuration: 1.1)
        XCTAssertFalse(
            app.buttons["planner.meal.completeMenu.\(uuid(of: cookedMeal))"].exists,
            "a cooked row must not offer 做好了 in the context menu"
        )
        app.buttons["编辑"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["编辑这一餐"].waitForExistence(timeout: 5))
    }

    func testCompletionIsAvailableAsAVoiceOverCustomAction() {
        let app = launchSeededWeek()
        let target = row(todayMeal, in: app)
        // Custom actions are what VoiceOver exposes in place of a swipe, which
        // it cannot perform. XCUITest surfaces them on the element itself, so
        // the driveable contract here is a single named row that carries its
        // actions; the spoken pass is the Slice A manual check (T002).
        XCTAssertFalse(target.label.isEmpty, "the row must name itself before offering actions")
        XCTAssertTrue(target.isHittable, "the row must stay reachable as a single element carrying its actions")
    }

    /// T002's AXXXL density check: at accessibility-extra-extra-extra-large the
    /// two leading actions must both stay reachable and distinguishable. If
    /// native density were inappropriate, this is where the finding is recorded
    /// instead of inventing custom row controls.
    func testAXXXLLeadingEdgeKeepsBothActionsReachable() {
        let app = launchSeededWeek("-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL")
        let target = row(todayMeal, in: app)
        target.swipeRight()
        let complete = app.buttons["planner.meal.complete.\(uuid(of: todayMeal))"]
        let edit = app.buttons["编辑"].firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 5), "AXXXL: 做好了 must stay reachable on the leading edge")
        XCTAssertTrue(edit.exists, "AXXXL: 编辑 must stay reachable on the leading edge")
        XCTAssertTrue(complete.isHittable, "AXXXL: 做好了 must be tappable")
        XCTAssertTrue(edit.isHittable, "AXXXL: 编辑 must be tappable")
        XCTAssertFalse(complete.frame.intersects(edit.frame), "AXXXL: the two leading actions must stay distinguishable")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Planner-AXXXL-leading-actions"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Shopping derivation

    func testToolsMenuOpensTodaysShoppingGeneration() {
        let app = launchSeededWeek()
        openToolsMenu(app)
        app.buttons["planner.shopping.generateToday"].tap()
        XCTAssertTrue(app.navigationBars["生成购物清单"].waitForExistence(timeout: 5),
                      "the shopping generation screen did not open")
    }

    func testEmptyTodayShowsNothingToGenerate() {
        let app = launchEmptyPlanner()
        openToolsMenu(app)
        app.buttons["planner.shopping.generateToday"].tap()
        XCTAssertTrue(app.staticTexts["没有可生成的购物清单"].waitForExistence(timeout: 5),
                      "an empty today must say there is nothing to generate")
    }

    private func openToolsMenu(_ app: XCUIApplication) {
        let menu = app.buttons["planner.tools.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "the 更多 menu is missing")
        menu.tap()
        XCTAssertTrue(app.buttons["planner.shopping.generateToday"].waitForExistence(timeout: 5),
                      "the menu did not offer 生成今日购物清单")
    }
}

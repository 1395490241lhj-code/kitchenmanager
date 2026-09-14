import XCTest

/// Weekly generation survives the generator's own child pickers, never takes a
/// picker over when it finishes, and ends — request and ephemeral state alike —
/// when the generator itself is left. The stubbed request takes fifteen seconds,
/// long enough to navigate around it and short enough to see it finish.
final class PlannerWeeklyGenerationLifecycleUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_PLANNER_REGRESSION", "PLANNER_DATA_WEEK", "UITEST_WEEKLY_STUB_GENERATION",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"]
        app.launch()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 10), "planner did not open")
        return app
    }

    private func openGenerator(_ app: XCUIApplication) {
        let menu = app.buttons["planner.tools.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "no 更多 menu")
        let entry = app.buttons["planner.weekly.open"]
        // The first tap after a cold launch occasionally lands before the
        // toolbar is interactive, which opens nothing at all.
        var attempts = 0
        while !entry.exists && attempts < 3 {
            menu.tap()
            _ = entry.waitForExistence(timeout: 5)
            attempts += 1
        }
        XCTAssertTrue(entry.exists, "the menu did not offer the weekly entry")
        entry.tap()
        XCTAssertTrue(app.navigationBars["生成一周菜单"].waitForExistence(timeout: 5), "the generator did not open")
    }

    /// The generate button sits in the form's last section; while a request is
    /// running its label is replaced by a spinner, so its absence is the busy state.
    private func generateButton(_ app: XCUIApplication) -> XCUIElement { app.buttons["生成菜单"] }

    /// Swipes only until the element can be tapped. The planner is a sheet, so
    /// an unconditional swipe down at the top would dismiss it instead.
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, swipingUp: Bool) {
        var attempts = 0
        while !element.isHittable && attempts < 6 {
            if swipingUp { app.swipeUp() } else { app.swipeDown() }
            attempts += 1
        }
    }

    private func startGeneration(_ app: XCUIApplication) {
        let generate = generateButton(app)
        reveal(app, generate, swipingUp: true)
        XCTAssertTrue(generate.waitForExistence(timeout: 5), "no generate button")
        generate.tap()
        XCTAssertTrue(waitForDisappearance(generate, timeout: 3), "generation did not start")
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }

    private func visitChild(_ app: XCUIApplication, _ title: String) {
        let row = app.staticTexts[title]
        reveal(app, row, swipingUp: false)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no \(title) row")
        row.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "\(title) did not open")
        app.navigationBars[title].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["生成一周菜单"].waitForExistence(timeout: 5), "did not return to the generator")
    }

    func testChildPickersDoNotCancelGenerationAndTheResultStillArrives() {
        let app = launch()
        openGenerator(app)
        startGeneration(app)

        visitChild(app, "菜系偏好")
        visitChild(app, "口味偏好")

        // The stub answers exactly one request and nothing taps 生成菜单 again,
        // so a result can only appear if the original request outlived both
        // round trips. A cancelled request would leave this waiting forever.
        XCTAssertTrue(app.navigationBars["生成的菜单"].waitForExistence(timeout: 25),
                      "the original request must finish and present its result after the round trips")
        XCTAssertTrue(app.staticTexts["测试菜 1"].waitForExistence(timeout: 5), "the stubbed menu is shown")
    }

    func testAFinishedMenuWaitsForTheGeneratorInsteadOfTakingOverAPicker() {
        let app = launch()
        openGenerator(app)
        startGeneration(app)

        let row = app.staticTexts["口味偏好"]
        reveal(app, row, swipingUp: false)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["口味偏好"].waitForExistence(timeout: 5))

        // Long enough for the stubbed request to finish while the picker is the
        // screen the member is on. Waiting the whole timeout out is the point:
        // the menu must not push itself over them.
        XCTAssertFalse(app.navigationBars["生成的菜单"].waitForExistence(timeout: 22),
                       "a finished menu must not take over an open picker")
        XCTAssertTrue(app.navigationBars["口味偏好"].exists, "the picker must still be on screen")

        let option = app.buttons["清淡"]
        XCTAssertTrue(option.isHittable, "the picker must still be usable")
        option.tap()
        XCTAssertTrue(app.navigationBars["口味偏好"].exists, "the picker must survive its own selection")

        // Coming back is what presents the menu that finished meanwhile.
        app.navigationBars["口味偏好"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["生成的菜单"].waitForExistence(timeout: 10),
                      "the finished menu must be presented once the generator is back")
        XCTAssertTrue(app.staticTexts["测试菜 1"].waitForExistence(timeout: 5))
    }

    func testLeavingTheGeneratorAbandonsTheWorkflowAndItsEphemeralState() {
        let app = launch()
        openGenerator(app)

        // An edited input, so the next visit can show whether anything survived.
        let days = app.steppers.element(boundBy: 0)
        reveal(app, days, swipingUp: false)
        XCTAssertTrue(days.waitForExistence(timeout: 5), "no day stepper")
        let untouchedDays = days.label
        days.buttons.element(boundBy: 0).tap()
        XCTAssertNotEqual(days.label, untouchedDays, "the day stepper did not change")

        startGeneration(app)

        // Real abandonment: pop the generator itself.
        app.navigationBars["生成一周菜单"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5), "did not return to the planner")

        openGenerator(app)
        let daysAgain = app.steppers.element(boundBy: 0)
        reveal(app, daysAgain, swipingUp: false)
        XCTAssertTrue(daysAgain.waitForExistence(timeout: 5))
        XCTAssertEqual(daysAgain.label, untouchedDays,
                       "an abandoned workflow must not carry its inputs into the next visit")

        reveal(app, generateButton(app), swipingUp: true)
        XCTAssertTrue(generateButton(app).waitForExistence(timeout: 5), "the generator must be idle after abandonment")
        XCTAssertFalse(app.navigationBars["生成的菜单"].waitForExistence(timeout: 19),
                       "an abandoned request must never present a result")
    }
}

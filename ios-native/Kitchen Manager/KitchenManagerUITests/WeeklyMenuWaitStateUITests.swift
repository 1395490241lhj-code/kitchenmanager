import XCTest

/// What the weekly surfaces show while a whole-menu request is running, and
/// what taking the way out actually does. The stubbed request waits fifteen
/// seconds, which is long enough to read the screen and cancel it on purpose.
final class WeeklyMenuWaitStateUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ state: String, size: String = "UICTContentSizeCategoryLarge") -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_SEED_PLANNER_REGRESSION",
            state,
            "UITEST_WEEKLY_STUB_GENERATION",
            "-UIPreferredContentSizeCategoryName", size
        ]
        app.launch()
        return app
    }

    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, swipingUp: Bool = true) {
        var attempts = 0
        while !element.isHittable && attempts < 8 {
            if swipingUp { app.swipeUp() } else { app.swipeDown() }
            attempts += 1
        }
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }

    // MARK: - Initial generation

    /// W1 / W2 — the wait says what is happening and offers the way out; taking
    /// it leaves the member on their own form with everything they typed.
    func testInitialGenerationSaysWhatIsHappeningAndCanBeCancelled() {
        let app = launch("PLANNER_DATA_WEEKLY")
        XCTAssertTrue(app.navigationBars["生成一周菜单"].waitForExistence(timeout: 10), "the generator did not open")

        let days = app.steppers.element(boundBy: 0)
        XCTAssertTrue(days.waitForExistence(timeout: 5), "no day stepper")
        days.buttons.element(boundBy: 0).tap()
        let editedDays = days.label
        XCTAssertFalse(editedDays.isEmpty, "the stepper must report what it is set to")

        let generate = app.buttons["生成菜单"]
        reveal(app, generate)
        XCTAssertTrue(generate.waitForExistence(timeout: 5), "no generate button")
        generate.tap()

        // W1: words, not a bare spinner — and nothing invented about progress.
        let waiting = app.staticTexts["正在生成一周菜单…"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "the wait must name itself")
        let cancel = app.buttons["weekly.generate.cancel"]
        XCTAssertTrue(cancel.exists, "the wait must offer a way out")
        XCTAssertEqual(cancel.label, "取消")
        XCTAssertFalse(generate.exists, "the generate action is busy, so it is not offered twice")
        XCTAssertFalse(app.staticTexts["正在重新生成…"].exists, "this is the first menu, not a replacement")

        // W2: the way out is real.
        cancel.tap()
        XCTAssertTrue(waitForDisappearance(waiting, timeout: 5), "the wait must end when it is cancelled")
        XCTAssertTrue(generate.waitForExistence(timeout: 5), "the generator must be usable again")
        XCTAssertEqual(app.alerts.count, 0, "cancelling is not a failure")

        // The form scrolled to reach the generate action, and a list recycles
        // the rows it scrolled past, so the stepper has to be brought back
        // before it can be asked what it says.
        reveal(app, days, swipingUp: false)
        XCTAssertTrue(days.waitForExistence(timeout: 5), "the form must still be there")
        XCTAssertEqual(days.label, editedDays, "cancelling must not throw away what was typed")

        // W3: the request the member cancelled cannot arrive behind them.
        XCTAssertFalse(app.navigationBars["生成的菜单"].waitForExistence(timeout: 20),
                       "a cancelled request must never present a result")
    }

    // MARK: - Regeneration

    /// R1 / R2 — the menu being replaced stays on screen the whole time, and
    /// cancelling leaves it exactly where it was.
    func testRegenerationKeepsThePreviousMenuVisibleAndCanBeCancelled() {
        let app = launch("PLANNER_DATA_WEEKLY_PLAIN")
        XCTAssertTrue(app.navigationBars["生成的菜单"].waitForExistence(timeout: 10), "result screen never appeared")

        let firstDish = app.staticTexts["麻婆豆腐"]
        XCTAssertTrue(firstDish.waitForExistence(timeout: 5), "the seeded menu is not on screen")

        app.buttons["更多"].tap()
        XCTAssertTrue(app.buttons["weekly.result.regenerate"].waitForExistence(timeout: 5))
        app.buttons["重新生成"].firstMatch.tap()
        XCTAssertTrue(app.alerts["重新生成菜单？"].waitForExistence(timeout: 5))
        app.alerts["重新生成菜单？"].buttons["重新生成"].tap()

        // R1: all three at once — the old menu, the sentence, and the way out.
        let waiting = app.staticTexts["正在重新生成…"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "the replacement must announce itself")
        let cancel = app.buttons["weekly.regenerate.cancel"]
        XCTAssertTrue(cancel.exists, "the replacement must offer a way out")
        XCTAssertEqual(cancel.label, "取消")
        XCTAssertTrue(firstDish.exists, "the menu being replaced must stay visible")
        XCTAssertEqual(app.staticTexts.matching(identifier: "正在重新生成…").count, 1,
                       "one waiting state, not one per region")

        // R5: the action that started it cannot start a second one.
        app.buttons["更多"].tap()
        XCTAssertTrue(app.buttons["weekly.result.regenerate"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["weekly.result.regenerate"].isEnabled,
                       "a second whole-menu regeneration must not be offered while one runs")
        // Dismiss the open menu by tapping past it; 更多 itself is covered while
        // the menu is up.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.95)).tap()
        XCTAssertTrue(waitForDisappearance(app.buttons["weekly.result.regenerate"], timeout: 5),
                      "the menu did not close")

        // R2: cancelling restores nothing, because nothing was taken away.
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(waitForDisappearance(waiting, timeout: 5), "the waiting state must end")
        XCTAssertTrue(firstDish.exists, "the previous menu must survive exactly")
        XCTAssertEqual(app.alerts.count, 0, "cancelling is not a failure")
    }

    /// The wait is text and a button, so the largest accessibility size is the
    /// one that decides whether it still works. Nothing here is carried by the
    /// spinner alone.
    func testTheWaitingStateStaysReadableAndReachableAtAccessibilitySizes() {
        // The generator's own wait is the longer of the two sentences and the
        // same row, so it is the harder case for the largest text size.
        let app = launch("PLANNER_DATA_WEEKLY", size: "UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertTrue(app.navigationBars["生成一周菜单"].waitForExistence(timeout: 10), "the generator did not open")

        let generate = app.buttons["生成菜单"]
        reveal(app, generate)
        XCTAssertTrue(generate.waitForExistence(timeout: 5), "no generate button")
        generate.tap()

        let waiting = app.staticTexts["正在生成一周菜单…"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "the sentence must survive the largest text size")
        let cancel = app.buttons["weekly.generate.cancel"]
        XCTAssertTrue(cancel.exists, "the way out must survive the largest text size")
        XCTAssertEqual(cancel.label, "取消", "VoiceOver reads the button by its own word")
        reveal(app, cancel)
        XCTAssertTrue(cancel.isHittable, "the way out must stay tappable at accessibility sizes")
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44, "the target must meet the project minimum")

        cancel.tap()
        XCTAssertTrue(waitForDisappearance(waiting, timeout: 5), "the waiting state must end")
    }
}

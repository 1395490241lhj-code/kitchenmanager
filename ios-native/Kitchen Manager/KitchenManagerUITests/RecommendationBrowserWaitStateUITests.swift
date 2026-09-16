import XCTest

/// What the recommendation browser reached through 更多推荐 shows while it is
/// fetching, and what the way out of that actually does. The browser has three
/// states and no fourth: a wait that names itself, the list, and the existing
/// error line. The seeded loading fixture puts a generation in flight with no
/// results yet, which is the state that used to render the empty state instead.
final class RecommendationBrowserWaitStateUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launchBrowser(
        size: String = "UICTContentSizeCategoryLarge",
        appearance: XCUIDevice.Appearance = .light
    ) -> XCUIApplication {
        XCUIDevice.shared.appearance = appearance
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_SEED_EMPTY_HOME",
            "UITEST_HOME_RECOMMENDATION_LOADING",
            "-UIPreferredContentSizeCategoryName", size
        ]
        app.launch()

        let more = app.buttons["home.recommendation.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "Home did not settle")
        for _ in 0..<6 where !more.isHittable { app.swipeUp() }
        more.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["推荐"].waitForExistence(timeout: 8),
            "the recommendation browser did not open"
        )
        return app
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }

    /// B1 / B2 — the wait names itself and offers the way out, and an unfinished
    /// request is not dressed up as an empty result. Taking the way out is
    /// silent, stays in the browser, and reveals the state that is actually
    /// true once nothing is running.
    func testBrowserWaitStateSaysWhatIsHappeningAndCanBeCancelled() {
        let app = launchBrowser()

        // B1: words, not a bare spinner, and nothing invented about progress.
        let waiting = app.staticTexts["正在生成推荐…"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 8), "the wait must name itself")
        XCTAssertEqual(app.staticTexts.matching(identifier: "正在生成推荐…").count, 1,
                       "exactly one waiting state, not one per region")
        XCTAssertFalse(app.staticTexts["正在生成…"].exists,
                       "the old in-button spinner label must not survive alongside the wait row")
        XCTAssertFalse(app.staticTexts["暂时没有找到合适的菜"].exists,
                       "a request still in flight must not be reported as an empty result")

        let cancel = app.buttons["recommendation.wait.cancel"]
        XCTAssertTrue(cancel.exists, "the wait must offer a way out")
        XCTAssertEqual(cancel.label, "取消")

        // B2: the way out is real, silent, and stays where the member is.
        for _ in 0..<6 where !cancel.isHittable { app.swipeUp() }
        cancel.tap()
        XCTAssertTrue(waitForDisappearance(waiting, timeout: 5), "the wait must end when it is cancelled")
        XCTAssertEqual(app.alerts.count, 0, "cancelling is not a failure")
        XCTAssertTrue(app.navigationBars.staticTexts["推荐"].exists, "cancelling stays in the browser")
        XCTAssertTrue(app.staticTexts["暂时没有找到合适的菜"].waitForExistence(timeout: 5),
                      "with nothing running, the browser shows the state that is actually true")
    }

    /// B3 — the wait is text and a button, so the largest accessibility size is
    /// the one that decides whether it still works, and dark mode is the one
    /// that decides whether it is still legible. Nothing here is carried by the
    /// spinner alone, and the row introduces no colour of its own.
    func testBrowserWaitStateStaysReadableAndReachableAtAccessibilitySizes() {
        let app = launchBrowser(size: "UICTContentSizeCategoryAccessibilityXXXL", appearance: .dark)

        let waiting = app.staticTexts["正在生成推荐…"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 10), "the sentence must survive the largest text size")

        let cancel = app.buttons["recommendation.wait.cancel"]
        XCTAssertTrue(cancel.exists, "the way out must survive the largest text size")
        XCTAssertEqual(cancel.label, "取消", "VoiceOver reads the button by its own word")
        for _ in 0..<8 where !cancel.isHittable { app.swipeUp() }
        XCTAssertTrue(cancel.isHittable, "the way out must stay tappable at accessibility sizes")
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44, "the target must meet the project minimum")
    }
}

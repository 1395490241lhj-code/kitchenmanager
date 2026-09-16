import XCTest

/// What the recommendation browser reached through 更多推荐 shows while it is
/// fetching. The browser has three states and no fourth: a wait that names
/// itself, the list, and the existing error line. The seeded loading fixture
/// puts a generation in flight with no results yet, which is the state that
/// used to render the empty state instead.
///
/// Unlike 做菜 and the weekly menu, this wait offers no cancellation: a Home
/// recommendation request is non-blocking background work that preserves what
/// is already on screen, so there is nothing for a member to stop and stay put
/// from. Repeated starts are blocked by the disabled trigger buttons instead.
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

    /// B1 / B2 — the wait names itself and an unfinished request is not dressed
    /// up as an empty result. Home recommendation requests are non-blocking,
    /// content-preserving background work, so unlike 做菜 and the weekly menu
    /// this wait carries no stop-and-stay cancellation. Double-start is blocked
    /// by the disabled trigger, not by a way out of the wait.
    func testBrowserWaitStateSaysWhatIsHappeningAndOffersNoCancel() {
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

        // B2: no way out of the wait, by its own identifier and by its word.
        // Scoped deliberately: 取消常做 on a card and any 取消 outside this
        // browser are other controls and are none of this test's business.
        XCTAssertFalse(app.buttons["recommendation.wait.cancel"].exists,
                       "the Home recommendation wait must not expose cancellation")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "取消")).count, 0,
                       "no replacement control may stand in for the removed wait cancel")

        XCTAssertTrue(app.navigationBars.staticTexts["推荐"].exists, "the wait stays in the browser")
    }

    /// B3 — the wait is now text beside a spinner, so the largest accessibility
    /// size is the one that decides whether it still reads, and dark mode is the
    /// one that decides whether it is still legible. Nothing here is carried by
    /// the spinner alone, and removing the button must not strand the sentence
    /// off-screen or leave the unfinished request looking like an empty result.
    func testBrowserWaitStateStaysReadableAndReachableAtAccessibilitySizes() {
        let app = launchBrowser(size: "UICTContentSizeCategoryAccessibilityXXXL", appearance: .dark)

        let waiting = app.staticTexts["正在生成推荐…"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 10), "the sentence must survive the largest text size")
        for _ in 0..<8 where !waiting.isHittable { app.swipeUp() }
        XCTAssertTrue(waiting.isHittable, "the wait must stay reachable at accessibility sizes")

        XCTAssertFalse(app.buttons["recommendation.wait.cancel"].exists,
                       "the removed cancel must not reappear at accessibility sizes")
        XCTAssertFalse(app.staticTexts["暂时没有找到合适的菜"].exists,
                       "an unfinished request is still not an empty result at accessibility sizes")
    }
}

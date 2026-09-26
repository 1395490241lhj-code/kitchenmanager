import XCTest

/// D-048 moved the recommendation wait onto Home itself: browsing the current
/// set no longer requires entering a separate recommendation screen. The wait
/// still names the work, never masquerades as an empty result, and remains
/// non-blocking with no cancellation control.
final class RecommendationBrowserWaitStateUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launchHome(
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
        XCTAssertTrue(
            app.descendants(matching: .any)["home.recommendation.loading"].waitForExistence(timeout: 10),
            "Home recommendation wait did not settle"
        )
        return app
    }

    func testHomeWaitStateSaysWhatIsHappeningAndOffersNoCancel() {
        let app = launchHome()

        let waiting = app.staticTexts["正在生成推荐…"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 8), "the wait must name itself")
        XCTAssertEqual(app.staticTexts.matching(identifier: "正在生成推荐…").count, 1,
                       "exactly one waiting state, not one per region")
        XCTAssertFalse(app.staticTexts["暂时没有合适的推荐"].exists,
                       "a request still in flight must not be reported as an empty result")
        XCTAssertFalse(app.buttons["recommendation.wait.cancel"].exists,
                       "the Home recommendation wait must not expose cancellation")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "取消")).count, 0,
                       "no replacement control may stand in for the removed wait cancel")
        XCTAssertTrue(app.navigationBars.staticTexts["今天"].exists, "the wait stays on Home")
        XCTAssertFalse(app.navigationBars.staticTexts["推荐"].exists, "no extra screen is required")
    }

    func testHomeWaitStateStaysReadableAndReachableAtAccessibilitySizes() {
        let app = launchHome(size: "UICTContentSizeCategoryAccessibilityXXXL", appearance: .dark)

        let waiting = app.staticTexts["正在生成推荐…"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 10), "the sentence must survive the largest text size")
        for _ in 0..<8 where !waiting.isHittable { app.swipeUp() }
        XCTAssertTrue(waiting.isHittable, "the wait must stay reachable at accessibility sizes")
        XCTAssertFalse(app.buttons["recommendation.wait.cancel"].exists,
                       "the removed cancel must not reappear at accessibility sizes")
        XCTAssertFalse(app.staticTexts["暂时没有合适的推荐"].exists,
                       "an unfinished request is still not an empty result at accessibility sizes")
    }
}

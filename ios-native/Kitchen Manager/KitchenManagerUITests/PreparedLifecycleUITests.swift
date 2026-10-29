import XCTest

final class PreparedLifecycleUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private let first = "88000000-0000-0000-0000-000000000001"
    private let legacy = "88000000-0000-0000-0000-000000000003"
    private let session = UUID().uuidString
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func launch(_ extra: [String] = [], seed: String = "UITEST_GROUPED_SEED_LINKED") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_PREPARED_GROUPING", "UITEST_FORCE_MEAL_PREP_DAY", "UITEST_GROUPED_CAPTURE_REOPEN", seed] + extra
        app.launchEnvironment["PREPARED_GROUPING_SESSION"] = session
        print("PR3_UI_SESSION=\(session)")
        app.launch(); XCTAssertTrue(app.buttons["home.mealPrep.add"].waitForExistence(timeout: 10))
        app.buttons["home.mealPrep.add"].tap()
        XCTAssertTrue(app.buttons["prepared.add.button"].waitForExistence(timeout: 5))
        return app
    }
    private func reach(_ app: XCUIApplication, _ element: XCUIElement) {
        for direction in [true, false] {
            for _ in 0..<10 {
                if element.exists && element.isHittable { return }
                if direction { app.swipeUp() } else { app.swipeDown() }
            }
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    func testBeginThawReviewCancellationCreatesNoEvent() {
        let app = launch()
        let action = app.buttons["prepared.lifecycle.beginThaw." + first]
        XCTAssertTrue(action.waitForExistence(timeout: 3), "frozen group needs its contextual lifecycle action")
        reach(app, action); action.tap()
        XCTAssertTrue(app.buttons["prepared.lifecycle.confirm"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["prepared.lifecycle.confirm"].isEnabled)
        capture(app, "lifecycle-review-cancel-light")
        app.buttons["prepared.lifecycle.cancel"].tap()
        XCTAssertTrue(action.waitForExistence(timeout: 3)); XCTAssertFalse(app.staticTexts["解冻中"].exists)
    }
    private func review(_ app: XCUIApplication, id: String, action: String) {
        let button = app.buttons["prepared.lifecycle." + action + "." + id]
        reach(app, button); XCTAssertGreaterThanOrEqual(button.frame.height, 43.5); button.tap()
        XCTAssertTrue(app.buttons["prepared.lifecycle.confirm"].waitForExistence(timeout: 4))
        XCTAssertGreaterThanOrEqual(app.buttons["prepared.lifecycle.cancel"].frame.height, 43.5)
    }
    private func confirm(_ app: XCUIApplication) {
        let toggle = app.switches["prepared.lifecycle.review"]
        showFully(app, toggle)
        XCTAssertGreaterThanOrEqual(toggle.frame.height, 43.5)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(app.buttons["prepared.lifecycle.confirm"].isEnabled)
        XCTAssertGreaterThanOrEqual(app.buttons["prepared.lifecycle.confirm"].frame.height, 43.5)
        app.buttons["prepared.lifecycle.confirm"].tap()
    }
    private func showFully(_ app: XCUIApplication, _ element: XCUIElement) {
        reach(app, element)
        for _ in 0..<6 {
            if element.frame.maxY < app.frame.maxY - 45 { break }
            app.swipeUp()
        }
    }
    private func split(_ app: XCUIApplication, id: String) -> String {
        let before = Set(rowIDs(app))
        let button = app.buttons["prepared.split." + id]; reach(app, button); button.tap()
        app.buttons["prepared.split.save"].tap()
        XCTAssertTrue(app.buttons["prepared.add.button"].waitForExistence(timeout: 4))
        return rowIDs(app).first { !before.contains($0) }!
    }
    private func rowIDs(_ app: XCUIApplication) -> [String] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "prepared.edit.")).allElementsBoundByIndex.map { String($0.identifier.dropFirst("prepared.edit.".count)) }
    }
    func testFourPortionChickenJourneyAndRestart() {
        let app = launch(seed: "UITEST_GROUPED_SEED_LIFECYCLE")
        let selected = split(app, id: first)
        review(app, id: selected, action: "beginThaw"); capture(app, "lifecycle-selected-200g-review-light")
        confirm(app)
        let thaw = app.buttons["prepared.lifecycle.completeThaw." + selected]
        XCTAssertTrue(thaw.waitForExistence(timeout: 4)); capture(app, "lifecycle-one-thawing-three-frozen-light")
        review(app, id: selected, action: "completeThaw"); confirm(app)
        XCTAssertTrue(app.buttons["prepared.lifecycle.markCooked." + selected].waitForExistence(timeout: 4))
        capture(app, "lifecycle-thaw-completed-light")
        review(app, id: selected, action: "markCooked"); confirm(app)
        XCTAssertTrue(app.buttons["prepared.consume." + selected].waitForExistence(timeout: 4))
        capture(app, "lifecycle-one-cooked-three-frozen-light")
        let use = app.buttons["prepared.consume." + selected]; reach(app, use); use.tap()
        XCTAssertFalse(app.buttons["prepared.edit." + selected].exists)
        let remaining = app.buttons["prepared.edit." + first]; reach(app, remaining)
        XCTAssertTrue(remaining.label.contains("剩 3 份"))
        XCTAssertTrue(app.buttons["prepared.lifecycle.beginThaw." + first].exists)
        capture(app, "lifecycle-consumed-sibling-600g-retained")
        app.terminate(); _ = launch(seed: "UITEST_GROUPED_SEED_LIFECYCLE")
        XCTAssertTrue(app.buttons["prepared.edit." + first].label.contains("剩 3 份"))
        XCTAssertFalse(app.buttons["prepared.edit." + selected].exists)
        capture(app, "lifecycle-chicken-restart")
    }
    func testActiveThawSplitInheritsAndCompletesIndependently() {
        let app = launch(seed: "UITEST_GROUPED_SEED_LIFECYCLE")
        review(app, id: first, action: "beginThaw"); confirm(app)
        XCTAssertTrue(app.buttons["prepared.lifecycle.completeThaw." + first].waitForExistence(timeout: 4))
        let selected = split(app, id: first)
        XCTAssertTrue(app.buttons["prepared.lifecycle.completeThaw." + selected].exists)
        review(app, id: selected, action: "completeThaw"); confirm(app)
        XCTAssertTrue(app.buttons["prepared.lifecycle.markCooked." + selected].waitForExistence(timeout: 4))
        let untouched = app.buttons["prepared.lifecycle.completeThaw." + first]; reach(app, untouched)
        XCTAssertTrue(untouched.exists); capture(app, "lifecycle-active-split-independent-completion")
    }
    func testLegacyCancelFailureRetryThenProtectedEditor() {
        let app = launch(["UITEST_GROUPED_FAIL_WRITE=1"], seed: "UITEST_GROUPED_SEED_LIFECYCLE")
        let edit = app.buttons["prepared.edit." + legacy]; reach(app, edit); edit.tap()
        XCTAssertTrue(app.buttons["prepared.editor.state"].exists)
        app.buttons["取消"].tap()
        review(app, id: legacy, action: "markCooked"); app.buttons["prepared.lifecycle.cancel"].tap()
        review(app, id: legacy, action: "markCooked"); confirm(app)
        XCTAssertTrue(app.alerts["备餐操作未完成"].waitForExistence(timeout: 4))
        capture(app, "lifecycle-save-failure-keeps-draft"); app.alerts.buttons["好"].tap()
        XCTAssertTrue(app.buttons["prepared.lifecycle.confirm"].isEnabled)
        capture(app, "lifecycle-save-retry-draft"); app.buttons["prepared.lifecycle.confirm"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 4)); reach(app, edit); edit.tap()
        XCTAssertFalse(app.buttons["prepared.editor.state"].exists)
        XCTAssertTrue(app.buttons["prepared.editor.portions-Increment"].exists)
        capture(app, "lifecycle-opted-in-legacy-protection")
    }
    func testStaleLifecycleRecheckRequiresRenewedExpiryReview() {
        let app = launch(["UITEST_GROUPED_STALE_EDIT"], seed: "UITEST_GROUPED_SEED_LIFECYCLE")
        review(app, id: first, action: "beginThaw")
        let change = app.buttons["prepared.lifecycle.fixture.consume"]; reach(app, change); change.tap()
        confirm(app)
        XCTAssertTrue(app.alerts["备餐操作未完成"].waitForExistence(timeout: 4))
        capture(app, "lifecycle-stale-error"); app.alerts.buttons["好"].tap()
        let recheck = app.buttons["prepared.lifecycle.recheck"]; reach(app, recheck)
        capture(app, "lifecycle-stale-current-facts"); recheck.tap()
        XCTAssertFalse(app.buttons["prepared.lifecycle.confirm"].isEnabled)
        confirm(app)
        XCTAssertTrue(app.buttons["prepared.lifecycle.completeThaw." + first].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["prepared.edit." + first].label.contains("剩 3 份"))
    }
    func testMissingGroupCannotCommitOpenDraft() {
        let app = launch(["UITEST_GROUPED_STALE_EDIT"], seed: "UITEST_GROUPED_SEED_LIFECYCLE")
        review(app, id: first, action: "beginThaw")
        let remove = app.buttons["prepared.lifecycle.fixture.remove"]; reach(app, remove); remove.tap()
        XCTAssertTrue(app.staticTexts["prepared.lifecycle.missing"].exists)
        XCTAssertFalse(app.buttons["prepared.lifecycle.confirm"].isEnabled)
        capture(app, "lifecycle-missing-keeps-draft")
    }
    private func appearance(dark: Bool, ax: Bool) {
        let extra = (dark ? ["UITEST_FORCE_DARK_APPEARANCE"] : []) + (ax ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
        let app = launch(extra, seed: "UITEST_GROUPED_SEED_LIFECYCLE")
        let variant = "\(dark ? "dark" : "light")-\(ax ? "axxxl" : "normal")"
        capture(app, "lifecycle-list-" + variant)
        review(app, id: first, action: "beginThaw")
        capture(app, "lifecycle-review-top-" + variant)
        let toggle = app.switches["prepared.lifecycle.review"]; showFully(app, toggle)
        capture(app, "lifecycle-expiry-review-" + variant)
        app.buttons["prepared.lifecycle.cancel"].tap()
        review(app, id: legacy, action: "markCooked")
        capture(app, "lifecycle-long-name-" + variant)
        app.buttons["prepared.lifecycle.cancel"].tap()
    }
    func testAppearanceLightNormal() { appearance(dark: false, ax: false) }
    func testAppearanceDarkNormal() { appearance(dark: true, ax: false) }
    func testAppearanceLightAXXXL() { appearance(dark: false, ax: true) }
    func testAppearanceDarkAXXXL() { appearance(dark: true, ax: true) }
}

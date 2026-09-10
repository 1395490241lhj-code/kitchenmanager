import XCTest

/// Ordinary-meal delete + undo from the Planner. Every path runs through the
/// production store contract (`removePlan` / `restorePlan`) and the shared
/// toast; only the persistence failure is injected.
final class PlannerMealDeleteUITests: XCTestCase {
    private let openMeal = "planner.meal.63000000-0000-0000-0000-000000000011"

    private func launchSeededWeek(_ extra: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_PLANNER_REGRESSION", "PLANNER_DATA_WEEK",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"] + extra
        app.launch()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 10), "planner did not open")
        return app
    }

    private func launchEmptyPlanner(_ extra: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_EMPTY_HOME",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"] + extra
        app.launch()
        let link = app.buttons["home.planner.link"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "planner entry link missing on Home")
        link.tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5), "planner did not open")
        return app
    }

    private func createMeal(in app: XCUIApplication) -> XCUIElement {
        app.buttons["planner.empty.create"].tap()
        XCTAssertTrue(app.navigationBars["新建一餐"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["planner.mealForm.recipe"].tap()
        let pick = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "planner.recipe.pick.")
        ).firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 5))
        pick.tap()
        XCTAssertTrue(app.navigationBars["新建一餐"].waitForExistence(timeout: 5))
        app.buttons["planner.mealForm.save"].tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5))
        let saved = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "planner.meal.")
        ).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "created meal missing")
        return saved
    }

    private func deleteBySwipe(_ target: XCUIElement, in app: XCUIApplication) {
        target.swipeLeft()
        let remove = app.buttons["移出计划"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "trailing swipe did not reveal 移出计划")
        remove.tap()
    }

    /// The toast label carries AppFeedbackView's semantic prefix, so matching
    /// on 成功：已移出「 verifies the state, the full success copy and that a
    /// dish name follows.
    private func successToast(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "成功：已移出「")
        ).firstMatch
    }

    /// Asserts the success toast and its undo action, then waits out the
    /// auto-dismiss so the next assertion is not racing a toast still on
    /// screen. 知道了 is a VoiceOver custom action on success toasts, so with
    /// VoiceOver off the timer is the only dismissal path — and it must run.
    private func expectSuccessToastAndClose(_ app: XCUIApplication) {
        let toast = successToast(in: app)
        XCTAssertTrue(toast.waitForExistence(timeout: 5), "the success toast must appear")
        XCTAssertTrue(app.buttons["撤销"].exists, "the undo action must be offered")
        wait(
            for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: toast)],
            timeout: 10
        )
    }

    // MARK: - Delete

    func testSwipeDeleteRemovesTheCorrectMealAndShowsUndo() {
        let app = launchEmptyPlanner()
        let meal = createMeal(in: app)
        deleteBySwipe(meal, in: app)
        expectSuccessToastAndClose(app)
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "planner.meal.")
            ).firstMatch.exists,
            "the meal row must be gone"
        )
    }

    func testUndoRestoresTheSameMealAtTheSamePosition() {
        let app = launchSeededWeek()
        let target = row(openMeal, in: app)
        let labelBefore = target.label
        deleteBySwipe(target, in: app)
        let undo = app.buttons["撤销"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        let restored = row(openMeal, in: app)
        XCTAssertTrue(restored.waitForExistence(timeout: 5), "undo must bring the row back")
        XCTAssertEqual(restored.label, labelBefore, "the same meal — same id, day, servings — must return")
    }

    func testSecondDeleteReplacesTheFirstUndoOpportunity() {
        let app = launchSeededWeek()
        let firstID = "planner.meal.63000000-0000-0000-0000-000000000011"
        deleteBySwipe(row(firstID, in: app), in: app)
        let undo = app.buttons["撤销"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        let second = row("planner.meal.63000000-0000-0000-0000-000000000021", in: app)
        deleteBySwipe(second, in: app)
        XCTAssertTrue(successToast(in: app).exists, "the toast must carry the second deletion")
        undo.tap()
        // The first token is dead: only the second meal may come back.
        XCTAssertTrue(
            second.waitForExistence(timeout: 5),
            "a stale undo must not resurrect the first deletion"
        )
        XCTAssertFalse(
            app.buttons[firstID].exists,
            "a stale undo must not resurrect the first deletion"
        )
    }

    func testUndoActionIsLabelledAndReachable() {
        let app = launchEmptyPlanner()
        let meal = createMeal(in: app)
        deleteBySwipe(meal, in: app)
        let undo = app.buttons["撤销"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "the undo action must exist")
        XCTAssertTrue(undo.isHittable, "the undo action must stay reachable")
        XCTAssertGreaterThanOrEqual(
            undo.frame.height, 44 - 1e-9,
            "the undo control stays a 44pt target"
        )
    }

    // MARK: - Persistence failure

    func testAFailedDeleteKeepsTheRowAndNeverClaimsSuccess() {
        // Write 1 is the create; write 2 is the delete, which fails.
        let app = launchEmptyPlanner("UITEST_PLAN_SECOND_WRITE_FAILS")
        let meal = createMeal(in: app)
        deleteBySwipe(meal, in: app)
        XCTAssertTrue(meal.waitForExistence(timeout: 5), "a failed delete must keep the row")
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已移出")).firstMatch.exists,
            "a failed delete must never show success feedback"
        )
        // AppFeedbackView prefixes its accessibility label with the semantic
        // state, so the exact label under test is the prefix plus the copy.
        XCTAssertTrue(app.staticTexts["错误：移出计划失败，请稍后重试。"].waitForExistence(timeout: 5),
                      "the failure must be stated honestly")
    }

    func testAFailedUndoKeepsTheRowAbsentAndReplacesTheToast() {
        // Write 1 is the create; write 2 is the delete; write 3 is the undo,
        // which fails. The delete itself must succeed for undo to be offered.
        // Write 3 is the first write after the failed one, so undo lands on it.
        let app = launchEmptyPlanner("UITEST_PLAN_THIRD_WRITE_FAILS")
        let meal = createMeal(in: app)
        deleteBySwipe(meal, in: app)
        let undo = app.buttons["撤销"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        // Query the toast inside the 4-second auto-dismiss window first; the
        // row stays absent after a failed undo, so the later absence
        // assertions remain valid.
        XCTAssertTrue(app.staticTexts["错误：撤销失败，这一餐仍在计划外。"].waitForExistence(timeout: 5),
                      "the undo failure must be stated honestly")
        XCTAssertFalse(meal.waitForExistence(timeout: 2), "a failed undo must keep the row absent")
        XCTAssertFalse(app.buttons["撤销"].exists, "no false undo success state may remain")
    }

    // MARK: - Context menu

    func testContextMenuAlsoOffersRemove() {
        let app = launchSeededWeek()
        let target = row(openMeal, in: app)
        target.press(forDuration: 1.1)
        let remove = app.buttons["移出计划"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "the context menu did not offer 移出计划")
        remove.tap()
        XCTAssertFalse(target.waitForExistence(timeout: 3), "context-menu delete must remove the row")
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
}

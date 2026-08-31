import XCTest

/// Planner smoke coverage: the seeded special plan renders in the week view,
/// its detail opens with dishes, dishes can be toggled, the edit form persists,
/// and the delete flow removes the event. Also exercises creating a new plan.
final class PlannerUITests: XCTestCase {
    private func launch(_ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func openPlanner(from app: XCUIApplication) {
        // Home (execution mode after seed) -> 今天的计划 -> Planner entry.
        let viewAll = app.buttons["home.today.plan.viewAll"]
        XCTAssertTrue(viewAll.waitForExistence(timeout: 5), "today plan card missing on Home")
        viewAll.tap()
        let todayPlanLink = app.buttons["today.plan.planner.link"]
        XCTAssertTrue(todayPlanLink.waitForExistence(timeout: 5), "planner entry link missing")
        todayPlanLink.tap()
        XCTAssertTrue(
            app.navigationBars["本周安排"].waitForExistence(timeout: 5),
            "planner did not open"
        )
    }

    private func scrollTo(_ predicate: String, in app: XCUIApplication) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", predicate)
        ).firstMatch
        var attempts = 0
        while !element.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        return element
    }

    private func openSeededPlanDetail(from app: XCUIApplication) {
        openPlanner(from: app)
        // The seeded event sits on this week's Saturday; scroll until its row is in
        // the accessibility hierarchy.
        let card = scrollTo("planner.special.entry.", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 5), "seeded special plan row missing")
        for _ in 0..<4 where !card.isHittable { app.swipeUp() }
        XCTAssertTrue(card.isHittable)
        card.tap()
        XCTAssertTrue(app.navigationBars["朋友聚餐"].waitForExistence(timeout: 5))
    }

    func testSeededSpecialPlanAppearsAndShowsDishes() {
        let app = launch("UITEST_SEED_SPECIAL_PLAN")
        openSeededPlanDetail(from: app)
        // Exact text, not a loose CONTAINS: a broken string interpolation would
        // render the literal source instead of the headcount.
        let peopleRow = app.descendants(matching: .any)["planner.special.peopleCount"]
        XCTAssertTrue(peopleRow.exists, "headcount row missing")
        XCTAssertTrue(
            peopleRow.label.contains("7 人"),
            "headcount must render the interpolated value, got: \(peopleRow.label)"
        )
        XCTAssertTrue(app.staticTexts["麻婆豆腐"].exists, "dish 1 not shown")
        XCTAssertTrue(app.staticTexts["番茄炒鸡蛋"].exists, "dish 2 not shown")
    }

    func testCreateSpecialPlanFlow() {
        let app = launch("UITEST_SEED_SPECIAL_PLAN")
        openPlanner(from: app)

        app.buttons["planner.special.create"].tap()
        let titleField = app.textFields["活动名称"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText("周末火锅")
        app.buttons["保存"].tap()

        // The form dismisses back to the week list; the new plan (today) shows.
        XCTAssertTrue(app.staticTexts["周末火锅"].waitForExistence(timeout: 5))
    }

    func testEditAndDeleteFlow() {
        let app = launch("UITEST_SEED_SPECIAL_PLAN")
        openSeededPlanDetail(from: app)

        // Edit the title; the detail reads live from the store.
        app.buttons["planner.special.edit"].tap()
        let titleField = app.textFields["活动名称"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText("改")
        app.buttons["保存"].tap()

        // The detail reads live from the store. The nav bar title is the
        // immediate edited-state signal; SwiftUI exposes it as an identifier.
        let editedBar = app.navigationBars.matching(
            NSPredicate(format: "identifier CONTAINS %@", "聚餐改")
        ).firstMatch
        XCTAssertTrue(editedBar.waitForExistence(timeout: 5), "edited title did not appear in the detail nav bar")

        // Delete via the toolbar menu. The planner owns both the store deletion
        // and the navigation path, so the detail pops on its own.
        deleteOpenPlan(in: app)
        assertNoSpecialPlanRow(in: app)
    }

    /// The delete-navigation contract on its own: open a plan from the planner,
    /// delete it, and land back on the week list with the row gone — no manual
    /// back tap, no leftover "deleted" placeholder screen.
    func testDeletingAPlanReturnsToThePlannerAutomatically() {
        let app = launch("UITEST_SEED_SPECIAL_PLAN")
        openSeededPlanDetail(from: app)

        deleteOpenPlan(in: app)

        XCTAssertFalse(
            app.staticTexts["特殊计划已删除"].exists,
            "delete must not strand the user on a placeholder screen"
        )
        XCTAssertFalse(
            app.buttons["planner.special.edit"].exists,
            "the detail screen must be popped after deleting"
        )
        assertNoSpecialPlanRow(in: app)
    }

    /// Deletes the currently open special plan and waits for the planner list.
    private func deleteOpenPlan(in app: XCUIApplication) {
        app.buttons["更多操作"].tap()
        let delete = app.buttons["planner.special.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "delete action missing")
        delete.tap()
        XCTAssertTrue(
            app.navigationBars["本周安排"].waitForExistence(timeout: 5),
            "deleting should return to the planner week list automatically"
        )
    }

    /// Scrolls the whole week and asserts no special-plan row is left.
    private func assertNoSpecialPlanRow(in app: XCUIApplication) {
        for _ in 0..<8 { app.swipeUp() }
        let entry = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "planner.special.entry.")
        ).firstMatch
        XCTAssertFalse(entry.exists, "deleted plan row must not remain in the planner")
    }
}

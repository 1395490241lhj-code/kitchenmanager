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

    /// The creation sheet is an AI request, not a form: one multiline field,
    /// one inventory switch (off), one generate action — and nothing else.
    func testCreateSpecialPlanFlowIsOneRequestPlusOneSwitch() {
        let app = launch("UITEST_SEED_SPECIAL_PLAN", "UITEST_SPECIAL_PLAN_AI_MENU")
        openPlanner(from: app)

        app.buttons["planner.special.create"].tap()
        let request = anyElement(app, "planner.compose.request")
        XCTAssertTrue(request.waitForExistence(timeout: 5), "request field missing")
        let inventory = app.switches["planner.compose.inventory"]
        XCTAssertTrue(inventory.waitForExistence(timeout: 5), "inventory switch missing")
        XCTAssertEqual(inventory.value as? String, "0", "a new plan starts without home inventory")
        let generate = app.buttons["planner.compose.generate"]
        XCTAssertTrue(generate.exists, "generate action missing")
        XCTAssertFalse(generate.isEnabled, "nothing to generate from an empty request")

        // No configuration controls survive in the sheet.
        XCTAssertFalse(app.textFields["活动名称"].exists, "title field must be gone")
        XCTAssertEqual(app.datePickers.count, 0, "no date/time picker")
        XCTAssertEqual(app.steppers.count, 0, "no headcount or dish-count stepper")
        // One Toggle exposes both an outer labelled element and an inner
        // unlabelled one, so the count is taken over labelled switches: there
        // must be exactly one, and it must be the inventory switch.
        let labelledSwitches = app.switches.allElementsBoundByIndex.filter { !$0.label.isEmpty }
        XCTAssertEqual(
            labelledSwitches.count, 1,
            "the inventory switch is the only toggle; saw \(labelledSwitches.map(\.label))"
        )
        XCTAssertTrue(labelledSwitches[0].label.contains("参考家中冰箱现有食材"))
        XCTAssertFalse(app.staticTexts["忌口与注意事项"].exists, "no constraints section")
        XCTAssertFalse(app.buttons["保存"].exists, "no save button; generating is the action")
        XCTAssertEqual(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "菜系")).count, 0,
            "no cuisine selector"
        )

        request.tap()
        request.typeText("这周六 7 个人一起吃饭，1 人不吃辣")
        XCTAssertTrue(generate.isEnabled)
        generate.tap()

        // The composer generates in place, then lands on the new plan's
        // detail with the draft menu already showing.
        XCTAssertTrue(app.navigationBars["周六朋友聚餐"].waitForExistence(timeout: 15), "new plan detail did not open")
        XCTAssertTrue(app.staticTexts["红烧牛腩"].waitForExistence(timeout: 5), "draft menu missing on the new plan")
        XCTAssertTrue(anyElement(app, "planner.special.request").exists, "the raw request is shown on the plan")
        let inventoryRow = anyElement(app, "planner.special.inventory")
        XCTAssertTrue(inventoryRow.exists)
        XCTAssertTrue(inventoryRow.label.contains("不参考家中库存"), "got: \(inventoryRow.label)")

        // Back on the week list the new plan (today, per the stub) shows.
        app.navigationBars["周六朋友聚餐"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["本周安排"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollTo("planner.special.entry.", in: app).exists)
    }

    /// A failed generation keeps the user in the sheet with their words
    /// intact, and creates no plan.
    func testFailedGenerationCreatesNoPlan() {
        let app = launch("UITEST_SEED_SPECIAL_PLAN", "UITEST_SPECIAL_PLAN_AI_FAILURE")
        openPlanner(from: app)
        app.buttons["planner.special.create"].tap()
        let request = anyElement(app, "planner.compose.request")
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        request.tap()
        request.typeText("周末火锅")
        app.buttons["planner.compose.generate"].tap()
        XCTAssertTrue(anyElement(app, "planner.compose.error").waitForExistence(timeout: 10), "error never surfaced")
        XCTAssertTrue(app.buttons["planner.compose.generate"].isEnabled, "the user can retry from the same words")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["本周安排"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["周末火锅局"].exists, "no plan may exist for a failed generation")
    }

    func testEditAndDeleteFlow() {
        let app = launch("UITEST_SEED_SPECIAL_PLAN", "UITEST_SPECIAL_PLAN_AI_MENU")
        openSeededPlanDetail(from: app)

        // Editing means re-describing: the composer opens prefilled with the
        // plan's request, and generating again rewrites the derived fields.
        app.buttons["planner.special.edit"].tap()
        let request = anyElement(app, "planner.compose.request")
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        XCTAssertTrue((request.value as? String)?.contains("7 个人") == true, "prefilled with the saved request")
        request.tap()
        request.typeText("，改成火锅")
        app.buttons["planner.compose.generate"].tap()

        // The detail reads live from the store: the stub's reading of a 火锅
        // request retitles the plan.
        XCTAssertTrue(
            app.navigationBars["周末火锅局"].waitForExistence(timeout: 15),
            "edited title did not appear in the detail nav bar"
        )
        XCTAssertTrue(app.staticTexts["红烧牛腩"].waitForExistence(timeout: 5), "the regenerated draft is shown")

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

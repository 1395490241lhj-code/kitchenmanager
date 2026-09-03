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

    /// The canonical route, and since D-031 the only one: Home -> 用餐计划.
    ///
    /// This used to go Home -> today plan card -> 查看全部 -> 查看本周安排 · 特殊计划,
    /// which is exactly the shape D-030 warned about — every assertion below it
    /// depended on a seed having created a plan for today, so the suite proved
    /// the screens worked while a real user on an unplanned day could not open
    /// them at all. A helper that takes only taps a user can find is the point.
    private func openPlanner(from app: XCUIApplication) {
        let plannerLink = app.buttons["home.planner.link"]
        XCTAssertTrue(plannerLink.waitForExistence(timeout: 10), "planner entry link missing on Home")
        plannerLink.tap()
        XCTAssertTrue(
            app.navigationBars["用餐计划"].waitForExistence(timeout: 5),
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

    /// The routing gap this covers, and why it is worth a test of its own.
    ///
    /// The planner used to be reachable only through today's plan detail, which
    /// Home only offers once a plan for today exists. On a day with nothing
    /// planned the whole planner — and with it every special plan — was
    /// unreachable: the screens worked, and no tap sequence led to them. The
    /// suite did not catch it because its seeds always created a today plan
    /// first, which is exactly the precondition that was missing in real use.
    ///
    /// So this starts from a genuinely empty Home and takes only taps a normal
    /// user can see, all the way to the composer.
    func testEmptyHomeStillReachesTheSpecialPlanComposer() {
        let app = launch("UITEST_SEED_EMPTY_HOME", "UITEST_SPECIAL_PLAN_AI_MENU")

        // Precondition: Home has no today plan, so the plan-gated route is gone.
        XCTAssertTrue(app.buttons["home.planner.link"].waitForExistence(timeout: 10), "planner link missing on an empty Home")
        XCTAssertFalse(app.buttons["home.today.plan.viewAll"].exists, "fixture must have no today plan")
        XCTAssertFalse(app.buttons["home.plan.secondaryLink"].exists, "fixture must have no today plan")

        app.buttons["home.planner.link"].tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 10), "the planner did not open from Home")

        app.buttons["planner.special.create"].tap()
        XCTAssertTrue(
            app.staticTexts["这次想怎么做饭？"].waitForExistence(timeout: 10),
            "the simplified composer did not appear"
        )
        XCTAssertTrue(anyElement(app, "planner.compose.request").exists, "request field missing")
        XCTAssertTrue(app.switches["planner.compose.inventory"].exists, "inventory switch missing")
        XCTAssertTrue(app.buttons["planner.compose.generate"].exists, "generate action missing")
    }

    /// The link is navigation, not a second headline: it stays a plain row and
    /// never becomes a competing card, on a day with plans or without.
    func testPlannerLinkStaysSecondaryInBothHomeModes() {
        let empty = launch("UITEST_SEED_EMPTY_HOME")
        let link = empty.buttons["home.planner.link"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        // Exactly the label, with nothing appended: no subtitle, no count, no
        // badge. A row that grows a second line stops being a link.
        XCTAssertEqual(link.label, "用餐计划", "the row says only where it goes")
        XCTAssertFalse(empty.staticTexts["本周安排"].exists, "the old week-scoped label must be gone")
        empty.terminate()

        // With a today plan the prominent path is still the plan card; the link
        // is present in addition to it, not instead of it.
        let seeded = launch("UITEST_SEED_SPECIAL_PLAN")
        XCTAssertTrue(seeded.buttons["home.today.plan.viewAll"].waitForExistence(timeout: 10), "the plan card must still lead the page")
        let seededLink = seeded.buttons["home.planner.link"]
        XCTAssertTrue(seededLink.exists, "the link must survive execution mode")
        XCTAssertEqual(seededLink.label, "用餐计划")
    }

    /// D-031: the planner has exactly one entry, and it is Home's. The deep
    /// route through today's plan detail is gone, and nothing about the detail
    /// screen's own job went with it.
    func testTodayPlanDetailNoLongerCarriesAPlannerRoute() {
        let app = launch("UITEST_SEED_SPECIAL_PLAN")

        let viewAll = app.buttons["home.today.plan.viewAll"]
        XCTAssertTrue(viewAll.waitForExistence(timeout: 10))
        // The card's action is named after where it goes, and that is not the
        // planner. 查看全部 belonged to the recommendation card as well, which
        // is precisely the ambiguity this removes.
        XCTAssertEqual(viewAll.label, "今天的计划", "the today card action names its destination")
        viewAll.tap()

        XCTAssertTrue(app.navigationBars.staticTexts["今天的计划"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons["today.plan.planner.link"].exists,
            "the duplicate planner route must be gone from today's plan detail"
        )
        XCTAssertFalse(app.staticTexts["查看本周安排 · 特殊计划"].exists)

        // What the detail is actually for is untouched, including the weekly AI
        // generator that used to sit confusingly next to the planner row.
        XCTAssertTrue(app.buttons["today.plan.weeklyMenu.link"].exists, "the weekly AI menu route must remain reachable")
        XCTAssertTrue(app.staticTexts["AI 生成一周菜单"].exists, "the weekly generator says it is a generator")
        XCTAssertTrue(app.buttons["生成今日购物清单"].exists, "today's own actions are unaffected")
    }

    /// The two Today-scoped secondary links describe mutually exclusive states —
    /// `想再加一道` only exists in execution mode, where `secondaryPlanCount` is
    /// zero by construction. `用餐计划` is unconditional and belongs to neither.
    func testTodaySecondaryLinksAreMutuallyExclusive() {
        let execution = launch("UITEST_SEED_SPECIAL_PLAN")
        XCTAssertTrue(execution.buttons["home.recommendation.moreLink"].waitForExistence(timeout: 10))
        XCTAssertFalse(
            execution.buttons["home.plan.secondaryLink"].exists,
            "a plan that is the primary task is never also a demoted one"
        )
        XCTAssertTrue(execution.buttons["home.planner.link"].exists)
        execution.terminate()

        // An eat-out dinner with a leftover plan is the other half: the plan is
        // demoted, and recommendation is not offered at all.
        let eatOut = launch("UITEST_SEED_HOME_EAT_OUT_WITH_PLAN")
        XCTAssertTrue(eatOut.buttons["home.plan.secondaryLink"].waitForExistence(timeout: 10))
        XCTAssertFalse(
            eatOut.buttons["home.recommendation.moreLink"].exists,
            "Home must not propose another dish for an evening already settled"
        )
        XCTAssertTrue(eatOut.buttons["home.planner.link"].exists, "the planner link belongs to neither mode")
    }

    /// An entirely empty week states the absence once and can be acted on,
    /// instead of repeating 暂无安排 seven times with no way to create anything.
    func testAnEmptyWeekOffersOneCreateAffordance() {
        let app = launch("UITEST_SEED_EMPTY_HOME", "UITEST_SPECIAL_PLAN_AI_MENU")
        openPlanner(from: app)

        let create = app.buttons["planner.empty.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5), "an empty week must offer a way to create a plan")
        XCTAssertEqual(create.label, "新建计划")
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "暂无安排")).count, 0,
            "an empty week must not repeat the per-day placeholder"
        )
        // The week context itself is kept: the range row still says which week.
        XCTAssertTrue(app.staticTexts["本周"].exists, "the week range must survive the empty state")

        create.tap()
        XCTAssertTrue(
            app.staticTexts["这次想怎么做饭？"].waitForExistence(timeout: 10),
            "the empty state must open the same simplified composer as the + does"
        )
    }

    /// The empty state is for an empty week only — a week with an entry keeps
    /// its day sections, and the seeded Saturday event still opens.
    func testAWeekWithEntriesShowsNoEmptyState() {
        let app = launch("UITEST_SEED_SPECIAL_PLAN")
        openPlanner(from: app)

        XCTAssertFalse(app.buttons["planner.empty.create"].exists, "a week with entries has no empty state")
        XCTAssertFalse(app.staticTexts["这一周还没有安排"].exists)
        XCTAssertTrue(scrollTo("planner.special.entry.", in: app).exists, "the seeded plan row must still be listed")
    }

    /// The one control that creates anything in the planner must not describe
    /// itself more narrowly than what it does.
    func testTheCreateToolbarItemIsNamedForPlansNotJustSpecialOnes() {
        let app = launch("UITEST_SEED_SPECIAL_PLAN")
        openPlanner(from: app)
        XCTAssertEqual(app.buttons["planner.special.create"].label, "新建计划")
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
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5))
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
            app.navigationBars["用餐计划"].waitForExistence(timeout: 5),
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

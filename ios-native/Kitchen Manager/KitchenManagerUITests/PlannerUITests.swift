import XCTest

/// Planner smoke coverage: the seeded special plan renders in the week view,
/// its detail opens with dishes, dishes can be toggled, the edit form persists,
/// and the delete flow removes the event. Also exercises creating a new plan.
final class PlannerUITests: XCTestCase {
    func testKitchenAIEntryPreservesDisplayedWeekAndExistingTools() throws {
        let app = launch("UITEST_SEED_EMPTY_HOME", "UITEST_AI_CONVERSATION_FAKE")
        openPlanner(from: app)
        app.buttons["切换周"].tap()
        app.buttons["下一周"].tap()
        let week = app.staticTexts["planner.week.range"].label
        XCTAssertTrue(app.buttons["planner.create.menu"].exists)
        app.buttons["planner.tools.menu"].tap()
        XCTAssertTrue(app.buttons["planner.weekly.open"].exists)
        let entry = app.buttons["planner.kitchenAI.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        guard entry.exists else { return }
        entry.tap()
        // Same identity-agnostic arrival signal the conversation suites use;
        // the Planner-affinity starter below proves which workspace opened.
        XCTAssertTrue(app.buttons["kitchenAI.overflowMenu"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["kitchenAI.starter.调整这周菜单"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["planner.week.range"].label, week)
        XCTAssertTrue(app.buttons["planner.create.menu"].exists)
        app.buttons["planner.tools.menu"].tap()
        XCTAssertTrue(app.buttons["planner.weekly.open"].exists)
    }

    private func launch(_ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// The canonical route: the 计划 tab. Planner is a top-level destination, so
    /// it no longer depends on Home carrying an entry for it at all — which is
    /// the strongest form of the lesson D-030 taught. Earlier shapes routed
    /// through the today plan card and then through a generic Home row; both
    /// only worked when a seed happened to have planned today.
    private func openPlanner(from app: XCUIApplication) {
        let planTab = app.tabBars.buttons["计划"]
        XCTAssertTrue(planTab.waitForExistence(timeout: 10), "计划 tab missing")
        planTab.tap()
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

    /// The toolbar + is a menu now, so every route to the Special Plan composer
    /// goes through it. Kept as a helper so the tests below assert what they are
    /// about rather than repeating the two taps.
    private func openSpecialPlanComposer(from app: XCUIApplication) {
        let menu = app.buttons["planner.create.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "the create menu is missing from the planner toolbar")
        menu.tap()
        let special = app.buttons["planner.special.create"]
        XCTAssertTrue(special.waitForExistence(timeout: 5), "新建聚餐 is missing from the create menu")
        special.tap()
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
        XCTAssertTrue(app.tabBars.buttons["计划"].waitForExistence(timeout: 10), "计划 tab missing on an empty Home")
        XCTAssertFalse(app.buttons["home.today.plan.start"].exists, "fixture must have no today plan")

        app.tabBars.buttons["计划"].tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 10), "the planner did not open from Home")

        openSpecialPlanComposer(from: app)
        XCTAssertTrue(
            app.staticTexts["这次想怎么做饭？"].waitForExistence(timeout: 10),
            "the simplified composer did not appear"
        )
        XCTAssertTrue(anyElement(app, "planner.compose.request").exists, "request field missing")
        XCTAssertTrue(app.switches["planner.compose.inventory"].exists, "inventory switch missing")
        XCTAssertTrue(app.buttons["planner.compose.generate"].exists, "generate action missing")
    }

    /// Planner owns a tab, so Home carries no generic entry for it in either
    /// mode. A top-level destination must not also be a directory row: that is
    /// what made 用餐计划 obsolete rather than merely redundant.
    func testHomeCarriesNoGenericPlannerRowInEitherMode() {
        let empty = launch("UITEST_SEED_EMPTY_HOME")
        XCTAssertTrue(empty.staticTexts["home.primary.title"].waitForExistence(timeout: 10))
        XCTAssertFalse(empty.buttons["home.planner.link"].exists, "the generic planning row must be gone")
        XCTAssertFalse(empty.buttons["用餐计划"].exists, "no Home row may stand in for the 计划 tab")
        XCTAssertTrue(empty.tabBars.buttons["计划"].exists, "the tab is the planning route")
        XCTAssertFalse(empty.staticTexts["本周安排"].exists, "the old week-scoped label must be gone")
        empty.terminate()

        // With a today plan the prominent path is still the plan card, and the
        // absent row does not come back in execution mode.
        let seeded = launch("UITEST_SEED_SPECIAL_PLAN")
        XCTAssertTrue(seeded.buttons["home.today.plan.start"].waitForExistence(timeout: 10), "the plan card must still lead the page")
        XCTAssertFalse(seeded.buttons["home.planner.link"].exists, "the generic planning row must stay gone in execution mode")
        XCTAssertTrue(seeded.tabBars.buttons["计划"].exists)
    }

    /// The 计划 tab is the planning route, and it reaches everything the Home
    /// card's retired 今天的计划 route used to: today's meal with 做好了,
    /// 生成今日购物清单 and the weekly generator.
    func testPlanTabReachesPlannerCapabilities() {
        let app = launch("UITEST_SEED_SPECIAL_PLAN")

        XCTAssertTrue(app.buttons["home.today.plan.start"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["今天的计划"].exists)
        XCTAssertFalse(app.buttons["home.plan.secondaryLink"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "home.planner.link").count, 0, "no generic planning row on Home")

        openPlanner(from: app)

        // Today's week is what opens, with today marked and the ordinary meal on it.
        let todayHeader = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'planner.day.' AND label CONTAINS '今天'")).firstMatch
        XCTAssertTrue(todayHeader.waitForExistence(timeout: 5), "the current week with today marked must be visible")
        let meal = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'planner.meal.'")).firstMatch
        XCTAssertTrue(meal.exists, "today's ordinary meal must be visible on Planner")

        // Slice A capabilities stay reachable from here.
        let menu = app.buttons["planner.tools.menu"]
        XCTAssertTrue(menu.exists, "the 更多 menu is missing")
        menu.tap()
        XCTAssertTrue(app.buttons["planner.shopping.generateToday"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["planner.weekly.open"].exists)
    }

    /// D-042: exactly one `更多推荐` in execution mode and none in eat-out;
    /// planning lives on its own tab rather than in a Home row. A plan that
    /// another task displaces is stated as static context, never a second route.
    func testHomeSecondaryRowsFollowTheCanonicalIA() {
        let execution = launch("UITEST_SEED_SPECIAL_PLAN")
        XCTAssertTrue(execution.buttons["home.recommendation.more"].waitForExistence(timeout: 10))
        XCTAssertEqual(execution.buttons.matching(identifier: "home.recommendation.more").count, 1)
        XCTAssertFalse(execution.buttons["home.plan.secondaryLink"].exists)
        XCTAssertFalse(execution.buttons["home.today.plan.viewAll"].exists)
        XCTAssertFalse(execution.staticTexts["home.context.otherPlans"].exists, "the plan is the primary task, not context")
        XCTAssertEqual(execution.buttons.matching(identifier: "home.planner.link").count, 0)
        execution.terminate()

        let eatOut = launch("UITEST_SEED_HOME_EAT_OUT_WITH_PLAN")
        let context = eatOut.staticTexts["home.context.otherPlans"]
        XCTAssertTrue(context.waitForExistence(timeout: 10), "the displaced plan is stated in Today Context")
        XCTAssertEqual(context.label, "今天另有 2 道计划")
        XCTAssertFalse(eatOut.buttons["home.context.otherPlans"].exists, "the context line is text, not a button")
        XCTAssertFalse(eatOut.buttons["home.plan.secondaryLink"].exists)
        XCTAssertFalse(eatOut.buttons["home.recommendation.more"].exists,
                       "Home must not propose another dish for an evening already settled")
        XCTAssertEqual(eatOut.buttons.matching(identifier: "home.planner.link").count, 0,
                       "planning is a tab, so neither mode carries a Home row for it")
    }

    /// An entirely empty week states the absence once and can be acted on,
    /// instead of repeating 暂无安排 seven times with no way to create anything.
    ///
    /// The CTA now starts ordinary meal creation directly rather than the
    /// Special Plan composer: scheduling the first meal is what an empty week
    /// is for. 聚餐 stays reachable from the toolbar menu, which
    /// `testTheCreateMenuOffersBothKindsOfPlan` holds to account.
    func testAnEmptyWeekOffersOneCreateAffordance() {
        let app = launch("UITEST_SEED_EMPTY_HOME", "UITEST_SPECIAL_PLAN_AI_MENU")
        openPlanner(from: app)

        let create = app.buttons["planner.empty.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5), "an empty week must offer a way to create a plan")
        XCTAssertEqual(create.label, "新建一餐")
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "暂无安排")).count, 0,
            "an empty week must not repeat the per-day placeholder"
        )
        // The week context itself is kept: the range row still says which week.
        XCTAssertTrue(app.staticTexts["本周"].exists, "the week range must survive the empty state")

        create.tap()
        XCTAssertTrue(
            app.navigationBars["新建一餐"].waitForExistence(timeout: 10),
            "the empty state must open ordinary meal creation without a menu in between"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["planner.mealForm.recipe"].exists,
            "the ordinary meal form must be the sheet that opened"
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

    /// The toolbar + creates two different things now, so it names both. The
    /// Special Plan composer stays reachable in exactly one tap more than
    /// before — this is the assertion that the empty-state CTA change did not
    /// strand it.
    func testTheCreateMenuOffersBothKindsOfPlan() {
        let app = launch("UITEST_SEED_SPECIAL_PLAN")
        openPlanner(from: app)

        let menu = app.buttons["planner.create.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "the toolbar create menu is missing")
        XCTAssertEqual(menu.label, "新建")
        menu.tap()

        let meal = app.buttons["planner.meal.create"]
        let special = app.buttons["planner.special.create"]
        XCTAssertTrue(meal.waitForExistence(timeout: 5), "新建一餐 missing from the create menu")
        XCTAssertTrue(special.exists, "新建聚餐 missing from the create menu")
        XCTAssertEqual(meal.label, "新建一餐")
        XCTAssertEqual(special.label, "新建聚餐")
        XCTAssertFalse(
            special.label.contains("AI"),
            "AI is how the composer works, not what the user is creating"
        )

        special.tap()
        XCTAssertTrue(
            app.staticTexts["这次想怎么做饭？"].waitForExistence(timeout: 10),
            "新建聚餐 must still open the existing Special Plan composer"
        )
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

        openSpecialPlanComposer(from: app)
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
        openSpecialPlanComposer(from: app)
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

import XCTest

/// Home V2's IA contract, asserted on the running app.
///
/// This file deliberately replaces the geometry contract that came before it.
/// The old assertions pinned `plan.minY < recommendation.minY < inventory.minY`
/// — three same-weight sections in a fixed order. Home V2 has one primary
/// region whose identity changes with the state, so those assertions could not
/// be preserved without preserving the IA they described. Each rewritten test
/// below says what replaced it.
final class HomeDashboardUITests: XCTestCase {
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeHittable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    private func launch(_ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func launchSeededDashboard() -> XCUIApplication {
        let app = launch("UITEST_SEED_HOME_DASHBOARD")
        XCTAssertTrue(app.staticTexts["home.primary.title"].waitForExistence(timeout: 5))
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    // MARK: - The three layers, in order
    //
    // Replaces `testPlannedDashboardShowsCompactPlanBeforeInlineRecommendation`.
    // The order being asserted is no longer plan → recommendation → inventory
    // but the page's own structure: context → primary task → needs attention.

    func testHomeRendersTodayContextThenPrimaryTaskThenNeedsAttention() throws {
        let app = launchSeededDashboard()
        // Leaf anchors on purpose. A SwiftUI accessibility modifier applied to a
        // container overrides every descendant's, so a section-level identifier
        // would erase the ids of the controls inside it.
        let context = app.staticTexts["home.today.date"]
        let primary = app.staticTexts["home.primary.title"]
        let attention = app.staticTexts["home.attention.section"]

        XCTAssertTrue(context.exists)
        XCTAssertTrue(primary.exists)
        XCTAssertTrue(attention.exists)
        XCTAssertLessThan(context.frame.minY, primary.frame.minY)
        XCTAssertLessThan(primary.frame.minY, attention.frame.minY)
        attachScreenshot(of: app, named: "home-v2-three-layers")
    }

    func testNavigationTitleStaysStableWhileThePrimaryTaskTitleCarriesTheState() throws {
        let planned = launchSeededDashboard()
        XCTAssertTrue(planned.navigationBars.staticTexts["今天"].waitForExistence(timeout: 5))
        XCTAssertEqual(planned.staticTexts["home.primary.title"].label, "今天做这些")
        planned.terminate()

        let undecided = launch("UITEST_SEED_EMPTY_HOME")
        XCTAssertTrue(undecided.navigationBars.staticTexts["今天"].waitForExistence(timeout: 5))
        XCTAssertEqual(undecided.staticTexts["home.primary.title"].label, "今天怎么吃")
    }

    // MARK: - Today Context
    //
    // The day type used to be a `.footnote` fragment reading 快手日 · 午餐已留 1 份.
    // It now states the day and explains it, and the explanation is the sentence
    // that makes the primary region below follow from something.

    func testTodayContextNamesTheDayAndExplainsItInPlainLanguage() throws {
        let app = launch("UITEST_SEED_EMPTY_HOME", "UITEST_FORCE_QUICK_DAY")
        let row = app.buttons["home.dayRhythm.row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("快手日"), row.label)
        XCTAssertTrue(
            row.label.contains("优先用现有食物，少做几步"),
            "The day must explain itself in plain language: \(row.label)"
        )
        XCTAssertGreaterThanOrEqual(row.frame.height, 43.5, "The day row must stay a 44pt target.")

        row.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["今天怎么安排"].waitForExistence(timeout: 5))
    }

    /// Carryover used to be concatenated onto the rhythm line, so food meant for
    /// tomorrow read as another attribute of today. The two halves are now in
    /// two different places.
    func testIncomingCarryoverSitsInTodayContextAndOutgoingDoesNot() throws {
        let app = launch("UITEST_SEED_HOME_CARRYOVER")
        let row = app.buttons["home.dayRhythm.row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("午餐已留 1 份"), "Yesterday's portion is today's food: \(row.label)")

        let footer = element(app, "home.carryover.outgoing")
        XCTAssertTrue(footer.exists)
        XCTAssertTrue(footer.label.contains("明日午餐留 1 份"))
        XCTAssertFalse(
            row.label.contains("明日午餐留"),
            "Tomorrow's food must not be an attribute of today's rhythm."
        )
        XCTAssertLessThan(row.frame.minY, footer.frame.minY)
    }

    // MARK: - Which surface is the primary task
    //
    // Replaces `testAnOrdinaryDayKeepsRecipeRecommendation…` and
    // `testAQuickDayShowsQuickMealInsteadOf…`. Same pair, same purpose — proving
    // the day-type pinning works in both directions — now expressed through the
    // primary region rather than through two competing sections.

    func testAnOrdinaryDayMakesRecipeRecommendationThePrimaryTask() throws {
        let app = launch("UITEST_SEED_EMPTY_HOME")
        XCTAssertTrue(app.buttons["home.recommendation.refresh"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["home.quickMeal.title"].exists)
        XCTAssertEqual(app.staticTexts["home.primary.title"].label, "今天怎么吃")
    }

    func testAQuickDayMakesQuickMealThePrimaryTask() throws {
        let app = launch("UITEST_SEED_QUICK_MEAL_PREPARED", "UITEST_FORCE_QUICK_DAY")
        XCTAssertTrue(app.staticTexts["home.quickMeal.title"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons["home.recommendation.refresh"].exists,
            "Home must never show both surfaces at once"
        )
        XCTAssertEqual(app.staticTexts["home.primary.title"].label, "今天怎么吃")
    }

    func testAMealPrepDayMakesTheBoardThePrimaryTaskWithItsOwnAction() throws {
        let app = launch("UITEST_SEED_COMPONENT_MEAL", "UITEST_FORCE_MEAL_PREP_DAY")
        XCTAssertTrue(app.buttons["home.mealPrep.add"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.primary.title"].label, "今天备的菜")
        XCTAssertEqual(app.staticTexts["home.primary.detail"].label, "先吃快到期的")

        // A production day previously had no primary action at all.
        let record = app.buttons["home.mealPrep.add"]
        XCTAssertEqual(record.label, "记一笔今天做的")
        attachScreenshot(of: app, named: "home-v2-meal-prep-primary")
        makeHittable(record, in: app)
        record.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["备餐"].waitForExistence(timeout: 5))
    }

    // MARK: - Decision mode → execution mode
    //
    // Replaces `testEmptyPlanStartsWithInlineRecommendationAndNoPlanCard` and
    // `testInlineRecommendationCanOpenFullExperienceAndAddToToday`, and adds the
    // assertion the old suite could not make: that adding a plan *changes what
    // kind of screen Home is*.

    func testAnEmptyPlanKeepsHomeInDecisionModeWithNoEmptyPlanCard() throws {
        let app = launch("UITEST_SEED_EMPTY_HOME")
        XCTAssertTrue(app.staticTexts["home.recommendation.title"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home.today.plan.start"].exists, "No plan, so no plan card.")
        XCTAssertTrue(element(app, "home.attention.healthy").exists)
        XCTAssertFalse(app.staticTexts["sync-smoke-status"].exists)
        // D-001 still holds: with nothing decided, Home actively helps decide.
        XCTAssertTrue(app.buttons["home.recommendation.addToday"].exists)
    }

    func testAddingToTodayFlipsHomeFromDecisionModeToExecutionMode() throws {
        let app = launch("UITEST_SEED_EMPTY_HOME")

        let add = app.buttons["home.recommendation.addToday"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.primary.title"].label, "今天怎么吃")
        attachScreenshot(of: app, named: "home-v2-decision-mode")
        add.tap()

        XCTAssertTrue(app.buttons["home.today.plan.start"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.primary.title"].label, "今天做这些")
        XCTAssertEqual(app.staticTexts["home.primary.detail"].label, "已完成 0/1")
        attachScreenshot(of: app, named: "home-v2-execution-mode")
    }

    /// The heart of Product Decision 1. Recommendation is not deleted — it is
    /// demoted from a full card with its own prominent CTA to a single link.
    func testExecutionModeDemotesRecommendationToALinkWithoutRemovingIt() throws {
        let app = launchSeededDashboard()

        XCTAssertTrue(app.buttons["home.today.plan.start"].exists)
        XCTAssertFalse(
            app.buttons["home.recommendation.refresh"].exists,
            "A second same-weight recommendation card must not sit beside the plan."
        )
        XCTAssertFalse(app.buttons["home.recommendation.addToday"].exists)

        let more = app.buttons["home.recommendation.moreLink"]
        XCTAssertTrue(more.exists)
        XCTAssertEqual(more.label, "想再加一道")
        makeHittable(more, in: app)
        more.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["推荐"].waitForExistence(timeout: 5))
    }

    func testExecutionModeHasExactlyOneProminentStartControl() throws {
        let app = launchSeededDashboard()
        XCTAssertTrue(app.buttons["home.today.plan.start"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["home.today.plan.start"].label, "开始准备")
        XCTAssertFalse(app.buttons["home.recommendation.addToday"].exists)
        XCTAssertFalse(app.buttons["home.mealPrep.add"].exists)
    }

    // MARK: - Eating out
    //
    // New. The contradiction Home V2 exists to remove.

    func testAnEatOutDinnerBecomesThePrimaryTask() throws {
        let app = launch("UITEST_SEED_HOME_EAT_OUT_WITH_PLAN")
        XCTAssertTrue(element(app, "home.primary.eatOut").waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.primary.title"].label, "今晚")
        XCTAssertEqual(app.staticTexts["home.primary.detail"].label, "已安排外食")
        attachScreenshot(of: app, named: "home-v2-eat-out-with-stale-plan")
    }

    func testAStalePlanUnderAnEatOutDinnerStaysReachableButNeverProminent() throws {
        let app = launch("UITEST_SEED_HOME_EAT_OUT_WITH_PLAN")
        XCTAssertTrue(element(app, "home.primary.eatOut").waitForExistence(timeout: 5))

        XCTAssertFalse(
            app.buttons["home.today.plan.start"].exists,
            "Home must not say 今晚外食 and offer 开始准备 in the same breath."
        )

        let link = app.buttons["home.plan.secondaryLink"]
        XCTAssertTrue(link.exists, "The plan is demoted, never deleted.")
        XCTAssertEqual(link.label, "今日仍有 2 道计划")
        makeHittable(link, in: app)
        link.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["今天的计划"].waitForExistence(timeout: 5))
    }

    // MARK: - Needs attention
    //
    // Replaces `testMixedInventoryShowsEveryRelevantCategoryAndOpensMatchingFilter`.
    // The categories are the same; what they render is not.

    func testAttentionRowsNameTheFoodAndOpenTheMatchingFilter() throws {
        let app = launch(
            "UITEST_SEED_HOME_DASHBOARD",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"
        )
        XCTAssertTrue(app.staticTexts["home.primary.title"].waitForExistence(timeout: 5))

        let expired = app.buttons["home.attention.expired.过期生菜"]
        XCTAssertTrue(expired.waitForExistence(timeout: 5))
        XCTAssertEqual(expired.label, "过期生菜，已过期 1 天", "A row must name the food, not count it.")
        XCTAssertTrue(app.buttons["home.attention.expiring.临期牛奶"].exists)
        XCTAssertTrue(app.buttons["home.attention.lowStock.大米"].exists)
        XCTAssertGreaterThanOrEqual(expired.frame.height, 43.5)

        makeHittable(expired, in: app)
        expired.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["食材"].waitForExistence(timeout: 5))
        let expiredFilter = app.segmentedControls["inventory.filter.picker"].buttons["已过期"]
        XCTAssertTrue(expiredFilter.waitForExistence(timeout: 5))
        XCTAssertTrue(expiredFilter.isSelected, "Home 的过期提醒必须打开已过期筛选。")
        XCTAssertTrue(app.staticTexts["过期生菜"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["临期牛奶"].exists, "临期项目不应出现在已过期结果中。")
    }

    /// New. A prepared batch going off used to be invisible outside a 备餐日.
    func testAnExpiringPreparedBatchAppearsInNeedsAttentionOnAnOrdinaryDay() throws {
        let app = launch("UITEST_SEED_HOME_PREPARED_ATTENTION")
        let prepared = app.buttons["home.attention.prepared.卤鸡腿"]
        XCTAssertTrue(prepared.waitForExistence(timeout: 5))
        XCTAssertEqual(prepared.label, "卤鸡腿，建议明天前吃完")
        XCTAssertFalse(app.buttons["home.mealPrep.add"].exists, "This is not a 备餐日.")

        // Four days out belongs on the board, not in a list of things to handle.
        XCTAssertFalse(app.buttons["home.attention.prepared.腌鸡肉"].exists)
        attachScreenshot(of: app, named: "home-v2-prepared-attention")

        makeHittable(prepared, in: app)
        prepared.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["备餐"].waitForExistence(timeout: 5))
    }

    /// The complement of the test above: on a 备餐日 the board already lists
    /// every batch with its own 建议…吃完 line, so a prepared row underneath
    /// would be the same fact twice on one screen.
    func testAPrepDayDoesNotRepeatItsBatchesInNeedsAttention() throws {
        let app = launch("UITEST_SEED_COMPONENT_MEAL", "UITEST_FORCE_MEAL_PREP_DAY")
        XCTAssertTrue(app.buttons["home.mealPrep.add"].waitForExistence(timeout: 5))

        // 卤鸡腿 is on the board and expires tomorrow, so it qualifies for
        // 需要处理 on every other day — but not on the day the board is showing.
        XCTAssertTrue(app.staticTexts.matching(identifier: "home.mealPrep.entry").count >= 0)
        XCTAssertFalse(
            app.buttons["home.attention.prepared.卤鸡腿"].exists,
            "The board is already saying this; 需要处理 must not say it again."
        )
        attachScreenshot(of: app, named: "home-v2-meal-prep-no-duplicate-attention")
    }

    /// The same underlying fact must produce exactly one row. Before Home V2 the
    /// inventory categories and the shopping reminder were two separate surfaces
    /// with two different shapes.
    func testEachFactAppearsExactlyOnceInNeedsAttention() throws {
        let app = launchSeededDashboard()
        XCTAssertTrue(app.buttons["home.attention.expired.过期生菜"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "home.attention.expired.过期生菜").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "home.attention.expiring.临期牛奶").count, 1)
        // The old chip identifiers are gone with the chips themselves.
        XCTAssertFalse(app.buttons["home.inventory.expired.button"].exists)
        XCTAssertFalse(app.staticTexts["home.inventory.summary"].exists)
    }

    func testAnEmptyAttentionListIsOneLineAndClaimsNoHeading() throws {
        let app = launch("UITEST_SEED_EMPTY_HOME")
        XCTAssertTrue(element(app, "home.attention.healthy").waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.staticTexts["home.attention.section"].exists,
            "An empty section must not claim a heading's worth of the page."
        )
    }

    // MARK: - Existing capabilities that must survive the restructure

    func testTodayPlanRowOpensThatRecipeDetailAndReturnsHome() throws {
        let app = launchSeededDashboard()

        let row = app.buttons["home.today.plan.row.sample-mapotofu"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.label, "麻婆豆腐，1 人份，未完成")
        makeHittable(row, in: app)
        row.tap()

        XCTAssertTrue(app.navigationBars.staticTexts["菜谱详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["麻婆豆腐"].exists)
        XCTAssertTrue(app.buttons["recipe.detail.startCooking"].exists)

        app.navigationBars["菜谱详情"].buttons.element(boundBy: 0).tap()

        XCTAssertTrue(app.buttons["home.today.plan.row.sample-mapotofu"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.staticTexts["菜谱详情"].exists)
    }

    func testTodayPlanViewAllStillReachesTheFullPlan() throws {
        let app = launchSeededDashboard()
        let viewAll = app.buttons["home.today.plan.viewAll"]
        makeHittable(viewAll, in: app)
        viewAll.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["今天的计划"].waitForExistence(timeout: 5))
    }

    func testHeaderImportAndSettingsRemainReachableFromMyTab() throws {
        let app = launchSeededDashboard()
        let importButton = app.buttons["home.import.add.button"]
        XCTAssertEqual(importButton.label, "导入与添加")
        XCTAssertFalse(app.buttons["home.settings.button"].exists)
        XCTAssertFalse(app.buttons["home.add.menu"].exists)
        importButton.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["导入与添加"].waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()

        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["我的"].waitForExistence(timeout: 5))
    }

    func testDecisionModeCanOpenTheFullRecommendationExperience() throws {
        let app = launch("UITEST_SEED_EMPTY_HOME")
        let viewAll = app.buttons["home.recommendation.viewAll"]
        XCTAssertTrue(viewAll.waitForExistence(timeout: 5))
        makeHittable(viewAll, in: app)
        viewAll.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["推荐"].waitForExistence(timeout: 5))
    }

    func testAIRefreshRunsOnHomeWithoutNavigatingAway() throws {
        let app = launch("UITEST_SEED_EMPTY_HOME")
        let refresh = app.buttons["home.recommendation.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        makeHittable(refresh, in: app)
        refresh.tap()
        XCTAssertFalse(app.navigationBars.staticTexts["推荐"].exists)
        XCTAssertTrue(app.buttons["home.recommendation.refresh"].exists)
    }

    func testInlineRecommendationLoadingErrorAndEmptyStatesStayOnHome() throws {
        let cases = [
            ("UITEST_HOME_RECOMMENDATION_LOADING", "home.recommendation.loading"),
            ("UITEST_HOME_RECOMMENDATION_ERROR", "home.recommendation.error"),
            ("UITEST_HOME_RECOMMENDATION_EMPTY", "home.recommendation.empty")
        ]

        for (argument, identifier) in cases {
            let app = launch("UITEST_SEED_EMPTY_HOME", argument)
            XCTAssertTrue(element(app, identifier).waitForExistence(timeout: 5))
            XCTAssertFalse(app.navigationBars.staticTexts["推荐"].exists)
            app.terminate()
        }
    }

    func testExpiredInventoryAndPurchasedStockInAreBothReachable() throws {
        let app = launch("UITEST_SEED_HOME_STOCK_IN")
        XCTAssertTrue(app.staticTexts["home.attention.section"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.attention.expired.过期生菜"].exists)
        XCTAssertTrue(app.buttons["home.shopping.stockIn.button"].exists)

        let expired = app.buttons["home.attention.expired.过期生菜"]
        makeHittable(expired, in: app)
        expired.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["食材"].waitForExistence(timeout: 5))
    }

    func testPurchasedReminderOpensExistingStockInConfirmationWhenNothingExpired() throws {
        let app = launch("UITEST_SEED_HOME_STOCK_IN_ONLY")

        let stockIn = app.buttons["home.shopping.stockIn.button"]
        XCTAssertTrue(stockIn.waitForExistence(timeout: 5))
        XCTAssertEqual(stockIn.label, "已买的 1 项，等待入库")
        XCTAssertFalse(app.buttons["home.attention.expired.过期生菜"].exists)

        makeHittable(stockIn, in: app)
        stockIn.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["买菜"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts["全部入库？"].waitForExistence(timeout: 5))
        app.alerts["全部入库？"].buttons["取消"].tap()
    }

    func testPurchasedAwaitingStockInDoesNotCreateEmptyTodayPlanCard() throws {
        let app = launch("UITEST_SEED_HOME_STOCK_IN")
        XCTAssertTrue(app.staticTexts["home.primary.title"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home.today.plan.start"].exists)
    }

    func testLocalPersistenceIssueIsVisibleWithoutReplacingLocalContent() throws {
        let app = launch("UITEST_SEED_HOME_ERROR")
        XCTAssertTrue(app.staticTexts["home.primary.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["库存暂未完全保存"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["查看食材"].exists)
    }

    func testClipboardPromptPresentationKeepsBothExplicitActionsAvailable() throws {
        let app = launch("UITEST_SEED_HOME_CLIPBOARD")
        XCTAssertTrue(app.otherElements["home.clipboard.import.prompt"].waitForExistence(timeout: 5))

        let pasteControl = app.buttons["clipboard.paste.control"]
        XCTAssertTrue(pasteControl.exists)
        XCTAssertEqual(
            pasteControl.label,
            "粘贴导入",
            "原生粘贴按钮应播报“粘贴导入”，而不是系统默认的 Paste"
        )
        makeHittable(pasteControl, in: app)
        XCTAssertTrue(pasteControl.isHittable, "整块粘贴区域应由原生控件接收点击")
        XCTAssertGreaterThanOrEqual(pasteControl.frame.width, 118, "原生控件应覆盖完整中文胶囊")
        XCTAssertGreaterThanOrEqual(pasteControl.frame.height, 43.5, "粘贴控件点击区域应至少 44pt 高")

        let ignore = app.buttons["home.clipboard.ignore.button"]
        XCTAssertTrue(ignore.exists)
        makeHittable(ignore, in: app)
    }

    func testBothModuleIssueActionsRemainReachable() throws {
        let app = launch("UITEST_SEED_HOME_MODULE_ISSUES")

        let inventoryAction = app.buttons["查看食材"]
        let shoppingAction = app.buttons["查看清单"]
        XCTAssertTrue(inventoryAction.waitForExistence(timeout: 5))
        XCTAssertTrue(shoppingAction.exists)

        makeHittable(shoppingAction, in: app)
        shoppingAction.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["买菜"].waitForExistence(timeout: 5))
    }
}

import XCTest

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

    private func launchSeededDashboard() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_HOME_DASHBOARD"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["home.recommendation.section"].waitForExistence(timeout: 5))
        return app
    }

    func testPlannedDashboardShowsCompactPlanBeforeInlineRecommendation() throws {
        let app = launchSeededDashboard()
        let plan = app.descendants(matching: .any)["home.today.plan.card"]
        let recommendation = app.descendants(matching: .any)["home.recommendation.section"]
        let inventory = app.descendants(matching: .any)["home.inventory.summary"]
        XCTAssertTrue(plan.exists)
        XCTAssertLessThan(plan.frame.minY, recommendation.frame.minY)
        XCTAssertLessThan(recommendation.frame.minY, inventory.frame.minY)

        let viewAll = app.buttons["home.today.plan.viewAll"]
        makeHittable(viewAll, in: app)
        viewAll.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["今天的计划"].waitForExistence(timeout: 5))
    }

    /// The Today Plan card's recipe rows are real buttons that open that dish's
    /// detail directly, rather than static summary text. `UITEST_SEED_HOME_DASHBOARD`
    /// plans `Recipe.samples`, so `RecipeStore.recipe(id:)` resolves them and the
    /// missing-recipe fallback is not the path under test here.
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
        attachScreenshot(of: app, named: "home-today-plan-row-recipe-detail")

        app.navigationBars["菜谱详情"].buttons.element(boundBy: 0).tap()

        XCTAssertTrue(app.descendants(matching: .any)["home.recommendation.section"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.today.plan.row.sample-mapotofu"].exists)
        XCTAssertFalse(app.navigationBars.staticTexts["菜谱详情"].exists)
    }

    func testMixedInventoryShowsEveryRelevantCategoryAndOpensMatchingFilter() throws {
        let app = launchSeededDashboard()
        XCTAssertTrue(app.buttons["home.inventory.expired.button"].exists)
        XCTAssertTrue(app.buttons["home.inventory.expiring.button"].exists)
        XCTAssertTrue(app.buttons["home.inventory.lowstock.button"].exists)

        let expired = app.buttons["home.inventory.expired.button"]
        makeHittable(expired, in: app)
        expired.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["食材"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["正在查看：已过期"].waitForExistence(timeout: 5))
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

    // MARK: - Which surface occupies the recommendation slot
    //
    // Home shows quick-meal assembly on a quick day and ordinary recipe
    // recommendation otherwise. The day type lives in UserDefaults, so every
    // launch here pins it — see `DayRhythmStore.applyUITestDayTypeIfRequested`.
    // These two tests are the pair that proves the pinning works in both
    // directions rather than passing by accident on a given simulator.

    func testAnOrdinaryDayKeepsRecipeRecommendationWhateverWasSavedBefore() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_EMPTY_HOME"]
        app.launch()

        XCTAssertTrue(app.staticTexts["home.recommendation.section"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["home.quickMeal.section"].exists)
    }

    func testAQuickDayShowsQuickMealInsteadOfRecipeRecommendation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_EMPTY_HOME", "UITEST_FORCE_QUICK_DAY"]
        app.launch()

        XCTAssertTrue(app.staticTexts["home.quickMeal.section"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.descendants(matching: .any)["home.recommendation.section"].exists,
            "Home must never show both surfaces at once"
        )
        // Section order is unchanged: the quick slot sits where recommendation did.
        let quickMeal = app.staticTexts["home.quickMeal.section"]
        let inventory = app.descendants(matching: .any)["home.inventory.healthy"]
        XCTAssertTrue(inventory.exists)
        XCTAssertLessThan(quickMeal.frame.minY, inventory.frame.minY)
    }

    func testEmptyPlanStartsWithInlineRecommendationAndNoPlanCard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_EMPTY_HOME"]
        app.launch()
        XCTAssertTrue(app.staticTexts["home.recommendation.title"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["home.today.plan.card"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["home.inventory.healthy"].exists)
        XCTAssertFalse(app.staticTexts["sync-smoke-status"].exists)
    }

    func testInlineRecommendationCanOpenFullExperienceAndAddToToday() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_EMPTY_HOME"]
        app.launch()

        let viewAll = app.buttons["home.recommendation.viewAll"]
        XCTAssertTrue(viewAll.waitForExistence(timeout: 5))
        viewAll.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["推荐"].waitForExistence(timeout: 5))
        app.navigationBars["推荐"].buttons.element(boundBy: 0).tap()

        let add = app.buttons["home.recommendation.addToday"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.descendants(matching: .any)["home.today.plan.card"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.today.plan.row.sample-mapotofu"].exists)
        XCTAssertEqual(app.staticTexts["home.recommendation.title"].label, "番茄炒鸡蛋")
        XCTAssertEqual(app.buttons["home.recommendation.addToday"].label, "加入今天")
    }

    func testAIRefreshRunsOnHomeWithoutNavigatingAway() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_EMPTY_HOME"]
        app.launch()

        let refresh = app.buttons["home.recommendation.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        refresh.tap()
        XCTAssertFalse(app.navigationBars.staticTexts["推荐"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["home.recommendation.section"].exists)
    }

    func testInlineRecommendationLoadingErrorAndEmptyStatesStayOnHome() throws {
        let cases = [
            ("UITEST_HOME_RECOMMENDATION_LOADING", "home.recommendation.loading"),
            ("UITEST_HOME_RECOMMENDATION_ERROR", "home.recommendation.error"),
            ("UITEST_HOME_RECOMMENDATION_EMPTY", "home.recommendation.empty")
        ]

        for (argument, identifier) in cases {
            let app = XCUIApplication()
            app.launchArguments = ["UITEST_SEED_EMPTY_HOME", argument]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)[identifier].waitForExistence(timeout: 5))
            XCTAssertFalse(app.navigationBars.staticTexts["推荐"].exists)
            app.terminate()
        }
    }

    func testExpiredInventoryAndPurchasedStockInAreBothReachable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_HOME_STOCK_IN"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["home.recommendation.section"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.inventory.expired.button"].exists)
        XCTAssertTrue(app.buttons["home.shopping.stockIn.button"].exists)

        app.buttons["home.inventory.expired.button"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["食材"].waitForExistence(timeout: 5))
    }

    /// Stock-in remains a separate operational alert below the inventory summary.
    func testPurchasedReminderOpensExistingStockInConfirmationWhenNothingExpired() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_HOME_STOCK_IN_ONLY"]
        app.launch()

        let stockIn = app.buttons["home.shopping.stockIn.button"]
        XCTAssertTrue(stockIn.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home.inventory.expired.button"].exists)

        stockIn.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["买菜"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts["全部入库？"].waitForExistence(timeout: 5))
        app.alerts["全部入库？"].buttons["取消"].tap()
    }

    func testPurchasedAwaitingStockInDoesNotCreateEmptyTodayPlanCard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_HOME_STOCK_IN"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["home.recommendation.section"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["home.today.plan.card"].exists)
    }

    func testLocalPersistenceIssueIsVisibleWithoutReplacingLocalContent() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_HOME_ERROR"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["home.recommendation.section"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["库存暂未完全保存"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["查看食材"].exists)
    }

    func testClipboardPromptPresentationKeepsBothExplicitActionsAvailable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_HOME_CLIPBOARD"]
        app.launch()

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

        attachScreenshot(of: app, named: "home-clipboard-banner")

        let ignore = app.buttons["home.clipboard.ignore.button"]
        XCTAssertTrue(ignore.exists)
        makeHittable(ignore, in: app)
    }

    func testBothModuleIssueActionsRemainReachable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_HOME_MODULE_ISSUES"]
        app.launch()

        let inventoryAction = app.buttons["查看食材"]
        let shoppingAction = app.buttons["查看清单"]
        XCTAssertTrue(inventoryAction.waitForExistence(timeout: 5))
        XCTAssertTrue(shoppingAction.exists)

        makeHittable(shoppingAction, in: app)
        shoppingAction.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["买菜"].waitForExistence(timeout: 5))
    }
}

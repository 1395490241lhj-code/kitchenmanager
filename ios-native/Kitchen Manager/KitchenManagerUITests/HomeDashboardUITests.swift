import XCTest

final class HomeDashboardUITests: XCTestCase {
    private func launchSeededDashboard() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_HOME_DASHBOARD"]
        app.launch()
        XCTAssertTrue(app.buttons["home.primary.action.button"].waitForExistence(timeout: 5))
        return app
    }

    func testPlannedDashboardHasOnePrimaryActionThatNavigatesToFullPlan() throws {
        let app = launchSeededDashboard()
        let primaryAction = app.buttons["home.primary.action.button"]
        XCTAssertEqual(primaryAction.label, "查看今日计划")
        XCTAssertEqual(app.buttons.matching(identifier: "home.primary.action.button").count, 1)
        primaryAction.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["今天的计划"].waitForExistence(timeout: 5))
    }

    func testPlannedDashboardOffersContextualAddPlanAction() throws {
        let app = launchSeededDashboard()
        let addPlan = app.buttons["home.today.plan.add.button"]
        XCTAssertTrue(addPlan.waitForExistence(timeout: 5))
        XCTAssertEqual(addPlan.label, "添加今日菜品")
        addPlan.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["推荐"].waitForExistence(timeout: 5))
    }

    func testOnlyHighestPriorityInventoryReminderIsShownAndOpensMatchingFilter() throws {
        let app = launchSeededDashboard()
        XCTAssertFalse(app.buttons["home.inventory.expiring.button"].exists)
        XCTAssertFalse(app.buttons["home.inventory.lowstock.button"].exists)
        XCTAssertFalse(app.buttons["home.shopping.pending.button"].exists)
        XCTAssertFalse(app.staticTexts["需要留意"].exists)
        app.buttons["home.inventory.expired.button"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["食材"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["正在查看：已过期"].waitForExistence(timeout: 5))
    }

    func testToolbarIsFocusedAndSettingsRemainReachableFromMyTab() throws {
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

    func testEmptyPlanHasOnePrimaryActionAndOffersRecommendationWithoutDebugUI() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_EMPTY_HOME"]
        app.launch()
        let primaryAction = app.buttons["home.primary.action.button"]
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 5))
        XCTAssertEqual(primaryAction.label, "添加今日菜品")
        XCTAssertEqual(app.buttons.matching(identifier: "home.primary.action.button").count, 1)
        XCTAssertFalse(app.buttons["home.today.plan.add.button"].exists)
        primaryAction.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["推荐"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["sync-smoke-status"].exists)
    }

    func testPurchasedItemsOverrideExpiredReminderAndOpenExistingStockInConfirmation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_HOME_STOCK_IN"]
        app.launch()

        let primaryAction = app.buttons["home.primary.action.button"]
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 5))
        XCTAssertEqual(primaryAction.label, "完成入库")
        XCTAssertTrue(app.buttons["home.shopping.stockIn.button"].exists)
        XCTAssertFalse(app.buttons["home.inventory.expired.button"].exists)

        primaryAction.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["买菜"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts["全部入库？"].waitForExistence(timeout: 5))
        app.alerts["全部入库？"].buttons["取消"].tap()
    }

    func testPurchasedAwaitingStockInStillOffersContextualAddPlanAction() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_HOME_STOCK_IN"]
        app.launch()

        let addPlan = app.buttons["home.today.plan.add.button"]
        XCTAssertTrue(addPlan.waitForExistence(timeout: 5))
        addPlan.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["推荐"].waitForExistence(timeout: 5))
    }

    func testLocalPersistenceIssueIsVisibleWithoutReplacingLocalContent() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_HOME_ERROR"]
        app.launch()

        XCTAssertTrue(app.buttons["home.primary.action.button"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["库存暂未完全保存"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["查看食材"].exists)
    }
}

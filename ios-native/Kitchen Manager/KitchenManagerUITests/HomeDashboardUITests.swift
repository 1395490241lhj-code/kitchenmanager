import XCTest

final class HomeDashboardUITests: XCTestCase {
    private func launchSeededDashboard() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_HOME_DASHBOARD"]
        app.launch()
        XCTAssertTrue(app.buttons["home.today.plan.card"].waitForExistence(timeout: 5))
        return app
    }

    func testTodayPlanCardNavigatesToFullPlan() throws {
        let app = launchSeededDashboard()
        app.buttons["home.today.plan.card"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["今天的计划"].waitForExistence(timeout: 5))
    }

    func testInventoryAlertOpensMatchingInventoryFilter() throws {
        let app = launchSeededDashboard()
        app.buttons["home.inventory.expired.button"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["食材"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["正在查看：已过期"].waitForExistence(timeout: 5))
    }

    func testShoppingSummaryAndSettingsRemainReachable() throws {
        let app = launchSeededDashboard()
        app.buttons["home.shopping.summary.card"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["买菜"].waitForExistence(timeout: 5))

        app.tabBars.buttons["首页"].tap()
        app.buttons["home.settings.button"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["我的"].waitForExistence(timeout: 5))
    }

    func testEmptyPlanOffersRecommendationWithoutDebugUI() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_EMPTY_HOME"]
        app.launch()
        XCTAssertTrue(app.buttons["home.today.plan.card"].waitForExistence(timeout: 5))
        app.buttons["home.today.plan.card"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["推荐"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["sync-smoke-status"].exists)
    }
}

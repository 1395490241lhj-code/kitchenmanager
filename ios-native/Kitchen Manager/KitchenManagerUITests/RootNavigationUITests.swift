#if DEBUG
import XCTest

/// The four-destination root: 今天 / 计划 / 食材 / 我的, one per user intent.
/// 买菜 and 菜谱库 are pushes on the tab that owns their subject, so a fifth tab
/// reappearing is a regression rather than a feature — and so is either surface
/// becoming unreachable.
@MainActor
final class RootNavigationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_EMPTY_HOME"]
        app.launch()
        XCTAssertTrue(app.staticTexts["home.primary.title"].waitForExistence(timeout: 15), "Home did not open")
        return app
    }

    func testRootOffersExactlyFourDestinations() {
        let app = launch()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5), "no tab bar")

        for label in ["今天", "计划", "食材", "我的"] {
            let tab = tabBar.buttons[label]
            XCTAssertTrue(tab.exists, "\(label) tab missing")
            XCTAssertGreaterThanOrEqual(tab.frame.height, 44, "\(label) tab below the hit-target floor")
        }
        XCTAssertEqual(tabBar.buttons.count, 4, "the root is 今天 / 计划 / 食材 / 我的 and nothing else")
        XCTAssertFalse(tabBar.buttons["买菜"].exists, "买菜 is a push on 食材, not a tab")
        XCTAssertFalse(tabBar.buttons["菜谱"].exists, "菜谱库 is a push on 计划, not a tab")
    }

    /// Plan hosts the canonical Planner, and the tab keeps its own navigation
    /// stack across a switch — the Planner is a destination now, not a sheet
    /// that is rebuilt every time it is opened.
    func testPlanHostsTheCanonicalPlannerAndKeepsItsStackAcrossTabs() {
        let app = launch()
        let tabBar = app.tabBars.firstMatch

        tabBar.buttons["计划"].tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 10), "Plan did not open the canonical Planner")

        let library = app.buttons["planner.recipes.open"]
        // One visible tap from the Plan root: a real toolbar action, not a row
        // inside 更多. 菜谱库 lost its tab; burying it would demote it twice.
        XCTAssertTrue(library.waitForExistence(timeout: 5), "菜谱库 must be visible on the Plan root")
        XCTAssertEqual(library.label, "菜谱库")
        // Visible and directly tappable on the root, rather than a row that only
        // exists after 更多 is opened. Toolbar items take the system's own 36pt
        // chrome height here, the same as this bar's existing actions.
        XCTAssertTrue(library.isHittable, "菜谱库 must be tappable without opening a menu")
        XCTAssertEqual(library.frame.height, app.buttons["planner.tools.menu"].frame.height,
                       "菜谱库 must match the bar's existing actions")
        library.tap()
        XCTAssertTrue(app.navigationBars["菜谱"].waitForExistence(timeout: 10), "菜谱库 did not open")

        tabBar.buttons["食材"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["食材"].waitForExistence(timeout: 10), "Inventory did not open")

        tabBar.buttons["计划"].tap()
        XCTAssertTrue(
            app.navigationBars["菜谱"].waitForExistence(timeout: 10),
            "the Plan tab's stack must survive leaving and returning to the tab"
        )

        tabBar.buttons["我的"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["我的"].waitForExistence(timeout: 10), "Settings did not open")
    }

    /// 买菜 lost its tab, so the Inventory row that replaced it is the only
    /// thing keeping the list reachable by hand.
    func testShoppingListIsReachableFromInventory() {
        let app = launch()
        app.tabBars.firstMatch.buttons["食材"].tap()

        let shopping = app.buttons["inventory.shopping.open"]
        XCTAssertTrue(shopping.waitForExistence(timeout: 10), "买菜清单 row missing from Inventory")
        XCTAssertGreaterThanOrEqual(shopping.frame.height, 44, "买菜清单 row below the hit-target floor")
        shopping.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["买菜"].waitForExistence(timeout: 10), "买菜 did not open")
    }
}
#endif

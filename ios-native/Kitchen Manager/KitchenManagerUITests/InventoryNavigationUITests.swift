import XCTest

final class InventoryNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Reproduces the exact user-reported scenario: four fresh inventory items
    /// (豆腐/莴笋/土豆/韭菜花), tapping each card once, and checking the detail
    /// title matches the tapped card and a single back tap returns to the list.
    func testTappingEachInventoryCardPushesOnlyThatItem() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_INVENTORY"]
        app.launch()

        let inventoryTab = app.tabBars.buttons["食材"]
        XCTAssertTrue(inventoryTab.waitForExistence(timeout: 5))
        inventoryTab.tap()

        let names = ["豆腐", "莴笋", "土豆", "韭菜花"]

        for name in names {
            let card = app.staticTexts[name].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5), "食材卡片 \(name) 未出现在列表中")
            card.tap()

            let detailTitle = app.navigationBars.staticTexts[name].firstMatch
            XCTAssertTrue(
                detailTitle.waitForExistence(timeout: 3),
                "点击 \(name) 后详情页标题不是 \(name)（可能被压入了其他食材）"
            )

            let backButton = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(backButton.waitForExistence(timeout: 3))
            backButton.tap()

            let listTitle = app.navigationBars.staticTexts["食材"].firstMatch
            XCTAssertTrue(
                listTitle.waitForExistence(timeout: 3),
                "点击 \(name) 后返回一次未直接回到食材主页（可能经过了其他食材详情）"
            )
        }
    }
}

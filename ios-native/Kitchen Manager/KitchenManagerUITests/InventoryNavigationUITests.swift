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

    /// Regression test for a real device-found crash (Phase 2B-7): deleting
    /// an inventory item from its own detail screen, after that screen has
    /// already created a Toggle binding (which captures the item's array
    /// index at that render pass), used to crash with an array
    /// index-out-of-range once the array shrank — a stale binding closure
    /// invoked once more during the dismiss transition. Toggling "设为常备
    /// 食材" first reproduces the exact vulnerable binding the crash log
    /// pointed at; deleting immediately after must not crash the app.
    func testDeletingInventoryItemAfterTogglingStapleDoesNotCrash() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_INVENTORY"]
        app.launch()

        let inventoryTab = app.tabBars.buttons["食材"]
        XCTAssertTrue(inventoryTab.waitForExistence(timeout: 5))
        inventoryTab.tap()

        let card = app.staticTexts["豆腐"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()

        let detailTitle = app.navigationBars.staticTexts["豆腐"].firstMatch
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 3))

        let stapleToggle = app.switches["设为常备食材"].firstMatch
        XCTAssertTrue(stapleToggle.waitForExistence(timeout: 3))
        stapleToggle.tap()

        let deleteButton = app.buttons["删除库存"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3))
        deleteButton.tap()

        let confirmButton = app.alerts.buttons["删除"].firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 3))
        confirmButton.tap()

        // The crash under test happens (or doesn't) during the dismiss
        // transition right after this tap — successfully landing back on a
        // responsive inventory list is the actual assertion that matters.
        let listTitle = app.navigationBars.staticTexts["食材"].firstMatch
        XCTAssertTrue(listTitle.waitForExistence(timeout: 5), "删除后未安全返回食材列表（App 可能已崩溃）")
        XCTAssertTrue(app.state == .runningForeground, "App 在删除库存后不再前台运行")
        XCTAssertFalse(app.staticTexts["豆腐"].firstMatch.exists, "已删除的食材不应再出现在列表中")

        // The bug's fix moved every field from an index-captured binding to
        // an id-resolved one — the regression this specifically guards
        // against is a *different* item silently inheriting the deleted
        // item's old array position and getting corrupted. Assert every
        // other seeded item is still present, and that one of them still
        // opens to its own, correct, untouched detail screen.
        for remainingName in ["莴笋", "土豆", "韭菜花"] {
            XCTAssertTrue(
                app.staticTexts[remainingName].firstMatch.waitForExistence(timeout: 3),
                "删除豆腐后，\(remainingName) 也不应受影响"
            )
        }
        let untouchedCard = app.staticTexts["莴笋"].firstMatch
        untouchedCard.tap()
        let untouchedDetailTitle = app.navigationBars.staticTexts["莴笋"].firstMatch
        XCTAssertTrue(
            untouchedDetailTitle.waitForExistence(timeout: 3),
            "删除豆腐后，莴笋的详情页标题不再是莴笋（可能被之前豆腐的绑定/索引串位污染）"
        )
        let untouchedQuantityField = app.textFields["当前数量"].firstMatch
        XCTAssertTrue(untouchedQuantityField.waitForExistence(timeout: 3))
        XCTAssertEqual(untouchedQuantityField.value as? String, "1", "莴笋的数量不应因删除豆腐而改变")
    }
}

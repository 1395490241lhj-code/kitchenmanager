import XCTest

final class ShoppingExperienceUITests: XCTestCase {
    private func launchShopping(additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_SHOPPING"] + additionalArguments
        app.launch()
        XCTAssertTrue(app.navigationBars.staticTexts["买菜"].waitForExistence(timeout: 5))
        return app
    }

    func testNormalHierarchyKeepsSummaryRowsAndExistingActionsAccessible() {
        let app = launchShopping()

        XCTAssertTrue(element("shopping.summary.pending", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("shopping.summary.purchased", in: app).exists)
        XCTAssertTrue(element("shopping.summary.categories", in: app).exists)
        XCTAssertTrue(app.buttons["shopping.add.button"].isHittable)
        XCTAssertTrue(app.buttons["shopping.mode.toggle"].isHittable)
        XCTAssertTrue(app.buttons["shopping.bulk.menu"].isHittable)
        let tomatoRow = app.buttons["番茄，2 个，未购买"]
        XCTAssertTrue(tomatoRow.exists)
        XCTAssertGreaterThanOrEqual(tomatoRow.frame.height, 44)
    }

    func testSearchShowsMatchingShoppingItem() throws {
        let app = launchShopping()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("番茄")

        XCTAssertTrue(app.staticTexts["番茄"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["大米"].exists)
    }

    func testSearchNoResultsOffersClearSearch() throws {
        let app = launchShopping()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("不存在的项目")

        let clear = app.buttons["shopping.search.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertTrue(clear.isHittable)
        XCTAssertGreaterThanOrEqual(clear.frame.height, 44)
        clear.tap()

        XCTAssertTrue(app.staticTexts["番茄"].waitForExistence(timeout: 5))
    }

    func testPendingOnlySearchHidesUnrelatedPurchasedSection() throws {
        let app = launchShopping()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("番茄")

        XCTAssertTrue(app.buttons["番茄，2 个，未购买"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["shopping.purchased.toggle"].exists)
        XCTAssertFalse(app.staticTexts["牛奶"].exists)
    }

    func testPurchasedSectionExpandsAndCollapses() throws {
        let app = launchShopping()
        let toggle = app.buttons["shopping.purchased.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["牛奶"].exists)

        toggle.tap()
        XCTAssertTrue(app.staticTexts["牛奶"].waitForExistence(timeout: 5))

        toggle.tap()
        XCTAssertFalse(app.staticTexts["牛奶"].exists)
    }

    func testBulkMenuMarksAllPendingItemsPurchased() throws {
        let app = launchShopping()
        let bulkMenu = app.buttons["shopping.bulk.menu"]
        XCTAssertTrue(bulkMenu.waitForExistence(timeout: 5))
        bulkMenu.tap()
        XCTAssertTrue(app.buttons["全部标记为已购买"].waitForExistence(timeout: 5))
        app.buttons["全部标记为已购买"].tap()

        let purchasedToggle = app.buttons["shopping.purchased.toggle"]
        XCTAssertTrue(purchasedToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(purchasedToggle.label.contains("3 项"))
        XCTAssertFalse(app.staticTexts["sync-smoke-status"].exists)
    }

    func testBulkMenuClearPurchasedSupportsCancelAndConfirm() throws {
        let app = launchShopping()

        openBulkMenu(in: app)
        app.buttons["清除已购买"].tap()
        XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["shopping.purchased.toggle"].exists)

        openBulkMenu(in: app)
        app.buttons["清除已购买"].tap()
        XCTAssertTrue(app.buttons["清除已购买"].waitForExistence(timeout: 5))
        app.buttons["清除已购买"].tap()
        XCTAssertFalse(app.buttons["shopping.purchased.toggle"].exists)
        XCTAssertTrue(app.staticTexts["番茄"].exists)
    }

    func testBulkMenuExposesStockInConfirmation() throws {
        let app = launchShopping()

        openBulkMenu(in: app)
        let stockIn = app.buttons["全部入库"]
        XCTAssertTrue(stockIn.waitForExistence(timeout: 5))
        stockIn.tap()
        XCTAssertTrue(app.alerts["全部入库？"].waitForExistence(timeout: 5))
        app.alerts["全部入库？"].buttons["取消"].tap()
    }

    func testStockInConfirmationProcessesPurchasedItemsIntoInventory() throws {
        let app = launchShopping()

        openBulkMenu(in: app)
        app.buttons["全部入库"].tap()
        let alert = app.alerts["全部入库？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["入库"].tap()

        XCTAssertFalse(app.buttons["shopping.purchased.toggle"].waitForExistence(timeout: 2))
        let inventoryTab = app.buttons["食材"]
        XCTAssertTrue(inventoryTab.waitForExistence(timeout: 5))
        inventoryTab.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["食材"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["牛奶"].waitForExistence(timeout: 5))
    }

    func testBulkMenuExpandsAndCollapsesPurchasedItems() throws {
        let app = launchShopping()

        openBulkMenu(in: app)
        app.buttons["展开已购买"].tap()
        XCTAssertTrue(app.staticTexts["牛奶"].waitForExistence(timeout: 5))

        openBulkMenu(in: app)
        app.buttons["折叠已购买"].tap()
        XCTAssertFalse(app.staticTexts["牛奶"].exists)
    }

    func testShoppingModeTogglesItemsAndReturnsToNormalMode() throws {
        let app = launchShopping()
        app.buttons["shopping.mode.toggle"].tap()
        XCTAssertTrue(element("shopping.mode.container", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("shopping.mode.remaining", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["shopping.mode.exit"].isHittable)
        XCTAssertFalse(app.buttons["shopping.mode.toggle"].exists, "购物模式中只能保留一个退出操作")
        XCTAssertFalse(app.buttons["shopping.bulk.menu"].exists)
        // Single-item entry stays available in the aisle; bulk management does not.
        XCTAssertTrue(app.buttons["shopping.add.button"].isHittable, "购物模式中仍应能添加项目")
        app.buttons["番茄，2 个，未购买"].tap()
        let purchasedToggle = app.buttons["shopping.mode.purchased.toggle"]
        XCTAssertTrue(purchasedToggle.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(purchasedToggle.frame.height, 44)
        // Purchased items start collapsed, so an already-bought item must not be
        // on screen until the toggle is used — and must hide again after it.
        XCTAssertFalse(app.staticTexts["牛奶"].exists, "已购买分组应默认折叠")
        purchasedToggle.tap()
        XCTAssertTrue(app.staticTexts["牛奶"].exists)
        app.buttons["shopping.mode.purchased.toggle"].tap()
        XCTAssertFalse(app.staticTexts["牛奶"].exists, "再次折叠后已购买项目应隐藏")
        app.buttons["shopping.mode.purchased.toggle"].tap()
        app.buttons["shopping.mode.exit"].tap()
        XCTAssertFalse(element("shopping.mode.container", in: app).exists)
        XCTAssertTrue(app.buttons["shopping.bulk.menu"].waitForExistence(timeout: 5))
    }

    func testEmptyStateUsesTheExistingAddShoppingSheet() {
        let app = launchShopping()

        openBulkMenu(in: app)
        app.buttons["全部标记为已购买"].tap()
        openBulkMenu(in: app)
        app.buttons["清除已购买"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.firstMatch.buttons["清除已购买"].tap()

        XCTAssertTrue(element("shopping.empty", in: app).waitForExistence(timeout: 5))
        let addButton = app.buttons["shopping.empty.add.button"]
        XCTAssertTrue(addButton.isHittable)
        addButton.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["添加买菜项目"].waitForExistence(timeout: 5))
    }

    func testAccessibilityXXXLKeepsCoreShoppingControlsReachable() {
        let app = launchShopping(additionalArguments: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ])

        XCTAssertTrue(element("shopping.summary.pending", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["番茄，2 个，未购买"].isHittable)
        XCTAssertTrue(app.buttons["shopping.add.button"].isHittable)
        XCTAssertTrue(app.buttons["shopping.mode.toggle"].isHittable)
    }

    // MARK: - Shopping Mode keeps search and single-item entry

    private func enterShoppingMode(in app: XCUIApplication) {
        app.buttons["shopping.mode.toggle"].tap()
        XCTAssertTrue(element("shopping.mode.container", in: app).waitForExistence(timeout: 5))
    }

    func testShoppingModeSupportsSearchingTheList() throws {
        let app = launchShopping()
        enterShoppingMode(in: app)

        // Single exit control, verified before search takes focus.
        XCTAssertTrue(app.buttons["shopping.mode.exit"].exists)
        XCTAssertFalse(app.buttons["shopping.mode.toggle"].exists, "购物模式中只能保留一个退出操作")

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "购物模式中应可搜索")
        search.tap()
        search.typeText("番茄")

        XCTAssertTrue(app.buttons["番茄，2 个，未购买"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["大米，1 袋，未购买"].exists, "搜索应过滤掉不匹配项目")
        let searching = XCTAttachment(screenshot: app.screenshot())
        searching.name = "shopping-mode-searching"
        searching.lifetime = .keepAlways
        add(searching)
        // Still in Shopping Mode, and bulk management stays out of it.
        XCTAssertTrue(element("shopping.mode.container", in: app).exists)
        XCTAssertFalse(app.buttons["shopping.bulk.menu"].exists, "购物模式不应恢复批量菜单")
    }

    func testShoppingModeSearchWithNoMatchOffersClearSearch() throws {
        let app = launchShopping()
        enterShoppingMode(in: app)

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("不存在的项目")

        let clear = app.buttons["shopping.mode.search.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "无结果时应提供清除搜索")
        clear.tap()
        XCTAssertTrue(app.buttons["番茄，2 个，未购买"].waitForExistence(timeout: 5))
    }

    func testShoppingModeCanAddItemThroughExistingSheet() throws {
        let app = launchShopping()
        enterShoppingMode(in: app)

        let add = app.buttons["shopping.add.button"]
        XCTAssertTrue(add.isHittable, "购物模式中应保留添加项目")
        add.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["添加买菜项目"].waitForExistence(timeout: 5))

        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("酱油")
        app.buttons["添加"].firstMatch.tap()

        // The new item lands in the mode's category-first list without leaving the mode.
        XCTAssertTrue(app.buttons["酱油，1 份，未购买"].waitForExistence(timeout: 5), "新项目应出现在购物模式列表中")
        XCTAssertTrue(element("shopping.mode.container", in: app).exists, "添加后应仍在购物模式")
        XCTAssertTrue(app.buttons["shopping.mode.exit"].exists)
    }

    func testShoppingModeAccessibilityXXXLKeepsSearchAndAddReachable() {
        let app = launchShopping(additionalArguments: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        // Baseline: the same toolbar button in normal mode, for comparison.
        let normalAddHeight = app.buttons["shopping.add.button"].frame.height
        enterShoppingMode(in: app)

        let add = app.buttons["shopping.add.button"]
        XCTAssertTrue(add.isHittable)
        // Toolbar chrome keeps UIKit's own bar-item metrics at every text size;
        // Shopping Mode must simply not be worse than normal Shopping.
        XCTAssertEqual(add.frame.height, normalAddHeight, accuracy: 0.5, "购物模式的添加按钮应与普通模式一致")
        let exit = app.buttons["shopping.mode.exit"]
        XCTAssertTrue(exit.isHittable)
        XCTAssertEqual(exit.frame.height, normalAddHeight, accuracy: 0.5, "退出控件应与其他工具栏控件一致")
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func openBulkMenu(in app: XCUIApplication) {
        let bulkMenu = app.buttons["shopping.bulk.menu"]
        XCTAssertTrue(bulkMenu.waitForExistence(timeout: 5))
        bulkMenu.tap()
    }
}

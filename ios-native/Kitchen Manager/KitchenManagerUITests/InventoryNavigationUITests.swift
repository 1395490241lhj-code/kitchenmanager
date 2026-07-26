import XCTest

final class InventoryNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The expanded tab-bar top edge, captured *before* any scrolling.
    /// `.tabBarMinimizeBehavior(.onScrollDown)` shrinks the bar once the list
    /// scrolls, so comparing against its live frame at the bottom of the list
    /// would test a smaller bar than the user rests on. Clearance is asserted
    /// against this full-size edge instead.
    private func expandedTabBarTop(of app: XCUIApplication) -> CGFloat {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
        return tabBar.frame.minY
    }

    /// While a search is active the app exposes two collection views — the real
    /// inventory list plus a short keyboard/suggestion strip that reports zero
    /// cells. `firstMatch` picks the strip, so the list is selected by area.
    private func inventoryList(of app: XCUIApplication) -> XCUIElement {
        let collections = app.collectionViews.allElementsBoundByIndex
        if let largest = collections.max(by: { $0.frame.height < $1.frame.height }) {
            return largest
        }
        return app.tables.firstMatch
    }

    /// Scrolls until `target` is on screen and hittable, then stops. Bounded by
    /// swipe count rather than a fixed number of pages, so the same helper works
    /// at default and Accessibility sizes (where the list is several times
    /// taller). Returns whether the target was reached.
    @discardableResult
    private func scrollUntilVisible(_ target: XCUIElement, in app: XCUIApplication, swipes: Int = 12) -> Bool {
        let scrollable = inventoryList(of: app)
        guard scrollable.exists else {
            XCTFail("库存列表不存在，无法滚动")
            return false
        }
        for _ in 0..<swipes {
            if target.exists && target.isHittable { return true }
            scrollable.swipeUp()
        }
        return target.exists && target.isHittable
    }

    /// A row is only genuinely reachable if its whole frame — not just its
    /// midpoint — comes to rest above the floating tab bar.
    private func assertClearsTabBar(
        _ element: XCUIElement,
        tabBarTop: CGFloat,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.exists, "\(label) 不存在", file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(label) 不可点击（可能被 Tab Bar 遮挡）", file: file, line: line)
        XCTAssertLessThanOrEqual(
            element.frame.maxY,
            tabBarTop,
            "\(label) 底部 \(element.frame.maxY) 仍在 Tab Bar 上边缘 \(tabBarTop) 之下，被遮挡",
            file: file,
            line: line
        )
    }

    /// Phase UI-3 blocking fix: the last row of a long inventory, the last
    /// search result, and the pantry empty-state CTA must all be able to rest
    /// fully above the floating tab bar — at default *and* Accessibility XXXL
    /// text sizes, where the content is several screens tall.
    func testInventoryBottomContentClearsFloatingTabBar() throws {
        for contentSize in ["UICTContentSizeCategoryLarge", "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = XCUIApplication()
            app.launchArguments = [
                "UITEST_SEED_INVENTORY_LARGE",
                "-UIPreferredContentSizeCategoryName", contentSize
            ]
            app.launch()

            XCTAssertTrue(app.staticTexts["嫩豆腐"].waitForExistence(timeout: 5))
            let tabBarTop = expandedTabBarTop(of: app)

            // "最近消耗" is the final row of the inventory list, so it is the row
            // most at risk of sitting under the tab bar. The NavigationLink
            // renders as a Button spanning the whole row, so its frame *is* the
            // row's frame — the cell wrapper carries no label of its own.
            let lastRow = app.buttons["最近消耗"]
            XCTAssertTrue(
                scrollUntilVisible(lastRow, in: app),
                "未能滚动到列表末尾的「最近消耗」（\(contentSize)）"
            )
            assertClearsTabBar(lastRow, tabBarTop: tabBarTop, label: "列表最后一行（\(contentSize)）")

            if contentSize.contains("Accessibility") {
                attachScreenshot(of: app, named: "inventory-accessibility-bottom")
            }
            app.terminate()
        }
    }

    /// The pantry empty state's CTA is the only way into the staple flow from
    /// this screen, so it must clear the tab bar too.
    func testPantryEmptyStateCTAClearsTabBarAndOpensExistingFlow() throws {
        let app = XCUIApplication()
        // Seeds fresh inventory only — no staples — so the pantry section
        // renders its empty state.
        app.launchArguments = ["UITEST_SEED_INVENTORY"]
        app.launch()

        let inventoryTab = app.tabBars.buttons["食材"]
        XCTAssertTrue(inventoryTab.waitForExistence(timeout: 5))
        inventoryTab.tap()
        XCTAssertTrue(app.staticTexts["还没有常备食材"].waitForExistence(timeout: 5))

        // The empty state renders the "还没有常备食材" title once; a repeated
        // "常备食材 0 项" section header above it was removed in UI-3.
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "还没有常备食材")).count,
            1,
            "常备食材空状态标题不应重复出现"
        )
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "常备食材 0")).firstMatch.exists,
            "常备食材空状态不应再带计数为 0 的重复分区标题"
        )

        let tabBarTop = expandedTabBarTop(of: app)

        let cta = app.buttons["inventory.staple.empty.add.button"]
        XCTAssertTrue(scrollUntilVisible(cta, in: app), "未能滚动到常备食材空状态 CTA")
        assertClearsTabBar(cta, tabBarTop: tabBarTop, label: "常备食材空状态 CTA")
        XCTAssertGreaterThanOrEqual(cta.frame.height, 44, "常备食材 CTA 点击区域应至少 44pt")

        // Still opens the pre-existing AddPantryStapleView flow.
        cta.tap()
        XCTAssertTrue(app.navigationBars["添加常备食材"].waitForExistence(timeout: 5))
    }

    /// The last search result must also be reachable rather than parked under
    /// the tab bar.
    func testLastSearchResultClearsTabBar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_INVENTORY_LARGE"]
        app.launch()

        XCTAssertTrue(app.staticTexts["嫩豆腐"].waitForExistence(timeout: 5))
        let tabBarTop = expandedTabBarTop(of: app)

        app.swipeDown()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        // "豆" matches 嫩豆腐 and 土豆, so there is a meaningful "last" result.
        searchField.typeText("豆")

        XCTAssertTrue(app.staticTexts["嫩豆腐"].waitForExistence(timeout: 3))

        // Result rows are the `inventory.item.*` buttons; take the lowest one on
        // screen. Cell wrappers carry no label, and while searching the app also
        // exposes a zero-cell keyboard suggestion strip.
        let results = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "inventory.item."))
            .allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(results.count, 2, "搜索「豆」应至少返回两条结果")
        guard let last = results.max(by: { $0.frame.maxY < $1.frame.maxY }) else {
            return XCTFail("搜索结果为空")
        }
        assertClearsTabBar(last, tabBarTop: tabBarTop, label: "最后一条搜索结果")
    }

    /// Phase UI-3 blocking fix: at Accessibility XXXL the title, summary, and
    /// section header must leave room for real food content on the first screen.
    /// Before the fix the large title plus the summary consumed it entirely, so
    /// no ingredient was reachable without scrolling.
    func testAccessibilityXXXLKeepsFirstIngredientOnFirstScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_SEED_INVENTORY_LARGE",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()

        let firstItem = app.staticTexts["嫩豆腐"]
        XCTAssertTrue(firstItem.waitForExistence(timeout: 5))

        let tabBarTop = expandedTabBarTop(of: app)
        XCTAssertTrue(
            firstItem.isHittable,
            "Accessibility XXXL 下首屏应能直接看到第一项食材，无需滚动"
        )
        XCTAssertLessThanOrEqual(
            firstItem.frame.maxY,
            tabBarTop,
            "第一项食材被 Tab Bar 遮挡，说明页面 chrome 仍占据整个首屏"
        )

        // The navigation title collapses to the inline title at Accessibility
        // sizes, so it stays a compact heading rather than a half-screen banner.
        let navigationBar = app.navigationBars["食材"]
        XCTAssertTrue(navigationBar.exists, "食材 导航栏缺失")
        let title = navigationBar.staticTexts["食材"]
        XCTAssertTrue(title.exists, "食材 标题缺失")
        XCTAssertLessThan(title.frame.height, 40, "Accessibility XXXL 下页面标题仍在失控放大")

        // The summary is chrome and must stay a minority of the screen rather
        // than pushing the list off it. `accessibilityElement(children: .ignore)`
        // publishes it as a container element, not a static text, so match on any
        // descendant carrying the combined label.
        let summary = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "项食材在库")
        ).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "总库存摘要缺失")
        XCTAssertLessThan(
            summary.frame.height,
            app.windows.firstMatch.frame.height * 0.25,
            "Accessibility XXXL 下总库存摘要占据了超过四分之一屏幕"
        )

        // Both toolbar actions stay bounded and tappable instead of scaling with
        // the text. Their published frames use UIKit's standard bar-button
        // metric (~36pt tall) with the navigation bar supplying the surrounding
        // touch slop, so this asserts "bounded and hittable" rather than a
        // 44pt published frame that a toolbar item never reports.
        for identifier in ["inventory.add.button", "inventory.more.button"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.exists, "\(identifier) 缺失")
            XCTAssertTrue(button.isHittable, "\(identifier) 不可点击")
            XCTAssertGreaterThanOrEqual(button.frame.height, 30, "\(identifier) 高度过小")
            XCTAssertLessThanOrEqual(button.frame.height, 60, "\(identifier) 图标随字号无限放大")
            XCTAssertLessThanOrEqual(button.frame.width, 60, "\(identifier) 图标随字号无限放大")
        }

        // The row keeps name, status, and quantity all present and
        // non-overlapping at this size.
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "inventory.item.")
        ).firstMatch
        XCTAssertTrue(row.exists, "首个食材行缺失")
        XCTAssertTrue(row.label.contains("嫩豆腐"), "食材行标签缺少名称：\(row.label)")
        XCTAssertTrue(row.label.contains("2 盒"), "食材行标签缺少数量：\(row.label)")

        let statusText = app.staticTexts["剩余 1 天"]
        let quantityText = app.staticTexts["2 盒"]
        XCTAssertTrue(statusText.exists, "状态文案缺失")
        XCTAssertTrue(quantityText.exists, "数量文案缺失")
        XCTAssertFalse(
            statusText.frame.intersects(quantityText.frame),
            "Accessibility XXXL 下状态与数量互相覆盖"
        )
        XCTAssertLessThanOrEqual(
            quantityText.frame.maxX,
            app.windows.firstMatch.frame.maxX,
            "数量被挤出屏幕"
        )

        attachScreenshot(of: app, named: "inventory-accessibility-xxxl")
    }

    func testInventorySearchKeepsExistingItemsAndAddAccessReachable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_INVENTORY"]
        app.launch()

        let inventoryTab = app.tabBars.buttons["食材"]
        XCTAssertTrue(inventoryTab.waitForExistence(timeout: 5))
        inventoryTab.tap()

        XCTAssertTrue(app.staticTexts["豆腐"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["inventory.add.button"].isHittable)
        attachScreenshot(of: app, named: "inventory-normal")

        app.swipeDown()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("豆腐")

        XCTAssertTrue(app.staticTexts["豆腐"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["土豆"].exists, "搜索结果不应保留不匹配食材")
        attachScreenshot(of: app, named: "inventory-search")
    }

    func testInventoryVisualReviewStatesRemainReadable() throws {
        let empty = XCUIApplication()
        empty.launchArguments = ["UITEST_SEED_EMPTY_INVENTORY"]
        empty.launch()
        XCTAssertTrue(empty.staticTexts["还没有食材"].waitForExistence(timeout: 5))
        XCTAssertTrue(empty.buttons["inventory.empty.add.button"].isHittable)
        attachScreenshot(of: empty, named: "inventory-empty")
        empty.terminate()

        let large = XCUIApplication()
        large.launchArguments = ["UITEST_SEED_INVENTORY_LARGE"]
        large.launch()
        XCTAssertTrue(large.staticTexts["嫩豆腐"].waitForExistence(timeout: 5))
        XCTAssertTrue(large.buttons["inventory.add.button"].isHittable)
        attachScreenshot(of: large, named: "inventory-large")
        large.terminate()

        let accessibility = XCUIApplication()
        accessibility.launchArguments = [
            "UITEST_SEED_INVENTORY_LARGE",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        accessibility.launch()
        XCTAssertTrue(accessibility.staticTexts["嫩豆腐"].waitForExistence(timeout: 5))
        XCTAssertTrue(accessibility.buttons["inventory.add.button"].isHittable)
        attachScreenshot(of: accessibility, named: "inventory-accessibility-xxxl")
        accessibility.terminate()

        // Dark Mode is driven through the app's own appearance preference.
        // Neither "-AppleInterfaceStyle Dark" as a launch argument nor
        // `XCUIDevice.shared.appearance = .dark` reached the app before its first
        // render here, so the previous "dark" screenshot was silently a duplicate
        // of the light one.
        let dark = XCUIApplication()
        dark.launchArguments = ["UITEST_SEED_INVENTORY_LARGE", "UITEST_FORCE_DARK_APPEARANCE"]
        dark.launch()
        XCTAssertTrue(dark.staticTexts["嫩豆腐"].waitForExistence(timeout: 5))
        XCTAssertTrue(dark.buttons["inventory.add.button"].isHittable)
        attachScreenshot(of: dark, named: "inventory-dark")
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

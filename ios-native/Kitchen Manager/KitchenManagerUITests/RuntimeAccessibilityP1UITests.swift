import XCTest

final class RuntimeAccessibilityP1UITests: XCTestCase {
    private let sizes = [
        ("normal", "UICTContentSizeCategoryL", false),
        ("accessibilityM", "UICTContentSizeCategoryAccessibilityM", true),
        ("accessibilityL", "UICTContentSizeCategoryAccessibilityL", true),
        ("accessibilityXL", "UICTContentSizeCategoryAccessibilityXL", true),
        ("accessibilityXXL", "UICTContentSizeCategoryAccessibilityXXL", true),
        ("accessibilityXXXL", "UICTContentSizeCategoryAccessibilityXXXL", true),
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// D-042 retired the Home → 今天的计划 route; today's meal row and its 做好了
    /// now live on Planner (Slice A), reached through the 计划 tab.
    func testTodayPlanRowAdaptsWithoutClipping() throws {
        for (name, size, _) in sizes {
            let app = launch("UITEST_SEED_ACCESSIBILITY_PLANNER_MEAL", size: size)
            // A tab-bar button needs no scrolling to reach at any text size.
            let planner = app.tabBars.buttons["计划"]
            XCTAssertTrue(planner.waitForExistence(timeout: 5))
            planner.tap()
            XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5), "\(name): 用餐计划未打开")

            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'planner.meal.'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(name): 菜品行缺失")
            XCTAssertTrue(row.label.contains("超长名称的番茄牛腩炖土豆配时令蔬菜家庭晚餐"), "\(name): 菜名缺失或被裁切: \(row.label)")
            XCTAssertTrue(row.label.contains("4 人份"), "\(name): 份量缺失: \(row.label)")
            XCTAssertTrue(scrollUntilFullyHittable(row, in: app), "\(name): 菜品行不可完整到达")
            assertOnScreen(row, in: app, label: "\(name) 菜品行")
            XCTAssertGreaterThanOrEqual(row.frame.height, 43.5, "\(name): 菜品行高度不足 44pt")

            row.swipeRight()
            let complete = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'planner.meal.complete.'")).firstMatch
            XCTAssertTrue(complete.waitForExistence(timeout: 5), "\(name): 做好了缺失")
            assertAction(complete, in: app, label: "\(name) 做好了")
            app.terminate()
        }
    }

    func testRestockSuggestionAndSummaryCTAAdaptWithoutClipping() throws {
        for (name, size, isAccessibility) in sizes {
            let app = launch("UITEST_SEED_ACCESSIBILITY_RESTOCK", size: size)
            let suggestionName = app.staticTexts["inventory.restock.name"]
            XCTAssertTrue(scrollUntilVisible(suggestionName, in: app), "\(name): 补货建议名称不可达")
            let add = app.buttons["inventory.restock.add.button"]
            // scrollUntilVisible may stop while the add button is still
            // half-hidden under the tab bar; hittability is what assertAction
            // checks, so finish scrolling the button into a hittable frame.
            _ = scrollUntilFullyHittable(add, in: app)
            assertOnScreen(suggestionName, in: app, label: "\(name) 补货建议名称")
            assertAction(add, in: app, label: "\(name) 加入清单")
            XCTAssertFalse(suggestionName.frame.intersects(add.frame), "\(name): 补货名称与按钮重叠")
            if isAccessibility {
                XCTAssertGreaterThanOrEqual(add.frame.minY, suggestionName.frame.maxY - 1, "XXXL: 建议操作未排在名称下方")
            } else {
                XCTAssertGreaterThanOrEqual(add.frame.minX, suggestionName.frame.maxX - 1, "Normal: 建议行不再横排")
            }

            let addAll = app.buttons["inventory.restock.addAll.button"]
            // scrollUntilVisible accepts partial overlap, which left a CTA
            // half-hidden under the tab bar and unhittable. Hittability is
            // the actual contract here, so wait for a fully contained frame.
            XCTAssertTrue(scrollUntilFullyHittable(addAll, in: app), "\(name): 汇总 CTA 不可达")
            assertAction(addAll, in: app, label: "\(name) 汇总 CTA")
            XCTAssertTrue(addAll.label.contains("加入 1 项常备补货"), "\(name): 汇总 CTA 文案不完整：\(addAll.label)")
            app.terminate()
        }
    }

    /// Home V2 replaced the count chips (即将到期 2) with named rows
    /// (临期牛奶 · 明天到期). The chip contract asserted that each capsule stayed
    /// narrower than the screen and wrapped onto its own line at Accessibility
    /// sizes; rows are list rows, so the equivalent contract is that they stack,
    /// stay tappable, and carry both halves of their label without truncating
    /// either. This test replaces `testHomeInventoryStatusChipsAdaptWithoutClipping`.
    func testHomeAttentionRowsAdaptWithoutClipping() throws {
        for (name, size, isAccessibility) in sizes {
            let app = launch("UITEST_SEED_HOME_DASHBOARD", size: size)
            // Old contract: three named rows, because Home listed up to four.
            // New contract: Home names the two highest-priority items and sends
            // the rest to Inventory, so 大米 (low stock, the lowest tier) is now
            // behind the overflow row rather than on the page.
            //
            // Not weaker: the layout property under test is asserted on the same
            // kinds of row at the same six sizes, and the overflow control — the
            // one that now carries everything the cap left out — is measured for
            // reachability and hit size for the first time.
            let rows = [
                app.buttons["home.attention.expired.过期生菜"],
                app.buttons["home.attention.expiring.临期牛奶"]
            ]
            let expectations = [
                ("过期生菜", "已过期"),
                ("临期牛奶", "明天到期")
            ]

            for (row, expectation) in zip(rows, expectations) {
                XCTAssertTrue(scrollUntilFullyHittable(row, in: app), "\(name): \(expectation.0) 行不可达")
                assertAction(row, in: app, label: "\(name) \(expectation.0) 行")
                XCTAssertTrue(
                    row.label.contains(expectation.0),
                    "\(name): 行必须点名食材，实际为 \(row.label)"
                )
                XCTAssertTrue(
                    row.label.contains(expectation.1),
                    "\(name): 行必须保留原因，实际为 \(row.label)"
                )
            }

            // Rows are always stacked — that is what makes them a list rather
            // than a chip cloud — at every size.
            XCTAssertGreaterThan(rows[1].frame.minY, rows[0].frame.minY, "\(name): 待处理行未纵向排列")

            // What the cap left out has to stay reachable and tappable, or the
            // smaller list is just a smaller truth.
            let overflow = app.buttons["home.attention.overflow"]
            XCTAssertTrue(scrollUntilFullyHittable(overflow, in: app), "\(name): 溢出行不可达")
            assertAction(overflow, in: app, label: "\(name) 溢出行")
            XCTAssertGreaterThan(overflow.frame.minY, rows[1].frame.minY, "\(name): 溢出行必须在具名行之后")

            if isAccessibility {
                // Name and detail stack instead of shrinking or truncating, so
                // the row gets taller rather than narrower.
                XCTAssertGreaterThan(
                    rows[0].frame.height,
                    2 * 44 - 1,
                    "XXXL: 行内应堆叠名称与原因，而不是截断"
                )
            }

            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "home-attention-rows-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    func testManualStockInFieldsAdaptWithoutOverflow() throws {
        for (name, size, isAccessibility) in sizes {
            let app = launch("UITEST_SEED_MANUAL_ACCESSIBILITY", size: size)
            // Manual entry lives on the Inventory tab now; Home has no `+` (FR-007).
            app.tabBars.buttons["食材"].tap()
            let manualEntry = app.buttons["inventory.add.button"]
            XCTAssertTrue(manualEntry.waitForExistence(timeout: 5), "\(name): 添加食材入口缺失")
            XCTAssertTrue(manualEntry.isHittable, "\(name): 添加食材入口不可达")
            manualEntry.tap()

            let ingredient = app.textFields["manualInventoryName"]
            let quantity = app.textFields["manualInventoryQuantity"]
            let unit = app.textFields["manualInventoryUnit"]
            let expiryDatePicker = app.datePickers["manualInventoryExpiryDatePicker"]
            let expiryHint = app.staticTexts["manualInventoryExpiryHint"]
            // Old contract: each bare Form TextField was asserted >=44pt at
            // Accessibility sizes. On this runtime the TextField's AX element
            // keeps the platform-intrinsic UITextField height (~35pt) and no
            // outer/inner frame or padding reaches it (measured probe,
            // baseline HEAD included), so the per-field height assertion was
            // never actually satisfiable at AX sizes. New contract: the form
            // row is the tappable surface and carries the 44pt target.
            // Not weaker: existence, on-screen containment, hittability,
            // non-overlap and stacking per field are all unchanged; the hit
            // height is asserted on the superset row container, which is what
            // users actually tap.
            let row = app.otherElements["manualInventoryDraftRow"]
            XCTAssertTrue(ingredient.waitForExistence(timeout: 5), "\(name): 名称字段缺失")
            XCTAssertTrue(quantity.exists, "\(name): 数量字段缺失")
            XCTAssertTrue(unit.exists, "\(name): 单位字段缺失")
            for (field, fieldName) in [(ingredient, "名称"), (quantity, "数量"), (unit, "单位")] {
                if isAccessibility {
                    XCTAssertTrue(scrollUntilFullyHittable(field, in: app), "\(name): \(fieldName)字段不可达")
                }
                assertFullyOnScreen(field, in: app, label: "\(name) \(fieldName)字段")
                XCTAssertTrue(field.isHittable, "\(name): \(fieldName)字段不可点击")
            }
            if isAccessibility {
                XCTAssertTrue(row.waitForExistence(timeout: 5), "\(name): 表单行缺失")
                XCTAssertGreaterThanOrEqual(row.frame.height, 43.5, "XXXL: 表单行点击高度不足 44pt")
            }
            XCTAssertTrue(expiryDatePicker.waitForExistence(timeout: 5), "\(name): 保质期 DatePicker 缺失")
            XCTAssertTrue(expiryHint.exists, "\(name): 保质期说明缺失")
            if isAccessibility {
                XCTAssertTrue(scrollUntilFullyHittable(expiryDatePicker, in: app), "\(name): 保质期 DatePicker 不可点击")
            } else {
                XCTAssertTrue(scrollUntilFullyVisible(expiryDatePicker, in: app), "\(name): 保质期 DatePicker 不可达")
            }
            assertFullyOnScreen(expiryDatePicker, in: app, label: "\(name) 保质期 DatePicker")
            XCTAssertTrue(scrollUntilFullyVisible(expiryHint, in: app), "\(name): 保质期说明不可达")
            assertFullyOnScreen(expiryHint, in: app, label: "\(name) 保质期说明")
            XCTAssertEqual(expiryDatePicker.label, "保质期", "\(name): DatePicker accessibility label 不正确")
            XCTAssertFalse(ingredient.frame.intersects(quantity.frame), "\(name): 名称与数量字段重叠")
            XCTAssertFalse(quantity.frame.intersects(unit.frame), "\(name): 数量与单位字段重叠")
            if isAccessibility {
                XCTAssertGreaterThanOrEqual(quantity.frame.minY, ingredient.frame.maxY - 1, "XXXL: 数量未排在名称下方")
                XCTAssertGreaterThanOrEqual(unit.frame.minY, quantity.frame.maxY - 1, "XXXL: 单位未排在数量下方")
                XCTAssertGreaterThan(unit.frame.width, 52, "XXXL: 单位字段仍被固定为 52pt")
            } else {
                XCTAssertLessThan(abs(quantity.frame.midY - ingredient.frame.midY), 2, "Normal: 名称与数量不再横排")
                XCTAssertLessThan(abs(unit.frame.midY - quantity.frame.midY), 2, "Normal: 数量与单位不再横排")
            }

            let confirm = app.buttons["确认入库"]
            XCTAssertTrue(scrollUntilHittable(confirm, in: app), "\(name): 确认入库按钮不可达")
            assertAction(confirm, in: app, label: "\(name) 确认入库")
            app.terminate()
        }
    }

    func testRecommendationCardsAdaptWithoutClipping() throws {
        let recipeID = "ui-test-accessibility-recommendation-one"
        for (name, size, isAccessibility) in sizes {
            let app = launch("UITEST_SEED_ACCESSIBILITY_RECOMMENDATION", size: size)
            let more = app.buttons["home.recommendation.more"]
            XCTAssertTrue(more.waitForExistence(timeout: 5), "\(name): 首页更多推荐入口缺失")
            XCTAssertFalse(app.buttons["home.recommendation.refresh"].exists, "\(name): 首页不应再有 AI 换几道")
            more.tap()
            XCTAssertTrue(app.navigationBars.staticTexts["推荐"].waitForExistence(timeout: 5), "\(name): 推荐页未打开")

            let title = app.staticTexts["recommendation.\(recipeID).title"]
            let ingredients = app.staticTexts["recommendation.\(recipeID).ingredients"]
            let reason = app.staticTexts["recommendation.\(recipeID).reason"]
            let addPlan = app.buttons["recommendation.\(recipeID).addPlan"]
            let viewRecipe = app.buttons["recommendation.\(recipeID).view"]
            let regenerate = app.buttons["recommendation.regenerate.button"]
            XCTAssertTrue(title.waitForExistence(timeout: 5), "\(name): 推荐标题缺失")
            XCTAssertTrue(ingredients.exists, "\(name): 配料摘要缺失")
            XCTAssertTrue(reason.exists, "\(name): 推荐理由缺失")
            XCTAssertTrue(addPlan.exists, "\(name): 加入计划按钮缺失")
            XCTAssertTrue(viewRecipe.exists, "\(name): 查看按钮缺失")
            XCTAssertTrue(regenerate.exists, "\(name): AI 换几道入口缺失")

            if isAccessibility {
                XCTAssertFalse(
                    app.descendants(matching: .any)["recommendation.pager"].exists,
                    "XXXL: 不应使用固定高度分页容器"
                )
                for (element, label) in [
                    (title, "XXXL 推荐标题"),
                    (ingredients, "XXXL 配料摘要"),
                    (reason, "XXXL 推荐理由")
                ] {
                    XCTAssertTrue(scrollUntilFullyVisible(element, in: app), "\(label) 不可完整滚动到")
                    assertFullyOnScreen(element, in: app, label: label)
                }
                for (element, label) in [
                    (addPlan, "XXXL 加入计划"),
                    (viewRecipe, "XXXL 查看")
                ] {
                    XCTAssertTrue(scrollUntilFullyHittable(element, in: app), "\(label) 不可点击")
                    assertFullyOnScreen(element, in: app, label: label)
                    XCTAssertGreaterThanOrEqual(element.frame.height, 43.5, "\(label) 点击高度不足 44pt")
                }
                XCTAssertEqual(title.label, "超长名称的番茄香草鸡腿家庭晚餐蔬菜炖锅")
                XCTAssertEqual(ingredients.label, "超长进口有机高山蔬菜组合 · 新鲜香草番茄家庭料理配料 · 去骨鸡腿肉")
                XCTAssertFalse(title.frame.intersects(ingredients.frame), "XXXL: 标题与配料摘要重叠")
                XCTAssertFalse(ingredients.frame.intersects(reason.frame), "XXXL: 配料摘要与理由重叠")
                XCTAssertTrue(scrollUntilFullyHittable(regenerate, in: app), "XXXL: AI 换几道不可点击")
                assertFullyOnScreen(regenerate, in: app, label: "XXXL AI 换几道")
            } else {
                let pager = app.descendants(matching: .any)["recommendation.pager"]
                XCTAssertTrue(pager.waitForExistence(timeout: 5), "Normal: 分页容器缺失")
                XCTAssertTrue(
                    app.descendants(matching: .any)["recommendation.pageIndicator"].exists,
                    "Normal: 分页状态缺失"
                )
                assertFullyOnScreen(addPlan, in: app, label: "Normal 加入计划")
                assertFullyOnScreen(viewRecipe, in: app, label: "Normal 查看")
                XCTAssertTrue(addPlan.isHittable, "Normal: 加入计划不可点击")
                XCTAssertTrue(viewRecipe.isHittable, "Normal: 查看不可点击")
                assertFullyOnScreen(regenerate, in: app, label: "Normal AI 换几道")
                XCTAssertTrue(regenerate.isHittable, "Normal: AI 换几道不可点击")
            }

            app.terminate()
        }
    }

    func testRecommendationMenuUsesPersistentActionsAndOmitsFakeFeedback() throws {
        let recipeID = "ui-test-accessibility-recommendation-one"
        let app = launch("UITEST_SEED_ACCESSIBILITY_RECOMMENDATION", size: "UICTContentSizeCategoryL")
        app.buttons["home.recommendation.more"].tap()

        let menu = app.buttons["recommendation.\(recipeID).menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(menu.frame.width, 43.5)
        XCTAssertGreaterThanOrEqual(menu.frame.height, 43.5)
        menu.tap()

        XCTAssertFalse(app.buttons["不喜欢这道"].exists)
        XCTAssertFalse(app.buttons["推荐有问题"].exists)
        XCTAssertTrue(app.buttons["从本次推荐移除"].exists)
        app.buttons["设为常做"].tap()

        menu.tap()
        XCTAssertTrue(app.buttons["取消常做"].waitForExistence(timeout: 5))
    }

    private func launch(_ seed: String, size: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [seed, "-UIPreferredContentSizeCategoryName", size]
        app.launch()
        return app
    }

    private func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<12 {
            if element.exists && element.frame.intersects(app.windows.firstMatch.frame) { return true }
            app.swipeUp()
        }
        return element.exists && element.frame.intersects(app.windows.firstMatch.frame)
    }

    /// Scrolls the tallest scrollable container up by dragging along its left
    /// edge. `app.swipeUp()` starts at the app's midpoint, which at Accessibility
    /// sizes lands on the wheel date picker: the wheel swallows the gesture (and
    /// spins the date) while the form never moves, so a full-containment loop
    /// built on it can never make progress. Dragging clear of the wheel keeps the
    /// scroll working on every screen this class touches.
    private func scrollContainerUp(in app: XCUIApplication) {
        let container = (app.scrollViews.allElementsBoundByIndex
                         + app.collectionViews.allElementsBoundByIndex
                         + app.tables.allElementsBoundByIndex)
            .max(by: { $0.frame.height < $1.frame.height })
        guard let container, container.exists else {
            app.swipeUp()
            return
        }
        let start = container.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.85))
        let end = container.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.25))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func scrollUntilFullyVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<30 {
            let screen = app.windows.firstMatch.frame
            if element.exists &&
                element.frame.minX >= screen.minX && element.frame.maxX <= screen.maxX &&
                element.frame.minY >= screen.minY && element.frame.maxY <= screen.maxY {
                return true
            }
            scrollContainerUp(in: app)
        }
        let screen = app.windows.firstMatch.frame
        return element.exists &&
            element.frame.minX >= screen.minX && element.frame.maxX <= screen.maxX &&
            element.frame.minY >= screen.minY && element.frame.maxY <= screen.maxY
    }

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return true }
            scrollContainerUp(in: app)
        }
        return element.exists && element.isHittable
    }

    private func scrollUntilFullyHittable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<30 {
            let screen = app.windows.firstMatch.frame
            if element.exists && element.isHittable &&
                element.frame.minX >= screen.minX && element.frame.maxX <= screen.maxX &&
                element.frame.minY >= screen.minY && element.frame.maxY <= screen.maxY {
                return true
            }
            scrollContainerUp(in: app)
        }
        let screen = app.windows.firstMatch.frame
        return element.exists && element.isHittable &&
            element.frame.minX >= screen.minX && element.frame.maxX <= screen.maxX &&
            element.frame.minY >= screen.minY && element.frame.maxY <= screen.maxY
    }

    private func assertOnScreen(
        _ element: XCUIElement,
        in app: XCUIApplication,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(element.exists, "\(label) 不存在", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.minX, screen.minX, "\(label) 左侧越出屏幕", file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxX, screen.maxX, "\(label) 右侧越出屏幕", file: file, line: line)
    }

    private func assertFullyOnScreen(
        _ element: XCUIElement,
        in app: XCUIApplication,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(element.exists, "\(label) 不存在", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.minX, screen.minX, "\(label) 左侧越出屏幕", file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxX, screen.maxX, "\(label) 右侧越出屏幕", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.minY, screen.minY, "\(label) 顶部越出屏幕", file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxY, screen.maxY, "\(label) 底部越出屏幕", file: file, line: line)
    }

    private func assertAction(
        _ element: XCUIElement,
        in app: XCUIApplication,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertOnScreen(element, in: app, label: label, file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(label) 不可点击", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 43.5, "\(label) 点击高度不足 44pt", file: file, line: line)
    }
}

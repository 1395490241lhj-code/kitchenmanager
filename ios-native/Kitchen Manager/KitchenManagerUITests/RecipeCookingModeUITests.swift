import XCTest

final class RecipeCookingModeUITests: XCTestCase {
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchRecipes() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_RECIPE_COOKING"]
        app.launch()
        let recipe = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "recipe.list.")
        ).firstMatch
        XCTAssertTrue(recipe.waitForExistence(timeout: 8))
        recipe.tap()
        app.swipeUp()
        XCTAssertTrue(app.buttons["recipe.detail.startCooking"].waitForExistence(timeout: 5))
        return app
    }

    func testRecipeDetailSupportsServingChecklistAndCookingNavigation() throws {
        let app = launchRecipes()
        app.swipeDown()
        attachScreenshot(of: app, named: "final-recipe-detail-standard")
        app.buttons["recipe.detail.servings-Increment"].tap()
        let ingredient0 = app.buttons["recipe.detail.ingredient.0"]
        XCTAssertGreaterThanOrEqual(ingredient0.frame.height, 44)
        ingredient0.tap()
        app.swipeUp()
        XCTAssertTrue(app.buttons["recipe.detail.startCooking"].waitForExistence(timeout: 5))
        app.buttons["recipe.detail.startCooking"].tap()
        XCTAssertTrue(app.buttons["recipe.cooking.next"].waitForExistence(timeout: 5))
        app.buttons["recipe.cooking.next"].tap()
        app.buttons["recipe.cooking.previous"].tap()
        XCTAssertTrue(app.buttons["recipe.cooking.exit"].exists)
        app.buttons["recipe.cooking.exit"].tap()
        app.buttons["保留进度"].tap()
        XCTAssertTrue(app.buttons["recipe.detail.startCooking"].waitForExistence(timeout: 5))
    }

    func testCookingTimerCanStartAndCancelWithoutDebugUI() throws {
        let app = launchRecipes()
        app.buttons["recipe.detail.startCooking"].tap()
        app.buttons["recipe.cooking.timer.start"].tap()
        app.buttons["1 分钟"].tap()
        XCTAssertTrue(app.buttons["recipe.cooking.timer.cancel"].waitForExistence(timeout: 3))
        attachScreenshot(of: app, named: "final-cooking-mode-timer")
        app.buttons["recipe.cooking.timer.cancel"].tap()
        XCTAssertFalse(app.staticTexts["sync-smoke-status"].exists)
    }

    func testCookingCompletionOpensExistingInventoryConfirmation() throws {
        let app = launchRecipes()
        app.buttons["recipe.detail.startCooking"].tap()
        app.buttons["recipe.cooking.finish"].tap()

        XCTAssertTrue(app.navigationBars.staticTexts["确认本次食材消耗"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["更新冰箱"].exists)
    }

    func testRecipeSearchShowsAQuietNoResultsState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_RECIPE_COOKING"]
        app.launch()

        let recipe = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "recipe.list.")
        ).firstMatch
        XCTAssertTrue(recipe.waitForExistence(timeout: 8))
        attachScreenshot(of: app, named: "final-recipe-list")
        app.swipeDown()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("不存在的菜谱")

        XCTAssertTrue(app.staticTexts["没有找到匹配菜谱"].waitForExistence(timeout: 5))
        let clear = app.buttons["recipe.search.clear"]
        XCTAssertTrue(clear.isHittable)
        XCTAssertGreaterThanOrEqual(clear.frame.height, 44)
        attachScreenshot(of: app, named: "final-recipe-search-empty")
    }

    func testRecipeFilterShowsActiveStateAndClearRestoresResults() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_RECIPE_COOKING"]
        app.launch()

        let filterMenu = app.buttons["recipe.filter.menu"]
        XCTAssertTrue(filterMenu.waitForExistence(timeout: 8))
        filterMenu.tap()
        app.buttons["收藏"].tap()

        XCTAssertTrue(app.otherElements["recipe.filter.active"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["没有符合筛选的菜谱"].exists)

        let clear = app.buttons["recipe.filter.clear"]
        XCTAssertTrue(clear.exists)
        XCTAssertTrue(clear.isHittable)
        XCTAssertGreaterThanOrEqual(clear.frame.height, 43.5)
        clear.tap()

        XCTAssertFalse(app.otherElements["recipe.filter.active"].exists)
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.list."))
                .firstMatch.waitForExistence(timeout: 5)
        )
    }

    func testRecipeCardKeepsDecisionMetadataReadable() throws {
        assertRecipeCardMetadata(contentSize: "UICTContentSizeCategoryLarge", requiresVerticalLayout: false)
    }

    func testRecipeCardKeepsDecisionMetadataReadableAtAccessibilityXXXL() throws {
        assertRecipeCardMetadata(contentSize: "UICTContentSizeCategoryAccessibilityXXXL", requiresVerticalLayout: true)
    }

    private func assertRecipeCardMetadata(contentSize: String, requiresVerticalLayout: Bool) {
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_SEED_RECIPE_LONG",
            "-UIPreferredContentSizeCategoryName", contentSize
        ]
        app.launch()

        let recipeRow = app.buttons["recipe.list.ui-test-recipe-long"]
        XCTAssertTrue(recipeRow.waitForExistence(timeout: 8), "目标菜谱行缺失")
        let title = recipeRow.staticTexts["周末慢炖番茄香草鸡腿蔬菜锅"]
        let metadata = recipeRow.staticTexts["75 分钟 · 中等"]
        let availability = recipeRow.staticTexts["缺少较多"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), "菜谱标题缺失")
        XCTAssertTrue(metadata.exists, "时间/难度信息缺失")
        XCTAssertTrue(availability.exists, "库存适配信息缺失")
        XCTAssertGreaterThan(availability.frame.width, 40, "库存适配文字退化为仅图标：\(availability.frame)")
        XCTAssertFalse(metadata.frame.intersects(availability.frame), "决策信息发生重叠")
        XCTAssertLessThanOrEqual(metadata.frame.maxX, app.windows.firstMatch.frame.maxX, "metadata 被裁出屏幕")
        XCTAssertLessThanOrEqual(availability.frame.maxX, app.windows.firstMatch.frame.maxX, "库存状态被裁出屏幕")
        if requiresVerticalLayout {
            XCTAssertGreaterThanOrEqual(
                availability.frame.minY,
                metadata.frame.maxY - 1,
                "Accessibility XXXL: metadata 与库存状态应纵向排列"
            )
        }
        attachScreenshot(
            of: app,
            named: requiresVerticalLayout ? "final-recipe-list-accessibility" : "final-recipe-list-polished"
        )
    }

    func testLongRecipeKeepsFinalStepAndCookingActionReachableAboveTabBar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_RECIPE_LONG"]
        app.launch()

        let recipe = app.buttons["recipe.list.ui-test-recipe-long"]
        XCTAssertTrue(recipe.waitForExistence(timeout: 8))
        recipe.tap()
        attachScreenshot(of: app, named: "final-recipe-detail-long-top")

        let startCooking = app.buttons["recipe.detail.startCooking"]
        XCTAssertTrue(startCooking.waitForExistence(timeout: 5))
        XCTAssertTrue(startCooking.isHittable)
        XCTAssertGreaterThanOrEqual(startCooking.frame.height, 44)
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists)
        XCTAssertLessThanOrEqual(startCooking.frame.maxY, tabBar.frame.minY)
        let ctaToTabGap = tabBar.frame.minY - startCooking.frame.maxY
        XCTAssertGreaterThanOrEqual(ctaToTabGap, 8, "pinned CTA overlaps floating tab bar (gap \(ctaToTabGap)pt)")
        XCTAssertLessThanOrEqual(ctaToTabGap, 28, "pinned CTA bar re-bloated (gap \(ctaToTabGap)pt)")

        let finalStep = app.descendants(matching: .any)["recipe.detail.step.9"]
        for _ in 0..<12 {
            guard finalStep.exists else {
                app.swipeUp()
                continue
            }
            if finalStep.frame.maxY <= startCooking.frame.minY {
                break
            }
            app.swipeUp()
        }
        XCTAssertTrue(finalStep.exists)
        XCTAssertLessThanOrEqual(finalStep.frame.maxY, startCooking.frame.minY,
            "final step hidden behind pinned CTA: step.maxY \(finalStep.frame.maxY), cta.minY \(startCooking.frame.minY)")

        for _ in 0..<6 where !startCooking.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(startCooking.isHittable)

        XCTAssertLessThanOrEqual(startCooking.frame.maxY, tabBar.frame.minY)
        attachScreenshot(of: app, named: "final-recipe-detail-long-bottom")
    }

    func testCookingControlsKeepEnabledStatesAndCurrentActionClear() throws {
        let app = launchRecipes()
        app.buttons["recipe.detail.startCooking"].tap()

        let previous = app.buttons["recipe.cooking.previous"]
        let ingredients = app.buttons["recipe.cooking.ingredients"]
        let next = app.buttons["recipe.cooking.next"]
        let complete = app.buttons["recipe.cooking.step.complete"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        for control in [previous, ingredients, next] {
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }
        XCTAssertFalse(previous.isEnabled)
        XCTAssertTrue(ingredients.isEnabled)
        XCTAssertTrue(next.isEnabled)
        attachScreenshot(of: app, named: "final-cooking-mode-first")

        complete.tap()
        XCTAssertTrue(complete.label.contains("已完成"))

        next.tap()
        XCTAssertTrue(previous.isEnabled)
        XCTAssertTrue(next.isEnabled)
        attachScreenshot(of: app, named: "final-cooking-mode-middle")

        for _ in 0..<12 where next.isEnabled {
            next.tap()
        }
        XCTAssertFalse(next.isEnabled)
        XCTAssertTrue(app.buttons["recipe.cooking.finish"].isHittable)
    }

    func testVisualReviewAccessibilityLayoutsRemainReadable() throws {
        let detail = XCUIApplication()
        detail.launchArguments = [
            "UITEST_RECIPE_DETAIL_SCREENSHOT",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        detail.launch()

        XCTAssertTrue(detail.staticTexts["周末慢炖番茄香草鸡腿蔬菜锅"].waitForExistence(timeout: 8))
        attachScreenshot(of: detail, named: "final-recipe-detail-accessibility-top")

        let startCooking = detail.buttons["recipe.detail.startCooking"]
        let finalStep = detail.descendants(matching: .any)["recipe.detail.step.9"]
        XCTAssertTrue(finalStep.waitForExistence(timeout: 8))
        let topFinalStepFrame = finalStep.frame
        detail.swipeUp()
        for _ in 0..<20 {
            if finalStep.isHittable && finalStep.frame.maxY <= startCooking.frame.minY {
                break
            }
            detail.swipeUp()
        }
        XCTAssertNotEqual(finalStep.frame, topFinalStepFrame, "Detail bottom screenshot 未发生实际滚动")
        XCTAssertTrue(finalStep.isHittable, "Detail final step 未滚动到可见位置")
        XCTAssertLessThanOrEqual(finalStep.frame.maxY, startCooking.frame.minY,
            "Detail final step 被 pinned CTA 遮挡")
        XCTAssertTrue(startCooking.isHittable)
        attachScreenshot(of: detail, named: "final-recipe-detail-accessibility-bottom")

        detail.terminate()

        let cooking = XCUIApplication()
        cooking.launchArguments = [
            "UITEST_RECIPE_COOKING_SCREENSHOT",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        cooking.launch()
        let next = cooking.buttons["recipe.cooking.next"]
        let previous = cooking.buttons["recipe.cooking.previous"]
        let ingredients = cooking.buttons["recipe.cooking.ingredients"]
        let finish = cooking.buttons["recipe.cooking.finish"]
        XCTAssertTrue(next.waitForExistence(timeout: 8))
        attachScreenshot(of: cooking, named: "final-cooking-mode-accessibility")

        for _ in 0..<16 where !finish.isHittable {
            cooking.swipeUp()
        }
        XCTAssertTrue(previous.isHittable)
        XCTAssertTrue(ingredients.isHittable)
        XCTAssertTrue(finish.isHittable)
        XCTAssertLessThanOrEqual(next.frame.maxY, previous.frame.minY)
        XCTAssertLessThanOrEqual(previous.frame.maxY, ingredients.frame.minY)
        XCTAssertLessThanOrEqual(ingredients.frame.maxY, finish.frame.minY)
        for button in [next, previous, ingredients, finish] {
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        attachScreenshot(of: cooking, named: "final-cooking-mode-accessibility-bottom")
    }

    func testVisualReviewDarkModeUsesSemanticSurfaces() throws {
        let list = XCUIApplication()
        list.launchArguments = ["UITEST_SEED_RECIPE_COOKING", "UITEST_FORCE_DARK_APPEARANCE"]
        list.launch()

        let recipe = list.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "recipe.list.")
        ).firstMatch
        XCTAssertTrue(recipe.waitForExistence(timeout: 8))
        attachScreenshot(of: list, named: "final-recipe-list-dark")
        list.terminate()

        let detail = XCUIApplication()
        detail.launchArguments = ["UITEST_RECIPE_DETAIL_SCREENSHOT", "UITEST_FORCE_DARK_APPEARANCE"]
        detail.launch()
        XCTAssertTrue(detail.staticTexts["周末慢炖番茄香草鸡腿蔬菜锅"].waitForExistence(timeout: 8))
        attachScreenshot(of: detail, named: "final-recipe-detail-dark")
    }

    func testRecipeListFinalRowClearsFloatingTabBar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_RECIPE_COOKING"]
        app.launch()

        // The seed clears the store and injects a fixed 19-recipe fixture, so the
        // first row proves the deterministic list is in place before any scrolling
        // — the remote library is not loaded under this seed. Waiting on the final
        // row directly is not possible: an off-screen List cell is not in the
        // accessibility hierarchy yet.
        let firstRow = app.buttons["recipe.list.ui-test-recipe-cooking-01"]
        let finalRow = app.buttons["recipe.list.ui-test-recipe-list-final"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "确定性菜谱 fixture 未注入")
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists)

        // Bounded scroll instead of a fixed swipe count: the number of swipes that
        // reaches the last of 19 rows differs between 375pt and 402pt widths.
        var swipes = 0
        while swipes < 12 && !(finalRow.exists && finalRow.isHittable) {
            app.swipeUp()
            swipes += 1
        }

        XCTAssertFalse(firstRow.isHittable, "长列表应发生真实滚动，首行仍可见")
        XCTAssertTrue(finalRow.isHittable, "\(swipes) 次滑动后仍未到达固定末行")
        XCTAssertLessThanOrEqual(
            finalRow.frame.maxY,
            tabBar.frame.minY,
            "Recipes final row 被 floating tab bar 遮挡"
        )
    }
}

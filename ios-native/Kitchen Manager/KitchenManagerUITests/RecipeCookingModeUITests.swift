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
        app.buttons["recipe.detail.ingredient.0"].tap()
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
        attachScreenshot(of: app, named: "final-recipe-search-empty")
    }

    func testLongRecipeKeepsFinalStepAndCookingActionReachableAboveTabBar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_RECIPE_LONG"]
        app.launch()

        let recipe = app.buttons["recipe.list.ui-test-recipe-long"]
        XCTAssertTrue(recipe.waitForExistence(timeout: 8))
        recipe.tap()
        attachScreenshot(of: app, named: "final-recipe-detail-long-top")

        let finalStep = app.descendants(matching: .any)["recipe.detail.step.9"]
        for _ in 0..<12 {
            guard finalStep.exists else {
                app.swipeUp()
                continue
            }
            if finalStep.frame.maxY < app.frame.maxY {
                break
            }
            app.swipeUp()
        }
        XCTAssertTrue(finalStep.exists)
        XCTAssertLessThan(finalStep.frame.maxY, app.frame.maxY)

        let startCooking = app.buttons["recipe.detail.startCooking"]
        for _ in 0..<6 where !startCooking.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(startCooking.isHittable)

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists)
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
        for _ in 0..<16 where !startCooking.isHittable {
            detail.swipeUp()
        }
        XCTAssertTrue(startCooking.isHittable)
        attachScreenshot(of: detail, named: "final-recipe-detail-accessibility-bottom")

        detail.terminate()

        let cooking = XCUIApplication()
        cooking.launchArguments = [
            "UITEST_RECIPE_COOKING_SCREENSHOT",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        cooking.launch()
        XCTAssertTrue(cooking.buttons["recipe.cooking.next"].waitForExistence(timeout: 8))
        attachScreenshot(of: cooking, named: "final-cooking-mode-accessibility")
    }

    func testVisualReviewDarkModeUsesSemanticSurfaces() throws {
        let list = XCUIApplication()
        list.launchArguments = ["UITEST_SEED_RECIPE_COOKING", "-AppleInterfaceStyle", "Dark"]
        list.launch()

        let recipe = list.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "recipe.list.")
        ).firstMatch
        XCTAssertTrue(recipe.waitForExistence(timeout: 8))
        attachScreenshot(of: list, named: "final-recipe-list-dark")
        list.terminate()

        let detail = XCUIApplication()
        detail.launchArguments = ["UITEST_RECIPE_DETAIL_SCREENSHOT", "-AppleInterfaceStyle", "Dark"]
        detail.launch()
        XCTAssertTrue(detail.staticTexts["周末慢炖番茄香草鸡腿蔬菜锅"].waitForExistence(timeout: 8))
        attachScreenshot(of: detail, named: "final-recipe-detail-dark")
    }
}

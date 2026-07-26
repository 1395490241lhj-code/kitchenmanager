import XCTest

final class RecipeCookingModeUITests: XCTestCase {
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
        app.buttons["recipe.cooking.timer.cancel"].tap()
        XCTAssertFalse(app.staticTexts["sync-smoke-status"].exists)
    }

    func testRecipeSearchShowsAQuietNoResultsState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_RECIPE_COOKING"]
        app.launch()

        let recipe = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "recipe.list.")
        ).firstMatch
        XCTAssertTrue(recipe.waitForExistence(timeout: 8))
        app.swipeDown()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("不存在的菜谱")

        XCTAssertTrue(app.staticTexts["没有找到匹配菜谱"].waitForExistence(timeout: 5))
    }

    func testLongRecipeKeepsCookingActionReachableAtTheDetailTop() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_RECIPE_LONG"]
        app.launch()

        let recipe = app.buttons["recipe.list.ui-test-recipe-long"]
        XCTAssertTrue(recipe.waitForExistence(timeout: 8))
        recipe.tap()

        let startCooking = app.buttons["recipe.detail.startCooking"]
        XCTAssertTrue(startCooking.waitForExistence(timeout: 5))
        XCTAssertTrue(startCooking.isHittable)
    }
}

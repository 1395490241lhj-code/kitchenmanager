#if DEBUG
import XCTest

@MainActor
final class RecipeFlowsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_RECIPE_REGRESSION", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"]
        app.launch()
        XCTAssertTrue(app.buttons["recipe.list.regression-mapo"].waitForExistence(timeout: 10))
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Recipe-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLibraryFilterAndSearch() {
        let app = launch()
        capture("01-Library")
        let title = app.buttons["recipe.list.regression-mapo"].staticTexts["麻婆豆腐"]
        XCTAssertEqual(title.frame.minX, 20, accuracy: 1)
        app.buttons["recipe.filter.menu"].tap()
        app.buttons["收藏"].tap()
        XCTAssertTrue(app.buttons["recipe.filter.clear"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["recipe.list.regression-mapo"].exists)
        XCTAssertFalse(app.buttons["recipe.list.regression-beef"].exists)
        capture("02-Filter-Active")
        app.buttons["recipe.filter.clear"].tap()
        app.swipeDown()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("zzznomatch")
        XCTAssertTrue(app.staticTexts["没有找到匹配菜谱"].waitForExistence(timeout: 5))
        capture("03-Search-Empty")
        app.buttons["recipe.search.clear"].tap()
        XCTAssertTrue(app.buttons["recipe.list.regression-mapo"].waitForExistence(timeout: 5))
    }

    func testDetailServingsStepsCookingAndEdit() {
        let app = launch()
        app.buttons["recipe.list.regression-mapo"].tap()
        let start = app.buttons["recipe.detail.startCooking"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.count, 0)
        XCTAssertGreaterThanOrEqual(start.frame.height, 44)
        capture("04-Detail-Normal")
        app.buttons["recipe.detail.servings-Increment"].tap()
        app.buttons["recipe.detail.servings-Increment"].tap()
        XCTAssertTrue(app.buttons["recipe.detail.ingredient.0"].label.contains("800"))
        capture("06-Detail-Adjusted-4-Servings")
        let finalStep = app.descendants(matching: .any)["recipe.detail.step.3"]
        for _ in 0..<6 where !finalStep.isHittable { app.swipeUp() }
        XCTAssertTrue(finalStep.isHittable)
        capture("07-Static-Steps")
        start.tap()
        let next = app.buttons["recipe.cooking.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        next.tap()
        XCTAssertTrue(app.staticTexts["recipe.cooking.currentStep"].label.contains("分两次"))
        capture("08-Cooking-Long-Step")
        app.buttons["recipe.cooking.timer.start"].tap()
        app.buttons["1 分钟"].tap()
        XCTAssertTrue(app.buttons["recipe.cooking.timer.cancel"].waitForExistence(timeout: 5))
        capture("09-Cooking-Timer")
        app.buttons["recipe.cooking.timer.cancel"].tap()
        app.buttons["recipe.cooking.exit"].tap()
        app.buttons["保留进度"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        app.buttons["菜谱操作"].tap()
        app.buttons["编辑菜谱"].tap()
        XCTAssertTrue(app.navigationBars["编辑菜谱"].waitForExistence(timeout: 5))
        capture("10-Edit")
    }

    func testDenseRecipe() {
        let app = launch()
        app.buttons["recipe.list.regression-beef"].tap()
        XCTAssertTrue(app.buttons["recipe.detail.startCooking"].waitForExistence(timeout: 5))
        capture("05-Dense-Detail-Top")
        let ingredient = app.buttons["recipe.detail.ingredient.9"]
        for _ in 0..<6 where !ingredient.isHittable { app.swipeUp() }
        XCTAssertTrue(ingredient.isHittable)
        capture("11-Dense-Ingredients")
        let step = app.descendants(matching: .any)["recipe.detail.step.4"]
        let start = app.buttons["recipe.detail.startCooking"]
        for _ in 0..<8 {
            if step.isHittable && step.frame.maxY <= start.frame.minY { break }
            app.swipeUp()
        }
        XCTAssertTrue(step.isHittable)
        XCTAssertLessThanOrEqual(step.frame.maxY, start.frame.minY)
        capture("12-Dense-Steps")
    }
}
#endif

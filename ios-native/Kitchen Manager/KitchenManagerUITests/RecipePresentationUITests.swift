#if DEBUG
import XCTest

@MainActor
final class RecipePresentationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_RECIPE_REGRESSION", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"]
        app.launch()
        XCTAssertTrue(app.buttons["recipe.list.regression-mapo"].waitForExistence(timeout: 10))
        return app
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "Recipe-" + name
        image.lifetime = .keepAlways
        add(image)
    }

    func testSixConvergenceStates() {
        let app = launch()
        XCTAssertEqual(app.buttons["recipe.list.regression-mapo"].staticTexts["麻婆豆腐"].frame.minX, 20, accuracy: 1)
        capture("01-Library")
        app.buttons["recipe.filter.menu"].tap()
        app.buttons["收藏"].tap()
        let clear = app.buttons["recipe.filter.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertLessThan(clear.frame.maxX, 200, "Clear belongs next to the intrinsic filter, not on the trailing rail")
        XCTAssertGreaterThanOrEqual(clear.frame.height, 44)
        capture("02-Filter")
        clear.tap()
        XCTAssertTrue(app.buttons["recipe.list.regression-beef"].exists)
        app.buttons["recipe.list.regression-mapo"].tap()
        let start = app.buttons["recipe.detail.startCooking"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(start.frame.height, 44)
        XCTAssertTrue(app.staticTexts["recipe.detail.baseServings"].label.contains("2"))
        capture("03-Base-Servings")
        app.buttons["recipe.detail.servings-Increment"].tap()
        app.buttons["recipe.detail.servings-Increment"].tap()
        XCTAssertTrue(app.buttons["recipe.detail.ingredient.0"].label.contains("800"))
        XCTAssertTrue(app.staticTexts["recipe.detail.baseServings"].label.contains("2"))
        capture("04-Adjusted-Servings")
        app.buttons["菜谱操作"].tap()
        app.buttons["编辑菜谱"].tap()
        XCTAssertTrue(app.navigationBars["编辑菜谱"].waitForExistence(timeout: 5))
        for label in ["菜名", "烹饪时间", "难度", "标签"] {
            XCTAssertTrue(app.staticTexts[label].exists, "Filled field must retain its identity: \(label)")
        }
        // Protect the editable field's meaning, not native Form's StaticText grouping.
        let cookingTime = app.textFields["烹饪时间（分钟）"]
        XCTAssertTrue(cookingTime.label.contains("烹饪时间"))
        XCTAssertTrue(cookingTime.label.contains("分钟"))
        XCTAssertEqual(cookingTime.value as? String, "25")
        let accessibilityTree = XCTAttachment(string: app.debugDescription)
        accessibilityTree.name = "Recipe-Editor-Accessibility"
        accessibilityTree.lifetime = .keepAlways
        add(accessibilityTree)
        XCTAssertTrue(app.steppers["recipe.draft.baseServings.stepper"].exists)
        capture("05-Editor")
        app.navigationBars.buttons.firstMatch.tap()
        start.tap()
        let next = app.buttons["recipe.cooking.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap(); next.tap()
        XCTAssertTrue(app.staticTexts["recipe.cooking.currentStep"].label.contains("分两次"))
        capture("06-Cooking")
    }

    func testUnknownBaseAndDenseContentRemainIntact() {
        let app = launch()
        app.buttons["recipe.list.regression-soup"].tap()
        let amount = app.buttons["recipe.detail.ingredient.0"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        let written = amount.label
        app.buttons["recipe.detail.servings-Increment"].tap()
        XCTAssertEqual(amount.label, written)
        XCTAssertTrue(app.staticTexts["recipe.detail.baseServings"].label.contains("未标注"))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["recipe.list.regression-beef"].tap()
        let first = app.buttons["recipe.detail.ingredient.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.staticTexts["600 克"].frame.maxX, 382, accuracy: 1)
        let last = app.descendants(matching: .any)["recipe.detail.step.4"]
        let start = app.buttons["recipe.detail.startCooking"]
        for _ in 0..<10 {
            if last.isHittable && last.frame.maxY <= start.frame.minY { break }
            app.swipeUp()
        }
        XCTAssertTrue(last.isHittable)
        XCTAssertLessThanOrEqual(last.frame.maxY, start.frame.minY)
        XCTAssertTrue(start.isHittable)
    }
}
#endif

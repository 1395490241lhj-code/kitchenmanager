import XCTest

@MainActor
final class RecipeVisualMatrixUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testLightNormal() { captureMatrix(dark: false, accessibility: false) }
    func testDarkNormal() { captureMatrix(dark: true, accessibility: false) }
    func testLightAccessibilityXXXL() { captureMatrix(dark: false, accessibility: true) }
    func testDarkAccessibilityXXXL() { captureMatrix(dark: true, accessibility: true) }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<24 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "Expected reachable semantic control: \(element)")
    }

    private func captureMatrix(dark: Bool, accessibility: Bool) {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_SEED_RECIPE_REGRESSION", "-UIPreferredContentSizeCategoryName",
            accessibility ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryLarge"
        ]
        app.launchArguments.append(dark ? "UITEST_FORCE_DARK_APPEARANCE" : "UITEST_FORCE_LIGHT_APPEARANCE")
        app.launch()
        let mapo = app.buttons["recipe.list.regression-mapo"]
        XCTAssertTrue(mapo.waitForExistence(timeout: 10))
        let screen = app.windows.firstMatch.frame
        let small = screen.width < 390
        let prefix = "Recipes-\(small ? "Small" : "Pro")-\(dark ? "Dark" : "Light")-\(accessibility ? "AXXXL" : "Normal")-"
        func capture(_ state: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = prefix + state
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        func tree(_ state: String) {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = prefix + state + "-accessibility"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        func openMenu() {
            let menu = app.buttons["菜谱操作"]
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            XCTAssertTrue(menu.isHittable)
            menu.tap()
        }

        XCTAssertEqual(mapo.staticTexts["麻婆豆腐"].frame.minX, 20, accuracy: 1)
        capture("01-Library")
        if !small {
            app.buttons["recipe.filter.menu"].tap()
            app.buttons["收藏"].tap()
            let clear = app.buttons["recipe.filter.clear"]
            XCTAssertTrue(clear.waitForExistence(timeout: 5))
            XCTAssertTrue(clear.isHittable)
            XCTAssertGreaterThanOrEqual(clear.frame.height, 44 - 1e-9)
            XCTAssertLessThanOrEqual(clear.frame.maxX, screen.maxX - 20 + 1)
            capture("02-Filter")
            clear.tap()
        }
        mapo.tap()
        let start = app.buttons["recipe.detail.startCooking"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isHittable)
        XCTAssertLessThanOrEqual(start.frame.maxY, screen.maxY)
        if !small { capture("03-Detail") }
        let increment = app.buttons["recipe.detail.servings-Increment"]
        reveal(increment, in: app)
        increment.tap(); increment.tap()
        XCTAssertTrue(app.staticTexts["recipe.detail.baseServings"].label.contains("2"))
        capture("05-Adjusted")
        tree("Detail")

        openMenu()
        app.buttons["编辑菜谱"].tap()
        XCTAssertTrue(app.navigationBars["编辑菜谱"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.cells.firstMatch.frame.minX, 20, accuracy: 1)
        let time = app.textFields["烹饪时间（分钟）"]
        reveal(time, in: app)
        XCTAssertTrue(time.label.contains("烹饪时间") && time.label.contains("分钟"))
        XCTAssertEqual(time.value as? String, "25")
        XCTAssertLessThanOrEqual(time.frame.maxX, screen.maxX)
        capture("08-Editor")
        tree("Editor")
        time.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(time.isHittable)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        let next = app.buttons["recipe.cooking.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        reveal(next, in: app); next.tap()
        reveal(next, in: app); next.tap()
        let step = app.staticTexts["recipe.cooking.currentStep"]
        XCTAssertTrue(step.label.contains("分两次"))
        for _ in 0..<24 {
            if step.frame.minY >= app.navigationBars.firstMatch.frame.maxY { break }
            app.swipeDown()
        }
        XCTAssertLessThanOrEqual(step.frame.maxX, screen.maxX - 20 + 1)
        capture("07-Cooking")
        tree("Cooking")
        let timer = app.buttons["recipe.cooking.timer.start"]
        reveal(timer, in: app)
        XCTAssertTrue(timer.isHittable)
        reveal(next, in: app)
        XCTAssertTrue(next.isHittable)
        app.buttons["recipe.cooking.exit"].tap()
        app.buttons["保留进度"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        let beef = app.buttons["recipe.list.regression-beef"]
        reveal(beef, in: app); beef.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        capture("04-Dense-Detail")
        let ingredient = app.buttons["recipe.detail.ingredient.0"]
        reveal(ingredient, in: app)
        XCTAssertLessThanOrEqual(ingredient.frame.maxX, screen.maxX - 20 + 1)
        XCTAssertFalse(ingredient.staticTexts["牛腩"].frame.intersects(ingredient.staticTexts["600 克"].frame))
        tree("Ingredients")
        let longStep = app.descendants(matching: .any)["recipe.detail.step.2"]
        reveal(longStep, in: app)
        for _ in 0..<8 {
            if longStep.frame.minY <= screen.midY { break }
            app.swipeUp()
        }
        capture("06-Static-Steps")
        let last = app.descendants(matching: .any)["recipe.detail.step.4"]
        for _ in 0..<30 {
            if last.exists && last.isHittable && last.frame.maxY <= start.frame.minY { break }
            app.swipeUp()
        }
        XCTAssertTrue(last.isHittable)
        XCTAssertLessThanOrEqual(last.frame.maxY, start.frame.minY)
        XCTAssertTrue(start.isHittable)
    }
}

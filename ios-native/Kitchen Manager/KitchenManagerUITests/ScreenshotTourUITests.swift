import XCTest

/// Captures the main screens for human visual review, not for assertions.
///
/// CI exports every `keepAlways` attachment from the UI result bundle as PNG
/// (see `.github/workflows/ios-tests.yml`), so a reviewer without Xcode can
/// look at the real rendering. When a change touches what a screen looks like,
/// add the state here (or a `keepAlways` capture in the feature's own test).
///
/// Navigation is deliberately forgiving: a missing element skips that capture
/// rather than failing, so one changed identifier never costs the whole tour.
final class ScreenshotTourUITests: XCTestCase {
    private struct Variant {
        let name: String
        let dark: Bool
        let accessibility: Bool
    }

    override func setUp() {
        continueAfterFailure = true
    }

    func testTourLightNormal() { tour(Variant(name: "Light", dark: false, accessibility: false)) }
    func testTourDarkNormal() { tour(Variant(name: "Dark", dark: true, accessibility: false)) }
    func testTourLightAccessibilityXXXL() { tour(Variant(name: "Light-AXXXL", dark: false, accessibility: true)) }

    private func tour(_ variant: Variant) {
        home(variant)
        recipeAndCooking(variant)
        shopping(variant)
        inventory(variant)
    }

    // MARK: - Screens

    private func home(_ variant: Variant) {
        let app = launch(["UITEST_SEED_HOME_DASHBOARD"], variant)
        _ = app.navigationBars.staticTexts["今天"].waitForExistence(timeout: 8)
        capture(app, variant, "01-Home")
        let missing = app.descendants(matching: .any)["home.today.missing.addToShopping"]
        if missing.waitForExistence(timeout: 2) {
            scrollUntilVisible(missing, in: app)
            capture(app, variant, "02-Home-MissingIngredients")
        }
        app.swipeUp()
        capture(app, variant, "03-Home-Scrolled")
        app.terminate()
    }

    private func recipeAndCooking(_ variant: Variant) {
        let app = launch(["UITEST_SEED_RECIPE_COOKING"], variant)
        let recipe = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.list.")).firstMatch
        guard recipe.waitForExistence(timeout: 8) else { capture(app, variant, "10-Recipes-Unavailable"); return }
        capture(app, variant, "10-Recipes-Library")
        recipe.tap()
        _ = app.buttons["recipe.detail.startCooking"].waitForExistence(timeout: 5)
        capture(app, variant, "11-RecipeDetail")
        let missing = app.descendants(matching: .any)["recipe.detail.missing"]
        if missing.exists || app.descendants(matching: .any)["recipe.detail.ingredient.0"].exists {
            scrollUntilVisible(app.descendants(matching: .any)["recipe.detail.ingredient.0"], in: app)
            capture(app, variant, "12-RecipeDetail-Ingredients")
        }
        let start = app.buttons["recipe.detail.startCooking"]
        guard start.exists else { app.terminate(); return }
        start.tap()
        guard app.buttons["recipe.cooking.next"].waitForExistence(timeout: 5)
                || app.buttons["recipe.cooking.finish"].waitForExistence(timeout: 1) else {
            app.terminate(); return
        }
        capture(app, variant, "13-Cooking-Step1")
        let step = app.staticTexts["recipe.cooking.currentStep"]
        if step.exists {
            step.swipeLeft()
            capture(app, variant, "14-Cooking-AfterSwipe")
        }
        app.terminate()
    }

    private func shopping(_ variant: Variant) {
        let app = launch(["UITEST_SEED_SHOPPING"], variant)
        let row = app.buttons["番茄，2 个，未购买"]
        guard row.waitForExistence(timeout: 8) else { capture(app, variant, "20-Shopping-Unavailable"); return }
        capture(app, variant, "20-Shopping")
        row.swipeLeft()
        if app.buttons["删除"].waitForExistence(timeout: 3) {
            capture(app, variant, "21-Shopping-SwipeActions")
            app.buttons["删除"].tap()
            if app.buttons["feedback.toast.action"].waitForExistence(timeout: 3) {
                capture(app, variant, "22-Shopping-UndoToast")
            }
        }
        app.buttons["shopping.add.button"].tap()
        if app.navigationBars.staticTexts["添加买菜项目"].waitForExistence(timeout: 3) {
            capture(app, variant, "23-Shopping-AddSheet")
        }
        app.terminate()
    }

    private func inventory(_ variant: Variant) {
        let app = launch(["UITEST_SEED_INVENTORY"], variant)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "inventory.item.")).firstMatch
        guard row.waitForExistence(timeout: 8) else { capture(app, variant, "30-Inventory-Unavailable"); return }
        capture(app, variant, "30-Inventory")
        row.swipeRight()
        let usedUp = app.buttons["用完"]
        if usedUp.waitForExistence(timeout: 3) {
            capture(app, variant, "31-Inventory-UsedUpAction")
            usedUp.tap()
            if app.buttons["feedback.toast.action"].waitForExistence(timeout: 3) {
                capture(app, variant, "32-Inventory-UndoToast")
            }
        }
        app.terminate()
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String], _ variant: Variant) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + [
            variant.dark ? "UITEST_FORCE_DARK_APPEARANCE" : "UITEST_FORCE_LIGHT_APPEARANCE",
            "-UIPreferredContentSizeCategoryName",
            variant.accessibility ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryLarge"
        ]
        app.launch()
        return app
    }

    private func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable {
            app.swipeUp()
        }
    }

    private func capture(_ app: XCUIApplication, _ variant: Variant, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Tour-\(variant.name)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

import XCTest

/// Covers the sample-fallback disclosure: when recipe loading fails and the
/// built-in `Recipe.samples` stand in, the Recipe tab must say so rather than
/// presenting them as the user's loaded library.
final class RecipeSampleFallbackUITests: XCTestCase {
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchFallbackRecipes(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // Clears the local store, lands on the Recipe tab, and — unlike the
        // other recipe seeds — lets the real loadRecipes() run. It fails against
        // the unreachable test backend, producing the confirmed fallback state.
        app.launchArguments = ["UITEST_SEED_RECIPE_LOAD_FAILURE"] + extra
        app.launch()
        return app
    }

    func testFallbackNoticeIsShownAndSamplesAreNotLabelledAsFullLibrary() throws {
        let app = launchFallbackRecipes()

        let notice = app.staticTexts["recipe.sampleFallback.message"]
        XCTAssertTrue(notice.waitForExistence(timeout: 8), "示例回退提示应当出现")
        XCTAssertTrue(app.buttons["recipe.sampleFallback.retry"].exists, "回退提示应提供重试")
        attachScreenshot(of: app, named: "sample-fallback-notice")

        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "示例菜谱 ·")).firstMatch
                .waitForExistence(timeout: 5),
            "回退状态应标记为示例菜谱"
        )
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "全部菜谱 ·")).firstMatch.exists,
            "回退的示例菜不应被称作用户的全部菜谱"
        )
        attachScreenshot(of: app, named: "sample-fallback-header")
    }

    func testLoadedLibraryShowsNoFallbackNotice() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_RECIPE_COOKING"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "全部菜谱 ·")).firstMatch
                .waitForExistence(timeout: 8),
            "正常加载时应保持全部菜谱标题"
        )
        XCTAssertFalse(app.staticTexts["recipe.sampleFallback.message"].exists, "正常加载不应出现回退提示")
        attachScreenshot(of: app, named: "loaded-library-no-notice")
    }

    /// The loading-state edge: an empty library with no load failure yet must
    /// stay neutral — no failure notice, no 示例菜谱 label.
    func testEmptyLibraryDuringLoadShowsNoFailureSemantics() throws {
        let app = XCUIApplication()
        // Isolates the recipe store and skips loadRecipes entirely, so the
        // library is empty while nothing has failed.
        app.launchArguments = ["UITEST_RECIPE_EMPTY_SCREENSHOT"]
        app.launch()

        let notice = app.staticTexts["recipe.sampleFallback.message"]
        XCTAssertFalse(notice.waitForExistence(timeout: 4), "未确认失败前不应出现加载失败提示")
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "示例菜谱 ·")).firstMatch.exists,
            "未确认失败前不应标记为示例菜谱"
        )
        attachScreenshot(of: app, named: "empty-library-neutral")
    }

    func testFallbackNoticeSurvivesAccessibilityXXXL() throws {
        let app = launchFallbackRecipes(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])

        let notice = app.staticTexts["recipe.sampleFallback.message"]
        XCTAssertTrue(notice.waitForExistence(timeout: 8), "XXXL 下仍应显示回退提示")
        let retry = app.buttons["recipe.sampleFallback.retry"]
        XCTAssertTrue(retry.exists, "XXXL 下重试仍需可用")
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44, "重试需保持最小点按尺寸")
        attachScreenshot(of: app, named: "sample-fallback-xxxl")
    }
}

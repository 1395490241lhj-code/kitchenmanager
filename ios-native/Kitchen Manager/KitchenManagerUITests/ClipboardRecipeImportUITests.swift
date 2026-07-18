import XCTest

final class ClipboardRecipeImportUITests: XCTestCase {
    private func launchHome() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_EMPTY_HOME"]
        app.launch()
        XCTAssertTrue(app.buttons["home.primary.action.button"].waitForExistence(timeout: 5))
        return app
    }

    func testManualSmartImportUsesSystemPasteControlWithoutClipboardDetectorOverride() {
        let app = launchHome()

        app.buttons["home.import.add.button"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["导入与添加"].waitForExistence(timeout: 5))

        let linkImport = app.buttons["home.import.recipe.xiaohongshu"]
        XCTAssertTrue(linkImport.waitForExistence(timeout: 5))
        linkImport.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["导入菜谱"].waitForExistence(timeout: 5))

        let pasteControl = app.buttons["clipboard.paste.control"]
        XCTAssertTrue(pasteControl.exists)
        XCTAssertTrue(pasteControl.isHittable)
        XCTAssertEqual(pasteControl.label, "粘贴剪贴板内容")
    }
}

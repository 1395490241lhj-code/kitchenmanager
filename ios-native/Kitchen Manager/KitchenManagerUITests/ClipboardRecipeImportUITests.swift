import XCTest

final class ClipboardRecipeImportUITests: XCTestCase {
    private func launchHome(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_EMPTY_HOME"] + extraArguments
        app.launch()
        XCTAssertTrue(app.buttons["home.primary.action.button"].waitForExistence(timeout: 5))
        return app
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Navigates Home → Smart Import → link import, where the shared paste
    /// control is rendered.
    private func openLinkImport(in app: XCUIApplication) {
        app.buttons["home.import.add.button"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["导入与添加"].waitForExistence(timeout: 5))

        let linkImport = app.buttons["home.import.recipe.xiaohongshu"]
        XCTAssertTrue(linkImport.waitForExistence(timeout: 5))
        linkImport.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["导入菜谱"].waitForExistence(timeout: 5))
    }

    func testManualSmartImportUsesSystemPasteControlWithoutClipboardDetectorOverride() {
        let app = launchHome()
        openLinkImport(in: app)

        let pasteControl = app.buttons["clipboard.paste.control"]
        XCTAssertTrue(pasteControl.exists)
        XCTAssertTrue(pasteControl.isHittable)
        XCTAssertEqual(pasteControl.label, "粘贴剪贴板内容")
    }

    /// Regression guard: the shared control's single hardcoded `displayMode` once
    /// turned this screen's paste affordance into a bare icon, because Home wanted
    /// icon-only and drew its own label. Here there is no replacement label, so the
    /// native icon-and-label presentation must be intact.
    ///
    /// Presentation is checked by geometry rather than by text, because the control
    /// is a `UIPasteControl` whose accessibility label we override — an icon-only
    /// control is about as wide as it is tall, whereas icon-and-label is
    /// substantially wider.
    func testRecipeImportPasteControlIsNotIconOnly() {
        let app = launchHome()
        openLinkImport(in: app)

        let pasteControl = app.buttons["clipboard.paste.control"]
        XCTAssertTrue(pasteControl.waitForExistence(timeout: 5))
        let frame = pasteControl.frame
        print("=====IMPORT PASTE CONTROL===== frame=\(frame) ratio=\(frame.width / frame.height)")

        // 43.5 rather than 44: the reported height is 43.99999999999997 — a
        // point-conversion rounding artifact of a 44pt control, not a real
        // undersized target.
        XCTAssertGreaterThanOrEqual(frame.height, 43.5, "粘贴控件点击区域应至少 44pt 高")
        XCTAssertGreaterThan(
            frame.width,
            frame.height * 1.3,
            "粘贴控件看起来仍是 icon-only（宽高比 \(frame.width / frame.height)），应为图标加文字"
        )
        attachScreenshot(of: app, named: "import-paste-default")
    }

    /// The label must survive Accessibility Dynamic Type without being clipped.
    ///
    /// Appearance is deliberately not switched here: `XCUIDevice.appearance` did
    /// not reach the app before its first render on this simulator (the dark and
    /// light screenshots came out byte-identical), and this branch has no DEBUG
    /// appearance launch hook. Dark Mode is verified visually instead, by setting
    /// the simulator's appearance with `simctl` and re-capturing — see the phase
    /// report. These geometry assertions are appearance-independent anyway.
    func testRecipeImportPasteControlSurvivesAccessibilitySizes() {
        for (name, extra) in [
            ("import-paste-accessibility", ["-UIPreferredContentSizeCategoryName",
                                            "UICTContentSizeCategoryAccessibilityXXXL"]),
            ("import-paste-current-appearance", [])
        ] {
            let app = launchHome(extraArguments: extra)
            openLinkImport(in: app)

            let pasteControl = app.buttons["clipboard.paste.control"]
            XCTAssertTrue(pasteControl.waitForExistence(timeout: 5))
            let frame = pasteControl.frame
            print("=====IMPORT PASTE \(name)===== frame=\(frame) ratio=\(frame.width / frame.height)")

            XCTAssertTrue(pasteControl.isHittable, "\(name): 粘贴控件不可点击")
            XCTAssertEqual(pasteControl.label, "粘贴剪贴板内容", "\(name): 无障碍标签应保持不变")
            XCTAssertGreaterThan(
                frame.width,
                frame.height * 1.05,
                "\(name): 粘贴控件退化为 icon-only（宽高比 \(frame.width / frame.height)）"
            )
            // Fully on screen — the label is not clipped by the form's width.
            XCTAssertLessThanOrEqual(
                frame.maxX,
                app.windows.firstMatch.frame.maxX,
                "\(name): 粘贴控件被裁切出屏幕"
            )
            attachScreenshot(of: app, named: name)
            app.terminate()
        }
    }
}

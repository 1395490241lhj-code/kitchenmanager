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
        XCTAssertEqual(pasteControl.label, "粘贴导入")
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
            XCTAssertEqual(pasteControl.label, "粘贴导入", "\(name): 无障碍标签应保持中文")
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

    /// P2-6 regression: the link-import primary CTA ("开始导入") must publish a
    /// full-height (>= 44pt) target whose entire frame is live — including the
    /// top edge — and must recover to a normal enabled state after a
    /// synchronous import failure (no stuck spinner or disabled button).
    ///
    /// The invalid-URL input fails synchronously via
    /// `LinkExtractError.invalidURL` before any network call, so this test can
    /// never reach a real endpoint. The failure is rendered as an inline
    /// "导入失败" form section (not an alert), whose appearance proves the tap
    /// actually triggered the action.
    func testImportCTAHitTargetIsLiveAndRecoversFromError() {
        for (name, extra) in [
            ("import-cta-normal", []),
            ("import-cta-accessibility", ["-UIPreferredContentSizeCategoryName",
                                          "UICTContentSizeCategoryAccessibilityXXXL"])
        ] {
            let app = launchHome(extraArguments: extra)
            openLinkImport(in: app)

            let cta = app.buttons["开始导入"]
            XCTAssertTrue(cta.waitForExistence(timeout: 5))
            XCTAssertFalse(cta.isEnabled, "\(name): 空输入时 CTA 应禁用")
            XCTAssertGreaterThanOrEqual(cta.frame.height, 43.5, "\(name): CTA 点击区域应至少 44pt 高")
            XCTAssertTrue(cta.isHittable, "\(name): CTA 不可点击")

            guard name == "import-cta-normal" else {
                // Accessibility sizes: verify geometry only; the typed-input
                // flow below is exercised at normal size.
                XCTAssertLessThanOrEqual(
                    cta.frame.maxY,
                    app.windows.firstMatch.frame.maxY,
                    "\(name): CTA 被裁切出屏幕"
                )
                attachScreenshot(of: app, named: name)
                app.terminate()
                continue
            }

            attachScreenshot(of: app, named: "import-cta-disabled")

            let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText("不是一个链接")

            XCTAssertTrue(cta.isEnabled, "有输入后 CTA 应启用")
            XCTAssertGreaterThanOrEqual(cta.frame.height, 43.5)
            attachScreenshot(of: app, named: "import-cta-enabled")

            // Real edge-of-frame tap: the whole published rect must trigger
            // the action, not just a smaller live band inside it.
            cta.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
            let errorLabel = app.staticTexts["无法生成链接抓取请求。"]
            XCTAssertTrue(errorLabel.waitForExistence(timeout: 5), "CTA 顶边 tap 未触发动作")
            attachScreenshot(of: app, named: "import-cta-error")

            // After the error the CTA must be fully usable again.
            XCTAssertTrue(cta.isEnabled, "错误后 CTA 应恢复可点击")
            XCTAssertTrue(cta.isHittable, "错误后 CTA 不可点击")
            app.terminate()
        }
    }

    private func launchAIConfirmation(
        seed: String,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_EMPTY_HOME", seed] + extraArguments
        app.launch()
        XCTAssertTrue(app.buttons["home.primary.action.button"].waitForExistence(timeout: 5))
        app.tabBars.buttons["菜谱"].tap()
        app.buttons["添加菜谱"].tap()
        app.buttons["AI 做菜"].tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["确认菜谱"].waitForExistence(timeout: 8),
            "AI confirmation 未出现"
        )
        // The action buttons sit below the editable draft sections in a lazy
        // Form, so reveal them before the caller asserts on them.
        for _ in 0..<8 where !app.buttons["保存并加入计划"].exists {
            app.swipeUp()
        }
        return app
    }

    func testAIConfirmationInvalidDraftDisablesSaveAndPlanActions() {
        for (name, extra) in [
            ("ai-confirm-invalid-normal", []),
            ("ai-confirm-invalid-accessibility", ["-UIPreferredContentSizeCategoryName",
                                                  "UICTContentSizeCategoryAccessibilityXXXL"])
        ] {
            let app = launchAIConfirmation(
                seed: "UITEST_SEED_AI_CONFIRMATION_FAILURE",
                extraArguments: extra
            )

            let saveAndPlan = app.buttons["保存并加入计划"]
            let saveOnly = app.buttons["仅保存"]
            XCTAssertTrue(saveAndPlan.waitForExistence(timeout: 5))
            XCTAssertTrue(saveOnly.waitForExistence(timeout: 5))
            XCTAssertFalse(saveAndPlan.isEnabled, "\(name): 缺食材时主操作必须禁用")
            XCTAssertFalse(saveOnly.isEnabled, "\(name): 缺食材时次操作必须禁用")
            XCTAssertGreaterThanOrEqual(saveAndPlan.frame.height, 43.5, "\(name): 主操作点击区域应至少 44pt")
            attachScreenshot(of: app, named: name)
            app.terminate()
        }
    }

    /// Success path (deterministic seed with a valid draft): the primary action
    /// completes, dismisses the confirmation and lands on the Today tab with no
    /// alert and no stuck loading.
    func testAIConfirmationSaveAndPlanCompletesWithoutStuckLoading() {
        let app = launchAIConfirmation(seed: "UITEST_SEED_AI_CONFIRMATION")
        attachScreenshot(of: app, named: "ai-confirm-success-initial")

        app.buttons["保存并加入计划"].tap()

        XCTAssertTrue(
            app.navigationBars.staticTexts["确认菜谱"].waitForNonExistence(timeout: 8),
            "保存成功后确认页未关闭"
        )
        XCTAssertFalse(app.alerts.firstMatch.exists, "成功路径不应出现错误弹窗")
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.activityIndicators.firstMatch.exists,
            "成功后仍有残留 spinner"
        )
    }


}

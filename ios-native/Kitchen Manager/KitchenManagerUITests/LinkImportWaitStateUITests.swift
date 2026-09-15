import XCTest

/// The link importer tells the truth while it waits, can be stopped without
/// leaving, and keeps the pasted link. The stubbed request takes six seconds —
/// long enough to read the waiting state and stop it, short enough to let a
/// deliberate retry finish.
final class LinkImportWaitStateUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launchLinkImport() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_EMPTY_HOME", "UITEST_LINK_IMPORT_STUB"]
        app.launch()
        XCTAssertTrue(app.staticTexts["home.primary.title"].waitForExistence(timeout: 10))
        app.tabBars.buttons["菜谱"].tap()
        let add = app.buttons["添加菜谱"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let linkImport = app.buttons["从链接导入"]
        XCTAssertTrue(linkImport.waitForExistence(timeout: 5))
        linkImport.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["导入菜谱"].waitForExistence(timeout: 5))
        return app
    }

    private let link = "https://example.com/uitest-link-import"

    private func linkField(_ app: XCUIApplication) -> XCUIElement {
        app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
    }

    private func typeLink(in app: XCUIApplication) {
        let field = linkField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no link field")
        field.tap()
        field.typeText(link)
    }

    private func startImport(_ app: XCUIApplication) {
        let start = app.buttons["开始导入"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "no 开始导入 button")
        start.tap()
    }

    private func cancelButton(_ app: XCUIApplication) -> XCUIElement { app.buttons["import.link.cancel"] }

    // L1 — one truthful sentence, a stop next to it, and none of the invented
    // stages or duration promises.
    func testWaitingStateIsTruthfulAndOffersAStop() {
        let app = launchLinkImport()
        typeLink(in: app)
        startImport(app)

        XCTAssertTrue(app.staticTexts["正在读取链接并整理菜谱…"].waitForExistence(timeout: 5),
                      "the waiting state must say what it is waiting for")
        XCTAssertTrue(cancelButton(app).waitForExistence(timeout: 5), "the stop must be available")

        for invented in ["正在解析链接", "正在读取页面", "正在提取视频", "正在识别语音", "正在识别字幕", "正在整理菜谱"] {
            XCTAssertFalse(app.staticTexts[invented].exists, "invented stage still shown: \(invented)")
        }
        XCTAssertFalse(app.staticTexts["可能需要一两分钟"].exists, "no duration is promised")
    }

    // L2 + L3 + L4 — stopping stays on the screen, keeps the link, says nothing,
    // and neither the cancelled request nor any lifecycle event installs a result.
    func testCancellingStaysOnScreenKeepsTheLinkAndInstallsNothing() {
        let app = launchLinkImport()
        typeLink(in: app)
        startImport(app)
        XCTAssertTrue(cancelButton(app).waitForExistence(timeout: 5))

        cancelButton(app).tap()

        XCTAssertTrue(app.navigationBars.staticTexts["导入菜谱"].waitForExistence(timeout: 3),
                      "cancelling must not leave the screen")
        let start = app.buttons["开始导入"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "the screen returns to its idle, retryable state")
        XCTAssertFalse(app.staticTexts["正在读取链接并整理菜谱…"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists, "stopping on purpose is not a failure")
        XCTAssertFalse(app.staticTexts["导入失败"].exists)
        XCTAssertEqual(linkField(app).value as? String, link, "the pasted link stays")

        // Past the stubbed request's own completion: the cancelled request must
        // not install a result, and nothing may restart on its own.
        XCTAssertFalse(app.staticTexts["基本信息"].waitForExistence(timeout: 9),
                       "a cancelled import must never produce a draft")
        XCTAssertFalse(app.staticTexts["正在读取链接并整理菜谱…"].exists,
                       "no second request may begin without an explicit tap")
        XCTAssertTrue(app.buttons["开始导入"].exists)
    }

    // L5 + L6 — a deliberate retry runs normally and reaches the existing draft
    // editor, with the same confirmation control as before.
    func testExplicitRetryAfterCancellingProducesTheNormalDraft() {
        let app = launchLinkImport()
        typeLink(in: app)
        startImport(app)
        XCTAssertTrue(cancelButton(app).waitForExistence(timeout: 5))
        cancelButton(app).tap()
        XCTAssertTrue(app.buttons["开始导入"].waitForExistence(timeout: 5))

        startImport(app)
        XCTAssertTrue(app.staticTexts["正在读取链接并整理菜谱…"].waitForExistence(timeout: 5),
                      "an explicit retry starts a new request")

        XCTAssertTrue(app.staticTexts["基本信息"].waitForExistence(timeout: 20),
                      "the successful import still reaches the draft editor")
        let save = app.buttons["import.result.save"]
        for _ in 0..<12 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable, "the existing explicit save control is unchanged")
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
}


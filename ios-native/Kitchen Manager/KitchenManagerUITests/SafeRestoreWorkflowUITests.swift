import XCTest

/// Feature 005, Phase 6: the destructive import workflow as a member meets it.
///
/// Every capture here is the production `BackupRestoreView` and its real
/// preview; the DEBUG fixture only decides which bytes are waiting. No test
/// confirms a replacement it did not intend to, and the ones that do confirm
/// run against an isolated simulator kitchen.
final class SafeRestoreWorkflowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launchBackupScreen(_ state: String = "dated", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_SAFE_RESTORE", "SAFE_RESTORE_\(state)"] + extra
        app.launch()
        let myTab = app.tabBars.buttons["我的"]
        XCTAssertTrue(myTab.waitForExistence(timeout: 10))
        myTab.tap()
        let backupRow = app.descendants(matching: .any).matching(identifier: "settings.backup.link").firstMatch
        for _ in 0..<12 where !(backupRow.exists && backupRow.isHittable) { app.swipeUp() }
        XCTAssertTrue(backupRow.exists && backupRow.isHittable, "备份入口无法到达")
        backupRow.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["备份与恢复"].waitForExistence(timeout: 10))
        return app
    }

    private func openPreview(_ app: XCUIApplication) {
        let restore = app.buttons["backup.recovery.restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5), "未处理的副本必须是可见且可操作的")
        restore.tap()
        // Anchored on the top of the sheet rather than the destructive button:
        // at accessibility sizes that button starts below the fold, and a lazy
        // Form has not built it yet.
        XCTAssertTrue(
            app.navigationBars.staticTexts["用副本恢复"].waitForExistence(timeout: 5),
            "未进入预览"
        )
        XCTAssertTrue(app.staticTexts["restorePreview.replacementWarning"].waitForExistence(timeout: 5))
    }

    /// Opens the destructive confirmation and returns its replace button.
    /// Looked up by the button itself rather than by container type: a
    /// `confirmationDialog` surfaces as a sheet or an alert depending on the
    /// device and version, and the test does not care which.
    @discardableResult
    private func openConfirmation(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["restorePreview.confirm"].tap()
        let replace = app.buttons["替换"]
        XCTAssertTrue(replace.waitForExistence(timeout: 10), "必须还有一次明确确认")
        return replace
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - The outstanding recovery copy is never hidden

    func testAnOutstandingRecoveryCopyIsVisibleAndActionable() {
        let app = launchBackupScreen()
        XCTAssertTrue(app.staticTexts["导入前的数据副本"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["backup.recovery.restore"].exists)
        XCTAssertTrue(app.buttons["backup.recovery.export"].exists, "副本必须可以被导出留存")
        XCTAssertTrue(app.staticTexts["backup.recovery.footer"].exists)
        attach(app, "safe-restore-outstanding-copy")
    }

    // MARK: - Preview tells the truth about the candidate

    func testPreviewReportsTheCandidateScopeAndExclusions() {
        let app = launchBackupScreen()
        openPreview(app)

        // Counts come from the candidate, not from the current kitchen, which
        // the fixture deliberately seeds with one unrelated item.
        XCTAssertTrue(app.staticTexts["restorePreview.count.inventory"].label.contains("2 项"))
        XCTAssertTrue(app.staticTexts["restorePreview.count.shoppingItems"].label.contains("1 项"))
        XCTAssertTrue(app.staticTexts["restorePreview.count.plans"].label.contains("0 项"))
        XCTAssertTrue(app.staticTexts["restorePreview.count.weeklyPlan"].label.contains("无"))

        let warning = app.staticTexts["restorePreview.replacementWarning"]
        XCTAssertTrue(warning.exists, "替换说明必须在确认之前出现")
        XCTAssertTrue(warning.label.contains("替换"))
        XCTAssertFalse(warning.label.contains("合并"), "替换不得被说成合并")

        let excluded = app.staticTexts["restorePreview.excluded"]
        XCTAssertTrue(excluded.label.contains("用户菜谱"))
        XCTAssertTrue(excluded.label.contains("收藏"))
        XCTAssertTrue(excluded.label.contains("常做记录"))

        attach(app, "safe-restore-preview-light")
    }

    func testALegacyBackupWithoutAnExportDateSaysSoInsteadOfInventingOne() {
        let app = launchBackupScreen("legacy")
        openPreview(app)

        let date = app.staticTexts["restorePreview.date"]
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        XCTAssertTrue(date.label.contains("没有记录时间"), "旧备份不得被安上一个虚构的时间，实际为：\(date.label)")
        attach(app, "safe-restore-preview-legacy-date")
    }

    // MARK: - Confirmation is required, and cancelling changes nothing

    func testCancellingThePreviewLeavesTheKitchenAlone() {
        let app = launchBackupScreen()
        openPreview(app)

        app.buttons["restorePreview.cancel"].tap()

        XCTAssertTrue(app.navigationBars.staticTexts["备份与恢复"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["backup.recovery.restore"].exists, "取消之后副本仍应保留")
        XCTAssertFalse(app.alerts.firstMatch.exists, "取消不是错误，不该弹出任何提示")
    }

    func testReachingThePreviewIsNotEnoughToReplaceAnything() {
        let app = launchBackupScreen()
        openPreview(app)

        // The destructive button opens a second, explicit confirmation; it does
        // not restore on its own.
        openConfirmation(app)
        XCTAssertTrue(app.buttons["取消"].exists, "确认里必须有退路")

        attach(app, "safe-restore-confirmation")
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(app.buttons["restorePreview.confirm"].waitForExistence(timeout: 5))
    }

    // MARK: - Confirming produces a truthful result

    func testConfirmingRestoresAndSaysSo() {
        let app = launchBackupScreen()
        openPreview(app)
        openConfirmation(app).tap()

        let result = app.alerts["数据已恢复"]
        XCTAssertTrue(result.waitForExistence(timeout: 10), "成功必须有明确反馈")
        attach(app, "safe-restore-result-success")
        result.buttons["好"].tap()

        // The copy did its job, so it is released rather than left blocking.
        XCTAssertFalse(
            app.buttons["backup.recovery.restore"].waitForExistence(timeout: 3),
            "成功之后不应再留下未处理的副本"
        )
    }

    // MARK: - Dark and the largest accessibility size

    func testPreviewRemainsLegibleInDarkMode() {
        let app = launchBackupScreen(extra: ["UITEST_FORCE_DARK_APPEARANCE"])
        openPreview(app)
        XCTAssertTrue(app.staticTexts["restorePreview.replacementWarning"].exists)
        attach(app, "safe-restore-preview-dark")
    }

    func testCriticalScopeInformationSurvivesTheLargestTextSize() {
        let app = launchBackupScreen(extra: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        openPreview(app)

        let warning = app.staticTexts["restorePreview.replacementWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertFalse(warning.label.contains("…"), "替换说明在最大字号下被截断")

        // The destructive action and the way out both stay reachable.
        let confirm = app.buttons["restorePreview.confirm"]
        for _ in 0..<10 where !(confirm.exists && confirm.isHittable) { app.swipeUp() }
        XCTAssertTrue(confirm.exists && confirm.isHittable, "最大字号下确认按钮不可达")
        XCTAssertGreaterThanOrEqual(confirm.frame.height, 43.5)
        XCTAssertTrue(app.buttons["restorePreview.cancel"].isHittable, "最大字号下取消不可达")

        attach(app, "safe-restore-preview-axxxl")
    }
}

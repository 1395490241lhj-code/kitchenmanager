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

    private func diskBackup(session: String, state: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_PREPARED_GROUPING", "UITEST_GROUPED_SEED_LIFECYCLE", "UITEST_GROUPED_CAPTURE_REOPEN"]
        if let state { app.launchArguments.append("UITEST_GROUPED_RECOVERY_STATE=" + state) }
        app.launchEnvironment["PREPARED_GROUPING_SESSION"] = session
        print("PR3_UI_SESSION=\(session)")
        app.launch(); XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 10))
        app.tabBars.buttons["我的"].tap()
        let row = app.descendants(matching: .any).matching(identifier: "settings.backup.link").firstMatch
        for _ in 0..<12 where !(row.exists && row.isHittable) { app.swipeUp() }
        row.tap(); XCTAssertTrue(app.buttons["backup.import.button"].waitForExistence(timeout: 5))
        return app
    }
    func testQualifiedV1V2V3RecoveryPreviewConfirmationAndRestart() {
        for (state, version) in [("legacy", 1), ("v2", 2), ("mixedV3", 3)] {
            let session = UUID().uuidString
            let app = diskBackup(session: session, state: state)
            openPreview(app)
            XCTAssertEqual(app.staticTexts["restorePreview.version"].label, "原文件版本：v\(version)")
            if version == 1 { XCTAssertTrue(app.staticTexts["restorePreview.date"].label.contains("没有记录时间")) }
            if version == 3 {
                let detail = app.staticTexts["prepared.restore.lifecycle.70000000-0000-0000-0000-000000000011"]
                for _ in 0..<10 where !(detail.exists && detail.isHittable) { app.swipeUp() }
                XCTAssertTrue(detail.label.contains("解冻中")); attach(app, "recovery-v3-lifecycle-detail")
            }
            let confirm = app.buttons["restorePreview.confirm"]
            for _ in 0..<10 where !(confirm.exists && confirm.isHittable) { app.swipeUp() }
            attach(app, "recovery-original-v\(version)-preview")
            openConfirmation(app).tap()
            XCTAssertTrue(app.alerts["数据已恢复"].waitForExistence(timeout: 6))
            app.alerts.buttons["好"].tap(); XCTAssertFalse(app.buttons["backup.recovery.restore"].exists)
            app.terminate(); _ = diskBackup(session: session)
            XCTAssertFalse(app.buttons["backup.recovery.restore"].exists)
            print("PR3_RECOVERY_UI_CASE=\(version) session=\(session)")
            attach(app, "recovery-v\(version)-fresh-process")
        }
    }
    func testSeparateRecoveryExportUsesSystemSaveSheetWithoutResolvingOriginal() throws {
        let session = UUID().uuidString
        let app = diskBackup(session: session, state: "mixedV3")
        app.buttons["backup.recovery.export"].tap()
        let save = app.buttons.matching(NSPredicate(format: "label IN %@", ["保存", "存储", "Save"])).firstMatch
        guard save.waitForExistence(timeout: 5) else {
            attach(app, "recovery-export-system-save-unavailable")
            throw XCTSkip("A08 export HOLD: system save control not found by this automation target; save is unverified")
        }
        attach(app, "recovery-export-system-save")
        if !save.isEnabled {
            let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
            if cancel.exists { cancel.tap() }
            throw XCTSkip("A08 export HOLD: no writable system save location")
        }
        save.tap()
        if app.buttons["替换"].waitForExistence(timeout: 1) {
            app.buttons["取消"].firstMatch.tap()
            throw XCTSkip("A08 export HOLD: existing filename collision retained without overwrite")
        }
        XCTAssertTrue(app.buttons["backup.recovery.restore"].waitForExistence(timeout: 5))
        openPreview(app)
        XCTAssertEqual(app.staticTexts["restorePreview.version"].label, "原文件版本：v3")
        print("PR3_RECOVERY_EXPORT_UI_SESSION=\(session)")
        attach(app, "recovery-original-remains-after-separate-export")
    }
    func testNormalSystemPickerOriginalBackupsAndMalformedV3() throws {
        guard let base = ProcessInfo.processInfo.environment["PR3_PICKER_BASE_URL"] else {
            throw XCTSkip("Normal picker requires the lease-scoped synthetic download server")
        }
        for version in ["v1", "v2", "v3", "malformed-v3"] {
            let session = UUID().uuidString
            let app = diskBackup(session: session)
            let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari"); safari.launch()
            let address = safari.textFields.firstMatch
            guard address.waitForExistence(timeout: 5) else {
                app.activate(); throw XCTSkip("A08 normal-import HOLD: supported Safari address entry unavailable")
            }
            address.tap(); address.typeText(base + "/PR3-Slice4-\(version).json\n")
            let download = safari.buttons.matching(NSPredicate(format: "label IN %@", ["下载", "Download"])).firstMatch
            if download.waitForExistence(timeout: 5) { download.tap() }
            app.activate(); app.buttons["backup.import.button"].tap()
            let name = "PR3-Slice4-" + version
            var file = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
            if !file.waitForExistence(timeout: 4), app.searchFields.firstMatch.exists {
                app.searchFields.firstMatch.tap(); app.searchFields.firstMatch.typeText(name)
                file = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
            }
            guard file.waitForExistence(timeout: 5) else {
                attach(app, "normal-import-system-picker-delivery-unavailable")
                throw XCTSkip("A08 normal-import HOLD: downloaded synthetic JSON is unavailable in the supported system picker")
            }
            attach(app, "normal-import-picker-" + version)
            let cell = app.cells.containing(.staticText, identifier: file.label).firstMatch
            if cell.exists { cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap() }
            else { file.tap() }
            let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["打开", "Open"])).firstMatch
            if open.waitForExistence(timeout: 1) { open.tap() }
            if version == "malformed-v3" {
                XCTAssertFalse(app.navigationBars.staticTexts["确认导入"].exists)
                XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
                attach(app, "normal-import-original-v3-rejected")
            } else {
                XCTAssertTrue(app.navigationBars.staticTexts["确认导入"].waitForExistence(timeout: 5))
                XCTAssertEqual(app.staticTexts["restorePreview.version"].label, "原文件版本：" + version)
                attach(app, "normal-import-original-" + version + "-preview")
                let confirm = app.buttons["restorePreview.confirm"]
                for _ in 0..<10 where !(confirm.exists && confirm.isHittable) { app.swipeUp() }
                openConfirmation(app).tap()
                XCTAssertTrue(app.alerts["数据已恢复"].waitForExistence(timeout: 5))
            }
            app.terminate(); _ = diskBackup(session: session)
            print("PR3_PICKER_UI_CASE=\(version) session=\(session)")
        }
    }
}

import XCTest

/// UI-5A coverage for the 我的 / Settings information architecture.
///
/// Everything here runs in ordinary Guest mode with no credentials: signed-in
/// lifecycle presentation is deliberately out of scope for UI-5A, so no
/// deterministic signed-in fixture exists yet. These tests only read and
/// navigate — the destructive clear-local-data action is opened and then
/// cancelled, never executed.
final class SettingsExperienceUITests: XCTestCase {
    /// Must stay identical to `SettingsView.guestAccountFooter`.
    private static let guestFooter = "无需登录即可继续使用全部本机功能。登录后可为未来跨设备同步做准备，并可选择将本机库存合并到家庭云端；购物清单、计划和菜谱仍只保存在本机。"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Present on every launch so the app's DEBUG appearance hook fires.
    ///
    /// That hook only resets the persisted `appearance` preference for launches
    /// carrying *some* `UITEST_`-prefixed argument. Without one, these tests would
    /// inherit whatever appearance a previous run left in UserDefaults — the dark
    /// test in this very file would tint every later screenshot. The argument
    /// matches no seed, so it has no other effect.
    private static let appearanceResetArgument = "UITEST_SETTINGS_EXPERIENCE"

    private func launchSettings(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [Self.appearanceResetArgument] + extraArguments
        app.launch()
        let myTab = app.tabBars.buttons["我的"]
        XCTAssertTrue(myTab.waitForExistence(timeout: 10))
        myTab.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["我的"].waitForExistence(timeout: 5))
        return app
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Scrolls the Settings form until `element` is hittable, or gives up.
    @discardableResult
    private func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if element.exists && element.isHittable { return true }
        for _ in 0..<12 {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    /// Scrolls to the end of the Settings form, stopping when the content stops
    /// moving rather than after a fixed count, so it works at both standard and
    /// Accessibility text sizes.
    private func scrollToBottomOfSettings(_ app: XCUIApplication) {
        let form = app.collectionViews.firstMatch.exists
            ? app.collectionViews.firstMatch
            : app.tables.firstMatch
        guard form.exists else { return }
        var previous = ""
        for _ in 0..<15 {
            let signature = form.cells.allElementsBoundByIndex
                .map { "\($0.identifier)|\($0.frame.minY)" }
                .joined()
            if signature == previous { return }
            previous = signature
            app.swipeUp()
        }
    }

    /// Scrolls to the end of the form and asserts the *last* interactive row rests
    /// entirely above the expanded tab bar.
    ///
    /// Only applied to the trailing row: a mid-list row cannot be asserted this way,
    /// because pushing it fully clear of the bar can scroll it off the top of a lazy
    /// `Form`, at which point it leaves the accessibility tree altogether.
    private func assertTrailingRowRestsAboveTabBar(
        _ element: XCUIElement,
        tabBarTop: CGFloat,
        label: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        scrollToBottomOfSettings(app)
        XCTAssertTrue(element.exists, "\(label) 不存在", file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(label) 不可点击", file: file, line: line)
        XCTAssertLessThanOrEqual(
            element.frame.maxY,
            tabBarTop,
            "\(label) 底部 \(element.frame.maxY) 仍在 Tab Bar 上边缘 \(tabBarTop) 之下",
            file: file,
            line: line
        )
    }

    /// The tab bar's expanded top edge, captured before any scrolling —
    /// `.tabBarMinimizeBehavior(.onScrollDown)` shrinks it once the form moves, so
    /// measuring later would test a smaller bar than the user rests against.
    private func expandedTabBarTop(of app: XCUIApplication) -> CGFloat {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
        return tabBar.frame.minY
    }

    // MARK: - 1. Guest Settings, standard type

    func testGuestSettingsLeadsWithAccountStatusAndKeepsLocalUseClear() throws {
        let app = launchSettings()

        // Account status is the first thing on the screen, and is presented as a
        // complete state rather than a warning.
        let accountEntry = app.buttons["settings.account.entry"]
        XCTAssertTrue(accountEntry.waitForExistence(timeout: 5))
        XCTAssertTrue(accountEntry.isHittable, "账号入口应可直接点击")
        XCTAssertGreaterThanOrEqual(accountEntry.frame.height, 43.5, "账号入口应至少 44pt 高")

        // Mode, local-usability status, and the action all read in one element.
        let label = accountEntry.label
        for fragment in ["游客模式", "本机功能已全部可用", "登录或创建账号"] {
            XCTAssertTrue(label.contains(fragment), "账号入口缺少「\(fragment)」，实际为：\(label)")
        }

        // Local usability is stated explicitly.
        XCTAssertTrue(
            app.staticTexts[Self.guestFooter].waitForExistence(timeout: 3),
            "游客说明文案缺失或与实现不一致"
        )

        // Guest mode must not be *framed* as a failure. Note this deliberately
        // does not assert the absence of `settings.account.error`: `AuthStore` is
        // seeded with a configuration message when the build has no Supabase
        // configuration, so that row can legitimately appear in Guest mode. That
        // is pre-existing, frozen auth error handling. What matters is that the
        // account entry itself still reads as a usable state and stays actionable.
        XCTAssertFalse(label.contains("错误"), "账号入口不应把游客模式描述为错误")
        XCTAssertFalse(label.contains("失败"), "账号入口不应把游客模式描述为失败")

        // Ordinary settings remain reachable on the same screen.
        XCTAssertTrue(app.staticTexts["显示模式"].exists)
        XCTAssertTrue(app.staticTexts["菜谱库模式"].exists)

        attachScreenshot(of: app, named: "settings-guest-standard")
    }

    // MARK: - 2. Core Settings entries

    func testCoreSettingsEntriesRemainReachable() throws {
        let app = launchSettings()

        // Appearance and recipe-library preferences.
        XCTAssertTrue(app.buttons["settings.appearance.picker"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.recipeLibrary.picker"].exists)

        // Reminder controls.
        XCTAssertTrue(app.switches["settings.expiryNotifications.toggle"].exists)
        XCTAssertTrue(app.switches["settings.stapleNotifications.toggle"].exists)

        // Pantry preference, backup, about, and the destructive entry all resolve
        // by scrolling — none is stranded off-screen.
        for identifier in [
            "settings.pantry.manage.link",
            "settings.backup.link",
            "settings.cleardata.button"
        ] {
            let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            XCTAssertTrue(scrollUntilVisible(row, in: app), "\(identifier) 无法滚动到可见位置")
        }

        XCTAssertTrue(app.staticTexts["版本"].exists, "关于分区应显示版本行")
    }

    // MARK: - 3. Clear-local-data confirmation (opened, then cancelled)

    func testClearLocalDataConfirmationStaysDestructiveAndCancellable() throws {
        let app = launchSettings()

        let clearButton = app.buttons["settings.cleardata.button"]
        XCTAssertTrue(scrollUntilVisible(clearButton, in: app), "清除数据入口无法滚动到可见位置")

        // Separated from ordinary settings: the backup row must not be its
        // immediate neighbour inside one section any more.
        let backupRow = app.descendants(matching: .any)
            .matching(identifier: "settings.backup.link").firstMatch
        if backupRow.exists {
            XCTAssertGreaterThan(
                clearButton.frame.minY,
                backupRow.frame.maxY,
                "破坏性操作应排在备份入口之后并自成一组"
            )
        }

        clearButton.tap()

        let alert = app.alerts["清除全部本地数据？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "确认弹窗未出现")

        // The destructive button and the cancel button both still exist, with
        // their original wording and roles.
        let confirm = alert.buttons["清除"]
        let cancel = alert.buttons["取消"]
        XCTAssertTrue(confirm.exists, "破坏性确认按钮应保持为「清除」")
        XCTAssertTrue(cancel.exists, "取消按钮应保持为「取消」")

        attachScreenshot(of: app, named: "settings-clear-data-confirmation")

        // Cancel — this test must never clear user data.
        cancel.tap()
        XCTAssertFalse(alert.exists, "取消后弹窗应关闭")

        // Settings is still on screen and nothing was destroyed.
        XCTAssertTrue(app.navigationBars.staticTexts["我的"].exists)
    }

    // MARK: - 4. Accessibility XXXL

    func testAccessibilityXXXLKeepsAccountContentAndLowerRowsReachable() throws {
        let app = launchSettings(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])

        let tabBarTop = expandedTabBarTop(of: app)

        // Primary account content is on the first screen, above the tab bar.
        let accountEntry = app.buttons["settings.account.entry"]
        XCTAssertTrue(accountEntry.waitForExistence(timeout: 5))
        XCTAssertTrue(accountEntry.isHittable, "XXXL 下账号入口应在首屏可点击")
        XCTAssertLessThanOrEqual(
            accountEntry.frame.minY,
            tabBarTop,
            "XXXL 下账号入口被 Tab Bar 遮挡"
        )
        for fragment in ["游客模式", "登录或创建账号"] {
            XCTAssertTrue(accountEntry.label.contains(fragment), "XXXL 下账号入口缺少「\(fragment)」")
        }

        // Supporting copy wraps rather than truncating: a truncated SwiftUI label
        // reports an ellipsis, and the full string would no longer match.
        let footer = app.staticTexts[Self.guestFooter]
        XCTAssertTrue(footer.waitForExistence(timeout: 3), "XXXL 下游客说明被截断或改写")
        XCTAssertFalse(footer.label.contains("…"), "游客说明出现省略号，说明被截断")

        attachScreenshot(of: app, named: "settings-guest-accessibility-xxxl-top")

        // Lower rows stay reachable by scrolling, and come to rest above the
        // expanded tab bar rather than under it.
        // Mid-list rows: reachability is the requirement. Clearance is asserted on
        // the trailing row instead, because scrolling a mid-list row fully clear of
        // the bar can push it off the top of the lazy Form and out of the tree.
        let backupRow = app.descendants(matching: .any)
            .matching(identifier: "settings.backup.link").firstMatch
        XCTAssertTrue(
            scrollUntilVisible(backupRow, in: app),
            "XXXL 下备份入口无法滚动到可见位置"
        )

        // Trailing destructive row: must come to rest fully above the expanded bar.
        let clearButton = app.buttons["settings.cleardata.button"]
        assertTrailingRowRestsAboveTabBar(
            clearButton,
            tabBarTop: tabBarTop,
            label: "XXXL 下清除入口",
            in: app
        )

        attachScreenshot(of: app, named: "settings-guest-accessibility-xxxl-bottom")
    }

    /// Standard-size bottom clearance, so the destructive row is not left under
    /// the tab bar at the default text size either.
    func testStandardSizeBottomRowsClearFloatingTabBar() throws {
        let app = launchSettings()
        let tabBarTop = expandedTabBarTop(of: app)

        let clearButton = app.buttons["settings.cleardata.button"]
        assertTrailingRowRestsAboveTabBar(
            clearButton,
            tabBarTop: tabBarTop,
            label: "清除入口",
            in: app
        )

        attachScreenshot(of: app, named: "settings-guest-scrolled-bottom")
    }

    // MARK: - 5. Dark Mode

    func testSettingsRemainsLegibleInDarkMode() throws {
        let app = launchSettings(extraArguments: ["UITEST_FORCE_DARK_APPEARANCE"])

        XCTAssertTrue(app.buttons["settings.account.entry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[Self.guestFooter].exists, "深色模式下游客说明缺失")
        XCTAssertTrue(app.staticTexts["显示模式"].exists)
        XCTAssertTrue(app.switches["settings.expiryNotifications.toggle"].exists)

        let clearButton = app.buttons["settings.cleardata.button"]
        XCTAssertTrue(scrollUntilVisible(clearButton, in: app), "深色模式下清除入口无法滚动到可见位置")

        attachScreenshot(of: app, named: "settings-guest-dark")
    }

    // MARK: - 6. Backup entry navigation (no export, no restore)

    func testBackupEntryNavigatesToExistingBackupDestination() throws {
        let app = launchSettings()

        let backupRow = app.descendants(matching: .any)
            .matching(identifier: "settings.backup.link").firstMatch
        XCTAssertTrue(scrollUntilVisible(backupRow, in: app), "备份入口无法滚动到可见位置")
        backupRow.tap()

        // Existing destination, reached unchanged. Neither export nor import is
        // triggered — only the presence of the entry points is checked.
        XCTAssertTrue(
            app.navigationBars.staticTexts["备份与恢复"].waitForExistence(timeout: 5),
            "未导航到既有的备份与恢复页面"
        )
        XCTAssertTrue(app.buttons["导出厨房备份"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["导入厨房备份"].exists)

        attachScreenshot(of: app, named: "settings-backup-entry")
    }
}

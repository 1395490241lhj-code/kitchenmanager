import XCTest

/// UI-5B1 uses only the app's DEBUG-only, in-memory account fixture. No test
/// in this class has credentials, tokens, or a real network-backed action.
final class AccountLifecycleExperienceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launchAccount(_ fixture: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [fixture, "UITEST_ACCOUNT_TEST"] + extra
        app.launch()
        let myTab = app.tabBars.buttons["我的"]
        XCTAssertTrue(myTab.waitForExistence(timeout: 10))
        myTab.tap()
        let accountEntry = app.buttons["settings.account.entry"]
        XCTAssertTrue(accountEntry.waitForExistence(timeout: 10))
        accountEntry.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["账号"].waitForExistence(timeout: 10))
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scrollToAccountBottom(_ app: XCUIApplication) {
        let form = app.collectionViews.firstMatch.exists
            ? app.collectionViews.firstMatch
            : app.tables.firstMatch
        guard form.exists else { return }
        var previous = ""
        for _ in 0..<16 {
            let signature = form.cells.allElementsBoundByIndex
                .map { "\($0.identifier)|\($0.frame.minY)" }
                .joined()
            if signature == previous { return }
            previous = signature
            app.swipeUp()
        }
    }

    private func assertAccountBottomClearsTabBar(
        _ app: XCUIApplication,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tabBarTop = app.tabBars.firstMatch.frame.minY
        let signOutFooter = app.staticTexts["退出登录不会删除本机的库存、计划、购物清单或菜谱。"]
        let deleteButton = app.buttons["account.delete.link"]
        let deleteFooter = app.staticTexts["永久删除你的登录身份，与退出登录不同。"]
        let diagnostics = app.buttons["account.sync.diagnostics.link"]

        scrollToAccountBottom(app)

        XCTAssertTrue(deleteButton.exists, "\(label) 未出现删除账号入口", file: file, line: line)
        XCTAssertTrue(deleteFooter.exists, "\(label) 未出现删除账号说明", file: file, line: line)
        XCTAssertTrue(signOutFooter.exists, "\(label) 未出现退出登录说明", file: file, line: line)
        XCTAssertLessThanOrEqual(
            signOutFooter.frame.maxY,
            tabBarTop,
            "\(label) 退出登录说明被 Tab Bar 遮挡：footer=\(signOutFooter.frame) tabBarTop=\(tabBarTop)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            deleteFooter.frame.maxY,
            tabBarTop,
            "\(label) 删除账号说明被 Tab Bar 遮挡：footer=\(deleteFooter.frame) tabBarTop=\(tabBarTop)",
            file: file,
            line: line
        )

        let trailingElement = diagnostics.exists ? diagnostics : deleteButton
        XCTAssertTrue(
            trailingElement.exists,
            "\(label) 最后一项不存在",
            file: file,
            line: line
        )
        XCTAssertTrue(
            trailingElement.isHittable,
            "\(label) 最后一项不可到达：frame=\(trailingElement.frame)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            trailingElement.frame.maxY,
            tabBarTop,
            "\(label) 最后一项被 Tab Bar 遮挡：last=\(trailingElement.frame) tabBarTop=\(tabBarTop)",
            file: file,
            line: line
        )
        print("=====ACCOUNT BOTTOM \(label)===== tabBarTop=\(tabBarTop) signOutFooter=\(signOutFooter.frame) deleteFooter=\(deleteFooter.frame) trailing=\(trailingElement.frame)")
    }

    func testOwnerSummaryShowsIdentityHouseholdRoleAndOriginalDestinations() throws {
        let app = launchAccount("UITEST_ACCOUNT_OWNER")
        XCTAssertTrue(app.staticTexts["厨房主人"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["家庭厨房"].exists)
        XCTAssertTrue(app.staticTexts["所有者"].exists)
        XCTAssertTrue(app.buttons["account.merge.link"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["account.sync.diagnostics.link"].exists)
        XCTAssertTrue(app.buttons["account.delete.link"].exists)
        attach(app, "account-owner-standard")
        assertAccountBottomClearsTabBar(app, label: "标准字号")
        attach(app, "account-standard-bottom")
    }

    func testMemberSummaryShowsMemberRole() throws {
        let app = launchAccount("UITEST_ACCOUNT_MEMBER")
        XCTAssertTrue(app.staticTexts["家庭成员"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["成员"].exists)
        attach(app, "account-member-standard")
    }

    func testLoadingStateIsVisibleWithoutPretendingToBeGuest() throws {
        let app = launchAccount("UITEST_ACCOUNT_LOADING")
        XCTAssertTrue(app.staticTexts["正在读取账号资料…"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["游客模式"].exists)
        attach(app, "account-loading")
    }

    func testAccountErrorStateIsVisibleAndRetryable() throws {
        let app = launchAccount("UITEST_ACCOUNT_ERROR")
        XCTAssertTrue(app.staticTexts["暂时无法读取账号资料，本机功能仍可继续使用。"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["重试"].exists)
        attach(app, "account-error")
    }

    func testSyncIdleAndCompletedStatusArePresentedAsStatus() throws {
        let idle = launchAccount("UITEST_ACCOUNT_SYNC_IDLE")
        XCTAssertTrue(idle.staticTexts["尚未开启"].waitForExistence(timeout: 5))
        attach(idle, "account-sync-idle")

        let completed = launchAccount("UITEST_ACCOUNT_SYNC_COMPLETED")
        XCTAssertTrue(completed.staticTexts["已同步"].waitForExistence(timeout: 5))
    }

    func testSyncErrorIsVisibleWithoutClaimingSuccess() throws {
        let app = launchAccount("UITEST_ACCOUNT_SYNC_ERROR")
        XCTAssertTrue(app.staticTexts["同步遇到问题，可重试"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["当前使用本机数据，稍后可重试。"].exists)
        XCTAssertFalse(app.staticTexts["已同步"].exists)
        attach(app, "account-sync-error")
    }

    func testSignOutConfirmationOpensAndCancelKeepsSignedIn() throws {
        let app = launchAccount("UITEST_ACCOUNT_OWNER")
        app.buttons["account.signout.button"].tap()
        let alert = app.alerts["退出登录？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.buttons["退出"].exists)
        XCTAssertTrue(alert.buttons["取消"].exists)
        attach(app, "account-signout-confirmation")
        alert.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["账号"].exists)
        XCTAssertTrue(app.staticTexts["厨房主人"].exists)
    }

    func testSignOutFailureIsVisibleAndDoesNotLeaveFixture() throws {
        let app = launchAccount("UITEST_ACCOUNT_SIGNOUT_FAILURE")
        app.buttons["account.signout.button"].tap()
        app.alerts["退出登录？"].buttons["退出"].tap()
        XCTAssertTrue(app.staticTexts["账号服务暂时不可用，请稍后再试。"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.staticTexts["账号"].exists)
        XCTAssertTrue(app.staticTexts["厨房主人"].exists)
        attach(app, "account-signout-failure")
    }

    func testDarkModeAndAccessibilityTopAndBottomRemainReachable() throws {
        let dark = launchAccount("UITEST_ACCOUNT_OWNER", extra: ["UITEST_FORCE_DARK_APPEARANCE"])
        XCTAssertTrue(dark.staticTexts["厨房主人"].waitForExistence(timeout: 5))
        attach(dark, "account-dark")

        let large = launchAccount(
            "UITEST_ACCOUNT_OWNER",
            extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        )
        XCTAssertTrue(large.staticTexts["厨房主人"].waitForExistence(timeout: 5))
        attach(large, "account-accessibility-xxxl-top")
        assertAccountBottomClearsTabBar(large, label: "Accessibility XXXL")
        attach(large, "account-accessibility-xxxl-bottom")
    }

    func testGuestLaunchDoesNotExposeFixtureEntry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_ACCOUNT_TEST"]
        app.launch()
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["我的"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["测试状态仅展示界面，不会连接网络或修改同步数据。"].exists)
        XCTAssertFalse(app.staticTexts["厨房主人"].exists)
    }
}

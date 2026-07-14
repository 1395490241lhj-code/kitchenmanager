import XCTest

/// A deliberately opt-in integration test. It compiles into every ordinary
/// `xcodebuild test` run (so it is visible and explicitly skipped, not
/// silently absent), but its body only runs when both sync flags are enabled
/// in Local.xcconfig and a development-only Supabase account is supplied to
/// the test process via environment variables — otherwise it safely
/// `XCTSkip`s. It never sends credentials to the app launch environment.
final class HostedSyncSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard !environment("SYNC_SMOKE_TEST_EMAIL").isEmpty,
              !environment("SYNC_SMOKE_TEST_PASSWORD").isEmpty else {
            throw XCTSkip("Hosted sync smoke credentials were not supplied.")
        }
    }

    func testExplicitDevelopmentInventorySmoke() throws {
        let email = environment("SYNC_SMOKE_TEST_EMAIL")
        let password = environment("SYNC_SMOKE_TEST_PASSWORD")
        let app = XCUIApplication()
        app.launch()

        let settingsTab = app.tabBars.buttons["我的"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()

        let guestEntry = app.staticTexts["游客模式"].firstMatch
        if guestEntry.waitForExistence(timeout: 5) {
            guestEntry.tap()
            let emailField = app.textFields["邮箱"]
            let passwordField = app.secureTextFields["密码"]
            XCTAssertTrue(emailField.waitForExistence(timeout: 5))
            emailField.tap()
            emailField.typeText(email)
            passwordField.tap()
            passwordField.typeText(password)
            app.buttons["登录"].tap()
        } else {
            // Do not take ownership of an unknown simulator session. A
            // deliberate hosted run may reuse only the supplied dev account.
            XCTAssertTrue(
                app.staticTexts["管理账号与家庭"].firstMatch.waitForExistence(timeout: 5),
                "Hosted smoke requires Guest mode or the supplied development account."
            )
        }

        let runSmoke = app.buttons["Run Sync Smoke"]
        XCTAssertTrue(
            runSmoke.waitForExistence(timeout: 15),
            "Enable SYNC_ENABLED, SYNC_SMOKE_ENABLED and development in Local.xcconfig before this explicit hosted run."
        )
        runSmoke.tap()
        XCTAssertTrue(app.alerts["Run Sync Smoke?"].waitForExistence(timeout: 5))
        app.alerts["Run Sync Smoke?"].buttons["Run"].tap()

        let status = app.staticTexts["sync-smoke-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 45))
        XCTAssertEqual(status.label, "Sync smoke passed. Guest data counts are unchanged.")

        let accountEntry = app.staticTexts["管理账号与家庭"].firstMatch
        XCTAssertTrue(accountEntry.waitForExistence(timeout: 5))
        accountEntry.tap()
        let signOut = app.buttons["退出登录"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        signOut.tap()
        XCTAssertTrue(app.alerts["退出登录？"].waitForExistence(timeout: 5))
        app.alerts["退出登录？"].buttons["退出"].tap()
        XCTAssertTrue(guestEntry.waitForExistence(timeout: 10))
    }

    private func environment(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }
}

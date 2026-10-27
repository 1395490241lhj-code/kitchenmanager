import XCTest

final class AccountDeletionLocalCleanupUITests: XCTestCase {
    func testRemoteCompletedLocalFailuresRetryOnlyKitchenCleanupAndPreserveRecipeLibrary() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_LOCAL_DELETION_CLEANUP"]
        app.launch()
        let typed = app.textFields["输入 DELETE 以确认"]
        XCTAssertTrue(typed.waitForExistence(timeout: 10))
        typed.tap()
        typed.typeText("DELETE")
        app.buttons["删除账号，此操作不可撤销"].tap()
        app.alerts["此操作不可撤销"].buttons["继续"].tap()
        let password = app.secureTextFields["当前密码"]
        XCTAssertTrue(password.waitForExistence(timeout: 3))
        password.tap()
        password.typeText("fixture-only")
        app.buttons["重新验证身份"].tap()
        let final = app.alerts["最后确认删除账号"]
        XCTAssertTrue(final.waitForExistence(timeout: 3))
        final.buttons["删除账号"].tap()

        let retry = app.buttons["account.delete.retryLocalCleanup"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["account.delete.localCleanupPending"].exists)
        XCTAssertFalse(app.textFields["输入 DELETE 以确认"].exists)
        XCTAssertFalse(app.buttons["删除账号，此操作不可撤销"].exists)
        XCTAssertFalse(app.secureTextFields["当前密码"].exists)
        capture(app, "account-remote-completed-local-cleanup-failed")
        for _ in 0..<2 {
            retry.tap()
            XCTAssertTrue(retry.waitForExistence(timeout: 3))
            XCTAssertTrue(app.staticTexts["account.delete.localCleanupPending"].exists)
        }
        capture(app, "account-local-cleanup-repeated-failure")
        retry.tap()
        XCTAssertTrue(app.staticTexts["cleanupFixture.guest"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["cleanupFixture.confirmations"].label, "外部删除确认：1 次")
        XCTAssertEqual(app.staticTexts["cleanupFixture.kitchen"].label, "库存：0，备餐：0")
        XCTAssertEqual(app.staticTexts["cleanupFixture.library"].label, "用户菜谱：1，收藏：1，常做：1")
        capture(app, "account-local-cleanup-success-library-preserved")
    }

    func testPendingAccountAIsBlockedAfterBReopensRealAccountDeletion() {
        verifyChangedContext(guest: false)
    }

    func testPendingAccountAIsReachableAndBlockedForGuestThroughSettingsNotice() {
        verifyChangedContext(guest: true)
    }

    private func verifyChangedContext(guest: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_LOCAL_DELETION_CLEANUP"]
        app.launch()
        let typed = app.textFields["输入 DELETE 以确认"]
        XCTAssertTrue(typed.waitForExistence(timeout: 10))
        typed.tap(); typed.typeText("DELETE")
        app.buttons["删除账号，此操作不可撤销"].tap()
        app.alerts["此操作不可撤销"].buttons["继续"].tap()
        let password = app.secureTextFields["当前密码"]
        XCTAssertTrue(password.waitForExistence(timeout: 3))
        password.tap(); password.typeText("fixture-only")
        app.buttons["重新验证身份"].tap()
        let final = app.alerts["最后确认删除账号"]
        XCTAssertTrue(final.waitForExistence(timeout: 3))
        final.buttons["删除账号"].tap()
        XCTAssertTrue(app.buttons["account.delete.retryLocalCleanup"].waitForExistence(timeout: 5))
        app.buttons["cleanupFixture.closeDeletion"].tap()
        app.buttons[guest ? "cleanupFixture.switchGuest" : "cleanupFixture.switchB"].tap()
        let context = app.staticTexts["cleanupFixture.context"]
        let label = guest ? "游客上下文" : "隔离账号 B"
        expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: context)
        waitForExpectations(timeout: 5)
        app.buttons["cleanupFixture.settings"].tap()
        let pendingNotice = app.buttons["settings.account.localCleanupPending"]
        XCTAssertTrue(pendingNotice.waitForExistence(timeout: 5))
        if guest {
            pendingNotice.tap()
        } else {
            app.buttons["settings.account.entry"].tap()
            XCTAssertTrue(app.staticTexts["account.identity.summary"].waitForExistence(timeout: 5))
            let deletion = app.buttons["account.delete.link"]
            for _ in 0..<6 {
                if deletion.exists && deletion.isHittable { break }
                app.swipeUp()
            }
            deletion.tap()
        }
        XCTAssertTrue(app.staticTexts["account.delete.localCleanupBlocked"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["account.delete.retryLocalCleanup"].isEnabled)
        XCTAssertFalse(app.textFields["输入 DELETE 以确认"].exists)
        XCTAssertFalse(app.secureTextFields["当前密码"].exists)
        capture(app, guest ? "account-pending-guest-cleanup-blocked" : "account-pending-B-cleanup-blocked")
        for _ in 0..<4 {
            if app.staticTexts["cleanupFixture.library"].exists { break }
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertEqual(app.staticTexts["cleanupFixture.confirmations"].label, "外部删除确认：1 次")
        XCTAssertEqual(app.staticTexts["cleanupFixture.kitchen"].label, "库存：2，备餐：2")
        XCTAssertEqual(app.staticTexts["cleanupFixture.library"].label, "用户菜谱：1，收藏：1，常做：1")
        XCTAssertEqual(app.staticTexts["cleanupFixture.context"].label, label)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

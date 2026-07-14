import XCTest

/// Real, credential-free UI verification for Phase 2B-3's guest-mode entry
/// point (`RecordFoodSheet`/merge UI itself requires a signed-in account, so
/// its logic is covered by the extensive mock-transport `GuestMergeTests`
/// suite instead — this file exercises only what's reachable in ordinary
/// Guest mode, on the real running app, with no test credentials).
final class GuestMergeUIPhase2B3UITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testGuestModeSettingsTabExplainsInventoryBackupWithoutShowingAnyMergeUI() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["我的"].tap()

        let guestRow = app.staticTexts["游客模式"]
        XCTAssertTrue(guestRow.waitForExistence(timeout: 5))

        // The explanatory copy must mention future sync prep AND inventory
        // backup, matching the exact product copy — and no merge-specific
        // UI (which requires a signed-in account) may ever appear here.
        let explanation = app.staticTexts[
            "无需登录即可继续使用全部本机功能。登录后可为未来跨设备同步做准备，并可选择将本机库存合并到家庭云端；购物清单、计划和菜谱仍只保存在本机。"
        ]
        XCTAssertTrue(explanation.waitForExistence(timeout: 3))

        XCTAssertFalse(app.buttons["guestMergePromptButton"].exists, "merge UI must never appear before sign-in")
        XCTAssertFalse(app.buttons["inventorySyncNowButton"].exists, "manual sync UI must never appear before sign-in")

        // Tapping through to the login screen must not crash and must not
        // silently trigger any merge/sync UI.
        guestRow.tap()
        let loginTitle = app.navigationBars.staticTexts["登录"]
        XCTAssertTrue(loginTitle.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["guestMergePromptButton"].exists)
    }
}

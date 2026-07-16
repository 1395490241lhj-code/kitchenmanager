import XCTest

/// Phase 2C-1 (minimum-app-version enforcement / sync rate limiting).
///
/// Following the same established boundary as
/// `GuestMergeUIPhase2B3UITests`: every state this phase introduces
/// (upgrade-required banner, disabled confirm/rollback, rate-limit message)
/// only ever renders once a real account is signed in and a real (or
/// injected) sync error has occurred — none of that is safely reachable
/// from a credential-free UI test, and this file does not attempt to build
/// a Debug-only mock-injection backdoor for it (that would need a new,
/// permanent test-only wiring point in the app's composition root, which is
/// out of scope for this phase). That behavior is instead covered by the
/// offline `GuestMergeTests` suite (`testConfirmMergeUpgradeRequiredSetsFlagAndPreservesLocalData`,
/// `testRollbackRateLimitedStaysRetryableAndRecordsRetryAfter`, etc.) and the
/// `SyncTransportTests` header/mapping tests. This file only exercises what
/// a credential-free UI test can actually reach for real: that local-only
/// (Guest) usage is completely unaffected by any of this phase's changes,
/// and that no merge/sync UI (which is where the new states would render)
/// leaks before sign-in.
final class Phase2C1VersionAndRateLimitUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testGuestModeInventoryRemainsFullyUsableAndNoSyncUIAppearsBeforeSignIn() throws {
        let app = XCUIApplication()
        app.launch()

        // Local-only inventory usage must be completely unaffected by this
        // phase's backend/transport changes — the Guest home screen and its
        // primary "食材" tab must be reachable exactly as before.
        let inventoryTab = app.buttons["食材"]
        XCTAssertTrue(inventoryTab.waitForExistence(timeout: 5))
        inventoryTab.tap()
        XCTAssertTrue(app.navigationBars.element.waitForExistence(timeout: 3), "the inventory screen must load normally for a signed-out Guest")

        // None of the new version/rate-limit UI (which only ever appears
        // inside signed-in merge/sync screens) may leak into Guest mode.
        for identifier in ["guestMergeUpgradeRequiredMessage", "inventorySyncRateLimitedMessage", "guestMergeConfirmButton", "guestMergeRollbackButton", "inventorySyncNowButton"] {
            XCTAssertFalse(app.staticTexts[identifier].exists)
            XCTAssertFalse(app.buttons[identifier].exists)
        }
    }
}

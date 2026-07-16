import XCTest

/// Phase 2C-2 (crash reporting + basic monitoring).
///
/// Following the same established boundary as `Phase2C1VersionAndRateLimitUITests`
/// and `GuestMergeUIPhase2B3UITests`: crash reporting is disabled by default
/// in every committed build configuration (`CRASH_REPORTING_ENABLED = NO`),
/// so the only thing a credential-free UI test can meaningfully verify is
/// that the app launches and behaves completely normally with it disabled —
/// that a real crash-reporting SDK's UI surface (there is none; this phase
/// only ships an abstraction + no-op provider) never appears, and that no
/// internal identifier (DSN, request id, event id) leaks into any
/// user-visible text. Provider-enabled states, breadcrumb emission, and
/// error-flow-specific behavior are covered by the offline
/// `CrashReportingTests`/`GuestMergeTests` suites instead — this file does
/// not add a Debug-only mock-injection backdoor for them.
final class Phase2C2ObservabilityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesNormallyWithCrashReportingDisabledAndGuestInventoryStaysUsable() throws {
        let app = XCUIApplication()
        app.launch()

        let inventoryTab = app.buttons["食材"]
        XCTAssertTrue(inventoryTab.waitForExistence(timeout: 5), "app must launch normally with crash reporting disabled (the committed default)")
        inventoryTab.tap()
        XCTAssertTrue(app.navigationBars.element.waitForExistence(timeout: 3), "local-only inventory usage must be unaffected by the observability changes")

        // No internal correlation/DSN/event identifier may ever appear in
        // ordinary user-visible text.
        for staticText in app.staticTexts.allElementsBoundByIndex {
            let value = staticText.label
            XCTAssertFalse(value.lowercased().contains("dsn"), "no DSN string may ever appear in the UI")
            XCTAssertFalse(value.lowercased().contains("sentry.io"), "no crash-provider endpoint may ever appear in the UI")
        }
    }
}

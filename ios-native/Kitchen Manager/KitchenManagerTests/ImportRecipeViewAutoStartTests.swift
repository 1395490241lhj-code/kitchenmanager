import XCTest
@testable import KitchenManager

/// Covers the pure auto-start decision logic behind the Share Extension
/// URL handoff (`ImportRecipeView.shouldAutoStartImport`). Deliberately not
/// a full SwiftUI/XCUITest exercise of `.task` itself — that would be
/// fragile and slow — this isolates exactly the boolean decision that
/// gates the one new network-triggering behavior added in this phase.
final class ImportRecipeViewAutoStartTests: XCTestCase {

    // MARK: - A. Auto-start decision

    func test_autoStartTrue_freshPresentation_allowsTrigger() {
        XCTAssertTrue(
            ImportRecipeView.shouldAutoStartImport(
                autoStart: true,
                hasAutoStarted: false,
                isImporting: false,
                hasDraft: false
            )
        )
    }

    func test_autoStartFalse_neverTriggers() {
        XCTAssertFalse(
            ImportRecipeView.shouldAutoStartImport(
                autoStart: false,
                hasAutoStarted: false,
                isImporting: false,
                hasDraft: false
            ),
            "manual Smart Import / plain ImportRecipeView entry points must never auto-fire"
        )
    }

    func test_alreadyAutoStarted_doesNotTriggerAgain() {
        XCTAssertFalse(
            ImportRecipeView.shouldAutoStartImport(
                autoStart: true,
                hasAutoStarted: true,
                isImporting: false,
                hasDraft: false
            )
        )
    }

    func test_currentlyImporting_doesNotTriggerAgain() {
        XCTAssertFalse(
            ImportRecipeView.shouldAutoStartImport(
                autoStart: true,
                hasAutoStarted: false,
                isImporting: true,
                hasDraft: false
            ),
            "a second automatic (or manual) request must not fire while one is already in flight"
        )
    }

    func test_alreadyHasDraft_doesNotTriggerAgain() {
        XCTAssertFalse(
            ImportRecipeView.shouldAutoStartImport(
                autoStart: true,
                hasAutoStarted: false,
                isImporting: false,
                hasDraft: true
            ),
            "once a draft exists (successful parse, or mid-edit), auto-start must not re-run and clobber it"
        )
    }

    func test_allBlockingConditionsAtOnce_stillDoesNotTrigger() {
        XCTAssertFalse(
            ImportRecipeView.shouldAutoStartImport(
                autoStart: true,
                hasAutoStarted: true,
                isImporting: true,
                hasDraft: true
            )
        )
    }

    // MARK: - B. Single-trigger-per-presentation semantics
    //
    // `.task` itself only runs once per view identity in SwiftUI (it does
    // not re-fire on every body re-evaluation), so the primary regression
    // this guards against is a *manual* re-entrant call path (e.g. a retry
    // or double-tap) incorrectly being treated as eligible for auto-start.
    // This simulates the state transitions across the lifetime of one
    // presentation: initial check → flag flip → subsequent checks.

    func test_stateTransition_acrossOnePresentationLifetime() {
        var hasAutoStarted = false
        let isImporting = false
        let hasDraft = false

        // First check (what `.task` sees on appear): eligible.
        XCTAssertTrue(
            ImportRecipeView.shouldAutoStartImport(
                autoStart: true, hasAutoStarted: hasAutoStarted, isImporting: isImporting, hasDraft: hasDraft
            )
        )

        // The `.task` body flips the flag before awaiting, exactly as
        // `ImportRecipeView` does — simulate that here.
        hasAutoStarted = true

        // Any subsequent re-check within the same presentation (e.g. if
        // body re-evaluates and something re-queried this) must now say no.
        XCTAssertFalse(
            ImportRecipeView.shouldAutoStartImport(
                autoStart: true, hasAutoStarted: hasAutoStarted, isImporting: isImporting, hasDraft: hasDraft
            )
        )
    }

    func test_freshPresentation_afterDismissAndReopen_isEligibleAgain() {
        // A new `SharedImportRequest` sheet presentation constructs a brand
        // new `ImportRecipeView` with fresh `@State` — modeled here as a
        // fresh set of locals with `hasAutoStarted` back at its default.
        let firstPresentationHasAutoStarted = true // left over from a prior, dismissed presentation

        XCTAssertFalse(
            ImportRecipeView.shouldAutoStartImport(
                autoStart: true, hasAutoStarted: firstPresentationHasAutoStarted, isImporting: false, hasDraft: false
            )
        )

        let freshPresentationHasAutoStarted = false // new `@State` for the next presentation
        XCTAssertTrue(
            ImportRecipeView.shouldAutoStartImport(
                autoStart: true, hasAutoStarted: freshPresentationHasAutoStarted, isImporting: false, hasDraft: false
            )
        )
    }

    func test_failedImport_doesNotReEnableAutoStart() {
        // After a failed importLink(), isImporting resets to false (the
        // `defer` in importLink() always clears it) but hasAutoStarted was
        // already flipped true before the call and is never reset on
        // failure — so a subsequent stray re-check must still say no,
        // and only the user's manual "重试" tap (which does not go through
        // this gate at all) can re-invoke importLink().
        XCTAssertFalse(
            ImportRecipeView.shouldAutoStartImport(
                autoStart: true, hasAutoStarted: true, isImporting: false, hasDraft: false
            ),
            "a failed auto-started import must not automatically retry itself"
        )
    }
}

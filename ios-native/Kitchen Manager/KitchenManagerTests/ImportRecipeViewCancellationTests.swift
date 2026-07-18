import XCTest
@testable import KitchenManager

/// Covers the pure "single active import request" decision logic behind
/// `ImportRecipeView.startImport()` (`shouldStartImport`), which every
/// trigger — manual tap, Retry tap, and the auto-start `.task` — funnels
/// through. Full Task-cancellation-propagation coverage (does dismissing
/// actually abort the in-flight HTTP request) lives in
/// `LinkExtractServiceTests` since that's where it's genuinely observable
/// without a fragile full-SwiftUI-lifecycle test.
final class ImportRecipeViewCancellationTests: XCTestCase {

    // MARK: - A. Single active request

    func test_noActiveTask_allowsStarting() {
        XCTAssertTrue(ImportRecipeView.shouldStartImport(hasActiveTask: false))
    }

    func test_activeTask_blocksASecondStart() {
        XCTAssertFalse(
            ImportRecipeView.shouldStartImport(hasActiveTask: true),
            "a second tap (or a concurrent auto-start) must not create a second in-flight request"
        )
    }

    func test_repeatedChecksWhileTaskActive_allConsistentlyRefuse() {
        // Simulates several rapid taps landing while the first request is
        // still in flight — every one of them must see the same "no".
        for _ in 0..<5 {
            XCTAssertFalse(ImportRecipeView.shouldStartImport(hasActiveTask: true))
        }
    }

    func test_taskClearedAfterCompletion_allowsStartingAgain() {
        // Models `startImport()`'s own lifecycle: `importTask` is set while
        // in flight, then set back to `nil` once `importLink()` returns
        // (success, real failure, or cancellation all funnel through the
        // same `importTask = nil` line) — so a subsequent Retry is allowed.
        var hasActiveTask = false

        XCTAssertTrue(ImportRecipeView.shouldStartImport(hasActiveTask: hasActiveTask))
        hasActiveTask = true // startImport() just created the Task
        XCTAssertFalse(ImportRecipeView.shouldStartImport(hasActiveTask: hasActiveTask))
        hasActiveTask = false // the Task's own body cleared it on completion
        XCTAssertTrue(
            ImportRecipeView.shouldStartImport(hasActiveTask: hasActiveTask),
            "Retry after completion (success, failure, or cancellation) must be allowed"
        )
    }

    // MARK: - C. Auto-start and manual tap never race
    //
    // `shouldAutoStartImport` and `shouldStartImport` are evaluated by two
    // different call sites (`.task` vs. the button), but both ultimately
    // gate the same `startImport()` — so once one has begun (hasActiveTask
    // true), the other's own additional guard (`isImporting`) is already
    // true too, and neither can create a second request.

    func test_autoStartAlreadyRunning_manualStartGuardAlsoRefuses() {
        // auto-start already flipped hasAutoStarted and is mid-flight
        XCTAssertFalse(
            ImportRecipeView.shouldAutoStartImport(
                autoStart: true, hasAutoStarted: true, isImporting: true, hasDraft: false
            )
        )
        // and startImport()'s own task guard independently also refuses
        XCTAssertFalse(ImportRecipeView.shouldStartImport(hasActiveTask: true))
    }
}

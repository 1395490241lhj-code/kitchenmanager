import XCTest

/// Covers the reported regression end-to-end through the real UI: a queued
/// share that the user explicitly deletes must not come back after a full
/// app relaunch.
///
/// The app is pointed at a DEBUG-only, app-container-backed queue via launch
/// arguments (`SharedImportConfig.uiTestQueueArgument`) because a UI test
/// process cannot write the app's App Group container. Everything being
/// verified — presentation, the close dialog, `discard`/`snooze`, and the
/// relaunch behavior — is the production code path; only the queue's
/// *location* differs.
final class SharedImportQueueLifecycleUITests: XCTestCase {
    private let importTitle = "导入菜谱"

    private func launch(seed: Bool, reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["UITEST_SEED_EMPTY_HOME", "UITEST_SHARED_IMPORT_QUEUE"]
        if reset { arguments.append("UITEST_SHARED_IMPORT_RESET") }
        if seed { arguments.append("UITEST_SEED_SHARED_IMPORT") }
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits for the shared-import sheet, then closes it with the given
    /// dialog choice.
    private func closeSharedImportSheet(in app: XCUIApplication, choosing choice: String) {
        XCTAssertTrue(
            app.navigationBars.staticTexts[importTitle].waitForExistence(timeout: 15),
            "a freshly queued share must be presented on launch"
        )
        let close = app.buttons["关闭"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()

        let decision = app.buttons[choice]
        XCTAssertTrue(decision.waitForExistence(timeout: 10), "closing must ask what to do with the queued share")
        decision.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts[importTitle].waitForNonExistence(timeout: 10),
            "the import sheet should dismiss after the decision"
        )
    }

    /// The bug: a share the user dealt with reappeared and re-imported on
    /// every cold launch, because dismissal was only an in-memory snooze.
    func testDeletedSharedImportDoesNotReappearAfterRelaunch() {
        let firstLaunch = launch(seed: true, reset: true)
        closeSharedImportSheet(in: firstLaunch, choosing: "删除此次导入")
        attachScreenshot(of: firstLaunch, named: "after-delete")
        firstLaunch.terminate()

        // Cold relaunch, nothing re-seeded: the deleted request is gone.
        let relaunch = launch(seed: false, reset: false)
        XCTAssertTrue(relaunch.buttons["home.primary.action.button"].waitForExistence(timeout: 15))
        XCTAssertFalse(
            relaunch.navigationBars.staticTexts[importTitle].waitForExistence(timeout: 8),
            "a deleted shared import must never be presented again"
        )
        attachScreenshot(of: relaunch, named: "relaunch-after-delete")
    }

    /// "稍后处理" keeps the link but must not re-trigger recognition on
    /// every launch either — and it must stay reachable from Home.
    func testDeferredSharedImportDoesNotAutoPresentAfterRelaunch() {
        let firstLaunch = launch(seed: true, reset: true)
        closeSharedImportSheet(in: firstLaunch, choosing: "稍后处理")
        firstLaunch.terminate()

        let relaunch = launch(seed: false, reset: false)
        XCTAssertTrue(relaunch.buttons["home.primary.action.button"].waitForExistence(timeout: 15))
        XCTAssertFalse(
            relaunch.navigationBars.staticTexts[importTitle].waitForExistence(timeout: 8),
            "a deferred shared import must not auto-present or auto-import again"
        )
        // ...but it is not lost: Home shows the pending-shares entry point.
        XCTAssertTrue(
            relaunch.buttons["home.pending.shares.row"].waitForExistence(timeout: 10),
            "a deferred share must remain reachable from an explicit Home entry point"
        )
        attachScreenshot(of: relaunch, named: "relaunch-after-defer")
    }

    /// The Home entry point exists only when something is actually pending.
    func testPendingSharesEntryPointIsAbsentWhenNothingIsDeferred() {
        let app = launch(seed: false, reset: true)
        XCTAssertTrue(app.buttons["home.primary.action.button"].waitForExistence(timeout: 15))
        XCTAssertFalse(
            app.buttons["home.pending.shares.row"].waitForExistence(timeout: 5),
            "no deferred share means no Home entry point"
        )
    }

    /// From the pending list the user can continue the import, and deleting
    /// updates the entry point (here: the last one, so it disappears).
    func testPendingShareCanBeResumedAndDeletedFromTheList() {
        let app = launch(seed: true, reset: true)
        closeSharedImportSheet(in: app, choosing: "稍后处理")

        let entry = app.buttons["home.pending.shares.row"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()

        XCTAssertTrue(app.navigationBars.staticTexts["待处理的分享"].waitForExistence(timeout: 10))
        let resume = app.buttons["pending.share.resume.button"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()

        // Continuing brings the ordinary import screen back.
        XCTAssertTrue(
            app.navigationBars.staticTexts[importTitle].waitForExistence(timeout: 15),
            "继续导入 must reopen the import screen"
        )
        attachScreenshot(of: app, named: "resumed-from-pending-list")

        // Put it back in the list, then delete it from there.
        closeSharedImportSheet(in: app, choosing: "稍后处理")
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["待处理的分享"].waitForExistence(timeout: 10))

        let delete = app.buttons["pending.share.delete.button"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()

        // Deleting the only pending share closes the list and removes the row.
        XCTAssertTrue(
            entry.waitForNonExistence(timeout: 10),
            "the Home entry point must disappear once nothing is pending"
        )
        attachScreenshot(of: app, named: "pending-list-emptied")
    }
}

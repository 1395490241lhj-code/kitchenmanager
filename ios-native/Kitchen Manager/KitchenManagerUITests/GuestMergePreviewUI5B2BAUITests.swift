import XCTest

/// Deterministic UI coverage for the explicit preview boundary. The DEBUG
/// account fixture transport never reaches a real server or mutation path.
final class GuestMergePreviewUI5B2BAUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launchOwner(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_ACCOUNT_OWNER", "UITEST_ACCOUNT_TEST"] + extra
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

    func testAccountAndPromptDoNotShowPreviewBeforeExplicitTap() throws {
        let app = launchOwner()
        XCTAssertTrue(app.buttons["account.merge.link"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.staticTexts["合并库存"].exists)
        XCTAssertFalse(app.buttons["guestMergeRetryPreviewButton"].exists)
        capture(app, named: "merge-prompt-before-tap")
    }

    func testExplicitMergeEntryOwnsPreviewLoadingAndFailureState() throws {
        let app = launchOwner()
        app.buttons["account.merge.link"].tap()

        XCTAssertTrue(app.staticTexts["无法读取家庭库存"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["guestMergeRetryPreviewButton"].exists)
        XCTAssertFalse(app.buttons["guestMergeConfirmButton"].exists)
        capture(app, named: "merge-preview-explicit-read-failure")
    }

    func testPreviewLoadingIsInsideSheetWithoutConfirmAction() throws {
        let app = launchOwner(extra: ["UITEST_SEED_INVENTORY", "UITEST_MERGE_LOADING"])
        app.buttons["account.merge.link"].tap()
        XCTAssertTrue(app.staticTexts["正在准备合并预览…"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["guestMergeConfirmButton"].exists)
        capture(app, named: "merge-preview-loading")
    }

    func testEmptyRemotePreviewDoesNotPretendToBeMerged() throws {
        let app = launchOwner(extra: ["UITEST_SEED_INVENTORY", "UITEST_MERGE_EMPTY"])
        app.buttons["account.merge.link"].tap()
        XCTAssertTrue(app.staticTexts["合并库存"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["已合并"].exists)
        capture(app, named: "merge-preview-empty-remote")
    }

    func testPreviewCountsArePresentedAfterExplicitRead() throws {
        let app = launchOwner(extra: ["UITEST_SEED_INVENTORY", "UITEST_MERGE_COUNTS"])
        app.buttons["account.merge.link"].tap()
        XCTAssertTrue(waitForPreviewContent(app), "preview counts/conflict content should appear\n\(app.debugDescription)")
        capture(app, named: "merge-preview-counts")
    }

    func testUnauthorizedAndOfflinePreviewErrorsRemainDistinct() throws {
        let unauthorized = launchOwner(extra: ["UITEST_SEED_INVENTORY", "UITEST_MERGE_UNAUTHORIZED"])
        unauthorized.buttons["account.merge.link"].tap()
        XCTAssertTrue(unauthorized.staticTexts["无法读取家庭库存"].waitForExistence(timeout: 10))
        capture(unauthorized, named: "merge-preview-unauthorized")

        let offline = launchOwner(extra: ["UITEST_SEED_INVENTORY", "UITEST_MERGE_OFFLINE"])
        offline.buttons["account.merge.link"].tap()
        XCTAssertTrue(offline.staticTexts["无法读取家庭库存"].waitForExistence(timeout: 10))
        XCTAssertFalse(offline.staticTexts["需要重新登录。"].exists)
        capture(offline, named: "merge-preview-offline")
    }

    func testRetrySuccessAndLegacyRegenerationRemainConfirmableOnlyAfterRead() throws {
        let retry = launchOwner(extra: ["UITEST_SEED_INVENTORY", "UITEST_MERGE_RETRY_SUCCESS"])
        retry.buttons["account.merge.link"].tap()
        XCTAssertTrue(waitForPreviewContent(retry))
        capture(retry, named: "merge-preview-retry-success")

        let legacy = launchOwner(extra: ["UITEST_SEED_INVENTORY", "UITEST_MERGE_LEGACY"])
        legacy.buttons["account.merge.link"].tap()
        XCTAssertTrue(waitForPreviewContent(legacy))
        capture(legacy, named: "merge-preview-legacy-regenerated")
    }

    func testDarkModePreviewRemainsReadable() throws {
        let app = launchOwner(extra: ["UITEST_SEED_INVENTORY", "UITEST_MERGE_COUNTS", "UITEST_FORCE_DARK_APPEARANCE"])
        app.buttons["account.merge.link"].tap()
        XCTAssertTrue(waitForPreviewContent(app))
        capture(app, named: "merge-preview-dark")
    }

    func testAccessibilityXXXLPreviewTopAndBottomRemainReachable() throws {
        let app = launchOwner(extra: [
            "UITEST_SEED_INVENTORY", "UITEST_MERGE_COUNTS",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        let mergeLink = app.buttons["account.merge.link"]
        if !mergeLink.isHittable { app.swipeUp() }
        XCTAssertTrue(mergeLink.waitForExistence(timeout: 5))
        mergeLink.tap()
        XCTAssertTrue(waitForPreviewContent(app))
        capture(app, named: "merge-preview-accessibility-xxxl-top")
        // Reach the actual end of the Form rather than stopping at the first
        // count row. This proves the confirmation action and final warning
        // copy remain above the floating tab bar at XXXL.
        for _ in 0..<6 where !app.buttons["guestMergeConfirmButton"].isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["guestMergeConfirmButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["guestMergeConfirmButton"].isHittable)
        // Continue to the terminal explanatory rows so the capture proves
        // the last content, not merely the first reachable action, clears the
        // floating tab bar.
        app.swipeUp()
        app.swipeUp()
        capture(app, named: "merge-preview-accessibility-xxxl-bottom")
    }

    // MARK: - Floating tab bar must never obstruct the merge flow

    /// Tab bar present on the account page, gone for the whole pushed merge flow,
    /// and back again once the flow is left.
    func testFloatingTabBarIsHiddenThroughoutMergeFlowAndRestoredOnExit() throws {
        let app = launchOwner(extra: ["UITEST_SEED_INVENTORY", "UITEST_MERGE_COUNTS"])

        // Account page keeps its normal floating tab bar.
        XCTAssertTrue(app.tabBars.firstMatch.exists, "账号页应保留正常浮动 Tab Bar")
        XCTAssertTrue(app.tabBars.buttons["我的"].exists)

        // Entering the merge flow hides it entirely.
        app.buttons["account.merge.link"].tap()
        XCTAssertTrue(waitForPreviewContent(app))
        assertNoFloatingTabBar(app, context: "合并预览")

        // Leaving the flow restores it.
        app.buttons["guestMergeDismissLater"].tap()
        XCTAssertTrue(app.buttons["account.merge.link"].waitForExistence(timeout: 10), "应返回账号页")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5), "退出合并流程后 Tab Bar 应恢复")
        XCTAssertTrue(app.tabBars.buttons["我的"].exists)
    }

    /// Every reachable state of the flow — not just the happy preview — must be
    /// free of the floating tab bar.
    func testTabBarStaysHiddenAcrossLoadingErrorPreviewAndConflictStates() throws {
        let states: [(String, [String], (XCUIApplication) -> Bool)] = [
            ("loading", ["UITEST_SEED_INVENTORY", "UITEST_MERGE_LOADING"],
             { $0.staticTexts["正在准备合并预览…"].waitForExistence(timeout: 5) }),
            ("fetch error", [],
             { $0.staticTexts["无法读取家庭库存"].waitForExistence(timeout: 10) }),
            ("unauthorized", ["UITEST_SEED_INVENTORY", "UITEST_MERGE_UNAUTHORIZED"],
             { $0.staticTexts["无法读取家庭库存"].waitForExistence(timeout: 10) }),
            ("offline", ["UITEST_SEED_INVENTORY", "UITEST_MERGE_OFFLINE"],
             { $0.staticTexts["无法读取家庭库存"].waitForExistence(timeout: 10) }),
            ("empty remote", ["UITEST_SEED_INVENTORY", "UITEST_MERGE_EMPTY"],
             { $0.staticTexts["合并库存"].waitForExistence(timeout: 10) }),
            ("counts / conflict", ["UITEST_SEED_INVENTORY", "UITEST_MERGE_COUNTS"],
             { self.waitForPreviewContent($0) }),
            ("retry success", ["UITEST_SEED_INVENTORY", "UITEST_MERGE_RETRY_SUCCESS"],
             { self.waitForPreviewContent($0) }),
            ("legacy regenerated", ["UITEST_SEED_INVENTORY", "UITEST_MERGE_LEGACY"],
             { self.waitForPreviewContent($0) })
        ]

        for (name, extra, settled) in states {
            let app = launchOwner(extra: extra)
            app.buttons["account.merge.link"].tap()
            XCTAssertTrue(settled(app), "\(name): 状态未就绪\n\(app.debugDescription)")
            assertNoFloatingTabBar(app, context: name)
            app.terminate()
        }
    }

    /// The empty-remote confirm action must be fully on screen and tappable, not
    /// sitting behind the bar.
    func testEmptyRemoteConfirmActionIsFullyVisibleAndHittable() throws {
        let app = launchOwner(extra: ["UITEST_SEED_INVENTORY", "UITEST_MERGE_EMPTY"])
        app.buttons["account.merge.link"].tap()
        XCTAssertTrue(app.staticTexts["合并库存"].waitForExistence(timeout: 10))
        assertNoFloatingTabBar(app, context: "empty remote")

        let confirm = app.buttons["guestMergeConfirmButton"]
        XCTAssertTrue(scrollUntilHittable(confirm, in: app), "“确认合并库存”应可滚动到达")
        assertFullyOnScreen(confirm, in: app, label: "确认合并库存")
    }

    /// Same for the counts and legacy-regenerated previews.
    func testCountsAndLegacyConfirmActionsAreScrollableAndHittable() throws {
        for (name, extra) in [("counts", "UITEST_MERGE_COUNTS"), ("legacy", "UITEST_MERGE_LEGACY")] {
            let app = launchOwner(extra: ["UITEST_SEED_INVENTORY", extra])
            app.buttons["account.merge.link"].tap()
            XCTAssertTrue(waitForPreviewContent(app), "\(name): 预览未就绪")
            assertNoFloatingTabBar(app, context: name)

            let confirm = app.buttons["guestMergeConfirmButton"]
            XCTAssertTrue(scrollUntilHittable(confirm, in: app), "\(name): 确认按钮应可滚动到达")
            assertFullyOnScreen(confirm, in: app, label: "\(name) 确认合并库存")
            app.terminate()
        }
    }

    /// The destructive cancel action at XXXL must also be fully reachable.
    func testAccessibilityXXXLCancelActionIsFullyVisibleAndHittable() throws {
        let app = launchOwner(extra: [
            "UITEST_SEED_INVENTORY", "UITEST_MERGE_COUNTS",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        let mergeLink = app.buttons["account.merge.link"]
        if !mergeLink.isHittable { app.swipeUp() }
        mergeLink.tap()
        XCTAssertTrue(waitForPreviewContent(app))
        assertNoFloatingTabBar(app, context: "XXXL preview")

        let cancel = app.buttons["guestMergeCancelButton"]
        XCTAssertTrue(scrollUntilHittable(cancel, in: app), "XXXL 下“取消本次合并”应可滚动到达")
        assertFullyOnScreen(cancel, in: app, label: "XXXL 取消本次合并")
    }

    // MARK: - Tab bar helpers

    /// No tab bar, and no stray floating "我的" pill either — at Accessibility
    /// sizes the minimized tab bar collapses to exactly that circular button, and
    /// it was overlapping the planned-item counts.
    private func assertNoFloatingTabBar(
        _ app: XCUIApplication, context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(
            app.tabBars.firstMatch.exists,
            "\(context): 合并流程内不应存在浮动 Tab Bar",
            file: file, line: line
        )
        XCTAssertFalse(
            app.tabBars.buttons["我的"].exists,
            "\(context): 不应残留悬浮的“我的”圆形 Tab 按钮",
            file: file, line: line
        )
    }

    /// Scrolls until `element` is not merely hittable but *entirely* inside the
    /// window, deciding when to stop from scroll progress rather than a count.
    ///
    /// Stopping at the first `isHittable` was the real defect behind the
    /// intermittent XXXL cancel-action failure: at Accessibility sizes that
    /// button is ~93pt tall, and it reports hittable while its lower edge is
    /// still ~60pt below the window, so `assertFullyOnScreen` then failed.
    /// Whether a run passed depended on exactly where scrolling happened to
    /// stop, which is why no fixed swipe count was ever reliable.
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch
        let tolerance: CGFloat = 1

        func fullyVisible() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let frame = element.frame
            let bounds = window.frame
            return frame.minY >= bounds.minY - tolerance && frame.maxY <= bounds.maxY + tolerance
        }

        if fullyVisible() { return true }

        var attempts = 0
        var noProgress = 0
        var recent: [String] = []
        let hardSafetyCap = 80

        while attempts < hardSafetyCap {
            let existedBefore = element.exists
            let midBefore = existedBefore ? element.frame.midY : .greatestFiniteMagnitude

            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
            start.press(forDuration: 0.05, thenDragTo: end)
            attempts += 1

            if fullyVisible() { return true }

            let existsNow = element.exists
            let midNow = existsNow ? element.frame.midY : .greatestFiniteMagnitude
            recent.append("attempt=" + String(attempts) + " exists=" + String(existsNow)
                + " frame=" + (existsNow ? String(describing: element.frame) : "-"))
            if recent.count > 10 { recent.removeFirst() }

            // No-progress only counts once the element is actually in the tree.
            // Before it appears, `exists` stays false while the page really is
            // scrolling, and counting that as stalled aborted the search on the
            // very swipe that would have revealed the button.
            if existsNow {
                let moved = !existedBefore || abs(midNow - midBefore) > 1
                noProgress = moved ? 0 : noProgress + 1
                if noProgress >= 4 { break }
            } else {
                noProgress = 0
            }
        }

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "scroll-failure"
        shot.lifetime = .keepAlways
        add(shot)
        XCTFail("无法把元素完整滚入窗口：attempts=" + String(attempts)
            + " noProgress=" + String(noProgress)
            + " window=" + String(describing: window.frame)
            + "\n" + recent.joined(separator: "\n")
            + "\n" + app.debugDescription)
        return false
    }

    /// Fully on screen and clear of the window's bottom edge — a button whose lower
    /// half sits behind a bar still reports `isHittable` from its midpoint.
    private func assertFullyOnScreen(
        _ element: XCUIElement, in app: XCUIApplication, label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let window = app.windows.firstMatch.frame
        let frame = element.frame
        XCTAssertTrue(element.isHittable, "\(label) 不可点击", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, window.minY, "\(label) 顶部超出屏幕", file: file, line: line)
        XCTAssertLessThanOrEqual(
            frame.maxY, window.maxY,
            "\(label) 底部 \(frame.maxY) 超出窗口 \(window.maxY)",
            file: file, line: line
        )
    }

    /// UI-5B2B-B2A renamed 预计新增/预计更新 to 将新增/将更新, so the old label no
    /// longer matches. Anchored on the section header as well, which is at the top
    /// of the Form and therefore rendered without scrolling at every text size.
    private func waitForPreviewContent(_ app: XCUIApplication) -> Bool {
        app.staticTexts["预计结果"].waitForExistence(timeout: 5)
            || app.buttons["guestMergeConfirmButton"].waitForExistence(timeout: 5)
            || app.staticTexts["将新增, 3 条"].waitForExistence(timeout: 5)
            || app.staticTexts["可能重复, 1 条"].waitForExistence(timeout: 5)
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

import XCTest

/// UI-5B2B-B2A: corrected preview summary, read-only resolved review, and
/// scope-accurate confirmation copy.
///
/// Every scenario runs against the DEBUG-only `.previewReady` summary fixtures.
/// Nothing here touches a real account, token, network, `SyncCoordinator`, or
/// mutation path, and nothing taps confirm.
final class GuestMergeSummaryUI5B2BB2AUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launchSummary(_ fixture: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_ACCOUNT_OWNER", "UITEST_ACCOUNT_TEST", fixture] + extra
        app.launch()
        openMergeFlow(app)
        return app
    }

    /// Waits on the fixture's own seed marker rather than sleeping, then walks
    /// 我的 → 账号 → 合并库存.
    private func openMergeFlow(_ app: XCUIApplication) {
        XCTAssertTrue(
            element(app, "uitest.summaryFixtureSeeded").waitForExistence(timeout: 20),
            "summary fixture seed marker never appeared"
        )
        let myTab = app.tabBars.buttons["我的"]
        XCTAssertTrue(myTab.waitForExistence(timeout: 10))
        myTab.tap()
        let accountEntry = app.buttons["settings.account.entry"]
        XCTAssertTrue(accountEntry.waitForExistence(timeout: 10))
        accountEntry.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["账号"].waitForExistence(timeout: 10))
        let mergeLink = app.buttons["account.merge.link"]
        if !mergeLink.isHittable { app.swipeUp() }
        XCTAssertTrue(mergeLink.waitForExistence(timeout: 10))
        mergeLink.tap()
        // Anchor on the top of the summary section, not the confirm button: the
        // Form renders lazily, so the button below the fold is genuinely absent
        // from the tree until scrolled to.
        XCTAssertTrue(
            element(app, "guestMergeSummaryWillCreate").waitForExistence(timeout: 15),
            "应进入合并预览页\n\(app.debugDescription)"
        )
    }

    /// The confirm button sits below the fold; scroll it into the tree first.
    private func confirmButton(_ app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["guestMergeConfirmButton"]
        XCTAssertTrue(scrollTo(app, button), "应能滚动到确认按钮\n\(app.debugDescription)")
        return button
    }

    /// Identifiers on a `LabeledContent` can resolve to more than one element in
    /// a Form, so every lookup below is explicitly first-match.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func value(_ app: XCUIApplication, _ identifier: String) -> String? {
        let target = element(app, identifier)
        guard target.exists else { return nil }
        return target.label
    }

    private func group(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        element(app, "guestMergeReviewGroup-\(name)")
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertNoTabBar(_ app: XCUIApplication, _ context: String) {
        XCTAssertFalse(app.tabBars.firstMatch.exists, "\(context): 合并流程内不应有 Tab Bar")
    }

    @discardableResult
    private func scrollTo(_ app: XCUIApplication, _ element: XCUIElement, maxSwipes: Int = 25) -> Bool {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
        return element.exists && element.isHittable
    }

    private func openResolvedReview(_ app: XCUIApplication) {
        let link = app.buttons["guestMergeResolvedReviewLink"]
        XCTAssertTrue(scrollTo(app, link), "应能滚动到查看处理结果入口\n\(app.debugDescription)")
        link.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["处理结果"].waitForExistence(timeout: 10))
    }

    // MARK: - Mixed summary

    func testMixedSummaryShowsEveryCategoryWithAccurateCounts() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_MIXED")

        // 2 plain creates (面粉/白糖) + keepBoth fork (鸡蛋) = 3; 酱油 update +
        // same-ID keepLocal 豆腐 = 2; 大米 keepRemote; 牛奶 skip; 青椒/土豆
        // unresolved; 食盐 exact match.
        XCTAssertEqual(value(app, "guestMergeSummaryWillCreate"), "计划新增, 3 条")
        XCTAssertEqual(value(app, "guestMergeSummaryWillUpdate"), "计划更新, 2 条")
        XCTAssertEqual(value(app, "guestMergeSummaryKeptRemote"), "保留家庭（不上传）, 1 条")
        XCTAssertEqual(value(app, "guestMergeSummarySkipped"), "本次跳过, 1 条")
        XCTAssertEqual(value(app, "guestMergeSummaryStillNeedsDecision"), "仍待处理, 2 条")
        XCTAssertEqual(value(app, "guestMergeSummaryNothingToDo"), "完全一致（无需处理）, 1 条")

        assertNoTabBar(app, "mixed summary")
        attach(app, named: "summary-mixed")
    }

    func testKeepRemoteAndSkipCountsAreVisibleAtAll() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_MIXED")
        // The regression this phase fixes: both were absent from every count.
        XCTAssertTrue(app.staticTexts["保留家庭（不上传）"].exists, "保留家庭数量必须可见")
        XCTAssertTrue(app.staticTexts["本次跳过"].exists, "本次跳过数量必须可见")
    }

    func testConflictReasonBreakdownCountsOnlyUnresolvedConflicts() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_MIXED")
        // Three candidates carry quantityMismatch (豆腐 keepLocal, 鸡蛋 keepBoth,
        // 青椒 unresolved); only 青椒 still needs a decision.
        XCTAssertEqual(value(app, "guestMergeConflictReason-quantityMismatch"), "数量不同, 1 条")
        // 牛奶's expiry conflict is resolved, so the row must be gone entirely.
        XCTAssertFalse(
            element(app, "guestMergeConflictReason-expiryMismatch").exists,
            "已解决的保质期冲突不得再出现在需要处理的冲突里"
        )
        // 大米's metadata conflict is resolved too.
        XCTAssertFalse(element(app, "guestMergeConflictReason-metadataMismatch").exists)
        // 土豆 is an unresolved ambiguous duplicate and must still be listed.
        XCTAssertEqual(value(app, "guestMergeConflictReason-ambiguousDuplicate"), "可能重复, 1 条")
    }

    // MARK: - Resolved review entry

    func testResolvedReviewEntryReportsResolvedTotalIncludingSkips() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_MIXED")
        let link = app.buttons["guestMergeResolvedReviewLink"]
        XCTAssertTrue(scrollTo(app, link))
        XCTAssertTrue(link.label.contains("查看处理结果"), link.label)
        XCTAssertTrue(link.label.contains("已处理 4 条"), link.label)
        XCTAssertTrue(link.label.contains("其中 1 条本次跳过"), link.label)
        for banned in ["已上传", "已合并"] {
            XCTAssertFalse(link.label.contains(banned), "入口文案不得声称已经上传：\(link.label)")
        }
    }

    func testResolvedReviewEntryIsAbsentWhenNothingHasBeenDecided() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_NO_CONFLICT")
        XCTAssertFalse(
            app.buttons["guestMergeResolvedReviewLink"].exists,
            "没有任何已记录选择时不应出现查看处理结果入口"
        )
    }

    // MARK: - Read-only review screen

    func testResolvedReviewIsReadOnlyWithNoChoiceControls() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_RESOLVED_ONLY")
        openResolvedReview(app)

        // No B1 choice rows, and no segmented control anywhere.
        for choice in ["keepLocal", "keepRemote", "keepBoth", "skip"] {
            let matching = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "guestMergeConflictChoice-\(choice)")
            )
            XCTAssertEqual(matching.count, 0, "只读页面不得出现 \(choice) 选择按钮")
        }
        XCTAssertEqual(app.segmentedControls.count, 0, "不得恢复 segmented picker")
        XCTAssertFalse(app.buttons["guestMergeConfirmButton"].exists, "只读页面不应有确认按钮")
        assertNoTabBar(app, "resolved review")

        // The footer must not assert a per-item upload state in either direction.
        let footer = element(app, "guestMergeReviewFooter")
        XCTAssertTrue(footer.exists, "只读页面应有中性说明 footer")
        XCTAssertTrue(footer.label.contains("不代表各条目的当前上传状态"), footer.label)
        for banned in ["已上传", "已合并", "尚未上传"] {
            XCTAssertEqual(app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", banned)
            ).count, 0, "只读页面不得声称已经 \(banned)")
        }
        attach(app, named: "resolved-review-collapsed")
    }

    func testCollapsedGroupsShowStableOrderAndCorrectCounts() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_RESOLVED_ONLY")
        openResolvedReview(app)

        XCTAssertEqual(value(app, "guestMergeReviewResolvedCount"), "已处理, 4 条")
        XCTAssertEqual(value(app, "guestMergeReviewSkippedCount"), "其中本次跳过, 1 条")

        // One candidate per group in this fixture, in the fixed display order.
        var previousMaxY: CGFloat = 0
        for group in ["keptLocal", "keptRemote", "keptBoth", "skipped"] {
            let header = self.group(app, group)
            XCTAssertTrue(header.exists, "分组 \(group) 应存在")
            XCTAssertTrue(header.label.contains("1 条"), "\(group) 数量应为 1 条：\(header.label)")
            XCTAssertGreaterThanOrEqual(header.frame.minY, previousMaxY - 1, "\(group) 分组顺序应固定")
            previousMaxY = header.frame.maxY
        }
    }

    func testExpandingAGroupRevealsCandidateChoiceAndConsequence() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_RESOLVED_ONLY")
        openResolvedReview(app)

        let header = group(app, "keptLocal")
        // Collapsed by default: the candidate is not rendered yet.
        XCTAssertFalse(app.staticTexts["豆腐"].exists, "分组默认应折叠")
        header.tap()

        let candidate = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "guestMergeReviewCandidate-"))
            .firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5), "展开后应显示 candidate")
        XCTAssertTrue(candidate.label.contains("豆腐"), candidate.label)
        XCTAssertTrue(candidate.label.contains("当前选择：保留本机"), candidate.label)
        // The B1 consequence copy, reused verbatim.
        XCTAssertTrue(candidate.label.contains("更新家庭库存里的同一条记录"), candidate.label)
        // Both differing values are shown.
        XCTAssertTrue(candidate.label.contains("本机"), candidate.label)
        XCTAssertTrue(candidate.label.contains("家庭"), candidate.label)

        attach(app, named: "resolved-review-expanded")
    }

    func testCandidateOrderWithinAGroupFollowsPlanOrder() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_LONG_RESOLVED")
        openResolvedReview(app)

        let header = group(app, "skipped")
        XCTAssertTrue(scrollTo(app, header))
        header.tap()

        // Order is asserted from the element tree, not from frame geometry:
        // absolute Y is not comparable across scrolls, since scrolling is what
        // brings each later row into the tree in the first place.
        //
        // The skipped group holds 已处理食材4, 8, 12, 16, 20 — every fourth
        // candidate — in plan order.
        let expected = [4, 8, 12, 16, 20].map {
            String(format: "guestMergeReviewCandidate-00000000-0000-0000-0000-0000000007%02d", $0)
        }
        var rendered: [String] = []
        var swipes = 0
        repeat {
            let ids = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "guestMergeReviewCandidate-"))
                .allElementsBoundByIndex
                .map(\.identifier)
            for id in ids where !rendered.contains(id) { rendered.append(id) }
            if rendered.count >= 3 { break }
            app.swipeUp()
            swipes += 1
        } while swipes < 15

        XCTAssertGreaterThanOrEqual(rendered.count, 3, "展开后应至少渲染 3 条候选：\(rendered)")
        // Every rendered row belongs to this group, and their relative order
        // matches plan order exactly.
        XCTAssertEqual(
            rendered,
            expected.filter(rendered.contains),
            "分组内候选顺序必须与 plan 原顺序一致"
        )
    }

    func testLongResolvedListScrollsToTheLastGroup() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_LONG_RESOLVED")
        openResolvedReview(app)
        XCTAssertEqual(value(app, "guestMergeReviewResolvedCount"), "已处理, 20 条")
        attach(app, named: "resolved-review-long-list")

        let last = group(app, "skipped")
        XCTAssertTrue(scrollTo(app, last), "应能滚动到最后一个分组")
        assertNoTabBar(app, "long resolved list")
    }

    // MARK: - Confirmation copy

    func testAllSkipConfirmationNeverPromisesAnUpload() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_ALL_SKIP")
        XCTAssertEqual(confirmButton(app).label, "完成，不上传任何条目")
        XCTAssertEqual(
            value(app, "guestMergeConfirmSupportingCopy"),
            "本次不会上传任何库存；家庭和本机数据保持现在的样子。"
        )
        XCTAssertFalse(confirmButton(app).label.contains("确认合并库存"))
        // Never disabled — existing behavior preserved, only the wording changed.
        XCTAssertTrue(confirmButton(app).isEnabled)
        attach(app, named: "summary-all-skip")
    }

    func testKeepRemoteOnlyConfirmationUsesTheZeroUploadWording() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_KEEP_REMOTE_ONLY")
        XCTAssertEqual(value(app, "guestMergeSummaryKeptRemote"), "保留家庭（不上传）, 3 条")
        XCTAssertEqual(confirmButton(app).label, "完成，不上传任何条目")
        attach(app, named: "summary-keep-remote-only")
    }

    func testUnresolvedWithUploadableUsesThePartialMergeButton() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_UNRESOLVED_UPLOADABLE")
        // 面粉 create + 酱油 update + 豆腐 same-ID keepLocal → 1 create, 2 updates.
        // Read the summary row first: scrolling to the confirm button moves the
        // summary section out of the rendered tree.
        XCTAssertEqual(value(app, "guestMergeSummaryStillNeedsDecision"), "仍待处理, 2 条")
        XCTAssertEqual(confirmButton(app).label, "先合并其余 3 条")
        XCTAssertEqual(
            value(app, "guestMergeConfirmSupportingCopy"),
            "还有 2 条待处理，本次不会上传这些条目。"
        )
        attach(app, named: "summary-unresolved")
    }

    func testUnresolvedWithZeroUploadableNeverShowsMergeTheRemainingZero() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_UNRESOLVED_ZERO_UPLOAD")
        let title = confirmButton(app).label
        XCTAssertEqual(title, "确认当前处理结果")
        XCTAssertFalse(title.contains("0 条"), "不得出现“先合并其余 0 条”：\(title)")
        XCTAssertEqual(
            value(app, "guestMergeConfirmSupportingCopy"),
            "目前没有可上传条目；确认后仍有 2 条冲突需要处理。"
        )
        attach(app, named: "summary-zero-upload-unresolved")
    }

    func testOrdinaryMergeCopyDoesNotRegress() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_NO_CONFLICT")
        XCTAssertEqual(confirmButton(app).label, "确认合并库存")
        XCTAssertEqual(value(app, "guestMergeConfirmSupportingCopy"), "计划新增 2 条、计划更新 1 条。")
        // The long-standing preview footnotes are untouched.
        XCTAssertTrue(app.staticTexts["只合并库存，不会上传购物清单、计划或菜谱。"].exists)
        XCTAssertTrue(app.staticTexts["可以随时取消，也可以稍后处理。"].exists)
        // No unresolved conflicts, so no 仍待处理 row.
        XCTAssertFalse(element(app, "guestMergeSummaryStillNeedsDecision").exists)
    }

    // MARK: - Restart

    func testResolvedReviewIsStillReachableAfterRelaunch() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_RESOLVED_ONLY")
        openResolvedReview(app)
        app.terminate()

        // A non-terminal session is resumed from persistence, so the recorded
        // choices — and this screen — survive a restart.
        let relaunched = XCUIApplication()
        relaunched.launchArguments = [
            "UITEST_ACCOUNT_OWNER", "UITEST_ACCOUNT_TEST", "UITEST_MERGE_SUMMARY_RESOLVED_ONLY"
        ]
        relaunched.launch()
        openMergeFlow(relaunched)
        openResolvedReview(relaunched)
        XCTAssertEqual(value(relaunched, "guestMergeReviewResolvedCount"), "已处理, 4 条")
    }

    // MARK: - Appearance and accessibility

    func testDarkModeSummaryRemainsReadable() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_MIXED", extra: ["UITEST_FORCE_DARK_APPEARANCE"])
        XCTAssertTrue(app.staticTexts["保留家庭（不上传）"].exists)
        XCTAssertTrue(app.staticTexts["仍待处理"].exists)
        assertNoTabBar(app, "dark")
        attach(app, named: "summary-dark")
    }

    func testAccessibilityXXXLKeepsEveryCountReachableAndUntruncated() throws {
        let app = launchSummary(
            "UITEST_MERGE_SUMMARY_MIXED",
            extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        )
        assertNoTabBar(app, "XXXL")
        attach(app, named: "summary-accessibility-xxxl-top")

        let window = app.windows.firstMatch.frame
        for identifier in [
            "guestMergeSummaryWillCreate", "guestMergeSummaryWillUpdate",
            "guestMergeSummaryKeptRemote", "guestMergeSummarySkipped",
            "guestMergeSummaryStillNeedsDecision", "guestMergeSummaryNothingToDo"
        ] {
            let row = element(app, identifier)
            XCTAssertTrue(scrollTo(app, row), "XXXL 下 \(identifier) 应可滚动到达")
            XCTAssertFalse(row.label.contains("…"), "XXXL 下 \(identifier) 出现省略号：\(row.label)")
            XCTAssertLessThanOrEqual(row.frame.maxX, window.maxX + 1, "XXXL 下 \(identifier) 超出屏幕宽度")
        }
        let link = app.buttons["guestMergeResolvedReviewLink"]
        XCTAssertTrue(scrollTo(app, link), "XXXL 下查看处理结果入口应可到达")
        attach(app, named: "summary-accessibility-xxxl-bottom")
    }

    // MARK: - Post-partial-confirm accuracy

    func testResumedAfterPartialConfirmSummaryNeverPromisesTheWholePlan() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_POST_PARTIAL_CONFIRM")

        // This session already uploaded part of the plan, so the confirm copy
        // must not reuse the definite first-pass wording nor invent a remaining
        // count.
        XCTAssertEqual(confirmButton(app).label, "确认当前处理计划")
        let copy = try XCTUnwrap(value(app, "guestMergeConfirmSupportingCopy"))
        XCTAssertEqual(copy, "当前页面汇总本次会话的整体计划，系统会根据当前同步状态继续处理。")
        for banned in ["计划新增", "先合并其余", "尚未上传", "已经上传", "已上传", "已经合并", "已合并",
                       "不会上传任何库存", "文案", "重新定义"] {
            XCTAssertFalse(copy.contains(banned), "已部分上传的会话不得出现“\(banned)”：\(copy)")
        }
        assertNoTabBar(app, "post-partial summary")
        attach(app, named: "summary-post-partial-confirm")
    }

    func testResumedAfterPartialConfirmReviewFooterIsNeutral() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_POST_PARTIAL_CONFIRM")
        openResolvedReview(app)

        let footer = element(app, "guestMergeReviewFooter")
        XCTAssertTrue(footer.exists)
        XCTAssertTrue(footer.label.contains("不代表各条目的当前上传状态"), footer.label)
        for banned in ["尚未上传", "已上传", "已合并"] {
            XCTAssertFalse(footer.label.contains(banned), footer.label)
        }
        // Still read-only.
        XCTAssertEqual(app.segmentedControls.count, 0)
        for choice in ["keepLocal", "keepRemote", "keepBoth", "skip"] {
            XCTAssertEqual(app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "guestMergeConflictChoice-\(choice)")
            ).count, 0)
        }
        assertNoTabBar(app, "post-partial review")
    }

    func testPostPartialCopyStillAccurateAfterRelaunch() throws {
        let app = launchSummary("UITEST_MERGE_SUMMARY_POST_PARTIAL_CONFIRM")
        XCTAssertEqual(confirmButton(app).label, "确认当前处理计划")
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launchArguments = [
            "UITEST_ACCOUNT_OWNER", "UITEST_ACCOUNT_TEST", "UITEST_MERGE_SUMMARY_POST_PARTIAL_CONFIRM"
        ]
        relaunched.launch()
        openMergeFlow(relaunched)
        XCTAssertEqual(confirmButton(relaunched).label, "确认当前处理计划",
                       "重启后仍应保持已部分上传会话的中性文案")
    }
}

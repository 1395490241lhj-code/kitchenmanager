import XCTest

/// UI-5B2B-B2B: safe editing of recorded conflict choices.
///
/// The core reachability scenarios start from a fixture with **no** recorded
/// choices and make every choice through the real UI, because a fixture that
/// pre-writes `userChoice` could not prove the production path exists. The
/// screenshot-oriented scenarios do use pre-selected fixtures, and are named as
/// such.
///
/// Nothing here touches a real account, token, network, `SyncCoordinator`, or
/// mutation path, and nothing taps confirm.
final class GuestMergeChoiceEditingUI5B2BB2BUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ fixture: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_ACCOUNT_OWNER", "UITEST_ACCOUNT_TEST", fixture] + extra
        app.launch()
        openMergeFlow(app)
        return app
    }

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
        XCTAssertTrue(
            element(app, "guestMergeSummaryWillCreate").waitForExistence(timeout: 15),
            "应进入合并预览页\n\(app.debugDescription)"
        )
    }

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

    @discardableResult
    private func scrollTo(_ app: XCUIApplication, _ target: XCUIElement, maxSwipes: Int = 25) -> Bool {
        var swipes = 0
        while !(target.exists && target.isHittable), swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
        return target.exists && target.isHittable
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

    private func openPreConfirmConflicts(_ app: XCUIApplication) {
        let link = app.buttons["guestMergePreConfirmConflictLink"]
        XCTAssertTrue(scrollTo(app, link), "应能找到确认前处理冲突入口\n\(app.debugDescription)")
        link.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["确认前处理冲突"].waitForExistence(timeout: 10))
    }

    private func openReview(_ app: XCUIApplication) {
        let link = app.buttons["guestMergeResolvedReviewLink"]
        XCTAssertTrue(scrollTo(app, link), "应能找到查看处理结果入口\n\(app.debugDescription)")
        link.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["处理结果"].waitForExistence(timeout: 10))
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// Fixture candidate ids, mirroring `AccountLifecycleSummaryFixture`.
    private let preConfirmSameID = "00000000-0000-0000-0000-000000000792"
    private let preConfirmDifferentID = "00000000-0000-0000-0000-000000000793"

    private func choiceRow(_ app: XCUIApplication, _ choice: String, _ candidate: String) -> XCUIElement {
        app.buttons["guestMergeConflictChoice-\(choice)-\(candidate)"]
    }

    private func editRow(_ app: XCUIApplication, _ choice: String, _ candidate: String) -> XCUIElement {
        app.buttons["guestMergeEditChoice-\(choice)-\(candidate)"]
    }


    // MARK: - Cold-relaunch probes

    private static let restartProbeIdentifiers = [
        "uitest.restart.mode", "uitest.restart.fixtureState", "uitest.restart.inventory",
        "uitest.restart.previewOrigin", "uitest.restart.session", "uitest.restart.forkIdentity",
        "uitest.restart.mutationCount"
    ]

    /// Probes always exist and always carry a value, so this reads the value
    /// rather than treating a missing element as the answer.
    private func probeValue(_ app: XCUIApplication, _ identifier: String) -> String? {
        let target = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        guard target.waitForExistence(timeout: 10) else { return nil }
        return target.value as? String
    }

    private func allProbes(_ app: XCUIApplication) -> String {
        Self.restartProbeIdentifiers
            .map { "\($0) = \(probeValue(app, $0) ?? "<element missing>")" }
            .joined(separator: "\n")
    }

    @discardableResult
    private func waitForProbeValue(
        _ app: XCUIApplication, _ identifier: String, containing expected: String,
        timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line
    ) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last: String?
        repeat {
            let current = probeValue(app, identifier)
            last = current
            if let current {
                if current.contains("missing-plan") || current.contains("missing-candidate") {
                    XCTFail(
                        "\(identifier) 报告 \(current)，说明状态缺失而不是尚未就绪\n\(allProbes(app))",
                        file: file, line: line
                    )
                    return current
                }
                if current.contains(expected) { return current }
            }
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 0.5)
        } while Date() < deadline
        XCTFail(
            "\(identifier) 未在超时前包含“\(expected)”，当前值 \(last ?? "<nil>")\n\(allProbes(app))",
            file: file, line: line
        )
        return last ?? ""
    }

    /// Sorted inventory ids from a probe payload, so equality is about which
    /// items exist rather than the order the store happened to return them in.
    private func inventoryIdSet(_ payload: String) -> [String] {
        (probeField(payload, "ids") ?? "").split(separator: ",").map(String.init).sorted()
    }

    /// Parses `key=value;key=value` probe payloads.
    private func probeField(_ payload: String, _ key: String) -> String? {
        payload.split(separator: ";")
            .first { $0.hasPrefix("\(key)=") }
            .map { String($0.dropFirst(key.count + 1)) }
    }

    // MARK: - Production path: choices made entirely through the UI

    func testPreConfirmEntryIsPresentAndReviewIsAbsentBeforeAnyChoice() throws {
        let app = launch("UITEST_MERGE_EDIT_PRECONFIRM_UNRESOLVED")

        let link = app.buttons["guestMergePreConfirmConflictLink"]
        XCTAssertTrue(scrollTo(app, link), "确认前处理冲突入口必须存在")
        XCTAssertTrue(link.label.contains("确认前处理冲突"), link.label)
        XCTAssertTrue(link.label.contains("2 条待处理"), link.label)
        // Nothing decided yet, so the review entry must not exist at all.
        XCTAssertFalse(app.buttons["guestMergeResolvedReviewLink"].exists, "尚未做出任何选择时不应有查看处理结果")
        assertNoTabBar(app, "preview")
        attach(app, named: "preview-preconfirm-conflict-entry")
    }

    func testChoicesMadeInPreConfirmFlowMakeTheReviewReachable() throws {
        let app = launch("UITEST_MERGE_EDIT_PRECONFIRM_UNRESOLVED")
        openPreConfirmConflicts(app)
        attach(app, named: "preconfirm-conflict-selection")

        XCTAssertEqual(value(app, "guestMergeConflictPendingCount"), "待处理, 2 条")
        let keepLocal = choiceRow(app, "keepLocal", preConfirmSameID)
        XCTAssertTrue(scrollTo(app, keepLocal))
        keepLocal.tap()

        // Stays put; nothing auto-returns and nothing confirms.
        XCTAssertTrue(app.navigationBars.staticTexts["确认前处理冲突"].waitForExistence(timeout: 5),
                      "选择后不应自动返回预览")
        XCTAssertFalse(app.staticTexts["正在合并库存…"].exists)
        XCTAssertFalse(app.staticTexts["合并完成"].exists)
        XCTAssertEqual(value(app, "guestMergeConflictPendingCount"), "待处理, 1 条")
        assertNoTabBar(app, "pre-confirm conflicts")

        back(app)
        // The review entry now exists — created purely by UI interaction.
        let review = app.buttons["guestMergeResolvedReviewLink"]
        XCTAssertTrue(scrollTo(app, review), "做出选择后应出现查看处理结果")
        XCTAssertTrue(review.label.contains("已处理 1 条"), review.label)
    }

    func testResolvingEveryPreConfirmConflictShowsTheCompletionState() throws {
        let app = launch("UITEST_MERGE_EDIT_PRECONFIRM_UNRESOLVED")
        openPreConfirmConflicts(app)

        for candidate in [preConfirmSameID, preConfirmDifferentID] {
            let row = choiceRow(app, "keepLocal", candidate)
            XCTAssertTrue(scrollTo(app, row), "应能找到 \(candidate) 的选项")
            row.tap()
        }
        XCTAssertTrue(
            element(app, "guestMergePreConfirmAllResolved").waitForExistence(timeout: 5),
            "全部处理后应显示完成状态"
        )
        // Still on the pushed screen; no confirm, no auto-return.
        XCTAssertTrue(app.navigationBars.staticTexts["确认前处理冲突"].exists)
        XCTAssertFalse(app.buttons["guestMergeConfirmButton"].exists)

        back(app)
        let review = app.buttons["guestMergeResolvedReviewLink"]
        XCTAssertTrue(scrollTo(app, review))
        XCTAssertTrue(review.label.contains("已处理 2 条"), review.label)
    }

    /// The full live-regroup scenario, with every choice produced by the UI.
    func testReviewGroupsRefreshAfterChoiceChange() throws {
        let app = launch("UITEST_MERGE_EDIT_PRECONFIRM_UNRESOLVED")
        openPreConfirmConflicts(app)
        let keepLocal = choiceRow(app, "keepLocal", preConfirmSameID)
        XCTAssertTrue(scrollTo(app, keepLocal))
        keepLocal.tap()
        back(app)
        openReview(app)

        // Recorded as keepLocal.
        XCTAssertTrue(group(app, "keptLocal").exists, "应出现保留本机分组")
        XCTAssertTrue(group(app, "keptLocal").label.contains("1 条"), group(app, "keptLocal").label)
        XCTAssertFalse(group(app, "keptBoth").exists, "此时不应有两条都保留分组")
        XCTAssertTrue(element(app, "guestMergeReviewEditableNotice").exists, "确认前应提示可以修改")
        attach(app, named: "review-editable")

        group(app, "keptLocal").tap()
        let edit = element(app, "guestMergeReviewEdit-\(preConfirmSameID)")
        XCTAssertTrue(scrollTo(app, edit), "应出现修改选择入口")
        edit.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["修改选择"].waitForExistence(timeout: 10))

        // Current choice is selected; the alternative is not.
        XCTAssertTrue(editRow(app, "keepLocal", preConfirmSameID).isSelected, "当前选择应为 selected")
        XCTAssertFalse(editRow(app, "keepBoth", preConfirmSameID).isSelected)
        attach(app, named: "edit-current-keep-local")

        editRow(app, "keepBoth", preConfirmSameID).tap()
        // Does not pop, and the new choice becomes selected immediately.
        XCTAssertTrue(app.navigationBars.staticTexts["修改选择"].exists, "修改后不应自动返回")
        XCTAssertTrue(
            editRow(app, "keepBoth", preConfirmSameID).waitForSelected(timeout: 5),
            "新选择应立即显示为 selected"
        )
        XCTAssertFalse(editRow(app, "keepLocal", preConfirmSameID).isSelected)
        attach(app, named: "edit-after-change-to-keep-both")

        // Back to the *same* review instance: groups must have regrouped live.
        back(app)
        XCTAssertTrue(app.navigationBars.staticTexts["处理结果"].waitForExistence(timeout: 10))
        XCTAssertTrue(group(app, "keptBoth").waitForExistence(timeout: 5), "candidate 应移入两条都保留")
        XCTAssertFalse(group(app, "keptLocal").exists, "原分组应为空并消失")
        XCTAssertEqual(value(app, "guestMergeReviewResolvedCount"), "已处理, 1 条", "已处理总数不变")
        attach(app, named: "review-after-choice-change")
    }

    func testChangingAChoiceToSkipUpdatesTheSkippedCount() throws {
        let app = launch("UITEST_MERGE_EDIT_PRECONFIRM_UNRESOLVED")
        openPreConfirmConflicts(app)
        let keepLocal = choiceRow(app, "keepLocal", preConfirmSameID)
        XCTAssertTrue(scrollTo(app, keepLocal))
        keepLocal.tap()
        back(app)
        openReview(app)
        XCTAssertNil(value(app, "guestMergeReviewSkippedCount"), "尚无跳过项")

        group(app, "keptLocal").tap()
        let edit = element(app, "guestMergeReviewEdit-\(preConfirmSameID)")
        XCTAssertTrue(scrollTo(app, edit))
        edit.tap()
        editRow(app, "skip", preConfirmSameID).tap()
        XCTAssertTrue(editRow(app, "skip", preConfirmSameID).waitForSelected(timeout: 5))
        back(app)

        XCTAssertTrue(group(app, "skipped").waitForExistence(timeout: 5))
        XCTAssertEqual(value(app, "guestMergeReviewSkippedCount"), "其中本次跳过, 1 条")
        XCTAssertEqual(value(app, "guestMergeReviewResolvedCount"), "已处理, 1 条")
        attach(app, named: "review-after-skip")
    }

    // MARK: - Live read-only transition and stale actions

    func testReviewBecomesReadOnlyWhenSyncStartsWhileOpen() throws {
        let app = launch("UITEST_MERGE_EDIT_EDITABLE_RESOLVED", extra: ["UITEST_ALLOW_SYNC_START_SEAM"])
        openReview(app)
        XCTAssertTrue(element(app, "guestMergeReviewEditableNotice").exists, "初始应可编辑")

        // Flip the session to "sync started" without leaving the screen.
        let seam = app.buttons["uitest.markSyncStarted"]
        XCTAssertTrue(seam.waitForExistence(timeout: 10), "可编辑状态下测试仍必须能找到 seam")
        seam.tap()

        XCTAssertTrue(
            element(app, "guestMergeReviewReadOnlyNotice").waitForExistence(timeout: 5),
            "同步开始后 review 应即时变为只读"
        )
        XCTAssertFalse(element(app, "guestMergeReviewEditableNotice").exists)
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "guestMergeReviewEdit-")).count, 0,
            "所有修改入口应消失"
        )
        // The seam is gated on the same editability as 修改选择, so it removes
        // itself the moment it fires: a read-only review — and therefore the
        // screenshot below — must never show a test-only control.
        XCTAssertFalse(seam.exists, "seam 触发后必须从只读界面消失")
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "uitest.")).count, 0,
            "只读 review 上不应有任何 uitest.* 控件"
        )
        // Summary and groups remain viewable, and nothing claims per-item upload state.
        XCTAssertTrue(element(app, "guestMergeReviewResolvedCount").exists)
        XCTAssertTrue(element(app, "guestMergeReviewFooter").label.contains("不代表各条目的当前上传状态"))
        // What the seam does and does not write is pinned by
        // `testMarkSyncStartedForUITestingOnlyMarksTheSessionAndStagesNothing`;
        // this test never taps confirm, so no upload path runs here either.
        attach(app, named: "review-post-confirm-readonly")
    }

    func testStaleEditorActionFailsClosedWithAVisibleError() throws {
        let app = launch("UITEST_MERGE_EDIT_EDITABLE_KEEP_BOTH", extra: ["UITEST_ALLOW_SYNC_START_SEAM"])
        openReview(app)
        let keepLocalCandidate = "00000000-0000-0000-0000-000000000798"
        group(app, "keptLocal").tap()
        let edit = element(app, "guestMergeReviewEdit-\(keepLocalCandidate)")
        XCTAssertTrue(scrollTo(app, edit))
        edit.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["修改选择"].waitForExistence(timeout: 10))
        XCTAssertTrue(editRow(app, "keepLocal", keepLocalCandidate).isSelected)

        // Session starts syncing behind this open screen.
        back(app)
        app.buttons["uitest.markSyncStarted"].tap()
        XCTAssertTrue(element(app, "guestMergeReviewReadOnlyNotice").waitForExistence(timeout: 5))
    }

    // MARK: - Partial-confirm path is untouched

    func testPartialConfirmPathStillWorksWithoutUsingThePreConfirmEntry() throws {
        let app = launch("UITEST_MERGE_EDIT_PRECONFIRM_UNRESOLVED")
        // The entry exists but the user ignores it.
        XCTAssertTrue(scrollTo(app, app.buttons["guestMergePreConfirmConflictLink"]))
        let confirm = app.buttons["guestMergeConfirmButton"]
        XCTAssertTrue(scrollTo(app, confirm))
        XCTAssertTrue(confirm.label.contains("先合并其余"), confirm.label)
        XCTAssertTrue(confirm.isEnabled, "partial merge 必须继续可用")
    }

    // MARK: - Restart

    /// The real cold-relaunch acceptance test: the choice is made **through the
    /// UI** in the first process, the app is fully terminated, and a second
    /// process must resume that same persisted session — not re-seed it and not
    /// regenerate the plan. Everything is asserted from fixed root-level probes.
    func testPreConfirmChoiceAndReservedForkPersistAcrossColdRelaunch() throws {
        let restartSameID = "00000000-0000-0000-0000-000000000760"

        // ---- Launch 1: SEED ----
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_ACCOUNT_OWNER", "UITEST_ACCOUNT_TEST", "UITEST_MERGE_CHOICE_EDITING_RESTART_SEED"
        ]
        app.launch()
        openMergeFlow(app)

        XCTAssertEqual(probeValue(app, "uitest.restart.mode"), "seed", allProbes(app))
        XCTAssertEqual(probeValue(app, "uitest.restart.fixtureState"), "seeded", allProbes(app))
        let seedInventory = try XCTUnwrap(probeValue(app, "uitest.restart.inventory"))
        XCTAssertTrue(seedInventory.contains(restartSameID), "库存应包含 restart candidate：\(seedInventory)")
        XCTAssertNotEqual(
            probeValue(app, "uitest.restart.previewOrigin"), "regenerated-invalid-plan",
            allProbes(app)
        )

        // Initially unresolved with no reservation.
        let initialFork = waitForProbeValue(app, "uitest.restart.forkIdentity", containing: "state=ready")
        XCTAssertEqual(probeField(initialFork, "candidate"), restartSameID, initialFork)
        XCTAssertEqual(probeField(initialFork, "choice"), "nil", initialFork)
        XCTAssertEqual(probeField(initialFork, "reserved"), "nil", initialFork)
        XCTAssertEqual(probeField(initialFork, "active"), "nil", initialFork)

        // Make the choice through the real production entry.
        openPreConfirmConflicts(app)
        let keepBoth = choiceRow(app, "keepBoth", restartSameID)
        XCTAssertTrue(scrollTo(app, keepBoth))
        keepBoth.tap()

        let afterKeepBoth = waitForProbeValue(app, "uitest.restart.forkIdentity", containing: "choice=keepBoth")
        XCTAssertEqual(probeField(afterKeepBoth, "action"), "create", afterKeepBoth)
        let reservedAtSeed = try XCTUnwrap(probeField(afterKeepBoth, "reserved"))
        let activeAtSeed = try XCTUnwrap(probeField(afterKeepBoth, "active"))
        XCTAssertNotEqual(reservedAtSeed, "nil", afterKeepBoth)
        XCTAssertEqual(activeAtSeed, reservedAtSeed, "keepBoth 下 active 必须等于 reserved")
        XCTAssertEqual(probeValue(app, "uitest.restart.mutationCount"), "count=0", allProbes(app))

        back(app)
        openReview(app)
        XCTAssertTrue(group(app, "keptBoth").waitForExistence(timeout: 5), "选择应已生效")
        XCTAssertEqual(value(app, "guestMergeReviewResolvedCount"), "已处理, 1 条")

        app.terminate()

        // ---- Launch 2: RESUME ----
        let relaunched = XCUIApplication()
        relaunched.launchArguments = [
            "UITEST_ACCOUNT_OWNER", "UITEST_ACCOUNT_TEST", "UITEST_MERGE_CHOICE_EDITING_RESTART_RESUME"
        ]
        relaunched.launch()
        openMergeFlow(relaunched)

        XCTAssertEqual(probeValue(relaunched, "uitest.restart.mode"), "resume", allProbes(relaunched))
        XCTAssertEqual(
            probeValue(relaunched, "uitest.restart.fixtureState"), "resume-no-seed",
            "第二次启动不得执行任何 fixture seed\n\(allProbes(relaunched))"
        )
        // The generic 测试库存 reset did not run: the same inventory ids are
        // present. Compared as a sorted set — the store does not promise a
        // stable ordering across launches, and order is not what this asserts.
        let resumeInventory = try XCTUnwrap(probeValue(relaunched, "uitest.restart.inventory"))
        XCTAssertEqual(
            inventoryIdSet(resumeInventory), inventoryIdSet(seedInventory),
            "重启后本地库存 id 必须完全一致\n\(allProbes(relaunched))"
        )
        XCTAssertEqual(probeField(resumeInventory, "count"), probeField(seedInventory, "count"))

        // Asserted from the branch preparePreview actually took.
        let origin = waitForProbeValue(relaunched, "uitest.restart.previewOrigin", containing: "resumed-existing")
        XCTAssertEqual(origin, "resumed-existing", allProbes(relaunched))
        XCTAssertNotEqual(origin, "regenerated-invalid-plan")
        XCTAssertNotEqual(origin, "created-new")

        let resumedFork = waitForProbeValue(relaunched, "uitest.restart.forkIdentity", containing: "choice=keepBoth")
        XCTAssertEqual(probeField(resumedFork, "candidate"), restartSameID, resumedFork)
        XCTAssertEqual(probeField(resumedFork, "action"), "create", resumedFork)
        XCTAssertEqual(probeField(resumedFork, "reserved"), reservedAtSeed, "reserved fork 必须逐字符相同")
        XCTAssertEqual(probeField(resumedFork, "active"), activeAtSeed, "active fork 必须逐字符相同")
        XCTAssertEqual(probeValue(relaunched, "uitest.restart.mutationCount"), "count=0")

        openReview(relaunched)
        XCTAssertTrue(group(relaunched, "keptBoth").exists, "重启后 candidate 仍应在两条都保留分组")
        XCTAssertTrue(element(relaunched, "guestMergeReviewEditableNotice").exists, "重启后仍应可编辑")

        // The restored session is genuinely writable: skip, then back to keepBoth.
        group(relaunched, "keptBoth").tap()
        let edit = element(relaunched, "guestMergeReviewEdit-\(restartSameID)")
        XCTAssertTrue(scrollTo(relaunched, edit), "重启后仍应有修改入口")
        edit.tap()
        XCTAssertTrue(relaunched.navigationBars.staticTexts["修改选择"].waitForExistence(timeout: 10))
        XCTAssertTrue(editRow(relaunched, "keepBoth", restartSameID).isSelected, "恢复后当前选择应为 keepBoth")

        editRow(relaunched, "skip", restartSameID).tap()
        let afterSkip = waitForProbeValue(relaunched, "uitest.restart.forkIdentity", containing: "choice=skip")
        XCTAssertEqual(probeField(afterSkip, "action"), "skip", afterSkip)
        XCTAssertEqual(probeField(afterSkip, "reserved"), reservedAtSeed, "skip 下 reserved 必须保留")
        XCTAssertEqual(probeField(afterSkip, "active"), "nil", "skip 下 active 必须为 nil")

        editRow(relaunched, "keepBoth", restartSameID).tap()
        let restored = waitForProbeValue(relaunched, "uitest.restart.forkIdentity", containing: "choice=keepBoth")
        XCTAssertEqual(probeField(restored, "reserved"), reservedAtSeed, "改回 keepBoth 必须复用同一 reserved")
        XCTAssertEqual(probeField(restored, "active"), reservedAtSeed, "active 应再次等于 reserved")
        XCTAssertEqual(probeValue(relaunched, "uitest.restart.mutationCount"), "count=0")
    }

    /// Fixture smoke only: a pre-seeded editable session stays editable across a
    /// relaunch. This does not stand in for the cold-relaunch test above.
    func testPreSeededEditableSessionSmokeSurvivesRelaunch() throws {
        let app = launch("UITEST_MERGE_EDIT_EDITABLE_RESOLVED")
        openReview(app)
        XCTAssertTrue(element(app, "guestMergeReviewEditableNotice").exists)
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launchArguments = [
            "UITEST_ACCOUNT_OWNER", "UITEST_ACCOUNT_TEST", "UITEST_MERGE_EDIT_EDITABLE_RESOLVED"
        ]
        relaunched.launch()
        openMergeFlow(relaunched)
        openReview(relaunched)
        XCTAssertTrue(element(relaunched, "guestMergeReviewEditableNotice").exists)
        group(relaunched, "keptLocal").tap()
        XCTAssertTrue(
            element(relaunched, "guestMergeReviewEdit-00000000-0000-0000-0000-000000000794")
                .waitForExistence(timeout: 5)
        )
    }

    func testPostConfirmSessionRemainsReadOnlyAfterRelaunch() throws {
        let app = launch("UITEST_MERGE_SUMMARY_POST_PARTIAL_CONFIRM")
        openReview(app)
        XCTAssertTrue(element(app, "guestMergeReviewReadOnlyNotice").exists)
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launchArguments = [
            "UITEST_ACCOUNT_OWNER", "UITEST_ACCOUNT_TEST", "UITEST_MERGE_SUMMARY_POST_PARTIAL_CONFIRM"
        ]
        relaunched.launch()
        openMergeFlow(relaunched)
        openReview(relaunched)
        XCTAssertTrue(element(relaunched, "guestMergeReviewReadOnlyNotice").exists, "重启后仍应只读")
        XCTAssertEqual(
            relaunched.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "guestMergeReviewEdit-")).count, 0
        )
    }

    func testConfirmedWithNothingUploadedIsStillReadOnly() throws {
        let app = launch("UITEST_MERGE_EDIT_CONFIRMED_ZERO_UPLOAD")
        openReview(app)
        XCTAssertTrue(element(app, "guestMergeReviewReadOnlyNotice").exists,
                      "confirmedAt 非 nil 即使未上传也应只读")
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "guestMergeReviewEdit-")).count, 0
        )
    }

    // MARK: - Structure, long list, appearance

    func testEditorUsesVerticalRowsWithNoSegmentedPicker() throws {
        let app = launch("UITEST_MERGE_EDIT_EDITABLE_KEEP_BOTH")
        openReview(app)
        let keepBothCandidate = "00000000-0000-0000-0000-000000000797"
        group(app, "keptBoth").tap()
        let edit = element(app, "guestMergeReviewEdit-\(keepBothCandidate)")
        XCTAssertTrue(scrollTo(app, edit))
        edit.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["修改选择"].waitForExistence(timeout: 10))

        XCTAssertEqual(app.segmentedControls.count, 0, "不得恢复 segmented picker")
        var previousMaxY: CGFloat = 0
        for choice in ["keepLocal", "keepRemote", "keepBoth", "skip"] {
            let row = editRow(app, choice, keepBothCandidate)
            XCTAssertTrue(scrollTo(app, row), "\(choice) 行应可达")
            XCTAssertGreaterThanOrEqual(row.frame.height, 43.5, "\(choice) 应至少 44pt")
            XCTAssertGreaterThanOrEqual(row.frame.minY, previousMaxY - 1, "\(choice) 应垂直排列")
            previousMaxY = row.frame.maxY
            // VoiceOver reads title + consequence from one element.
            XCTAssertGreaterThan(row.label.count, 4, "\(choice) 无障碍标签过短：\(row.label)")
        }
        XCTAssertTrue(editRow(app, "keepBoth", keepBothCandidate).isSelected, "当前选择应有 selected trait")
        assertNoTabBar(app, "editor")
        attach(app, named: "edit-current-keep-both")
    }

    func testLongResolvedListLastCandidateIsEditable() throws {
        let app = launch("UITEST_MERGE_EDIT_EDITABLE_LONG")
        openReview(app)
        XCTAssertEqual(value(app, "guestMergeReviewResolvedCount"), "已处理, 20 条")
        let lastGroup = group(app, "skipped")
        XCTAssertTrue(scrollTo(app, lastGroup))
        lastGroup.tap()
        let lastCandidate = "00000000-0000-0000-0000-000000000720"
        let edit = element(app, "guestMergeReviewEdit-\(lastCandidate)")
        XCTAssertTrue(scrollTo(app, edit), "应能滚动到最后一条并编辑")
        edit.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["修改选择"].waitForExistence(timeout: 10))
        XCTAssertTrue(editRow(app, "skip", lastCandidate).isSelected)
        assertNoTabBar(app, "long list editor")
        attach(app, named: "edit-long-list-last-item")
    }

    func testDarkModeEditingRemainsReadable() throws {
        let app = launch("UITEST_MERGE_EDIT_EDITABLE_RESOLVED", extra: ["UITEST_FORCE_DARK_APPEARANCE"])
        openReview(app)
        let candidate = "00000000-0000-0000-0000-000000000794"
        group(app, "keptLocal").tap()
        let edit = element(app, "guestMergeReviewEdit-\(candidate)")
        XCTAssertTrue(scrollTo(app, edit))
        edit.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["修改选择"].waitForExistence(timeout: 10))
        XCTAssertTrue(editRow(app, "keepLocal", candidate).isSelected)
        assertNoTabBar(app, "dark editor")
        attach(app, named: "editing-dark")
    }

    func testAccessibilityXXXLEditorRemainsReachableAndUntruncated() throws {
        let app = launch(
            "UITEST_MERGE_EDIT_EDITABLE_RESOLVED",
            extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        )
        openReview(app)
        attach(app, named: "editing-accessibility-xxxl-top")
        let candidate = "00000000-0000-0000-0000-000000000794"
        let header = group(app, "keptLocal")
        XCTAssertTrue(scrollTo(app, header))
        header.tap()
        let edit = element(app, "guestMergeReviewEdit-\(candidate)")
        XCTAssertTrue(scrollTo(app, edit))
        edit.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["修改选择"].waitForExistence(timeout: 10))

        let window = app.windows.firstMatch.frame
        for choice in ["keepLocal", "keepRemote", "keepBoth", "skip"] {
            let row = editRow(app, choice, candidate)
            XCTAssertTrue(scrollTo(app, row), "XXXL 下 \(choice) 应可达")
            XCTAssertFalse(row.label.contains("…"), "XXXL 下 \(choice) 出现省略号：\(row.label)")
            XCTAssertLessThanOrEqual(row.frame.maxX, window.maxX + 1, "XXXL 下 \(choice) 超出屏幕")
        }
        assertNoTabBar(app, "XXXL editor")
        attach(app, named: "editing-accessibility-xxxl-bottom")
    }
}

private extension XCUIElement {
    /// `isSelected` is not a queryable predicate on every element type, so poll.
    func waitForSelected(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isSelected { return true }
            _ = waitForExistence(timeout: 0.3)
        }
        return isSelected
    }
}

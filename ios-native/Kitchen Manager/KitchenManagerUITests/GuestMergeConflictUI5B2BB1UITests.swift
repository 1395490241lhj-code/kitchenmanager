import XCTest

/// UI-5B2B-B1: conflict-screen presentation correctness.
///
/// Every scenario runs against the DEBUG-only conflict fixtures, which seed a
/// local `.conflict` session. Nothing here touches a real account, token,
/// network, `SyncCoordinator`, or mutation path.
final class GuestMergeConflictUI5B2BB1UITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private enum Choice: String, CaseIterable {
        case keepLocal, keepRemote, keepBoth, skip
        var title: String {
            switch self {
            case .keepLocal: "保留本机"
            case .keepRemote: "保留家庭"
            case .keepBoth: "两条都保留"
            case .skip: "本次跳过"
            }
        }
    }

    /// Same-ID quantity conflict on 豆腐 unless another fixture is requested.
    private func launchConflict(_ fixture: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_ACCOUNT_OWNER", "UITEST_ACCOUNT_TEST", fixture] + extra
        app.launch()

        // Wait on the fixture's own completion marker rather than sleeping: the
        // seed is async and the conflict screen only appears once it has landed.
        XCTAssertTrue(
            app.otherElements["uitest.conflictFixtureSeeded"].waitForExistence(timeout: 15)
                || app.descendants(matching: .any)["uitest.conflictFixtureSeeded"].waitForExistence(timeout: 5),
            "conflict fixture seed marker never appeared"
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
        return app
    }

    private func choiceRow(_ app: XCUIApplication, _ choice: Choice, _ candidateID: String) -> XCUIElement {
        app.buttons["guestMergeConflictChoice-\(choice.rawValue)-\(candidateID)"]
    }

    /// Fixture candidate ids, mirroring `AccountLifecycleConflictFixture`.
    private let sameIDCandidate = "00000000-0000-0000-0000-000000000501"
    private let differentIDCandidate = "00000000-0000-0000-0000-000000000502"
    private let expiryCandidate = "00000000-0000-0000-0000-000000000503"

    /// The pending count is rendered as a `LabeledContent`, whose value may be
    /// exposed either on the identified element or as a sibling static text
    /// depending on how the row is combined, so accept both.
    private func assertPendingCount(
        _ app: XCUIApplication, _ expected: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let text = "\(expected) 条"
        let identified = app.descendants(matching: .any)["guestMergeConflictPendingCount"]
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if identified.exists && identified.label.contains(text) { return }
            if app.staticTexts[text].exists { return }
            _ = app.staticTexts[text].waitForExistence(timeout: 0.5)
        } while Date() < deadline
        XCTFail(
            "待处理数量应为 \(text)；identified=\(identified.exists ? identified.label : "<缺失>")\n"
                + app.debugDescription,
            file: file, line: line
        )
    }

    /// Scrolls until `element` is rendered and hittable. Lists render lazily, so
    /// a row below the fold is genuinely absent from the tree until scrolled to.
    @discardableResult
    private func scrollTo(_ app: XCUIApplication, _ element: XCUIElement, maxSwipes: Int = 25) -> Bool {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
        return element.exists && element.isHittable
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertNoTabBar(_ app: XCUIApplication, _ context: String) {
        XCTAssertFalse(app.tabBars.firstMatch.exists, "\(context): 合并流程内不应有 Tab Bar")
        XCTAssertFalse(app.tabBars.buttons["我的"].exists, "\(context): 不应残留悬浮 Tab 按钮")
    }

    // MARK: - Entry and layout

    func testConflictFixtureReachesConflictScreenWithHiddenTabBar() throws {
        let app = launchConflict("UITEST_MERGE_CONFLICT_SAME_ID")

        XCTAssertTrue(app.navigationBars.staticTexts["处理冲突"].waitForExistence(timeout: 10),
                      "应进入冲突页面而不是预览页\n\(app.debugDescription)")
        assertNoTabBar(app, "conflict screen")

        // Pending count, local vs family values, and the reason are all present.
        XCTAssertTrue(app.staticTexts["待处理"].exists)
        XCTAssertTrue(app.staticTexts["本机"].exists)
        XCTAssertTrue(app.staticTexts["家庭"].exists)
        XCTAssertTrue(app.staticTexts["本机与家庭的数量不同。"].exists)
        XCTAssertTrue(app.staticTexts["豆腐"].exists, "候选名称应作为分区标题显示")

        attach(app, named: "conflict-default-unselected")
    }

    // MARK: - No phantom default

    func testNothingIsPreSelectedOnFirstEntry() throws {
        let app = launchConflict("UITEST_MERGE_CONFLICT_SAME_ID")
        XCTAssertTrue(app.navigationBars.staticTexts["处理冲突"].waitForExistence(timeout: 10))

        for choice in Choice.allCases {
            let row = choiceRow(app, choice, sameIDCandidate)
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(choice.title) 行缺失")
            XCTAssertFalse(
                row.isSelected,
                "首次进入时 \(choice.title) 不得处于选中状态"
            )
        }

        // The specific regression: 保留家庭 was previously displayed as chosen
        // because the picker fell back to `pendingChoice[id] ?? .keepRemote`.
        XCTAssertFalse(
            choiceRow(app, .keepRemote, sameIDCandidate).isSelected,
            "保留家庭不得作为假默认值显示为已选中"
        )

        // Still unresolved, so the row is still listed and the count is unchanged.
        assertPendingCount(app, 1)
    }

    // MARK: - Vertical rows

    func testFourVerticalChoiceRowsExistInFixedOrderAndAreFullyTappable() throws {
        let app = launchConflict("UITEST_MERGE_CONFLICT_SAME_ID")
        XCTAssertTrue(app.navigationBars.staticTexts["处理冲突"].waitForExistence(timeout: 10))

        var previousMaxY: CGFloat = 0
        for choice in Choice.allCases {
            let row = choiceRow(app, choice, sameIDCandidate)
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertTrue(row.isHittable, "\(choice.title) 整行应可点击")
            XCTAssertGreaterThanOrEqual(row.frame.height, 43.5, "\(choice.title) 行高应至少 44pt")
            // Vertically stacked in declaration order, never a segmented control.
            XCTAssertGreaterThanOrEqual(
                row.frame.minY, previousMaxY - 1,
                "\(choice.title) 应位于上一项下方（垂直排列）"
            )
            previousMaxY = row.frame.maxY
            // Title and consequence both reach VoiceOver through one element.
            XCTAssertTrue(row.label.contains(choice.title), "\(choice.title) 无障碍标签缺少标题：\(row.label)")
            XCTAssertGreaterThan(row.label.count, choice.title.count, "\(choice.title) 缺少结果说明")
        }
        XCTAssertEqual(app.segmentedControls.count, 0, "不应再使用 segmented control")
    }

    // MARK: - Copy

    func testSameIDCopyDescribesUpdatingTheExistingFamilyRecord() throws {
        let app = launchConflict("UITEST_MERGE_CONFLICT_SAME_ID")
        XCTAssertTrue(app.navigationBars.staticTexts["处理冲突"].waitForExistence(timeout: 10))

        let keepLocal = choiceRow(app, .keepLocal, sameIDCandidate).label
        XCTAssertTrue(keepLocal.contains("更新家庭库存里的同一条记录"), keepLocal)
        XCTAssertTrue(keepLocal.contains("替换"), keepLocal)

        let keepRemote = choiceRow(app, .keepRemote, sameIDCandidate).label
        XCTAssertTrue(keepRemote.contains("保持不变"), keepRemote)
        XCTAssertTrue(keepRemote.contains("不会上传"), keepRemote)

        let keepBoth = choiceRow(app, .keepBoth, sameIDCandidate).label
        XCTAssertTrue(keepBoth.contains("单独新增一份"), keepBoth)
        XCTAssertTrue(keepBoth.contains("不会覆盖"), keepBoth)

        let skip = choiceRow(app, .skip, sameIDCandidate).label
        XCTAssertTrue(skip.contains("本次合并不会上传"), skip)

        for label in [keepLocal, keepRemote, keepBoth, skip] {
            for term in ["fork", "hash", "remote ID", "mutation", "snapshot"] {
                XCTAssertFalse(label.lowercased().contains(term.lowercased()), "文案泄漏技术术语 \(term)：\(label)")
            }
        }
        attach(app, named: "conflict-same-id-options")
    }

    func testDifferentIDCopyDescribesAddingToTheFamilyInventory() throws {
        let app = launchConflict("UITEST_MERGE_CONFLICT_DIFFERENT_ID")
        XCTAssertTrue(app.navigationBars.staticTexts["处理冲突"].waitForExistence(timeout: 10))

        let keepLocal = choiceRow(app, .keepLocal, differentIDCandidate).label
        XCTAssertTrue(keepLocal.contains("新增到家庭库存"), keepLocal)
        XCTAssertFalse(keepLocal.contains("替换"), "different-ID 不会替换任何记录：\(keepLocal)")

        let keepBoth = choiceRow(app, .keepBoth, differentIDCandidate).label
        XCTAssertTrue(keepBoth.contains("另一条记录"), keepBoth)
        XCTAssertTrue(keepBoth.contains("两条都会保留"), keepBoth)

        attach(app, named: "conflict-different-id-options")
    }

    func testSameIDAndDifferentIDCopyDiffer() throws {
        let same = launchConflict("UITEST_MERGE_CONFLICT_SAME_ID")
        XCTAssertTrue(same.navigationBars.staticTexts["处理冲突"].waitForExistence(timeout: 10),
                      "same-ID 未进入冲突页\n\(same.debugDescription)")
        let sameKeepLocal = choiceRow(same, .keepLocal, sameIDCandidate).label
        let sameKeepBoth = choiceRow(same, .keepBoth, sameIDCandidate).label
        same.terminate()

        let different = launchConflict("UITEST_MERGE_CONFLICT_DIFFERENT_ID")
        XCTAssertTrue(different.navigationBars.staticTexts["处理冲突"].waitForExistence(timeout: 10),
                      "different-ID 未进入冲突页\n\(different.debugDescription)")
        let differentKeepLocal = choiceRow(different, .keepLocal, differentIDCandidate).label
        let differentKeepBoth = choiceRow(different, .keepBoth, differentIDCandidate).label

        XCTAssertNotEqual(sameKeepLocal, differentKeepLocal, "保留本机文案必须区分 same-ID 与 different-ID")
        XCTAssertNotEqual(sameKeepBoth, differentKeepBoth, "两条都保留文案必须区分 same-ID 与 different-ID")
    }

    // MARK: - Selection behavior

    func testChoosingOneConflictResolvesOnlyThatRowAndStaysOnConflictScreen() throws {
        let app = launchConflict("UITEST_MERGE_CONFLICT_MULTIPLE")
        XCTAssertTrue(app.navigationBars.staticTexts["处理冲突"].waitForExistence(timeout: 10))
        assertPendingCount(app, 3)

        let first = choiceRow(app, .keepRemote, sameIDCandidate)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()

        // Exactly one resolve: the row leaves the unresolved list and the count
        // drops by exactly one — a second resolve would drop it further.
        assertPendingCount(app, 2)
        XCTAssertFalse(
            choiceRow(app, .keepRemote, sameIDCandidate).exists,
            "已处理的冲突行应按现有语义从未处理列表消失"
        )

        // Other unresolved rows remain, and we are still on the conflict screen.
        XCTAssertTrue(choiceRow(app, .keepLocal, differentIDCandidate).exists, "其他未处理冲突应保留")
        XCTAssertTrue(app.navigationBars.staticTexts["处理冲突"].exists, "仍有冲突时应停留在冲突页")

        attach(app, named: "conflict-after-one-choice")

        // The third candidate is below the fold and the list renders lazily, so
        // scroll to it rather than asserting on an unrendered row.
        XCTAssertTrue(
            scrollTo(app, choiceRow(app, .keepLocal, expiryCandidate)),
            "第三条未处理冲突应仍可滚动到达"
        )
    }

    func testResolvingTheLastConflictReturnsToPreviewWithoutConfirming() throws {
        let app = launchConflict("UITEST_MERGE_CONFLICT_SAME_ID")
        XCTAssertTrue(app.navigationBars.staticTexts["处理冲突"].waitForExistence(timeout: 10))

        choiceRow(app, .skip, sameIDCandidate).tap()

        // Existing behavior: the flow hands control back to the preview screen.
        // Identified by the preview's own summary section rather than the confirm
        // button — UI-5B2B-B2A added summary rows above it, so the button now sits
        // below the fold and a lazily-rendered Form leaves it out of the tree
        // until scrolled to. The behavior under test (auto-return, without
        // confirming) is unchanged.
        XCTAssertTrue(
            app.staticTexts["预计结果"].waitForExistence(timeout: 10),
            "处理完最后一条后应自动返回预览\n\(app.debugDescription)"
        )
        XCTAssertTrue(scrollTo(app, app.buttons["guestMergeConfirmButton"]), "预览页应有确认按钮")
        // Returning is not confirming: no progress or result screen appears.
        XCTAssertFalse(app.staticTexts["正在合并库存…"].exists)
        XCTAssertFalse(app.staticTexts["合并完成"].exists)
        assertNoTabBar(app, "back on preview")
    }

    // MARK: - Long list

    func testLongConflictListScrollsToTheLastCandidateAndItsChoices() throws {
        let app = launchConflict("UITEST_MERGE_CONFLICT_LONG")
        XCTAssertTrue(app.navigationBars.staticTexts["处理冲突"].waitForExistence(timeout: 10))
        assertPendingCount(app, 20)
        attach(app, named: "conflict-long-list-top")

        let lastCandidate = "00000000-0000-0000-0000-000000000520"
        let lastSkip = choiceRow(app, .skip, lastCandidate)
        var scrolls = 0
        while !lastSkip.exists || !lastSkip.isHittable, scrolls < 25 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(lastSkip.exists && lastSkip.isHittable, "应能滚动到最后一个候选的选项")

        for choice in Choice.allCases {
            XCTAssertTrue(choiceRow(app, choice, lastCandidate).exists, "最后一条应有全部四个选项")
        }
        assertNoTabBar(app, "long list bottom")
        attach(app, named: "conflict-long-list-bottom")
    }

    // MARK: - Appearance and accessibility

    func testDarkModeConflictScreenRemainsReadable() throws {
        let app = launchConflict("UITEST_MERGE_CONFLICT_SAME_ID", extra: ["UITEST_FORCE_DARK_APPEARANCE"])
        XCTAssertTrue(app.navigationBars.staticTexts["处理冲突"].waitForExistence(timeout: 10))
        for choice in Choice.allCases {
            XCTAssertTrue(choiceRow(app, choice, sameIDCandidate).exists)
        }
        assertNoTabBar(app, "dark")
        attach(app, named: "conflict-dark")
    }

    func testAccessibilityXXXLKeepsChoiceRowsReachableAndUntruncated() throws {
        let app = launchConflict(
            "UITEST_MERGE_CONFLICT_SAME_ID",
            extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        )
        XCTAssertTrue(app.navigationBars.staticTexts["处理冲突"].waitForExistence(timeout: 10))
        assertNoTabBar(app, "XXXL")
        attach(app, named: "conflict-accessibility-xxxl-top")

        let window = app.windows.firstMatch.frame
        for choice in Choice.allCases {
            let row = choiceRow(app, choice, sameIDCandidate)
            var scrolls = 0
            while !(row.exists && row.isHittable), scrolls < 20 {
                app.swipeUp()
                scrolls += 1
            }
            XCTAssertTrue(row.exists && row.isHittable, "XXXL 下 \(choice.title) 应可滚动到达")
            // Full title and consequence still reach VoiceOver, and the row is not
            // clipped horizontally.
            XCTAssertTrue(row.label.contains(choice.title), "XXXL 下 \(choice.title) 标题被截断：\(row.label)")
            XCTAssertFalse(row.label.contains("…"), "XXXL 下 \(choice.title) 文案出现省略号：\(row.label)")
            XCTAssertLessThanOrEqual(row.frame.maxX, window.maxX + 1, "XXXL 下 \(choice.title) 超出屏幕宽度")
        }
        attach(app, named: "conflict-accessibility-xxxl-bottom")
    }
}

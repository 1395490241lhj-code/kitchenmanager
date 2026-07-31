import XCTest
@testable import KitchenManager

/// UI-5B2B-B2A: the pure summary/grouping/confirmation mapping.
///
/// These exist because the shipped preview derived its conflict-reason counts
/// from `conflictReason` alone, so a partly-resolved plan overstated the
/// outstanding work, and because 保留家庭 and 本次跳过 appeared in no count at
/// all. Nothing here touches a controller, transport, persistence, or network.
final class InventoryMergeSummaryPresentationTests: XCTestCase {
    private func candidate(
        id: Int,
        action: InventoryMergeAction,
        reason: InventoryMergeConflictReason? = nil,
        choice: InventoryMergeConflictChoice? = nil,
        sameIdentity: Bool = true,
        name: String? = nil
    ) -> InventoryMergeCandidate {
        let local = UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000009%02d", id))!
        let remote = UUID(uuidString: String(format: "00000000-0000-0000-0000-000000000A%02d", id))!
        let base = InventoryMergeCandidate(
            localItemId: local,
            name: name ?? "食材\(id)",
            unit: "份",
            localQuantity: Double(id),
            localExpiryDate: nil,
            remoteItemId: action == .create && reason == nil ? nil : (sameIdentity ? local : remote),
            remoteQuantity: Double(id + 1),
            remoteExpiryDate: nil,
            remoteVersion: nil,
            action: action,
            conflictReason: reason,
            userChoice: nil
        )
        guard let choice else { return base }
        return base.applyingChoice(choice)
    }

    private func plan(_ candidates: [InventoryMergeCandidate]) -> InventoryMergePlan {
        InventoryMergePlan(
            sessionId: UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!,
            householdId: UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!,
            generatedAt: Date(timeIntervalSince1970: 1_767_225_600),
            sourceCount: candidates.count,
            candidates: candidates,
            skippedItemIds: [],
            planHash: "test-plan",
            knownRemoteItemCount: candidates.count,
            remoteSnapshotHash: "test-snapshot",
            remoteSnapshotFetchedAt: Date(timeIntervalSince1970: 1_767_225_600)
        )
    }

    /// creates + updates + keepRemote + skip + keepBoth + unresolved + exact match.
    private var mixedPlan: InventoryMergePlan {
        plan([
            candidate(id: 1, action: .create),
            candidate(id: 2, action: .update),
            candidate(id: 3, action: .skip),
            candidate(id: 4, action: .create, reason: .quantityMismatch, choice: .keepLocal),
            candidate(id: 5, action: .create, reason: .metadataMismatch, choice: .keepRemote, sameIdentity: false),
            candidate(id: 6, action: .create, reason: .expiryMismatch, choice: .skip),
            candidate(id: 7, action: .create, reason: .quantityMismatch, choice: .keepBoth),
            candidate(id: 8, action: .create, reason: .quantityMismatch, choice: nil),
            candidate(id: 9, action: .create, reason: .ambiguousDuplicate, choice: nil, sameIdentity: false)
        ])
    }

    // MARK: - The six summary predicates

    func testWillCreateCountsResolvedCreatesAndNeverUnresolvedOnes() {
        let summary = InventoryMergeSummaryPresentation.make(plan: mixedPlan)
        // id1 plain create, id4 same-ID keepLocal → .update (not create),
        // id7 keepBoth → .create. id8/id9 are unresolved creates and excluded.
        XCTAssertEqual(summary.willCreate, 2)
    }

    func testWillUpdateCountsOnlyResolvedUpdates() {
        let summary = InventoryMergeSummaryPresentation.make(plan: mixedPlan)
        // id2 plain update, plus id4 same-ID keepLocal which becomes .update.
        XCTAssertEqual(summary.willUpdate, 2)
    }

    func testKeptRemoteIsCountedAndNoLongerInvisible() {
        XCTAssertEqual(InventoryMergeSummaryPresentation.make(plan: mixedPlan).keptRemote, 1)
    }

    func testSkippedThisTimeIsCountedAndNoLongerInvisible() {
        XCTAssertEqual(InventoryMergeSummaryPresentation.make(plan: mixedPlan).skippedThisTime, 1)
    }

    func testStillNeedsDecisionUsesTheRealUnresolvedCount() {
        let summary = InventoryMergeSummaryPresentation.make(plan: mixedPlan)
        XCTAssertEqual(summary.stillNeedsDecision, 2)
        XCTAssertEqual(summary.stillNeedsDecision, mixedPlan.conflicts.count, "必须与 model 的 needsDecision 一致")
    }

    func testNothingToDoCountsOnlyExactMatches() {
        XCTAssertEqual(InventoryMergeSummaryPresentation.make(plan: mixedPlan).nothingToDo, 1)
    }

    // MARK: - The miscount this phase fixes

    func testConflictReasonBreakdownCountsOnlyUnresolvedCandidates() {
        let rows = InventoryMergeConflictReasonPresentation.make(plan: mixedPlan)
        let quantity = rows.first { $0.reason == .quantityMismatch }
        // Three candidates carry .quantityMismatch (id4 keepLocal, id7 keepBoth,
        // id8 unresolved); only id8 still needs a decision.
        XCTAssertEqual(quantity?.count, 1, "已解决的数量冲突不得再计入需要处理")
        XCTAssertEqual(mixedPlan.quantityConflicts.count, 3, "model 属性本身保持不变")
    }

    func testResolvedQuantityConflictDisappearsFromTheBreakdownEntirely() {
        let resolvedOnly = plan([candidate(id: 1, action: .create, reason: .quantityMismatch, choice: .keepLocal)])
        XCTAssertTrue(
            InventoryMergeConflictReasonPresentation.make(plan: resolvedOnly).isEmpty,
            "全部已处理时不应显示任何需要处理的冲突原因"
        )
    }

    func testEveryReasonRowIsUnresolvedOnlyAndEmptyRowsAreDropped() {
        let subject = plan([
            candidate(id: 1, action: .create, reason: .expiryMismatch, choice: nil),
            candidate(id: 2, action: .create, reason: .metadataMismatch, choice: .skip),
            candidate(id: 3, action: .create, reason: .multipleRemoteCandidates, choice: nil, sameIdentity: false)
        ])
        let rows = InventoryMergeConflictReasonPresentation.make(plan: subject)
        XCTAssertEqual(rows.map(\.reason), [.expiryMismatch, .multipleRemoteCandidates])
        XCTAssertTrue(rows.allSatisfy { $0.count == 1 })
    }

    func testKeepRemoteIsNeverCountedAsNothingToDo() {
        let subject = plan([candidate(id: 1, action: .create, reason: .quantityMismatch, choice: .keepRemote)])
        let summary = InventoryMergeSummaryPresentation.make(plan: subject)
        XCTAssertEqual(summary.nothingToDo, 0, "保留家庭是一次决定，不是无需处理")
        XCTAssertEqual(summary.keptRemote, 1)
    }

    func testSkippedConflictIsNeverCountedAsNothingToDo() {
        // A deferred conflict also carries `action == .skip`, so only the
        // `conflictReason == nil` half keeps the two apart.
        let subject = plan([candidate(id: 1, action: .create, reason: .quantityMismatch, choice: .skip)])
        let summary = InventoryMergeSummaryPresentation.make(plan: subject)
        XCTAssertEqual(summary.nothingToDo, 0)
        XCTAssertEqual(summary.skippedThisTime, 1)
    }

    func testOnlyAnExactMatchCountsAsNothingToDo() {
        let subject = plan([candidate(id: 1, action: .skip)])
        XCTAssertEqual(InventoryMergeSummaryPresentation.make(plan: subject).nothingToDo, 1)
    }

    // MARK: - keepBoth counts as an addition

    func testSameIdKeepBothCountsAsWillCreate() {
        let subject = plan([candidate(id: 1, action: .create, reason: .quantityMismatch, choice: .keepBoth)])
        let resolved = subject.candidates[0]
        XCTAssertNotNil(resolved.forkedLocalItemId, "same-ID keepBoth 会另建副本")
        XCTAssertEqual(InventoryMergeSummaryPresentation.make(plan: subject).willCreate, 1)
    }

    func testDifferentIdKeepBothCountsAsWillCreate() {
        let subject = plan([
            candidate(id: 1, action: .create, reason: .ambiguousDuplicate, choice: .keepBoth, sameIdentity: false)
        ])
        XCTAssertNil(subject.candidates[0].forkedLocalItemId)
        XCTAssertEqual(InventoryMergeSummaryPresentation.make(plan: subject).willCreate, 1)
    }

    // MARK: - Group partition

    func testEachResolvedCandidateAppearsInExactlyOneGroup() {
        let groups = InventoryMergeCandidateGroupPresentation.make(plan: mixedPlan)
        let ids = groups.flatMap { $0.candidates.map(\.id) }
        XCTAssertEqual(Set(ids).count, ids.count, "一个 candidate 不得同时出现在两个分组")
        // Four resolved conflicts in the mixed plan.
        XCTAssertEqual(ids.count, 4)
    }

    func testGroupsCoverEveryResolvedConflictAndNothingElse() {
        let grouped = Set(InventoryMergeCandidateGroupPresentation.make(plan: mixedPlan)
            .flatMap { $0.candidates.map(\.id) })
        let expected = Set(mixedPlan.candidates
            .filter { $0.conflictReason != nil && $0.userChoice != nil }
            .map(\.localItemId))
        XCTAssertEqual(grouped, expected)
    }

    func testUnresolvedCandidatesNeverAppearInAResolvedGroup() {
        let unresolvedIDs = Set(mixedPlan.candidates.filter(\.needsDecision).map(\.localItemId))
        let grouped = Set(InventoryMergeCandidateGroupPresentation.make(plan: mixedPlan)
            .flatMap { $0.candidates.map(\.id) })
        XCTAssertTrue(grouped.isDisjoint(with: unresolvedIDs))
    }

    func testNonConflictCandidatesNeverAppearInResolvedGroups() {
        let nonConflictIDs = Set(mixedPlan.candidates.filter { $0.conflictReason == nil }.map(\.localItemId))
        let grouped = Set(InventoryMergeCandidateGroupPresentation.make(plan: mixedPlan)
            .flatMap { $0.candidates.map(\.id) })
        XCTAssertTrue(grouped.isDisjoint(with: nonConflictIDs), "非冲突条目从来不是一次决定")
    }

    func testGroupsAppearInFixedOrderAndEmptyGroupsAreDropped() {
        let groups = InventoryMergeCandidateGroupPresentation.make(plan: mixedPlan)
        XCTAssertEqual(groups.map(\.group), [.keptLocal, .keptRemote, .keptBoth, .skipped])
        let onlySkip = plan([candidate(id: 1, action: .create, reason: .quantityMismatch, choice: .skip)])
        XCTAssertEqual(InventoryMergeCandidateGroupPresentation.make(plan: onlySkip).map(\.group), [.skipped])
    }

    func testCandidatesKeepPlanOrderWithinAGroup() {
        let subject = plan([
            candidate(id: 3, action: .create, reason: .quantityMismatch, choice: .skip, name: "第一"),
            candidate(id: 1, action: .create, reason: .quantityMismatch, choice: .skip, name: "第二"),
            candidate(id: 2, action: .create, reason: .quantityMismatch, choice: .skip, name: "第三")
        ])
        let group = try! XCTUnwrap(InventoryMergeCandidateGroupPresentation.make(plan: subject).first)
        XCTAssertEqual(group.candidates.map(\.name), ["第一", "第二", "第三"], "必须保持 plan 原顺序，不得排序")
    }

    func testResolvedTotalIncludesSkipAndSaysSo() {
        let summary = InventoryMergeSummaryPresentation.make(plan: mixedPlan)
        XCTAssertEqual(summary.resolvedCount, 4, "已处理总数包含跳过")
        XCTAssertTrue(summary.resolvedSummaryText.contains("已处理 4 条"))
        XCTAssertTrue(summary.resolvedSummaryText.contains("其中 1 条本次跳过"), summary.resolvedSummaryText)
    }

    func testResolvedSummaryTextOmitsTheSkipClauseWhenNothingWasSkipped() {
        let subject = plan([candidate(id: 1, action: .create, reason: .quantityMismatch, choice: .keepLocal)])
        let text = InventoryMergeSummaryPresentation.make(plan: subject).resolvedSummaryText
        XCTAssertEqual(text, "已处理 1 条")
    }

    // MARK: - Purity

    func testMappingNeverMutatesThePlanOrItsCandidates() {
        // Bound once: `mixedPlan` is computed, and same-ID `keepBoth` mints a
        // fresh `forkedLocalItemId` on every evaluation, so two separate
        // evaluations differ for reasons that have nothing to do with purity.
        let subject = mixedPlan
        let snapshot = subject
        _ = InventoryMergeSummaryPresentation.make(plan: subject)
        _ = InventoryMergeConflictReasonPresentation.make(plan: subject)
        _ = InventoryMergeCandidateGroupPresentation.make(plan: subject)
        _ = InventoryMergeConfirmationPresentation.make(
            summary: InventoryMergeSummaryPresentation.make(plan: subject), session: nil
        )
        XCTAssertEqual(subject, snapshot, "presentation mapping 不得修改 plan 或 candidate")
        XCTAssertEqual(subject.candidates.map(\.userChoice), snapshot.candidates.map(\.userChoice))
        XCTAssertEqual(subject.candidates.map(\.action), snapshot.candidates.map(\.action))
        XCTAssertEqual(subject.candidates.map(\.forkedLocalItemId), snapshot.candidates.map(\.forkedLocalItemId))
    }

    // MARK: - Confirmation copy

    func testPlainMergeWithNoConflictsKeepsTheOriginalButtonTitle() {
        let subject = plan([candidate(id: 1, action: .create), candidate(id: 2, action: .update)])
        let confirmation = InventoryMergeConfirmationPresentation.make(
            summary: InventoryMergeSummaryPresentation.make(plan: subject), session: nil
        )
        XCTAssertEqual(confirmation.buttonTitle, "确认合并库存")
        XCTAssertEqual(confirmation.supportingCopy, "计划新增 1 条、计划更新 1 条。")
    }

    func testMixedResolvedConfirmationListsUploadsAndDeferrals() {
        let confirmation = InventoryMergeConfirmationPresentation.make(
            summary: InventoryMergeSummaryPresentation.make(plan: mixedPlan), session: nil
        )
        // The mixed plan still has unresolved conflicts, so it is Case B.
        XCTAssertEqual(confirmation.buttonTitle, "先合并其余 4 条")
        XCTAssertTrue(confirmation.supportingCopy.contains("还有 2 条待处理"), confirmation.supportingCopy)
        XCTAssertTrue(confirmation.supportingCopy.contains("1 条保留家庭内容"), confirmation.supportingCopy)
        XCTAssertTrue(confirmation.supportingCopy.contains("1 条本次跳过"), confirmation.supportingCopy)
    }

    func testAllResolvedWithUploadsCombinesActualCounts() {
        let subject = plan([
            candidate(id: 1, action: .create),
            candidate(id: 2, action: .create),
            candidate(id: 3, action: .create),
            candidate(id: 4, action: .update),
            candidate(id: 5, action: .create, reason: .quantityMismatch, choice: .keepRemote),
            candidate(id: 6, action: .create, reason: .quantityMismatch, choice: .skip),
            candidate(id: 7, action: .create, reason: .expiryMismatch, choice: .skip)
        ])
        let confirmation = InventoryMergeConfirmationPresentation.make(
            summary: InventoryMergeSummaryPresentation.make(plan: subject), session: nil
        )
        XCTAssertEqual(confirmation.buttonTitle, "确认合并库存")
        XCTAssertEqual(
            confirmation.supportingCopy,
            "计划新增 3 条、计划更新 1 条；1 条保留家庭内容，2 条本次跳过。"
        )
    }

    func testAllSkipConfirmationNeverClaimsAnythingWillUpload() {
        let subject = plan((1...3).map {
            candidate(id: $0, action: .create, reason: .quantityMismatch, choice: .skip)
        })
        let confirmation = InventoryMergeConfirmationPresentation.make(
            summary: InventoryMergeSummaryPresentation.make(plan: subject), session: nil
        )
        XCTAssertEqual(confirmation.buttonTitle, "完成，不上传任何条目")
        XCTAssertEqual(
            confirmation.supportingCopy,
            "本次不会上传任何库存；家庭和本机数据保持现在的样子。"
        )
    }

    func testKeepRemoteOnlyConfirmationUsesTheZeroUploadWording() {
        let subject = plan((1...2).map {
            candidate(id: $0, action: .create, reason: .quantityMismatch, choice: .keepRemote)
        })
        let confirmation = InventoryMergeConfirmationPresentation.make(
            summary: InventoryMergeSummaryPresentation.make(plan: subject), session: nil
        )
        XCTAssertEqual(confirmation.buttonTitle, "完成，不上传任何条目")
    }

    func testKeepRemoteAndSkipMixWithZeroUploadsAlsoUsesTheZeroUploadWording() {
        let subject = plan([
            candidate(id: 1, action: .create, reason: .quantityMismatch, choice: .keepRemote),
            candidate(id: 2, action: .create, reason: .expiryMismatch, choice: .skip)
        ])
        let confirmation = InventoryMergeConfirmationPresentation.make(
            summary: InventoryMergeSummaryPresentation.make(plan: subject), session: nil
        )
        XCTAssertEqual(confirmation.buttonTitle, "完成，不上传任何条目")
    }

    func testUnresolvedWithUploadableUsesThePartialMergeButton() {
        let subject = plan([
            candidate(id: 1, action: .create),
            candidate(id: 2, action: .update),
            candidate(id: 3, action: .create, reason: .quantityMismatch, choice: nil)
        ])
        let confirmation = InventoryMergeConfirmationPresentation.make(
            summary: InventoryMergeSummaryPresentation.make(plan: subject), session: nil
        )
        XCTAssertEqual(confirmation.buttonTitle, "先合并其余 2 条")
        XCTAssertEqual(confirmation.supportingCopy, "还有 1 条待处理，本次不会上传这些条目。")
    }

    func testUnresolvedWithZeroUploadableNeverSaysMergeTheRemainingZero() {
        let subject = plan([
            candidate(id: 1, action: .create, reason: .quantityMismatch, choice: .keepRemote),
            candidate(id: 2, action: .create, reason: .expiryMismatch, choice: .skip),
            candidate(id: 3, action: .create, reason: .quantityMismatch, choice: nil)
        ])
        let confirmation = InventoryMergeConfirmationPresentation.make(
            summary: InventoryMergeSummaryPresentation.make(plan: subject), session: nil
        )
        XCTAssertEqual(confirmation.buttonTitle, "确认当前处理结果")
        XCTAssertFalse(confirmation.buttonTitle.contains("0 条"), "不得出现“先合并其余 0 条”")
        XCTAssertEqual(
            confirmation.supportingCopy,
            "目前没有可上传条目；确认后仍有 1 条冲突需要处理。"
        )
    }

    func testUploadableCountMatchesTheModelsReadyToUploadCreatesAndUpdates() {
        // The mapping must describe what `confirmMerge` would upload, without
        // redefining `readyToUpload` itself.
        let expected = mixedPlan.readyToUpload.filter { $0.action == .create || $0.action == .update }.count
        XCTAssertEqual(InventoryMergeSummaryPresentation.make(plan: mixedPlan).uploadableCount, expected)
    }

    // MARK: - Wording bans

    func testNoCopyEverClaimsSomethingWasAlreadyUploadedOrMerged() {
        var texts: [String] = []
        for subject in [mixedPlan,
                        plan((1...2).map { candidate(id: $0, action: .create, reason: .quantityMismatch, choice: .skip) }),
                        plan([candidate(id: 1, action: .create)])] {
            let summary = InventoryMergeSummaryPresentation.make(plan: subject)
            let confirmation = InventoryMergeConfirmationPresentation.make(summary: summary, session: nil)
            texts.append(summary.resolvedSummaryText)
            texts.append(confirmation.buttonTitle)
            texts.append(confirmation.supportingCopy)
            texts.append(contentsOf: InventoryMergeCandidateGroupPresentation.make(plan: subject)
                .flatMap { [$0.title] + $0.candidates.flatMap { [$0.choiceTitle, $0.consequence] } })
        }
        for text in texts {
            for banned in ["已上传", "已合并", "上传完成", "合并完成"] {
                XCTAssertFalse(text.contains(banned), "文案不得声称已经发生：\(banned) in \(text)")
            }
        }
    }

    func testGroupTitlesAreStable() {
        XCTAssertEqual(InventoryMergeCandidateGroup.keptLocal.title, "已选择保留本机")
        XCTAssertEqual(InventoryMergeCandidateGroup.keptRemote.title, "已选择保留家庭")
        XCTAssertEqual(InventoryMergeCandidateGroup.keptBoth.title, "已选择两条都保留")
        XCTAssertEqual(InventoryMergeCandidateGroup.skipped.title, "本次跳过")
    }

    func testResolvedCandidateReusesTheB1ConsequenceCopy() {
        let subject = candidate(id: 1, action: .create, reason: .quantityMismatch, choice: .keepLocal)
        let presentation = try! XCTUnwrap(InventoryMergeResolvedCandidatePresentation.make(candidate: subject))
        let b1 = InventoryMergeConflictChoicePresentation.make(choice: .keepLocal, isSameRemoteRecord: true)
        XCTAssertEqual(presentation.choiceTitle, b1.title)
        XCTAssertEqual(presentation.consequence, b1.consequence, "复查页面不得与做选择时的说明不一致")
    }

    func testResolvedCandidateMakeReturnsNilForUnresolvedOrNonConflict() {
        XCTAssertNil(InventoryMergeResolvedCandidatePresentation.make(
            candidate: candidate(id: 1, action: .create, reason: .quantityMismatch, choice: nil)
        ))
        XCTAssertNil(InventoryMergeResolvedCandidatePresentation.make(
            candidate: candidate(id: 2, action: .create)
        ))
    }

    // MARK: - Post-partial-confirm accuracy

    private func session(
        status: GuestMergeSessionStatus = .previewReady,
        confirmedAt: Date? = nil,
        uploadedItemCount: Int = 0,
        plan: InventoryMergePlan
    ) -> GuestMergeSession {
        GuestMergeSession(
            id: plan.sessionId, userId: UUID(uuidString: "00000000-0000-0000-0000-0000000000F3")!,
            householdId: plan.householdId, entityType: .inventoryItem, status: status,
            createdAt: plan.generatedAt, updatedAt: plan.generatedAt, confirmedAt: confirmedAt,
            completedAt: nil, cancelledAt: nil, rollbackAvailableUntil: nil, localSnapshot: [],
            plan: plan, plannedItemCount: 0, uploadedItemCount: uploadedItemCount,
            conflictCount: plan.conflicts.count, failedCount: 0, lastErrorCode: nil,
            createdEntityIds: [], mergeVersion: 1
        )
    }

    func testHasUploadedAlreadyIsFalseBeforeAnyConfirm() {
        let subject = session(plan: mixedPlan)
        XCTAssertFalse(InventoryMergeReviewFooterPresentation.hasUploadedAlready(session: subject))
    }

    func testHasUploadedAlreadyIsTrueFromEitherConfirmedAtOrUploadedCount() {
        let byDate = session(confirmedAt: Date(timeIntervalSince1970: 1), plan: mixedPlan)
        XCTAssertTrue(InventoryMergeReviewFooterPresentation.hasUploadedAlready(session: byDate))
        let byCount = session(uploadedItemCount: 2, plan: mixedPlan)
        XCTAssertTrue(InventoryMergeReviewFooterPresentation.hasUploadedAlready(session: byCount))
    }

    func testReviewFooterNeverClaimsAnUploadStateInEitherDirection() {
        for subject in [
            session(plan: mixedPlan),
            session(confirmedAt: Date(timeIntervalSince1970: 1), uploadedItemCount: 2, plan: mixedPlan),
            session(status: .conflict, confirmedAt: Date(timeIntervalSince1970: 1), uploadedItemCount: 2, plan: mixedPlan)
        ] {
            let footer = InventoryMergeReviewFooterPresentation.make(session: subject)
            for banned in ["尚未上传", "已上传", "已合并", "将会上传", "即将上传"] {
                XCTAssertFalse(footer.text.contains(banned), "footer 不得声称上传状态：\(footer.text)")
            }
            XCTAssertTrue(footer.text.contains("不代表各条目的当前上传状态"), footer.text)
        }
    }

    func testReviewFooterIsAccurateWithNoSessionAtAll() {
        let footer = InventoryMergeReviewFooterPresentation.make(session: nil)
        XCTAssertFalse(footer.text.contains("尚未上传"))
        XCTAssertFalse(footer.text.contains("已上传"))
    }

    func testPostPartialConfirmationNeverDescribesTheWholePlanAsUpcoming() {
        let subject = session(confirmedAt: Date(timeIntervalSince1970: 1), uploadedItemCount: 2, plan: mixedPlan)
        let confirmation = InventoryMergeConfirmationPresentation.make(
            summary: InventoryMergeSummaryPresentation.make(plan: mixedPlan), session: subject
        )
        XCTAssertEqual(confirmation.buttonTitle, "确认当前处理计划")
        XCTAssertEqual(confirmation.supportingCopy, "当前页面汇总本次会话的整体计划，系统会根据当前同步状态继续处理。")
        // Must not reuse the first-pass definite copy, nor invent a remaining count.
        XCTAssertFalse(confirmation.supportingCopy.contains("计划新增"), confirmation.supportingCopy)
        XCTAssertFalse(confirmation.buttonTitle.contains("先合并其余"), confirmation.buttonTitle)
    }

    func testPostPartialConfirmationWithNothingOutstandingIsStillConservative() {
        let resolved = plan([
            candidate(id: 1, action: .create),
            candidate(id: 2, action: .create, reason: .quantityMismatch, choice: .keepLocal)
        ])
        let subject = session(confirmedAt: Date(timeIntervalSince1970: 1), uploadedItemCount: 1, plan: resolved)
        let confirmation = InventoryMergeConfirmationPresentation.make(
            summary: InventoryMergeSummaryPresentation.make(plan: resolved), session: subject
        )
        XCTAssertEqual(confirmation.buttonTitle, "确认当前处理计划")
        // Same sentence whether or not conflicts remain — it never claims this
        // page can distinguish which individual entries are outstanding.
        XCTAssertEqual(confirmation.supportingCopy, "当前页面汇总本次会话的整体计划，系统会根据当前同步状态继续处理。")
    }

    /// An all-skip plan in a session that already uploaded must NOT claim
    /// "本次不会上传任何库存" — something was uploaded earlier in this session.
    func testAllSkipCopyIsSuppressedOnceTheSessionHasAlreadyUploaded() {
        let allSkip = plan((1...3).map {
            candidate(id: $0, action: .create, reason: .quantityMismatch, choice: .skip)
        })
        let subject = session(confirmedAt: Date(timeIntervalSince1970: 1), uploadedItemCount: 3, plan: allSkip)
        let confirmation = InventoryMergeConfirmationPresentation.make(
            summary: InventoryMergeSummaryPresentation.make(plan: allSkip), session: subject
        )
        XCTAssertNotEqual(confirmation.buttonTitle, "完成，不上传任何条目")
        XCTAssertFalse(confirmation.supportingCopy.contains("本次不会上传任何库存"), confirmation.supportingCopy)
    }

    func testPresentationMappingNeverMutatesTheSession() {
        let before = session(confirmedAt: Date(timeIntervalSince1970: 1), uploadedItemCount: 2, plan: mixedPlan)
        let snapshot = before
        _ = InventoryMergeReviewFooterPresentation.make(session: before)
        _ = InventoryMergeConfirmationPresentation.make(
            summary: InventoryMergeSummaryPresentation.make(plan: mixedPlan), session: before
        )
        XCTAssertEqual(before, snapshot, "presentation mapping 不得修改 session")
    }

    func testResolvedSummaryTextNeverAssertsAnUploadState() {
        for subject in [mixedPlan, plan([candidate(id: 1, action: .create, reason: .quantityMismatch, choice: .skip)])] {
            let text = InventoryMergeSummaryPresentation.make(plan: subject).resolvedSummaryText
            for banned in ["尚未上传", "已上传", "已合并"] {
                XCTAssertFalse(text.contains(banned), text)
            }
        }
    }

    func testPostPartialCopyUsesNoDeveloperFacingWordingAndNoUploadClaim() {
        let subject = session(confirmedAt: Date(timeIntervalSince1970: 1), uploadedItemCount: 2, plan: mixedPlan)
        let confirmation = InventoryMergeConfirmationPresentation.make(
            summary: InventoryMergeSummaryPresentation.make(plan: mixedPlan), session: subject
        )
        XCTAssertEqual(confirmation.buttonTitle, "确认当前处理计划")
        XCTAssertEqual(confirmation.supportingCopy, "当前页面汇总本次会话的整体计划，系统会根据当前同步状态继续处理。")
        for banned in ["文案", "重新定义", "尚未上传", "已经上传", "已上传", "已经合并", "已合并"] {
            XCTAssertFalse(
                confirmation.supportingCopy.contains(banned),
                "post-partial 文案不得包含“\(banned)”：\(confirmation.supportingCopy)"
            )
            XCTAssertFalse(confirmation.buttonTitle.contains(banned), confirmation.buttonTitle)
        }
    }

    /// Identical with and without outstanding conflicts, so the sentence cannot
    /// imply a per-item distinction the source cannot make.
    func testPostPartialCopyIsIdenticalWithAndWithoutOutstandingConflicts() {
        let withUnresolved = session(confirmedAt: Date(timeIntervalSince1970: 1), uploadedItemCount: 2, plan: mixedPlan)
        let allResolved = plan([
            candidate(id: 1, action: .create),
            candidate(id: 2, action: .create, reason: .quantityMismatch, choice: .keepLocal)
        ])
        let withoutUnresolved = session(confirmedAt: Date(timeIntervalSince1970: 1), uploadedItemCount: 1, plan: allResolved)
        let a = InventoryMergeConfirmationPresentation.make(
            summary: InventoryMergeSummaryPresentation.make(plan: mixedPlan), session: withUnresolved
        )
        let b = InventoryMergeConfirmationPresentation.make(
            summary: InventoryMergeSummaryPresentation.make(plan: allResolved), session: withoutUnresolved
        )
        XCTAssertEqual(a, b)
    }

    /// A failed first confirm still recorded `confirmedAt`, so the neutral copy
    /// has to hold there too.
    func testFailedFirstConfirmAlsoGetsTheNeutralCopy() {
        let subject = session(
            status: .failed, confirmedAt: Date(timeIntervalSince1970: 1), uploadedItemCount: 0, plan: mixedPlan
        )
        let confirmation = InventoryMergeConfirmationPresentation.make(
            summary: InventoryMergeSummaryPresentation.make(plan: mixedPlan), session: subject
        )
        XCTAssertEqual(confirmation.buttonTitle, "确认当前处理计划")
        XCTAssertEqual(confirmation.supportingCopy, "当前页面汇总本次会话的整体计划，系统会根据当前同步状态继续处理。")
    }
}

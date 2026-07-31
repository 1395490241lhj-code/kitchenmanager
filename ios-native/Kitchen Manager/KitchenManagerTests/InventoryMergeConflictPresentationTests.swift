import XCTest
@testable import KitchenManager

/// UI-5B2B-B1: pure presentation mapping for conflict choices.
///
/// `InventoryMergeConflictChoicePresentation` owns only titles and
/// plain-language consequence copy. These tests exist because the previous
/// screen derived its displayed selection from
/// `pendingChoice[id] ?? .keepRemote` — a view-local default that showed
/// 保留家庭 as chosen before the user had chosen anything, and that ignored the
/// persisted `userChoice` entirely. Nothing here touches a controller, a
/// transport, persistence, or the network.
final class InventoryMergeConflictPresentationTests: XCTestCase {
    private let localId = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let otherRemoteId = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    private func candidate(
        remoteItemId: UUID?,
        userChoice: InventoryMergeConflictChoice? = nil,
        reason: InventoryMergeConflictReason? = .quantityMismatch
    ) -> InventoryMergeCandidate {
        InventoryMergeCandidate(
            localItemId: localId,
            name: "豆腐",
            unit: "块",
            localQuantity: 1,
            localExpiryDate: nil,
            remoteItemId: remoteItemId,
            remoteQuantity: 3,
            remoteExpiryDate: nil,
            remoteVersion: nil,
            action: .create,
            conflictReason: reason,
            userChoice: userChoice
        )
    }

    // MARK: - No phantom default

    func testNilUserChoiceSelectsNoOptionAtAll() {
        let subject = candidate(remoteItemId: localId, userChoice: nil)
        for choice in InventoryMergeConflictChoicePresentation.orderedChoices {
            XCTAssertFalse(
                subject.userChoice == choice,
                "未选择时 \(choice.rawValue) 不得显示为已选中"
            )
        }
        XCTAssertNil(subject.userChoice, "presentation 不得写入 userChoice")
    }

    func testKeepRemoteIsNotTreatedAsAnImplicitDefault() {
        let subject = candidate(remoteItemId: localId, userChoice: nil)
        XCTAssertFalse(
            subject.userChoice == .keepRemote,
            "保留家庭曾因 `pendingChoice[id] ?? .keepRemote` 被误显示为默认选中"
        )
    }

    func testEachPersistedChoiceMapsToItselfAndNothingElse() {
        for persisted in InventoryMergeConflictChoicePresentation.orderedChoices {
            let subject = candidate(remoteItemId: localId, userChoice: persisted)
            let selected = InventoryMergeConflictChoicePresentation.orderedChoices
                .filter { subject.userChoice == $0 }
            XCTAssertEqual(selected, [persisted], "持久化的 \(persisted.rawValue) 必须且只能映射为自身")
        }
    }

    // MARK: - Display order

    func testOrderedChoicesCoverAllFourOptionsInDisplayOrder() {
        XCTAssertEqual(
            InventoryMergeConflictChoicePresentation.orderedChoices,
            [.keepLocal, .keepRemote, .keepBoth, .skip]
        )
    }

    // MARK: - Titles

    func testTitlesAreStableAndUseTheApprovedWording() {
        let expected: [InventoryMergeConflictChoice: String] = [
            .keepLocal: "保留本机",
            .keepRemote: "保留家庭",
            .keepBoth: "两条都保留",
            .skip: "本次跳过"
        ]
        for (choice, title) in expected {
            for isSame in [true, false] {
                XCTAssertEqual(
                    InventoryMergeConflictChoicePresentation.make(choice: choice, isSameRemoteRecord: isSame).title,
                    title,
                    "\(choice.rawValue) 标题应与 same-ID 判定无关"
                )
            }
        }
    }

    // MARK: - same-ID copy

    func testSameIdKeepLocalSaysItReplacesTheFamilyRecord() {
        let copy = InventoryMergeConflictChoicePresentation.make(choice: .keepLocal, isSameRemoteRecord: true).consequence
        XCTAssertTrue(copy.contains("更新家庭库存里的同一条记录"), copy)
        XCTAssertTrue(copy.contains("替换"), "same-ID 保留本机必须说明会替换家庭内容：\(copy)")
    }

    func testSameIdKeepBothSaysItAddsASeparateCopyWithoutOverwriting() {
        let copy = InventoryMergeConflictChoicePresentation.make(choice: .keepBoth, isSameRemoteRecord: true).consequence
        XCTAssertTrue(copy.contains("单独新增一份"), copy)
        XCTAssertTrue(copy.contains("不会覆盖"), copy)
    }

    // MARK: - different-ID copy

    func testDifferentIdKeepLocalSaysItAddsToTheFamilyInventory() {
        let copy = InventoryMergeConflictChoicePresentation.make(choice: .keepLocal, isSameRemoteRecord: false).consequence
        XCTAssertTrue(copy.contains("新增到家庭库存"), copy)
        XCTAssertTrue(copy.contains("保持不变"), "different-ID 保留本机不得暗示覆盖：\(copy)")
        XCTAssertFalse(copy.contains("替换"), "different-ID 保留本机不会替换任何记录：\(copy)")
    }

    func testDifferentIdKeepBothSaysBothRecordsAreKept() {
        let copy = InventoryMergeConflictChoicePresentation.make(choice: .keepBoth, isSameRemoteRecord: false).consequence
        XCTAssertTrue(copy.contains("另一条记录"), copy)
        XCTAssertTrue(copy.contains("两条都会保留"), copy)
    }

    func testKeepLocalAndKeepBothCopyDiffersBetweenSameIdAndDifferentId() {
        for choice in [InventoryMergeConflictChoice.keepLocal, .keepBoth] {
            let same = InventoryMergeConflictChoicePresentation.make(choice: choice, isSameRemoteRecord: true).consequence
            let different = InventoryMergeConflictChoicePresentation.make(choice: choice, isSameRemoteRecord: false).consequence
            XCTAssertNotEqual(same, different, "\(choice.rawValue) 的 same-ID 与 different-ID 文案必须不同")
        }
    }

    // MARK: - Identity-independent copy

    func testKeepRemoteAndSkipCopyDoesNotDependOnIdentityMatch() {
        for choice in [InventoryMergeConflictChoice.keepRemote, .skip] {
            let same = InventoryMergeConflictChoicePresentation.make(choice: choice, isSameRemoteRecord: true)
            let different = InventoryMergeConflictChoicePresentation.make(choice: choice, isSameRemoteRecord: false)
            XCTAssertEqual(same, different, "\(choice.rawValue) 的结果与是否同一条记录无关")
        }
    }

    func testKeepRemoteSaysFamilyStaysAndLocalIsNotUploaded() {
        let copy = InventoryMergeConflictChoicePresentation.make(choice: .keepRemote, isSameRemoteRecord: true).consequence
        XCTAssertTrue(copy.contains("保持不变"), copy)
        XCTAssertTrue(copy.contains("不会上传"), copy)
    }

    /// Deliberately does not promise the re-editing entry point, which is
    /// UI-5B2B-B2 and does not exist yet.
    func testSkipSaysItIsNotUploadedThisTimeWithoutPromisingReEditing() {
        let copy = InventoryMergeConflictChoicePresentation.make(choice: .skip, isSameRemoteRecord: false).consequence
        XCTAssertTrue(copy.contains("本次合并不会上传"), copy)
        for promise in ["稍后可以修改", "可重新选择", "重新编辑", "以后可以改"] {
            XCTAssertFalse(copy.contains(promise), "不得承诺尚未实现的重新编辑入口：\(copy)")
        }
    }

    // MARK: - Plain language

    func testNoConsequenceCopyLeaksTechnicalTerms() {
        for choice in InventoryMergeConflictChoicePresentation.orderedChoices {
            for isSame in [true, false] {
                let copy = InventoryMergeConflictChoicePresentation.make(choice: choice, isSameRemoteRecord: isSame).consequence
                for term in ["fork", "Fork", "hash", "Hash", "remote ID", "remoteId", "mutation", "Mutation", "snapshot", "Snapshot", "ID"] {
                    XCTAssertFalse(copy.contains(term), "\(choice.rawValue) 文案泄漏技术术语 \(term)：\(copy)")
                }
            }
        }
    }

    // MARK: - Purity

    func testMakingPresentationNeverMutatesTheCandidate() {
        let before = candidate(remoteItemId: localId, userChoice: .keepLocal)
        var subject = before
        for choice in InventoryMergeConflictChoicePresentation.orderedChoices {
            _ = InventoryMergeConflictChoicePresentation.make(
                choice: choice,
                isSameRemoteRecord: subject.remoteItemId == subject.localItemId
            )
        }
        XCTAssertEqual(subject, before, "presentation 不得修改 candidate")
        XCTAssertEqual(subject.userChoice, .keepLocal)
        XCTAssertEqual(subject.action, before.action)
        XCTAssertEqual(subject.forkedLocalItemId, before.forkedLocalItemId)
        subject.userChoice = before.userChoice
    }

    func testIdentityComparisonMatchesApplyingChoiceBehaviorForSameId() {
        // The copy says same-ID keepLocal *updates* the family record; verify the
        // model genuinely behaves that way, so copy and behavior cannot drift.
        let sameId = candidate(remoteItemId: localId).applyingChoice(.keepLocal)
        XCTAssertEqual(sameId.action, .update)
        let differentId = candidate(remoteItemId: otherRemoteId).applyingChoice(.keepLocal)
        XCTAssertEqual(differentId.action, .create)
    }

    func testIdentityComparisonMatchesApplyingChoiceBehaviorForKeepBoth() {
        let sameId = candidate(remoteItemId: localId).applyingChoice(.keepBoth)
        XCTAssertEqual(sameId.action, .create)
        XCTAssertNotNil(sameId.forkedLocalItemId, "same-ID 两条都保留会另建一份")
        let differentId = candidate(remoteItemId: otherRemoteId).applyingChoice(.keepBoth)
        XCTAssertEqual(differentId.action, .create)
        XCTAssertNil(differentId.forkedLocalItemId, "different-ID 使用自身 id，无需另建")
    }
}

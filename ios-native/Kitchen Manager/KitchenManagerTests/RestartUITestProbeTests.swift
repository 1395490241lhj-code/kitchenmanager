import XCTest
@testable import KitchenManager

/// UI-5B2B-B2B: value mapping behind the cold-relaunch probes, plus the fixture
/// isolation rules the restart launch modes depend on.
///
/// These exist so a probe can be trusted before a UI test relies on it — the
/// earlier dynamic marker failed silently and made a UI failure unreadable.
final class RestartUITestProbeTests: XCTestCase {
    private let candidateId = AccountLifecycleSummaryFixture.restartSameIDCandidateID
    private let otherId = UUID(uuidString: "00000000-0000-0000-0000-0000000007FF")!

    private func candidate(
        choice: InventoryMergeConflictChoice? = nil, sameIdentity: Bool = true
    ) -> InventoryMergeCandidate {
        let base = InventoryMergeCandidate(
            localItemId: candidateId, name: "豆腐", unit: "份",
            localQuantity: 60, localExpiryDate: nil,
            remoteItemId: sameIdentity ? candidateId : otherId,
            remoteQuantity: 61, remoteExpiryDate: nil, remoteVersion: nil,
            action: .create, conflictReason: .quantityMismatch, userChoice: nil
        )
        guard let choice else { return base }
        return base.applyingChoice(choice)
    }

    private func plan(_ candidates: [InventoryMergeCandidate]) -> InventoryMergePlan {
        InventoryMergePlan(
            sessionId: UUID(uuidString: "00000000-0000-0000-0000-00000000076A")!,
            householdId: AccountLifecycleSummaryFixture.choiceEditingRestart.householdID,
            generatedAt: Date(timeIntervalSince1970: 1), sourceCount: candidates.count,
            candidates: candidates, skippedItemIds: [], planHash: "probe",
            knownRemoteItemCount: candidates.count, remoteSnapshotHash: "probe-remote",
            remoteSnapshotFetchedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func field(_ payload: String, _ key: String) -> String? {
        payload.split(separator: ";").first { $0.hasPrefix("\(key)=") }
            .map { String($0.dropFirst(key.count + 1)) }
    }

    // MARK: - Waiting / missing

    func testForkIdentityReportsMissingPlanRatherThanVanishing() {
        let value = RestartUITestProbePresentation.forkIdentity(plan: nil, candidateId: candidateId)
        XCTAssertEqual(value, "state=missing-plan", "plan 缺失时必须给出明确状态，而不是没有值")
    }

    func testForkIdentityReportsMissingCandidateWithoutStaleData() {
        let unrelated = InventoryMergeCandidate(
            localItemId: otherId, name: "大米", unit: "份", localQuantity: 1, localExpiryDate: nil,
            remoteItemId: otherId, remoteQuantity: 2, remoteExpiryDate: nil, remoteVersion: nil,
            action: .create, conflictReason: .quantityMismatch, userChoice: .keepBoth
        )
        let value = RestartUITestProbePresentation.forkIdentity(
            plan: plan([unrelated]), candidateId: candidateId
        )
        XCTAssertEqual(value, "state=missing-candidate")
        XCTAssertFalse(value.contains("keepBoth"), "不得显示其他 candidate 的数据：\(value)")
        XCTAssertFalse(value.contains(otherId.uuidString.lowercased()), value)
    }

    func testSessionAndOriginAndMutationCountReportWaitingWhenUnknown() {
        XCTAssertEqual(RestartUITestProbePresentation.session(nil), "state=waiting")
        XCTAssertEqual(RestartUITestProbePresentation.previewOrigin(nil), "state=waiting")
        XCTAssertEqual(RestartUITestProbePresentation.mutationCount(nil), "state=waiting")
        XCTAssertEqual(RestartUITestProbePresentation.inventory([]), "state=empty")
    }

    // MARK: - Choice states

    func testInitialUnresolvedCandidateHasNoReservation() {
        let value = RestartUITestProbePresentation.forkIdentity(
            plan: plan([candidate()]), candidateId: candidateId
        )
        XCTAssertEqual(field(value, "state"), "ready")
        XCTAssertEqual(field(value, "candidate"), candidateId.uuidString.lowercased())
        XCTAssertEqual(field(value, "choice"), "nil")
        XCTAssertEqual(field(value, "action"), "create")
        XCTAssertEqual(field(value, "reserved"), "nil")
        XCTAssertEqual(field(value, "active"), "nil")
    }

    func testKeepBothReportsMatchingReservedAndActive() throws {
        let resolved = candidate(choice: .keepBoth)
        let value = RestartUITestProbePresentation.forkIdentity(
            plan: plan([resolved]), candidateId: candidateId
        )
        XCTAssertEqual(field(value, "choice"), "keepBoth")
        XCTAssertEqual(field(value, "action"), "create")
        let reserved = try XCTUnwrap(field(value, "reserved"))
        XCTAssertNotEqual(reserved, "nil")
        XCTAssertEqual(field(value, "active"), reserved)
    }

    func testSkipRetainsReservationAndClearsActive() throws {
        let keepBoth = candidate(choice: .keepBoth)
        let reserved = try XCTUnwrap(keepBoth.forkedLocalItemId).uuidString.lowercased()
        let value = RestartUITestProbePresentation.forkIdentity(
            plan: plan([keepBoth.applyingChoice(.skip)]), candidateId: candidateId
        )
        XCTAssertEqual(field(value, "choice"), "skip")
        XCTAssertEqual(field(value, "action"), "skip")
        XCTAssertEqual(field(value, "reserved"), reserved, "skip 必须保留 reservation")
        XCTAssertEqual(field(value, "active"), "nil", "skip 下不得有 active fork")
    }

    func testReturningToKeepBothReusesTheSameReservation() throws {
        let keepBoth = candidate(choice: .keepBoth)
        let reserved = try XCTUnwrap(keepBoth.forkedLocalItemId).uuidString.lowercased()
        let restored = keepBoth.applyingChoice(.skip).applyingChoice(.keepBoth)
        let value = RestartUITestProbePresentation.forkIdentity(
            plan: plan([restored]), candidateId: candidateId
        )
        XCTAssertEqual(field(value, "reserved"), reserved)
        XCTAssertEqual(field(value, "active"), reserved)
    }

    // MARK: - Canonical formatting

    func testEveryUUIDInProbeValuesIsLowercased() throws {
        let value = RestartUITestProbePresentation.forkIdentity(
            plan: plan([candidate(choice: .keepBoth)]), candidateId: candidateId
        )
        for key in ["candidate", "reserved", "active"] {
            let field = try XCTUnwrap(self.field(value, key))
            XCTAssertEqual(field, field.lowercased(), "\(key) 必须小写：\(field)")
        }
    }

    func testInventoryProbeIsStableAndLowercased() {
        let items = AccountLifecycleSummaryFixture.restartLocalItems
        let value = RestartUITestProbePresentation.inventory(items)
        XCTAssertEqual(field(value, "count"), "\(items.count)")
        let ids = try! XCTUnwrap(field(value, "ids"))
        XCTAssertEqual(ids, ids.lowercased())
        // Same input, same output — no random ordering inside the mapping.
        XCTAssertEqual(RestartUITestProbePresentation.inventory(items), value)
    }

    func testModeAndFixtureStateStrings() {
        XCTAssertEqual(RestartUITestProbePresentation.mode(.none), "none")
        XCTAssertEqual(RestartUITestProbePresentation.mode(.seed), "seed")
        XCTAssertEqual(RestartUITestProbePresentation.mode(.resume), "resume")
        XCTAssertEqual(RestartUITestProbePresentation.fixtureState(.none), "not-a-restart-launch")
        XCTAssertEqual(RestartUITestProbePresentation.fixtureState(.seed), "seeded")
        XCTAssertEqual(RestartUITestProbePresentation.fixtureState(.resume), "resume-no-seed")
    }

    // MARK: - Restart fixture shape

    func testRestartFixtureCandidateIsASameIDUnresolvedConflictPresentInLocalInventory() throws {
        let items = AccountLifecycleSummaryFixture.restartLocalItems
        XCTAssertTrue(
            items.contains { $0.id == candidateId },
            "canonical candidate 必须存在于 restart 本地库存"
        )
        let session = AccountLifecycleSummaryFixture.choiceEditingRestart.session(
            userID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!, localItems: items
        )
        let seeded = try XCTUnwrap(session.plan?.candidates.first { $0.localItemId == candidateId })
        XCTAssertEqual(seeded.remoteItemId, seeded.localItemId, "必须是 same-ID 冲突")
        XCTAssertNotNil(seeded.conflictReason)
        XCTAssertNil(seeded.userChoice, "初始必须未处理，choice 由 UI 产生")
        XCTAssertNil(seeded.forkedLocalItemId, "初始不得预留 fork")
    }

    func testRestartLocalItemsAreFullyDeterministic() {
        let first = AccountLifecycleSummaryFixture.restartLocalItems
        let second = AccountLifecycleSummaryFixture.restartLocalItems
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.map(\.quantity), second.map(\.quantity))
        XCTAssertEqual(first.map(\.unit), second.map(\.unit))
        XCTAssertEqual(first.map(\.createdAt), second.map(\.createdAt))
        XCTAssertEqual(first.map(\.updatedAt), second.map(\.updatedAt))
        XCTAssertTrue(first.allSatisfy { $0.expiryDate == nil })
    }

    /// The seeded plan hash must match what `isPlanStillValid` recomputes from
    /// the same deterministic items — otherwise a relaunch regenerates the plan
    /// and silently discards the recorded choices.
    func testSeededRestartPlanIsStillValidAgainstItsOwnDeterministicInventory() throws {
        let items = AccountLifecycleSummaryFixture.restartLocalItems
        let session = AccountLifecycleSummaryFixture.choiceEditingRestart.session(
            userID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!, localItems: items
        )
        let seededPlan = try XCTUnwrap(session.plan)
        XCTAssertTrue(
            InventoryMergePlanner.isPlanStillValid(seededPlan, against: items, currentRemoteItems: []),
            "restart fixture 的 planHash 必须与其确定性库存一致"
        )
        XCTAssertEqual(session.status, .previewReady)
        XCTAssertNil(session.confirmedAt)
        XCTAssertEqual(session.uploadedItemCount, 0)
        XCTAssertTrue(session.createdEntityIds.isEmpty)
    }

    // MARK: - Launch-mode isolation

    func testRestartLaunchModeIsNoneWithoutTheRestartArguments() {
        // The unit-test process passes neither argument.
        XCTAssertEqual(AccountLifecycleSummaryFixture.restartLaunchMode, .none)
        XCTAssertFalse(AccountLifecycleSummaryFixture.isResumeOnlyLaunch)
    }

    func testRestartFixtureUsesIsolatedHouseholdAndSession() {
        let restart = AccountLifecycleSummaryFixture.choiceEditingRestart
        for other in AccountLifecycleSummaryFixture.allCases where other != restart {
            XCTAssertNotEqual(restart.householdID, other.householdID)
            XCTAssertNotEqual(restart.sessionID, other.sessionID)
        }
        // And distinct from the B1 conflict fixtures.
        for conflict in AccountLifecycleConflictFixture.allCases {
            XCTAssertNotEqual(restart.householdID, conflict.householdID)
            XCTAssertNotEqual(restart.sessionID, conflict.sessionID)
        }
    }

    func testOrdinaryFixturesStillActivateAndKeepTheirOwnIdentities() {
        // `.none` mode must leave every pre-existing fixture untouched.
        XCTAssertEqual(AccountLifecycleSummaryFixture.allCases.count,
                       Set(AccountLifecycleSummaryFixture.allCases.map(\.rawValue)).count)
        XCTAssertTrue(AccountLifecycleSummaryFixture.allCases.contains(.mixed))
        XCTAssertTrue(AccountLifecycleSummaryFixture.allCases.contains(.postPartialConfirmResumed))
        XCTAssertTrue(AccountLifecycleConflictFixture.allCases.contains(.sameIDQuantity))
        XCTAssertTrue(AccountLifecycleConflictFixture.allCases.contains(.longList))
    }
}

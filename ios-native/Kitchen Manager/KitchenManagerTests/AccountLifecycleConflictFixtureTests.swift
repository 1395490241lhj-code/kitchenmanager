import XCTest
import SwiftData
@testable import KitchenManager

/// UI-5B2B-B1: safety properties of the DEBUG-only conflict fixtures.
///
/// SwiftUI may run a `.task` more than once, so seeding has to be safe to
/// repeat. These tests exercise the launch-argument-independent `seed(...)`
/// entry point directly against in-memory persistence, so the properties are
/// proven deterministically instead of inferred from a UI run.
@MainActor
final class AccountLifecycleConflictFixtureTests: XCTestCase {
    private let userID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!

    override func setUp() {
        super.setUp()
        AccountLifecycleConflictFixture.resetSeedTrackingForTesting()
        AccountLifecycleSummaryFixture.resetSeedTrackingForTesting()
    }

    private func makePersistence() throws -> (ModelContainer, SwiftDataSyncPersistence) {
        let container = try ModelContainer(
            for: InventoryRecord.self, SyncMetadataRecord.self, PendingMutationRecord.self,
            SyncCursorRecord.self, GuestMergeSessionRecord.self, InventorySyncEnrollmentRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (container, SwiftDataSyncPersistence(modelContainer: container))
    }

    private func sessionCount(_ container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<GuestMergeSessionRecord>())
    }

    // MARK: - Activation

    func testNoConflictFixtureIsActiveWithoutItsLaunchArgument() {
        // The unit-test process passes none of the conflict arguments, so this
        // is also a direct check that an ordinary launch seeds nothing.
        XCTAssertNil(AccountLifecycleConflictFixture.active)
    }

    func testSeedIfRequestedIsANoOpWhenNoFixtureIsActive() async throws {
        let (container, persistence) = try makePersistence()
        let seeded = await AccountLifecycleConflictFixture.seedIfRequested(
            persistence: persistence, userID: userID
        )
        XCTAssertFalse(seeded, "没有 conflict launch argument 时不得 seed")
        XCTAssertEqual(try sessionCount(container), 0, "普通启动不得写入任何 session")
    }

    func testEveryFixtureUsesADistinctHouseholdAndSession() {
        let households = AccountLifecycleConflictFixture.allCases.map(\.householdID)
        let sessions = AccountLifecycleConflictFixture.allCases.map(\.sessionID)
        XCTAssertEqual(Set(households).count, households.count, "fixture household 必须互不相同")
        XCTAssertEqual(Set(sessions).count, sessions.count, "fixture session 必须互不相同")
        // Also distinct from the pre-existing merge fixtures' household.
        let legacyHousehold = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        XCTAssertFalse(households.contains(legacyHousehold), "不得复用既有 merge fixture 的 household")
    }

    func testEveryFixtureSeedsAConflictSessionWhoseCandidatesAllNeedADecision() {
        for fixture in AccountLifecycleConflictFixture.allCases {
            let session = fixture.session(userID: userID)
            XCTAssertEqual(session.status, .conflict, "\(fixture.rawValue) 必须处于 conflict 状态")
            let candidates = try! XCTUnwrap(session.plan).candidates
            XCTAssertFalse(candidates.isEmpty, "\(fixture.rawValue) 应至少有一条冲突")
            for candidate in candidates {
                XCTAssertNotNil(candidate.conflictReason, "\(fixture.rawValue) 每条候选都应有冲突原因")
                XCTAssertNil(candidate.userChoice, "\(fixture.rawValue) 候选不得预设选择")
            }
        }
    }

    // MARK: - Idempotency

    func testSeedingTheSameFixtureTwiceCreatesExactlyOneSession() async throws {
        let (container, persistence) = try makePersistence()
        let fixture = AccountLifecycleConflictFixture.multiple

        let firstSeed = await fixture.seed(persistence: persistence, userID: userID)
        XCTAssertTrue(firstSeed)
        XCTAssertEqual(try sessionCount(container), 1)

        for _ in 0..<3 {
            let repeated = await fixture.seed(persistence: persistence, userID: userID)
            XCTAssertTrue(repeated, "重复 seed 应报告 fixture 已就绪")
        }
        XCTAssertEqual(try sessionCount(container), 1, "重复 seed 不得产生第二个 session")
    }

    func testRepeatSeedingDoesNotDuplicateCandidates() async throws {
        let (_, persistence) = try makePersistence()
        let fixture = AccountLifecycleConflictFixture.longList
        let expected = fixture.session(userID: userID).plan?.candidates.count

        for _ in 0..<3 { await fixture.seed(persistence: persistence, userID: userID) }

        let stored = try await persistence.activeGuestMergeSession(
            userId: userID, householdId: fixture.householdID, entityType: .inventoryItem
        )
        let candidates = try XCTUnwrap(stored?.plan?.candidates)
        XCTAssertEqual(candidates.count, expected, "重复 seed 不得追加重复候选")
        XCTAssertEqual(Set(candidates.map(\.localItemId)).count, candidates.count, "候选 id 必须唯一")
    }

    /// The reason the per-process guard exists: without it, a second `.task`
    /// run would upsert the pristine fixture over a session the test had already
    /// made choices in, silently undoing them.
    func testRepeatSeedingDoesNotOverwriteAlreadyResolvedChoices() async throws {
        let (_, persistence) = try makePersistence()
        let fixture = AccountLifecycleConflictFixture.multiple
        await fixture.seed(persistence: persistence, userID: userID)

        let loaded = try await persistence.activeGuestMergeSession(
            userId: userID, householdId: fixture.householdID, entityType: .inventoryItem
        )
        var session = try XCTUnwrap(loaded)
        var plan = try XCTUnwrap(session.plan)
        plan.candidates[0] = plan.candidates[0].applyingChoice(.skip)
        session.plan = plan
        try await persistence.saveGuestMergeSession(session)

        await fixture.seed(persistence: persistence, userID: userID)

        let reloadedRaw = try await persistence.activeGuestMergeSession(
            userId: userID, householdId: fixture.householdID, entityType: .inventoryItem
        )
        let reloaded = try XCTUnwrap(reloadedRaw)
        XCTAssertEqual(
            reloaded.plan?.candidates.first?.userChoice, .skip,
            "重复 seed 不得把已处理的选择重置为未处理"
        )
    }

    /// The other half of the scoping: a new process must re-seed, or a scenario
    /// a previous UI test case resolved would be inherited already-resolved.
    func testANewProcessReSeedsAPreviouslyResolvedFixture() async throws {
        let (container, persistence) = try makePersistence()
        let fixture = AccountLifecycleConflictFixture.multiple
        await fixture.seed(persistence: persistence, userID: userID)

        let loaded = try await persistence.activeGuestMergeSession(
            userId: userID, householdId: fixture.householdID, entityType: .inventoryItem
        )
        var session = try XCTUnwrap(loaded)
        var plan = try XCTUnwrap(session.plan)
        plan.candidates[0] = plan.candidates[0].applyingChoice(.skip)
        session.plan = plan
        try await persistence.saveGuestMergeSession(session)

        // Simulate a fresh app launch against the same persistent store.
        AccountLifecycleConflictFixture.resetSeedTrackingForTesting()
        await fixture.seed(persistence: persistence, userID: userID)

        let reloadedRaw = try await persistence.activeGuestMergeSession(
            userId: userID, householdId: fixture.householdID, entityType: .inventoryItem
        )
        let reloaded = try XCTUnwrap(reloadedRaw)
        XCTAssertNil(
            reloaded.plan?.candidates.first?.userChoice,
            "新进程必须重新 seed，否则上一条测试的选择会泄漏到下一条"
        )
        XCTAssertEqual(reloaded.plan?.conflicts.count, 3, "重新 seed 后应回到三条未处理冲突")
        XCTAssertEqual(try sessionCount(container), 1, "重新 seed 仍然只有一个 session")
    }

    func testSeedingOneFixtureDoesNotDisturbAnother() async throws {
        let (container, persistence) = try makePersistence()
        let first = AccountLifecycleConflictFixture.sameIDQuantity
        let second = AccountLifecycleConflictFixture.differentIDMetadata

        await first.seed(persistence: persistence, userID: userID)
        await second.seed(persistence: persistence, userID: userID)
        await first.seed(persistence: persistence, userID: userID)

        XCTAssertEqual(try sessionCount(container), 2, "两个 fixture 应各自独立")
        let firstSession = try await persistence.activeGuestMergeSession(
            userId: userID, householdId: first.householdID, entityType: .inventoryItem
        )
        let secondSession = try await persistence.activeGuestMergeSession(
            userId: userID, householdId: second.householdID, entityType: .inventoryItem
        )
        XCTAssertEqual(firstSession?.id, first.sessionID)
        XCTAssertEqual(secondSession?.id, second.sessionID)
    }

    // MARK: - No writes beyond the local session

    func testSeedingStagesNoMutationAndAdvancesNoCursor() async throws {
        let (container, persistence) = try makePersistence()
        for fixture in AccountLifecycleConflictFixture.allCases {
            await fixture.seed(persistence: persistence, userID: userID)
        }
        let context = ModelContext(container)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<PendingMutationRecord>()), 0,
            "seed 不得暂存任何 mutation"
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<SyncCursorRecord>()), 0,
            "seed 不得推进 sync cursor"
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<InventoryRecord>()), 0,
            "seed 不得写入本机库存"
        )
    }

    // MARK: - UI-5B2B-B2A summary fixtures

    func testNoSummaryFixtureIsActiveWithoutItsLaunchArgument() {
        XCTAssertNil(AccountLifecycleSummaryFixture.active)
    }

    func testSummarySeedIfRequestedIsANoOpWhenNoFixtureIsActive() async throws {
        let (container, persistence) = try makePersistence()
        let seeded = await AccountLifecycleSummaryFixture.seedIfRequested(
            persistence: persistence, userID: userID, localItems: []
        )
        XCTAssertFalse(seeded, "没有 summary launch argument 时不得 seed")
        XCTAssertEqual(try sessionCount(container), 0, "普通启动不得写入任何 session")
    }

    func testSummaryFixturesUseHouseholdsAndSessionsIsolatedFromConflictFixtures() {
        let summaryHouseholds = AccountLifecycleSummaryFixture.allCases.map(\.householdID)
        let summarySessions = AccountLifecycleSummaryFixture.allCases.map(\.sessionID)
        XCTAssertEqual(Set(summaryHouseholds).count, summaryHouseholds.count, "household 必须互不相同")
        XCTAssertEqual(Set(summarySessions).count, summarySessions.count, "session 必须互不相同")

        let conflictHouseholds = Set(AccountLifecycleConflictFixture.allCases.map(\.householdID))
        let conflictSessions = Set(AccountLifecycleConflictFixture.allCases.map(\.sessionID))
        XCTAssertTrue(Set(summaryHouseholds).isDisjoint(with: conflictHouseholds), "不得复用 B1 的 household")
        XCTAssertTrue(Set(summarySessions).isDisjoint(with: conflictSessions), "不得复用 B1 的 session")

        // Also distinct from the pre-existing merge fixtures' households.
        for raw in 0x10...0x17 {
            let legacy = UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000000%02d", raw))!
            XCTAssertFalse(summaryHouseholds.contains(legacy))
        }
    }

    func testEverySummaryFixtureSeedsAPreviewReadySession() {
        for fixture in AccountLifecycleSummaryFixture.allCases {
            let session = fixture.session(userID: userID, localItems: [])
            XCTAssertEqual(
                session.status, .previewReady,
                "\(fixture.rawValue) 必须是 previewReady —— 本阶段的界面都在预览页"
            )
            XCTAssertNotNil(session.plan)
        }
    }

    /// The seeded plan must look current to `preparePreview`, or it would be
    /// regenerated for a `.previewReady` session and the recorded choices this
    /// phase displays would be discarded.
    func testSeededSummaryPlanIsConsideredStillValidAgainstTheSameLocalItems() {
        let localItems = [
            InventoryItem(name: "面粉", quantity: 1, unit: "袋", expiryDate: nil),
            InventoryItem(name: "白糖", quantity: 2, unit: "袋", expiryDate: nil)
        ]
        for fixture in AccountLifecycleSummaryFixture.allCases {
            let session = fixture.session(userID: userID, localItems: localItems)
            let plan = try! XCTUnwrap(session.plan)
            XCTAssertTrue(
                InventoryMergePlanner.isPlanStillValid(plan, against: localItems, currentRemoteItems: []),
                "\(fixture.rawValue) 的 plan 必须被视为仍然有效，否则会被重新生成"
            )
        }
    }

    func testSummaryFixtureCandidatesRecordChoicesWithoutCallingTheController() {
        // Resolved candidates must carry a `userChoice` and a consistent `action`,
        // produced by the model's own `applyingChoice` — never by `resolveConflict`,
        // which this phase must not invoke.
        let mixed = AccountLifecycleSummaryFixture.mixed.candidates
        let resolved = mixed.filter { $0.conflictReason != nil && $0.userChoice != nil }
        XCTAssertFalse(resolved.isEmpty)
        for candidate in resolved {
            switch candidate.userChoice {
            case .keepLocal:
                XCTAssertEqual(candidate.action, candidate.remoteItemId == candidate.localItemId ? .update : .create)
            case .keepRemote:
                XCTAssertEqual(candidate.action, .keepRemote)
            case .keepBoth:
                XCTAssertEqual(candidate.action, .create)
            case .skip:
                XCTAssertEqual(candidate.action, .skip)
            case nil:
                XCTFail("unreachable")
            }
        }
        XCTAssertTrue(mixed.contains { $0.needsDecision }, "mixed fixture 必须同时包含未处理项")
        XCTAssertTrue(mixed.contains { $0.conflictReason == nil }, "mixed fixture 必须同时包含非冲突项")
    }

    func testRepeatSummarySeedingCreatesExactlyOneSessionPerFixture() async throws {
        let (container, persistence) = try makePersistence()
        let fixture = AccountLifecycleSummaryFixture.mixed
        for _ in 0..<3 {
            let seeded = await fixture.seed(persistence: persistence, userID: userID, localItems: [])
            XCTAssertTrue(seeded)
        }
        XCTAssertEqual(try sessionCount(container), 1, "重复 seed 不得产生第二个 session")
    }

    func testRepeatSummarySeedingDoesNotOverwriteChangedStateInTheSameProcess() async throws {
        let (_, persistence) = try makePersistence()
        let fixture = AccountLifecycleSummaryFixture.mixed
        await fixture.seed(persistence: persistence, userID: userID, localItems: [])

        let loaded = try await persistence.activeGuestMergeSession(
            userId: userID, householdId: fixture.householdID, entityType: .inventoryItem
        )
        var session = try XCTUnwrap(loaded)
        session.conflictCount = 99
        try await persistence.saveGuestMergeSession(session)

        await fixture.seed(persistence: persistence, userID: userID, localItems: [])

        let reloaded = try await persistence.activeGuestMergeSession(
            userId: userID, householdId: fixture.householdID, entityType: .inventoryItem
        )
        XCTAssertEqual(reloaded?.conflictCount, 99, "同一进程内重复 seed 不得覆盖测试中已变化的状态")
    }

    func testANewProcessReSeedsSummaryFixtures() async throws {
        let (container, persistence) = try makePersistence()
        let fixture = AccountLifecycleSummaryFixture.mixed
        await fixture.seed(persistence: persistence, userID: userID, localItems: [])

        let loaded = try await persistence.activeGuestMergeSession(
            userId: userID, householdId: fixture.householdID, entityType: .inventoryItem
        )
        var session = try XCTUnwrap(loaded)
        session.conflictCount = 99
        try await persistence.saveGuestMergeSession(session)

        AccountLifecycleSummaryFixture.resetSeedTrackingForTesting()
        await fixture.seed(persistence: persistence, userID: userID, localItems: [])

        let reloaded = try await persistence.activeGuestMergeSession(
            userId: userID, householdId: fixture.householdID, entityType: .inventoryItem
        )
        XCTAssertEqual(reloaded?.conflictCount, 2, "新进程必须重新 seed 回确定状态")
        XCTAssertEqual(try sessionCount(container), 1)
    }

    func testSummarySeedingStagesNoMutationAndAdvancesNoCursor() async throws {
        let (container, persistence) = try makePersistence()
        for fixture in AccountLifecycleSummaryFixture.allCases {
            await fixture.seed(persistence: persistence, userID: userID, localItems: [])
        }
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingMutationRecord>()), 0, "seed 不得暂存任何 mutation")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncCursorRecord>()), 0, "seed 不得推进 sync cursor")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryRecord>()), 0, "seed 不得写入本机库存")
    }
}

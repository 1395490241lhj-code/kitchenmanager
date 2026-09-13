import XCTest
import SwiftData
@testable import KitchenManager

/// Feature 004, Slice 0 — prerequisite harness-integrity repair (FR-011).
///
/// Three GuestMergeSmoke runners seed a baseline through the real merge
/// confirmation path. Before this slice their baseline preview produced a plan
/// carrying no remote fingerprint, which production confirmation correctly
/// refuses, so each of those runners died at its very first checkpoint.
///
/// These tests deliberately assert nothing about inventory consistency
/// windows. W1-W4 belong to a later slice.
///
/// Slice 0b repaired the second prerequisite found while doing that: a
/// seeding-only baseline controller is now built with a zero rollback window,
/// so its completed session no longer stays the active rollback-capable one and
/// the next preview in the same runner is the fresh scenario preview the smoke
/// needs. Production and default callers keep the ordinary 24-hour window,
/// which the default-window control test below pins directly.
///
/// Simulator boundary: SimulatedMergeServer models one identity and one
/// household, which is everything the fork and production-preview runners need.
/// The full Phase 2B-2 matrix therefore ends at its User B account-isolation
/// checkpoint, and that limit is deliberate — this suite does not fake
/// multi-identity support just to make the run finish.
@MainActor
final class GuestMergeSmokeConsistencyTests: XCTestCase {
    private let userIdA = UUID()
    private let userIdB = UUID()
    private let householdId = UUID()

    // MARK: Slice 0 — repaired baselines reach their intended checkpoints

    /// The full Phase 2B-2 matrix. It now confirms its baseline, builds a fresh
    /// scenario preview, and runs all the way to the account-isolation
    /// checkpoint, which is the furthest the single-identity simulator can
    /// truthfully model.
    func testFullSmokeRunReachesTheAccountIsolationCheckpoint() async throws {
        let server = SimulatedMergeServer(userID: userIdA, householdID: householdId)
        let runner = GuestMergeSmokeRunner(
            smokeConfiguration: Self.enabledConfiguration, transportFactory: { _ in server }
        )
        let authStoreA = await Self.signedInAuthStore(userID: userIdA)
        let authStoreB = await Self.signedInAuthStore(userID: userIdB)

        do {
            _ = try await runner.run(
                authStoreA: authStoreA,
                authStoreB: authStoreB,
                reSignInA: {
                    _ = await authStoreA.signIn(email: "slice0-a@example.com", password: "not-a-real-password")
                }
            )
            XCTFail("the single-identity simulator cannot model the account-isolation checkpoint")
        } catch let error as GuestMergeSmokeError {
            guard case .validationFailed(let detail) = error else {
                return XCTFail("unexpected smoke error: \(error)")
            }
            XCTAssertFalse(detail.hasPrefix("baseline"), "the baseline must confirm: \(detail)")
            XCTAssertNotEqual(
                detail, "preview did not reach previewReady with a saved plan hash",
                "the scenario preview must be fresh, never a resumed baseline session"
            )
            XCTAssertEqual(
                detail, "User B's real bootstrap unexpectedly shares User A's household",
                "the run must advance to the simulator's single-identity boundary"
            )
        }

        let uploadedEntities = await server.appliedEntityCount()
        XCTAssertGreaterThanOrEqual(
            uploadedEntities, 6, "the baseline must have confirmed and uploaded its marker dataset"
        )
    }

    /// Phase 2B-2.5. Runs to completion: baseline seeding, a fresh conflicting
    /// preview against it, a same-id keepBoth fork, confirmation and rollback.
    func testIdentityForkSmokeCompletes() async throws {
        let server = SimulatedMergeServer(userID: userIdA, householdID: householdId)
        let runner = GuestMergeSmokeRunner(
            smokeConfiguration: Self.enabledConfiguration, transportFactory: { _ in server }
        )
        let passed = try await runner.runIdentityForkMinimalSmoke(
            authStoreA: await Self.signedInAuthStore(userID: userIdA)
        )
        XCTAssertTrue(passed)
    }

    /// Phase 2B-8. Runs to completion: its baseline seeds through the
    /// production preview overload this runner exists to exercise, and the
    /// stale-confirm and fresh-preview stages follow against it.
    func testProductionRemotePreviewSmokeCompletes() async throws {
        let server = SimulatedMergeServer(userID: userIdA, householdID: householdId)
        let runner = GuestMergeSmokeRunner(
            smokeConfiguration: Self.enabledConfiguration, transportFactory: { _ in server }
        )
        let passed = try await runner.runProductionRemotePreviewMinimalSmoke(
            authStoreA: await Self.signedInAuthStore(userID: userIdA)
        )
        XCTAssertTrue(passed)
    }

    // MARK: Production rollback availability is unchanged

    // MARK: Slice A - boundary plumbing semantics

    /// The helper delegates to KitchenStore's existing depth-counted window, so
    /// these tests cover only what the helper itself adds. Nesting, the edit
    /// gate, echo suppression and lock-on-reconciliation-failure are already
    /// proven against the primitive in KitchenStoreTests and GuestMergeTests.
    func testConsistencyWindowHelperClosesTheWindowOnSuccess() async throws {
        let kitchenStore = Self.makeKitchenStore(container: try Self.makeContainer())
        var bodyRan = false

        try await GuestMergeSmokeRunner.withInventoryConsistencyWindow(kitchenStore, "slice A unit test") {
            bodyRan = true
            XCTAssertTrue(kitchenStore.isInventoryLockedForSync, "the window must be open inside the body")
        }

        XCTAssertTrue(bodyRan)
        XCTAssertFalse(kitchenStore.isInventoryLockedForSync, "a successful reconciliation closes the window")
    }

    func testConsistencyWindowHelperClosesTheWindowWhenTheBodyThrowsAndKeepsTheOriginalError() async throws {
        let kitchenStore = Self.makeKitchenStore(container: try Self.makeContainer())

        do {
            try await GuestMergeSmokeRunner.withInventoryConsistencyWindow(kitchenStore, "slice A unit test") {
                () async throws -> Void in throw SliceABodyFailure()
            }
            XCTFail("the body's error must propagate")
        } catch is SliceABodyFailure {
            // The original error, never repackaged as a reconciliation failure.
        }

        XCTAssertFalse(kitchenStore.isInventoryLockedForSync, "the window must close on the failure path too")
    }

    /// Proves the helper reuses the existing depth counter instead of inventing
    /// a parallel lock of its own.
    func testNestedConsistencyWindowHelpersDoNotUnlockEarly() async throws {
        let kitchenStore = Self.makeKitchenStore(container: try Self.makeContainer())

        try await GuestMergeSmokeRunner.withInventoryConsistencyWindow(kitchenStore, "outer") {
            try await GuestMergeSmokeRunner.withInventoryConsistencyWindow(kitchenStore, "inner") {
                XCTAssertTrue(kitchenStore.isInventoryLockedForSync)
            }
            XCTAssertTrue(
                kitchenStore.isInventoryLockedForSync, "the inner close must not release the outer window"
            )
        }

        XCTAssertFalse(kitchenStore.isInventoryLockedForSync)
    }

    /// A defer-based close would discard this; the helper exists so it cannot.
    func testConsistencyWindowHelperSurfacesAReconciliationFailureAndKeepsTheStoreLocked() async throws {
        let container = try Self.makeContainer()
        let failable = FailableInventoryPersistence(wrapping: SwiftDataInventoryPersistence(container: container))
        let kitchenStore = Self.makeKitchenStore(container: container, inventoryPersistence: failable)
        failable.failLoads = true

        do {
            try await GuestMergeSmokeRunner.withInventoryConsistencyWindow(kitchenStore, "slice A unit test") {
                () async throws -> Void in
            }
            XCTFail("a failed reconciliation must not be swallowed")
        } catch let error as GuestMergeSmokeError {
            guard case .validationFailed(let detail) = error else {
                return XCTFail("unexpected smoke error: \(error)")
            }
            XCTAssertTrue(detail.contains("reconciliation failed"), detail)
        }

        XCTAssertTrue(
            kitchenStore.isInventoryLockedForSync, "the store stays locked until reconciliation can succeed"
        )
    }

    /// Case D: a failed body must never hide an unsafe store. The reconciliation
    /// failure dominates the visible result while the body's own failure stays
    /// diagnosable.
    func testConsistencyWindowHelperReportsReconciliationFailureEvenWhenTheBodyAlsoThrew() async throws {
        let container = try Self.makeContainer()
        let failable = FailableInventoryPersistence(wrapping: SwiftDataInventoryPersistence(container: container))
        let kitchenStore = Self.makeKitchenStore(container: container, inventoryPersistence: failable)
        var bodyThrew = false

        do {
            try await GuestMergeSmokeRunner.withInventoryConsistencyWindow(kitchenStore, "slice A unit test") {
                () async throws -> Void in
                // The operation moved durable state and then failed, leaving the
                // closing reconciliation unable to read it back.
                failable.failLoads = true
                bodyThrew = true
                throw SliceABodyFailure()
            }
            XCTFail("the failure must propagate")
        } catch let error as GuestMergeSmokeError {
            guard case .validationFailed(let detail) = error else {
                return XCTFail("unexpected smoke error: \(error)")
            }
            XCTAssertTrue(detail.contains("reconciliation failed"), "the unsafe state must dominate: \(detail)")
            XCTAssertTrue(
                detail.contains("SliceABodyFailure"), "the original body failure must stay diagnosable: \(detail)"
            )
        } catch {
            XCTFail("the reconciliation failure must dominate, got \(error)")
        }

        XCTAssertTrue(bodyThrew, "the body must actually have failed for this to be case D")
        XCTAssertTrue(kitchenStore.isInventoryLockedForSync, "the store stays locked until reconciliation succeeds")
    }

    /// Cleanup is proven clean only after a successful reconciliation. Slice A
    /// never attempts one, so production cleanup outcomes stay conservatively
    /// unproven until W4 lands in Slice B.
    func testCleanupOutcomeIsProvenCleanOnlyAfterASuccessfulReconciliation() {
        let stagedId = UUID()
        let failedId = UUID()
        func outcome(
            targeted: Set<UUID>, stagingFailed: Set<UUID> = [],
            run: SyncRunOutcome? = nil, reconciled: Bool? = nil
        ) -> GuestMergeSmokeCleanupOutcome {
            var value = GuestMergeSmokeCleanupOutcome(targetedIds: targeted)
            value.stagingFailedIds = stagingFailed
            value.coordinatorOutcome = run
            value.reconciled = reconciled
            return value
        }

        let notAttempted = outcome(targeted: [stagedId], run: .completed, reconciled: nil)
        XCTAssertTrue(notAttempted.completedCleanupSteps)
        XCTAssertFalse(notAttempted.isProvenClean, "a reconciliation that never ran proves nothing")

        let reconcileFailed = outcome(targeted: [stagedId], run: .completed, reconciled: false)
        XCTAssertTrue(reconcileFailed.completedCleanupSteps)
        XCTAssertFalse(reconcileFailed.isProvenClean)

        let proven = outcome(targeted: [stagedId], run: .completed, reconciled: true)
        XCTAssertTrue(proven.isProvenClean)
        XCTAssertTrue(proven.unprovenIds.isEmpty)

        let stagingFailed = outcome(
            targeted: [stagedId, failedId], stagingFailed: [failedId], run: .completed, reconciled: true
        )
        XCTAssertFalse(stagingFailed.completedCleanupSteps)
        XCTAssertFalse(stagingFailed.isProvenClean)
        XCTAssertEqual(stagingFailed.unprovenIds, [failedId], "a swallowed staging failure stays observable")

        let runFailed = outcome(targeted: [stagedId], run: .failed(.transport), reconciled: true)
        XCTAssertFalse(runFailed.completedCleanupSteps)
        XCTAssertFalse(runFailed.isProvenClean)
        XCTAssertEqual(runFailed.unprovenIds, [stagedId], "a failed run leaves every tracked id unproven")

        let empty = GuestMergeSmokeCleanupOutcome()
        XCTAssertTrue(empty.completedCleanupSteps, "nothing tracked means no step was left undone")
        XCTAssertFalse(empty.isProvenClean, "Slice A never claims proof it has not attempted")
    }

    /// Control for the Slice 0b repair: only the seeding configuration steps
    /// aside. A merge completed with the ordinary rollback window is still
    /// returned as the active rollback-capable session, so the harness change
    /// cannot hide a production rollback regression.
    func testDefaultRollbackWindowKeepsACompletedMergeActiveWhileZeroWindowDoesNot() async throws {
        let (defaultPersistence, defaultController) = try await Self.completedMerge(
            userID: userIdA, householdID: householdId, rollbackWindow: 24 * 60 * 60
        )
        XCTAssertEqual(defaultController.session?.status, .completed)
        let stillActive = try await defaultPersistence.activeGuestMergeSession(
            userId: userIdA, householdId: householdId, entityType: .inventoryItem
        )
        XCTAssertEqual(stillActive?.id, defaultController.session?.id)
        XCTAssertEqual(stillActive?.status, .completed)
        XCTAssertNotNil(stillActive?.rollbackAvailableUntil, "the default window must stay rollback-capable")

        let (seedingPersistence, seedingController) = try await Self.completedMerge(
            userID: userIdA, householdID: householdId, rollbackWindow: 0
        )
        XCTAssertEqual(seedingController.session?.status, .completed)
        let notRetained = try await seedingPersistence.activeGuestMergeSession(
            userId: userIdA, householdId: householdId, entityType: .inventoryItem
        )
        XCTAssertNil(notRetained, "a zero-window seeding session must not remain the active session")
    }

    // MARK: Production confirmation semantics are unchanged

    /// Slice 0 repaired the harness, never the gate. A plan built by the
    /// no-transport preview overload still carries no remote fingerprint, and
    /// confirmation still refuses it without uploading anything.
    func testConfirmMergeStillRefusesAPlanWithNoRemoteFingerprint() async throws {
        let container = try Self.makeContainer()
        let persistence = SwiftDataSyncPersistence(modelContainer: container)
        let kitchenStore = Self.makeKitchenStore(container: container)
        let server = SimulatedMergeServer(userID: userIdA, householdID: householdId)
        let controller = GuestMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in server }
        )
        controller.kitchenStore = kitchenStore
        kitchenStore.inventory = [
            InventoryItem(name: "__slice0_no_fingerprint", quantity: 1, unit: "个", expiryDate: nil)
        ]

        await controller.preparePreview(userId: userIdA, householdId: householdId, kitchenStore: kitchenStore)
        XCTAssertNil(
            controller.plan?.remoteSnapshotHash,
            "the no-transport overload must still produce a fingerprint-less plan"
        )

        await controller.confirmMerge(authStore: await Self.signedInAuthStore(userID: userIdA))
        XCTAssertNotEqual(controller.session?.status, .completed)
        XCTAssertEqual(controller.lastErrorMessage, "请重新查看合并预览后再确认。")
        let uploadedEntities = await server.appliedEntityCount()
        XCTAssertEqual(uploadedEntities, 0, "a refused confirmation must never upload anything")
    }

    // MARK: Helpers

    private static let enabledConfiguration = GuestMergeSmokeConfiguration(
        isSmokeEnabled: true,
        isDevelopmentBuild: true,
        isDevelopmentEnvironment: true,
        isMergeFeatureEnabled: true
    )

    private static func signedInAuthStore(userID: UUID) async -> AuthStore {
        let store = AuthStore(
            authService: Slice0AuthService(userID: userID), accountService: UnavailableAccountService()
        )
        let didSignIn = await store.signIn(email: "slice0@example.com", password: "not-a-real-password")
        precondition(didSignIn)
        return store
    }

    /// Drives one complete merge through the production confirmation path and
    /// hands back the stack so the caller can inspect session lifecycle.
    private static func completedMerge(
        userID: UUID, householdID: UUID, rollbackWindow: TimeInterval
    ) async throws -> (SwiftDataSyncPersistence, GuestMergeController) {
        let container = try makeContainer()
        let persistence = SwiftDataSyncPersistence(modelContainer: container)
        let kitchenStore = makeKitchenStore(container: container)
        let server = SimulatedMergeServer(userID: userID, householdID: householdID)
        let controller = GuestMergeController(
            persistence: persistence,
            configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: { _ in server },
            rollbackWindow: rollbackWindow
        )
        controller.kitchenStore = kitchenStore
        kitchenStore.inventory = [
            InventoryItem(name: "__slice0b_control", quantity: 1, unit: "个", expiryDate: nil)
        ]
        await controller.preparePreview(
            userId: userID, householdId: householdID, kitchenStore: kitchenStore, remoteTransport: server
        )
        await controller.confirmMerge(authStore: await signedInAuthStore(userID: userID))
        return (persistence, controller)
    }

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: InventoryRecord.self, ShoppingItemRecord.self, TodayPlanRecord.self,
            ConsumptionRecordEntity.self, WeeklyPlanRecord.self,
            SyncMetadataRecord.self, PendingMutationRecord.self, SyncCursorRecord.self,
            GuestMergeSessionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private static func makeKitchenStore(
        container: ModelContainer, inventoryPersistence: (any InventoryPersistenceProtocol)? = nil
    ) -> KitchenStore {
        KitchenStore(
            userDefaults: UserDefaults(suiteName: "guest-merge-slice0-\(UUID().uuidString)")!,
            inventoryPersistence: inventoryPersistence ?? SwiftDataInventoryPersistence(container: container),
            shoppingListPersistence: SwiftDataShoppingListPersistence(container: container),
            todayPlanPersistence: SwiftDataTodayPlanPersistence(container: container),
            consumptionPersistence: SwiftDataConsumptionPersistence(container: container),
            weeklyPlanPersistence: SwiftDataWeeklyPlanPersistence(container: container)
        )
    }
}

private struct SliceABodyFailure: Error {}

private final class Slice0AuthService: AuthService {
    private let userID: UUID

    init(userID: UUID) { self.userID = userID }

    var authStateChanges: AsyncStream<AuthStateChange> { AsyncStream { $0.finish() } }
    func restoreSession() async throws -> AuthSession? { nil }
    func signUp(email: String, password: String) async throws -> SignUpOutcome { throw AuthenticationError.unavailable }
    func signIn(email: String, password: String) async throws -> AuthSession {
        AuthSession(user: AuthUser(id: userID, email: email), accessToken: "slice0-token")
    }
    func signOut() async throws {}
}

/// A deterministic stand-in for the development backend: one household, real
/// per-entity optimistic-concurrency versioning, and a mutation-id idempotency
/// ledger, which is the minimum needed for the merge runners to behave exactly
/// as they do against the real service.
private actor SimulatedMergeServer: SyncTransport {
    private let userID: UUID
    private let householdID: UUID
    private var sequence = 0
    private var entityVersion: [UUID: Int] = [:]
    private var ledger: [UUID: SyncMutationResult] = [:]
    private var latestChange: [UUID: SyncChangeEnvelope] = [:]

    init(userID: UUID, householdID: UUID) {
        self.userID = userID
        self.householdID = householdID
    }

    func appliedEntityCount() -> Int { entityVersion.count }

    func bootstrap() async throws -> SyncBootstrapResponse {
        SyncBootstrapResponse(
            schemaVersion: 1,
            user: .init(id: userID, email: nil),
            households: [.init(id: householdID, role: "owner")],
            defaultHouseholdId: householdID,
            syncScopes: [
                SyncScopeDescriptor(type: .household, id: householdID, cursor: try SyncCursorValue(String(sequence)))
            ],
            serverTime: Date(),
            capabilities: .init(push: true, pull: true, maxBatchSize: 100)
        )
    }

    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse {
        let page = latestChange.values.filter { $0.sequence > cursor }.sorted { $0.sequence < $1.sequence }
        let limited = Array(page.prefix(limit))
        return SyncChangesResponse(
            scopeType: scope.type,
            scopeId: scope.id,
            cursor: limited.last?.sequence ?? cursor,
            hasMore: page.count > limited.count,
            changes: limited
        )
    }

    func sendMutations(scope: SyncScope, mutations requests: [SyncMutation]) async throws -> SyncMutationBatchResponse {
        var results: [SyncMutationResult] = []
        for request in requests {
            // Idempotency ledger, keyed on mutationId exactly like the real
            // service: a resent mutation is a duplicate no-op, never a second
            // apply and never a version bump.
            if let original = ledger[request.mutationId] {
                results.append(SyncMutationResult(
                    mutationId: original.mutationId, entityId: original.entityId,
                    status: .duplicate, version: original.version, sequence: original.sequence,
                    errorCode: nil, originalStatus: .applied, serverRecord: nil
                ))
                continue
            }

            let currentVersion = entityVersion[request.entityId] ?? 0
            let sentBaseVersion = Int(request.baseVersion?.rawValue ?? "0") ?? 0
            guard sentBaseVersion == currentVersion else {
                results.append(SyncMutationResult(
                    mutationId: request.mutationId, entityId: request.entityId,
                    status: .conflict, version: try SyncCursorValue(String(currentVersion)), sequence: nil,
                    errorCode: "stale_version", originalStatus: nil,
                    serverRecord: [
                        "id": .string(request.entityId.uuidString.lowercased()),
                        "version": .string(String(currentVersion))
                    ]
                ))
                continue
            }

            sequence += 1
            let nextVersion = currentVersion + 1
            entityVersion[request.entityId] = nextVersion
            let result = SyncMutationResult(
                mutationId: request.mutationId, entityId: request.entityId,
                status: .applied, version: try SyncCursorValue(String(nextVersion)),
                sequence: try SyncCursorValue(String(sequence)), errorCode: nil,
                originalStatus: nil, serverRecord: nil
            )
            ledger[request.mutationId] = result

            let data: [String: SyncJSONValue]
            if request.operation == .delete {
                data = [
                    "id": .string(request.entityId.uuidString.lowercased()),
                    "version": .string(String(nextVersion)),
                    "deletedAt": .string(Self.iso8601.string(from: Date()))
                ]
            } else {
                data = request.data ?? [:]
            }
            // Only the latest envelope per entity is retained, so a pull after
            // a push observes the write that was just applied rather than a
            // superseded one.
            latestChange[request.entityId] = SyncChangeEnvelope(
                sequence: try SyncCursorValue(String(sequence)), entityType: request.entityType,
                entityId: request.entityId, operation: request.operation,
                version: try SyncCursorValue(String(nextVersion)), changedAt: Date(), data: data
            )
            results.append(result)
        }
        return SyncMutationBatchResponse(results: results, cursor: try SyncCursorValue(String(sequence)))
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

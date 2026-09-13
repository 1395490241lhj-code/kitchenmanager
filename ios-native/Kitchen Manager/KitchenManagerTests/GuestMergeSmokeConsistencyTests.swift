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
/// Slice 0 repairs only the remote-fingerprint defect. Every run below now
/// confirms its baseline and continues, and each one stops one checkpoint
/// later on a second, independent pre-existing harness defect: a completed
/// merge session keeps a 24-hour rollback window, and activeGuestMergeSession
/// deliberately keeps returning a session inside that window, so the next
/// preparePreview in the same runner resumes the finished baseline session
/// instead of building a fresh preview. That defect is outside Slice 0's
/// frozen scope. These tests therefore pin the exact checkpoint each runner
/// now reaches, so repairing it later has to update them deliberately.
@MainActor
final class GuestMergeSmokeConsistencyTests: XCTestCase {
    private let userIdA = UUID()
    private let userIdB = UUID()
    private let householdId = UUID()

    // MARK: Slice 0 — repaired baselines reach their intended checkpoints

    /// The full Phase 2B-2 matrix. Before the repair this failed at its own
    /// baseline; it now confirms the baseline, uploads the marker dataset and
    /// stops at the following checkpoint.
    func testFullSmokeRunGetsPastItsBaselineSeeding() async throws {
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
            XCTFail("the resumed-baseline-session defect still stops this run short")
        } catch let error as GuestMergeSmokeError {
            guard case .validationFailed(let detail) = error else {
                return XCTFail("unexpected smoke error: \(error)")
            }
            XCTAssertFalse(
                detail.hasPrefix("baseline"), "the repaired baseline must no longer be the failure point: \(detail)"
            )
            XCTAssertEqual(detail, "preview did not reach previewReady with a saved plan hash")
        }

        let uploadedEntities = await server.appliedEntityCount()
        XCTAssertGreaterThanOrEqual(
            uploadedEntities, 6, "the baseline must have confirmed and uploaded its marker dataset"
        )
    }

    /// Phase 2B-2.5. Its baseline seeds one remote counterpart, which now
    /// confirms; the run then stops at its conflict checkpoint.
    func testIdentityForkSmokeGetsPastItsBaselineSeeding() async throws {
        let server = SimulatedMergeServer(userID: userIdA, householdID: householdId)
        let runner = GuestMergeSmokeRunner(
            smokeConfiguration: Self.enabledConfiguration, transportFactory: { _ in server }
        )

        do {
            _ = try await runner.runIdentityForkMinimalSmoke(
                authStoreA: await Self.signedInAuthStore(userID: userIdA)
            )
            XCTFail("the resumed-baseline-session defect still stops this run short")
        } catch let error as GuestMergeSmokeError {
            guard case .validationFailed(let detail) = error else {
                return XCTFail("unexpected smoke error: \(error)")
            }
            XCTAssertFalse(
                detail.hasPrefix("baseline"), "the repaired baseline must no longer be the failure point: \(detail)"
            )
            XCTAssertEqual(detail, "expected quantity conflict against the real baseline")
        }

        let uploadedEntities = await server.appliedEntityCount()
        XCTAssertGreaterThanOrEqual(uploadedEntities, 1, "the baseline must have confirmed and uploaded its counterpart")
    }

    /// Phase 2B-8. Its baseline seeds through the production preview overload
    /// this runner exists to exercise, which now confirms; the run then stops
    /// at its remote-count checkpoint.
    func testProductionRemotePreviewSmokeGetsPastItsBaselineSeeding() async throws {
        let server = SimulatedMergeServer(userID: userIdA, householdID: householdId)
        let runner = GuestMergeSmokeRunner(
            smokeConfiguration: Self.enabledConfiguration, transportFactory: { _ in server }
        )

        do {
            _ = try await runner.runProductionRemotePreviewMinimalSmoke(
                authStoreA: await Self.signedInAuthStore(userID: userIdA)
            )
            XCTFail("the resumed-baseline-session defect still stops this run short")
        } catch let error as GuestMergeSmokeError {
            guard case .validationFailed(let detail) = error else {
                return XCTFail("unexpected smoke error: \(error)")
            }
            XCTAssertFalse(
                detail.hasPrefix("baseline"), "the repaired baseline must no longer be the failure point: \(detail)"
            )
            XCTAssertEqual(detail, "production preview overload did not report a non-zero remote count")
        }

        let uploadedEntities = await server.appliedEntityCount()
        XCTAssertGreaterThanOrEqual(uploadedEntities, 1, "the baseline marker must have confirmed and uploaded")
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

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: InventoryRecord.self, ShoppingItemRecord.self, TodayPlanRecord.self,
            ConsumptionRecordEntity.self, WeeklyPlanRecord.self,
            SyncMetadataRecord.self, PendingMutationRecord.self, SyncCursorRecord.self,
            GuestMergeSessionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private static func makeKitchenStore(container: ModelContainer) -> KitchenStore {
        KitchenStore(
            userDefaults: UserDefaults(suiteName: "guest-merge-slice0-\(UUID().uuidString)")!,
            inventoryPersistence: SwiftDataInventoryPersistence(container: container),
            shoppingListPersistence: SwiftDataShoppingListPersistence(container: container),
            todayPlanPersistence: SwiftDataTodayPlanPersistence(container: container),
            consumptionPersistence: SwiftDataConsumptionPersistence(container: container),
            weeklyPlanPersistence: SwiftDataWeeklyPlanPersistence(container: container)
        )
    }
}

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



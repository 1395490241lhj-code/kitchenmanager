import SwiftData
import XCTest
@testable import KitchenManager

@MainActor
final class SyncSmokeTests: XCTestCase {
    private let userID = UUID()
    private let scope = SyncScope(type: .household, id: UUID())

    func testSmokePreflightRejectsDisabledSmokeBeforeReadingSession() async throws {
        let (_, persistence) = try makePersistence()
        let runner = SyncSmokeRunner(
            configuration: SyncConfiguration(isEnabled: true),
            smokeConfiguration: SyncSmokeConfiguration(
                isSmokeEnabled: false,
                isDevelopmentBuild: true,
                isDevelopmentEnvironment: true
            ),
            persistence: persistence,
            transportFactory: { _ in SimulatedSmokeTransport(userID: self.userID, scope: self.scope) }
        )
        await XCTAssertThrowsSmokeError(.smokeDisabled) {
            _ = try await runner.run(using: AuthStore.guestPreview())
        }
    }

    func testSmokePreflightRejectsReleaseAndDisabledSync() async throws {
        let (_, persistence) = try makePersistence()
        let store = await signedInStore()
        let releaseRunner = SyncSmokeRunner(
            configuration: SyncConfiguration(isEnabled: true),
            smokeConfiguration: SyncSmokeConfiguration(
                isSmokeEnabled: true,
                isDevelopmentBuild: false,
                isDevelopmentEnvironment: true
            ),
            persistence: persistence,
            transportFactory: { _ in SimulatedSmokeTransport(userID: self.userID, scope: self.scope) }
        )
        await XCTAssertThrowsSmokeError(.nonDevelopmentBuild) {
            _ = try await releaseRunner.run(using: store)
        }

        let disabledRunner = SyncSmokeRunner(
            configuration: SyncConfiguration(isEnabled: false),
            smokeConfiguration: SyncSmokeConfiguration(
                isSmokeEnabled: true,
                isDevelopmentBuild: true,
                isDevelopmentEnvironment: true
            ),
            persistence: persistence,
            transportFactory: { _ in SimulatedSmokeTransport(userID: self.userID, scope: self.scope) }
        )
        await XCTAssertThrowsSmokeError(.syncDisabled) {
            _ = try await disabledRunner.run(using: store)
        }
    }

    func testSmokePreflightRejectsMissingDevelopmentEnvironment() async throws {
        let (_, persistence) = try makePersistence()
        let runner = SyncSmokeRunner(
            configuration: SyncConfiguration(isEnabled: true),
            smokeConfiguration: SyncSmokeConfiguration(
                isSmokeEnabled: true,
                isDevelopmentBuild: true,
                isDevelopmentEnvironment: false
            ),
            persistence: persistence,
            transportFactory: { _ in SimulatedSmokeTransport(userID: self.userID, scope: self.scope) }
        )
        await XCTAssertThrowsSmokeError(.nonDevelopmentEnvironment) {
            _ = try await runner.run(using: await self.signedInStore())
        }
    }

    func testSmokePreflightRejectsGuestAndMissingDefaultHousehold() async throws {
        let (_, persistence) = try makePersistence()
        let enabled = SyncSmokeConfiguration(
            isSmokeEnabled: true,
            isDevelopmentBuild: true,
            isDevelopmentEnvironment: true
        )
        let guestRunner = SyncSmokeRunner(
            configuration: SyncConfiguration(isEnabled: true), smokeConfiguration: enabled,
            persistence: persistence,
            transportFactory: { _ in SimulatedSmokeTransport(userID: self.userID, scope: self.scope) }
        )
        await XCTAssertThrowsSmokeError(.notAuthenticated) {
            _ = try await guestRunner.run(using: AuthStore.guestPreview())
        }

        let signedIn = await signedInStore()
        let noScopeRunner = SyncSmokeRunner(
            configuration: SyncConfiguration(isEnabled: true), smokeConfiguration: enabled,
            persistence: persistence,
            transportFactory: { _ in SimulatedSmokeTransport(userID: self.userID, scope: nil) }
        )
        await XCTAssertThrowsSmokeError(.missingDefaultHousehold) {
            _ = try await noScopeRunner.run(using: signedIn)
        }
    }

    func testControlledInventorySmokeCompletesWithoutTouchingExistingGuestItem() async throws {
        let (_, persistence) = try makePersistence()
        let guestItem = InventoryItem(name: "游客保留食材", quantity: 7, unit: "个", expiryDate: nil)
        try await persistence.applyRemoteInventory(
            item: guestItem,
            removeInventory: false,
            metadata: metadata(id: guestItem.id, version: "1", state: .synced)
        )
        let transport = SimulatedSmokeTransport(userID: userID, scope: scope)
        let runner = SyncSmokeRunner(
            configuration: SyncConfiguration(isEnabled: true),
            smokeConfiguration: SyncSmokeConfiguration(
                isSmokeEnabled: true,
                isDevelopmentBuild: true,
                isDevelopmentEnvironment: true
            ),
            persistence: persistence,
            transportFactory: { _ in transport }
        )

        let report = try await runner.run(using: await signedInStore())

        XCTAssertEqual(report, SyncSmokeReport(
            createApplied: true, updateApplied: true, duplicateHandled: true,
            conflictRetained: true, softDeleteApplied: true,
            cursorAdvanced: true, finalPullWasIdempotent: true
        ))
        let retainedGuestItem = try await persistence.inventoryItem(id: guestItem.id)
        let appliedVersions = await transport.appliedVersions()
        let changeOperations = await transport.changeOperations()
        let itemNamePrefixes = await transport.itemNamePrefixes()
        XCTAssertEqual(retainedGuestItem?.quantity, 7)
        XCTAssertEqual(appliedVersions, ["1", "2", "3"])
        XCTAssertEqual(changeOperations, [.upsert, .upsert, .delete])
        XCTAssertEqual(itemNamePrefixes, ["__sync_smoke_inventory_"])
    }

    func testStaleSmokeMutationUsesRequestedBaseVersionAndCanBeExplicitlyDiscarded() async throws {
        let (_, persistence) = try makePersistence()
        let adapter = InventorySyncAdapter(persistence: persistence)
        let item = InventoryItem(name: "__sync_smoke_inventory_test", quantity: 2, unit: "个", expiryDate: nil)
        try await persistence.saveMetadata(metadata(id: item.id, version: "2", state: .synced))
        let mutationID = try await adapter.stageSmokeUpsert(
            item: item,
            scope: scope,
            staleBaseVersion: try SyncCursorValue("1")
        )
        let pending = try await persistence.pendingMutations(scope: scope, maxAttempts: 5)
        XCTAssertEqual(pending.first?.mutationId, mutationID)
        XCTAssertEqual(pending.first?.baseVersion?.rawValue, "1")
        try await persistence.discardPendingMutation(id: mutationID)
        let remaining = try await persistence.pendingMutations(scope: scope, maxAttempts: 5)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAuthStoreTokenProviderStopsAfterSignOut() async throws {
        let auth = TestAuthService(userID: userID)
        let store = AuthStore(authService: auth, accountService: UnavailableAccountService())
        let didSignIn = await store.signIn(email: "dev@example.com", password: "not-logged")
        XCTAssertTrue(didSignIn)
        let provider = AuthStoreSyncTokenProvider(authStore: store)
        let initialToken = await provider.accessToken()
        XCTAssertNotNil(initialToken)
        await store.signOut()
        let tokenAfterSignOut = await provider.accessToken()
        XCTAssertNil(tokenAfterSignOut)
    }

    private func signedInStore() async -> AuthStore {
        let auth = TestAuthService(userID: userID)
        let store = AuthStore(authService: auth, accountService: UnavailableAccountService())
        let didSignIn = await store.signIn(email: "dev@example.com", password: "not-logged")
        precondition(didSignIn)
        return store
    }

    private func metadata(id: UUID, version: String, state: EntitySyncState) -> SyncMetadata {
        SyncMetadata(
            entityType: .inventoryItem, entityId: id, scope: scope,
            remoteVersion: try! SyncCursorValue(version), state: state,
            lastSyncedAt: Date(), lastErrorCode: nil, lastErrorAt: nil,
            deletedAt: nil, updatedAt: Date()
        )
    }

    private func makePersistence() throws -> (ModelContainer, SwiftDataSyncPersistence) {
        let container = try ModelContainer(
            for: InventoryRecord.self, SyncMetadataRecord.self, PendingMutationRecord.self, SyncCursorRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (container, SwiftDataSyncPersistence(modelContainer: container))
    }
}

@MainActor
private final class TestAuthService: AuthService {
    private let userID: UUID

    init(userID: UUID) { self.userID = userID }

    var authStateChanges: AsyncStream<AuthStateChange> { AsyncStream { $0.finish() } }
    func restoreSession() async throws -> AuthSession? { nil }
    func signUp(email: String, password: String) async throws -> SignUpOutcome { throw AuthenticationError.unavailable }
    func signIn(email: String, password: String) async throws -> AuthSession {
        AuthSession(user: AuthUser(id: userID, email: email), accessToken: "unit-test-token")
    }
    func signOut() async throws {}
}

private actor SimulatedSmokeTransport: SyncTransport {
    private let userID: UUID
    private let scope: SyncScope?
    private var version = 0
    private var sequence = 0
    private var mutations: [UUID: SyncMutationResult] = [:]
    private var changes: [SyncChangeEnvelope] = []

    init(userID: UUID, scope: SyncScope?) {
        self.userID = userID
        self.scope = scope
    }

    func bootstrap() async throws -> SyncBootstrapResponse {
        let descriptors = scope.map { [SyncScopeDescriptor(type: $0.type, id: $0.id, cursor: try! SyncCursorValue(String(sequence)))] } ?? []
        return SyncBootstrapResponse(
            schemaVersion: 1,
            user: .init(id: userID, email: nil),
            households: scope.map { [.init(id: $0.id, role: "owner")] } ?? [],
            defaultHouseholdId: scope?.id,
            syncScopes: descriptors,
            serverTime: Date(),
            capabilities: .init(push: true, pull: true, maxBatchSize: 100)
        )
    }

    func fetchChanges(scope requestedScope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse {
        guard scope == requestedScope else { throw SyncError.forbidden }
        let page = changes.filter { $0.sequence > cursor }
        let limited = Array(page.prefix(limit))
        let next = limited.last?.sequence ?? cursor
        return SyncChangesResponse(
            scopeType: requestedScope.type, scopeId: requestedScope.id,
            cursor: next, hasMore: page.count > limited.count, changes: limited
        )
    }

    func sendMutations(scope requestedScope: SyncScope, mutations requests: [SyncMutation]) async throws -> SyncMutationBatchResponse {
        guard scope == requestedScope else { throw SyncError.forbidden }
        var results: [SyncMutationResult] = []
        for request in requests {
            if let original = mutations[request.mutationId] {
                results.append(SyncMutationResult(
                    mutationId: original.mutationId, entityId: original.entityId,
                    status: .duplicate, version: original.version, sequence: original.sequence,
                    errorCode: nil, originalStatus: .applied, serverRecord: nil
                ))
                continue
            }
            guard request.baseVersion?.rawValue == String(version) else {
                results.append(SyncMutationResult(
                    mutationId: request.mutationId, entityId: request.entityId,
                    status: .conflict, version: try SyncCursorValue(String(version)), sequence: nil,
                    errorCode: "stale_version", originalStatus: nil,
                    serverRecord: ["id": .string(request.entityId.uuidString.lowercased()), "version": .string(String(version))]
                ))
                continue
            }
            version += 1
            sequence += 1
            let result = SyncMutationResult(
                mutationId: request.mutationId, entityId: request.entityId,
                status: .applied, version: try SyncCursorValue(String(version)),
                sequence: try SyncCursorValue(String(sequence)), errorCode: nil,
                originalStatus: nil, serverRecord: nil
            )
            mutations[request.mutationId] = result
            let data: [String: SyncJSONValue]
            if request.operation == .delete {
                data = ["id": .string(request.entityId.uuidString.lowercased()), "version": .string(String(version)), "deletedAt": .string(ISO8601DateFormatter().string(from: Date()))]
            } else {
                data = request.data ?? [:]
            }
            changes.append(SyncChangeEnvelope(
                sequence: try SyncCursorValue(String(sequence)), entityType: request.entityType,
                entityId: request.entityId, operation: request.operation,
                version: try SyncCursorValue(String(version)), changedAt: Date(), data: data
            ))
            results.append(result)
        }
        return SyncMutationBatchResponse(results: results, cursor: try SyncCursorValue(String(sequence)))
    }

    func appliedVersions() -> [String] {
        mutations.values.compactMap { $0.version?.rawValue }.sorted()
    }

    func changeOperations() -> [SyncOperation] { changes.map(\.operation) }

    func itemNamePrefixes() -> [String] {
        changes.compactMap { change in
            guard case .string(let name)? = change.data["name"] else { return nil }
            return name.hasPrefix("__sync_smoke_inventory_")
                ? "__sync_smoke_inventory_"
                : name
        }
        .unique()
    }
}

private extension Array where Element: Hashable {
    func unique() -> [Element] {
        reduce(into: []) { values, value in
            if !values.contains(value) { values.append(value) }
        }
    }
}

private func XCTAssertThrowsSmokeError(
    _ expected: SyncSmokeError,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? SyncSmokeError, expected, file: file, line: line)
    }
}

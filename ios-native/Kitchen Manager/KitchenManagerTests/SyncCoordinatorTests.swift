import SwiftData
import XCTest
@testable import KitchenManager

@MainActor
final class SyncCoordinatorTests: XCTestCase {
    private let userID = UUID()
    private let scope = SyncScope(type: .household, id: UUID())

    func testDisabledDoesNotCallTransportOrPersistence() async {
        let transport = MockSyncTransport()
        let coordinator = SyncCoordinator(
            configuration: SyncConfiguration(),
            persistence: FailingSyncPersistence(),
            transport: transport
        )
        let outcome = await coordinator.runOnce(authentication: nil)
        let state = await coordinator.state()
        let callCount = await transport.callCount()
        XCTAssertEqual(outcome, .disabled)
        XCTAssertEqual(state, .disabled)
        XCTAssertEqual(callCount, 0)
    }

    func testEnabledWithoutAuthenticationPausesWithoutTransport() async {
        let transport = MockSyncTransport()
        let coordinator = SyncCoordinator(
            configuration: SyncConfiguration(isEnabled: true),
            persistence: FailingSyncPersistence(),
            transport: transport
        )
        let outcome = await coordinator.runOnce(authentication: nil)
        let callCount = await transport.callCount()
        XCTAssertEqual(outcome, .paused(.notAuthenticated))
        XCTAssertEqual(callCount, 0)
    }

    func testLoginDoesNotAutomaticallyRunCoordinator() async throws {
        let (_, persistence) = try makePersistence()
        let transport = MockSyncTransport()
        _ = SyncCoordinator(
            configuration: SyncConfiguration(isEnabled: true),
            persistence: persistence,
            transport: transport
        )
        let callCount = await transport.callCount()
        let pending = try await persistence.pendingMutations(scope: scope, maxAttempts: 5)
        XCTAssertEqual(callCount, 0)
        XCTAssertTrue(pending.isEmpty)
    }

    func testExistingGuestInventoryWriteDoesNotCreatePendingMutation() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = KitchenStore(
            userDefaults: defaults,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList,
            todayPlanPersistence: bundle.todayPlan,
            consumptionPersistence: bundle.consumption,
            weeklyPlanPersistence: bundle.weeklyPlan
        )
        store.addInventory(name: "游客鸡蛋", quantity: 2, unit: "个", expiryDate: nil)
        let pending = try await bundle.sync.pendingMutations(scope: scope, maxAttempts: 5)
        XCTAssertEqual(store.inventory.first?.name, "游客鸡蛋")
        XCTAssertTrue(pending.isEmpty)
    }

    func testNoScopePausesSafely() async throws {
        let (_, persistence) = try makePersistence()
        let transport = MockSyncTransport(bootstrap: bootstrap(scopes: []))
        let coordinator = makeCoordinator(persistence: persistence, transport: transport)
        let outcome = await coordinator.runOnce(authentication: auth())
        let bootstrapCount = await transport.bootstrapCount()
        let fetchCount = await transport.fetchCount()
        XCTAssertEqual(outcome, .paused(.forbidden))
        XCTAssertEqual(bootstrapCount, 1)
        XCTAssertEqual(fetchCount, 0)
    }

    func testBootstrapFailureMovesToFailed() async throws {
        let (_, persistence) = try makePersistence()
        let transport = MockSyncTransport(error: .backendUnavailable)
        let coordinator = makeCoordinator(persistence: persistence, transport: transport)
        let outcome = await coordinator.runOnce(authentication: auth())
        let state = await coordinator.state()
        XCTAssertEqual(outcome, .failed(.backendUnavailable))
        XCTAssertEqual(state, .failed)
    }

    func testPushSuccessRemovesPendingWithSameMutationID() async throws {
        let (container, persistence) = try makePersistence()
        let adapter = InventorySyncAdapter(persistence: persistence)
        let item = InventoryItem(name: "鸡蛋", quantity: 6, unit: "个", expiryDate: nil)
        let mutationID = UUID()
        _ = try await adapter.stageUpsert(item: item, scope: scope, mutationId: mutationID)
        let response = SyncMutationBatchResponse(
            results: [mutationResult(id: mutationID, entityID: item.id, status: .applied)],
            cursor: try SyncCursorValue("1")
        )
        let transport = MockSyncTransport(
            bootstrap: bootstrap(scopes: [scope]), mutationResponse: response,
            changes: emptyChanges(cursor: "0")
        )
        let coordinator = makeCoordinator(persistence: persistence, transport: transport)
        let outcome = await coordinator.runOnce(authentication: auth())
        let sentIDs = await transport.lastMutationIDs()
        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<PendingMutationRecord>()).isEmpty)
        XCTAssertEqual(sentIDs, [mutationID])
    }

    func testPushConflictIsRetained() async throws {
        let (container, persistence) = try makePersistence()
        let adapter = InventorySyncAdapter(persistence: persistence)
        let item = InventoryItem(name: "鸡蛋", quantity: 6, unit: "个", expiryDate: nil)
        let mutationID = try await adapter.stageUpsert(item: item, scope: scope)
        let transport = MockSyncTransport(
            bootstrap: bootstrap(scopes: [scope]),
            mutationResponse: SyncMutationBatchResponse(
                results: [mutationResult(id: mutationID, entityID: item.id, status: .conflict)],
                cursor: .zero
            ),
            changes: emptyChanges(cursor: "0")
        )
        let coordinator = makeCoordinator(persistence: persistence, transport: transport)
        let outcome = await coordinator.runOnce(authentication: auth())
        let conflictMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: item.id)
        XCTAssertEqual(outcome, .completed)
        let records = try ModelContext(container).fetch(FetchDescriptor<PendingMutationRecord>())
        XCTAssertEqual(records.first?.statusRawValue, "conflict")
        XCTAssertEqual(conflictMetadata?.state, .conflicted)
    }

    func testPullSuccessAppliesInventoryAndAdvancesCursor() async throws {
        let (_, persistence) = try makePersistence()
        let entityID = UUID()
        let change = inventoryChange(id: entityID, version: "2", sequence: "5")
        let transport = MockSyncTransport(
            bootstrap: bootstrap(scopes: [scope]),
            changes: SyncChangesResponse(
                scopeType: scope.type, scopeId: scope.id, cursor: try SyncCursorValue("5"),
                hasMore: false, changes: [change]
            )
        )
        let coordinator = makeCoordinator(persistence: persistence, transport: transport)
        let outcome = await coordinator.runOnce(authentication: auth())
        let item = try await persistence.inventoryItem(id: entityID)
        let cursor = try await persistence.cursor(for: scope)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(item?.name, "鸡蛋")
        XCTAssertEqual(cursor.value.rawValue, "5")
    }

    func testApplyFailureDoesNotAdvanceCursor() async throws {
        let (_, persistence) = try makePersistence()
        let unsupported = SyncChangeEnvelope(
            sequence: try SyncCursorValue("5"), entityType: .shoppingItem, entityId: UUID(),
            operation: .upsert, version: try SyncCursorValue("1"), changedAt: Date(), data: [:]
        )
        let transport = MockSyncTransport(
            bootstrap: bootstrap(scopes: [scope]),
            changes: SyncChangesResponse(
                scopeType: scope.type, scopeId: scope.id, cursor: try SyncCursorValue("5"),
                hasMore: false, changes: [unsupported]
            )
        )
        let coordinator = makeCoordinator(persistence: persistence, transport: transport)
        let outcome = await coordinator.runOnce(authentication: auth())
        let cursor = try await persistence.cursor(for: scope)
        XCTAssertEqual(outcome, .failed(.unsupportedEntity))
        XCTAssertEqual(cursor.value, .zero)
    }

    func testDuplicateRemoteChangesAreIdempotentAndPageStillAdvances() async throws {
        let (_, persistence) = try makePersistence()
        let id = UUID()
        let change = inventoryChange(id: id, version: "3", sequence: "8")
        let transport = MockSyncTransport(
            bootstrap: bootstrap(scopes: [scope]),
            changes: SyncChangesResponse(
                scopeType: scope.type, scopeId: scope.id, cursor: try SyncCursorValue("9"),
                hasMore: false, changes: [change, change]
            )
        )
        let coordinator = makeCoordinator(persistence: persistence, transport: transport)
        let outcome = await coordinator.runOnce(authentication: auth())
        let item = try await persistence.inventoryItem(id: id)
        let cursor = try await persistence.cursor(for: scope)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(item?.quantity, 6)
        XCTAssertEqual(cursor.value.rawValue, "9")
    }

    func testRunOnceRejectsConcurrentReentry() async throws {
        let (_, persistence) = try makePersistence()
        let transport = MockSyncTransport(bootstrap: bootstrap(scopes: []), bootstrapDelay: .milliseconds(100))
        let coordinator = makeCoordinator(persistence: persistence, transport: transport)
        let first = Task { await coordinator.runOnce(authentication: auth()) }
        try await Task.sleep(for: .milliseconds(20))
        let second = await coordinator.runOnce(authentication: auth())
        XCTAssertEqual(second, .alreadyRunning)
        _ = await first.value
    }

    private func makeCoordinator(
        persistence: SwiftDataSyncPersistence,
        transport: MockSyncTransport
    ) -> SyncCoordinator {
        SyncCoordinator(
            configuration: SyncConfiguration(isEnabled: true),
            persistence: persistence,
            transport: transport
        )
    }

    private func auth() -> SyncAuthenticationContext {
        SyncAuthenticationContext(userID: userID, isAuthenticated: true)
    }

    private func bootstrap(scopes: [SyncScope]) -> SyncBootstrapResponse {
        SyncBootstrapResponse(
            schemaVersion: 1,
            user: .init(id: userID, email: "cook@example.com"),
            households: scopes.filter { $0.type == .household }.map { .init(id: $0.id, role: "owner") },
            defaultHouseholdId: scopes.first(where: { $0.type == .household })?.id,
            syncScopes: scopes.map { .init(type: $0.type, id: $0.id, cursor: .zero) },
            serverTime: Date(),
            capabilities: .init(push: true, pull: true, maxBatchSize: 100)
        )
    }

    private func emptyChanges(cursor: String) -> SyncChangesResponse {
        SyncChangesResponse(
            scopeType: scope.type, scopeId: scope.id,
            cursor: try! SyncCursorValue(cursor), hasMore: false, changes: []
        )
    }

    private func mutationResult(
        id: UUID,
        entityID: UUID,
        status: SyncMutationStatus
    ) -> SyncMutationResult {
        SyncMutationResult(
            mutationId: id, entityId: entityID, status: status,
            version: try? SyncCursorValue("2"), sequence: try? SyncCursorValue("3"),
            errorCode: status == .conflict ? "stale_version" : nil,
            originalStatus: nil, serverRecord: nil
        )
    }

    private func inventoryChange(id: UUID, version: String, sequence: String) -> SyncChangeEnvelope {
        SyncChangeEnvelope(
            sequence: try! SyncCursorValue(sequence), entityType: .inventoryItem,
            entityId: id, operation: .upsert, version: try! SyncCursorValue(version),
            changedAt: Date(), data: [
                "name": .string("鸡蛋"), "quantity": .number(6), "unit": .string("个")
            ]
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

private actor MockSyncTransport: SyncTransport {
    private var bootstrapValue: SyncBootstrapResponse?
    private var mutationValue: SyncMutationBatchResponse?
    private var changesValue: SyncChangesResponse?
    private var configuredError: SyncError?
    private var calls = 0
    private var bootstraps = 0
    private var fetches = 0
    private var sentMutationIDs: [UUID] = []
    private let bootstrapDelay: Duration?

    init(
        bootstrap: SyncBootstrapResponse? = nil,
        mutationResponse: SyncMutationBatchResponse? = nil,
        changes: SyncChangesResponse? = nil,
        error: SyncError? = nil,
        bootstrapDelay: Duration? = nil
    ) {
        bootstrapValue = bootstrap
        mutationValue = mutationResponse
        changesValue = changes
        configuredError = error
        self.bootstrapDelay = bootstrapDelay
    }

    func bootstrap() async throws -> SyncBootstrapResponse {
        calls += 1
        bootstraps += 1
        if let bootstrapDelay { try await Task.sleep(for: bootstrapDelay) }
        if let configuredError { throw configuredError }
        guard let bootstrapValue else { throw SyncError.invalidConfiguration }
        return bootstrapValue
    }

    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse {
        calls += 1
        fetches += 1
        if let configuredError { throw configuredError }
        guard let changesValue else { throw SyncError.invalidConfiguration }
        return changesValue
    }

    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse {
        calls += 1
        sentMutationIDs = mutations.map(\.mutationId)
        if let configuredError { throw configuredError }
        guard let mutationValue else { throw SyncError.invalidConfiguration }
        return mutationValue
    }

    func callCount() -> Int { calls }
    func bootstrapCount() -> Int { bootstraps }
    func fetchCount() -> Int { fetches }
    func lastMutationIDs() -> [UUID] { sentMutationIDs }
}

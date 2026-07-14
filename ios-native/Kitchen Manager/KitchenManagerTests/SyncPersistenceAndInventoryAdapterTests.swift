import SwiftData
import XCTest
@testable import KitchenManager

@MainActor
final class SyncPersistenceAndInventoryAdapterTests: XCTestCase {
    private let scope = SyncScope(type: .household, id: UUID())

    func testCursorIsIndependentPerScopeAndRejectsRollback() async throws {
        let (_, persistence) = try makePersistence()
        let other = SyncScope(type: .user, id: UUID())
        try await persistence.advanceCursor(scope: scope, to: SyncCursorValue("10"), at: Date())
        try await persistence.advanceCursor(scope: other, to: SyncCursorValue("3"), at: Date())
        try await persistence.advanceCursor(scope: scope, to: SyncCursorValue("10"), at: Date())
        let scopeCursor = try await persistence.cursor(for: scope)
        let otherCursor = try await persistence.cursor(for: other)
        XCTAssertEqual(scopeCursor.value.rawValue, "10")
        XCTAssertEqual(otherCursor.value.rawValue, "3")
        do {
            try await persistence.advanceCursor(scope: scope, to: SyncCursorValue("9"), at: Date())
            XCTFail("cursor rollback should fail")
        } catch {
            XCTAssertEqual(error as? SyncError, .invalidCursor)
        }
    }

    func testMetadataUniqueKeyStaleProtectionAndTombstone() async throws {
        let (_, persistence) = try makePersistence()
        let id = UUID()
        try await persistence.saveMetadata(metadata(id: id, version: "5", state: .synced))
        try await persistence.saveMetadata(metadata(id: id, version: "4", state: .failed))
        let current = try await persistence.metadata(entityType: .inventoryItem, entityId: id)
        XCTAssertEqual(current?.uniqueKey, "inventory_item:\(id.uuidString.lowercased())")
        XCTAssertEqual(current?.remoteVersion?.rawValue, "5")
        XCTAssertEqual(current?.state, .synced)

        let deletedAt = Date()
        try await persistence.saveMetadata(SyncMetadata(
            entityType: .inventoryItem, entityId: id, scope: scope,
            remoteVersion: try SyncCursorValue("6"), state: .synced,
            lastSyncedAt: deletedAt, lastErrorCode: nil, lastErrorAt: nil,
            deletedAt: deletedAt, updatedAt: deletedAt
        ))
        let tombstone = try await persistence.metadata(entityType: .inventoryItem, entityId: id)
        XCTAssertEqual(tombstone?.deletedAt, deletedAt)
    }

    func testMetadataDeletionDoesNotDeleteInventory() async throws {
        let (_, persistence) = try makePersistence()
        let adapter = InventorySyncAdapter(persistence: persistence)
        let item = inventory(name: "鸡蛋")
        _ = try await adapter.stageUpsert(item: item, scope: scope)
        try await persistence.deleteMetadata(entityType: .inventoryItem, entityId: item.id)
        let persistedItem = try await persistence.inventoryItem(id: item.id)
        XCTAssertEqual(persistedItem?.name, "鸡蛋")
    }

    func testPendingQueueStableOrderAndRetryKeepsMutationID() async throws {
        let (_, persistence) = try makePersistence()
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let date = Date(timeIntervalSince1970: 100)
        try await persistence.savePending(try pending(id: secondID, entityID: UUID(), createdAt: date.addingTimeInterval(1)))
        try await persistence.savePending(try pending(id: firstID, entityID: UUID(), createdAt: date))
        try await persistence.markInFlight(ids: [firstID], attemptedAt: Date(), maxAttempts: 5)
        try await persistence.markPendingFailed(ids: [firstID], code: "transport", attemptedAt: Date(), maxAttempts: 5)
        let queue = try await persistence.pendingMutations(scope: scope, maxAttempts: 5)
        XCTAssertEqual(queue.map(\.mutationId), [firstID, secondID])
        XCTAssertEqual(queue.first?.attemptCount, 1)
    }

    func testAppliedAndDuplicateClearPendingButConflictAndRejectedRemain() async throws {
        let (container, persistence) = try makePersistence()
        let applied = UUID(), duplicate = UUID(), conflict = UUID(), rejected = UUID()
        for id in [applied, duplicate, conflict, rejected] {
            let entityID = UUID()
            try await persistence.saveMetadata(metadata(id: entityID, version: "1", state: .pendingUpdate))
            try await persistence.savePending(try pending(id: id, entityID: entityID, createdAt: Date()))
        }
        let records = try ModelContext(container).fetch(FetchDescriptor<PendingMutationRecord>())
        let idsByMutation = Dictionary(uniqueKeysWithValues: records.map { ($0.mutationId, $0.entityId) })
        try await persistence.resolvePending(result(id: applied, entityID: idsByMutation[applied]!, status: .applied), resolvedAt: Date())
        try await persistence.resolvePending(result(id: duplicate, entityID: idsByMutation[duplicate]!, status: .duplicate), resolvedAt: Date())
        try await persistence.resolvePending(result(id: conflict, entityID: idsByMutation[conflict]!, status: .conflict), resolvedAt: Date())
        try await persistence.resolvePending(result(id: rejected, entityID: idsByMutation[rejected]!, status: .rejected), resolvedAt: Date())

        let remaining = try ModelContext(container).fetch(FetchDescriptor<PendingMutationRecord>())
        XCTAssertEqual(Set(remaining.map(\.mutationId)), Set([conflict, rejected]))
        XCTAssertEqual(remaining.first(where: { $0.mutationId == conflict })?.statusRawValue, "conflict")
        XCTAssertEqual(remaining.first(where: { $0.mutationId == rejected })?.statusRawValue, "rejected")
    }

    func testInvalidPendingPayloadFailsSafely() {
        let value = PendingMutation(
            mutationId: UUID(), entityType: .inventoryItem, entityId: UUID(), scope: scope,
            operation: .upsert, baseVersion: .zero, payloadData: Data("not-json".utf8),
            clientUpdatedAt: Date(), createdAt: Date(), attemptCount: 0,
            lastAttemptAt: nil, lastErrorCode: nil, status: .pending
        )
        XCTAssertThrowsError(try value.asMutation()) { XCTAssertEqual($0 as? SyncError, .decoding) }
    }

    func testLocalCreateUpdateDeleteProduceExpectedStatesAndStableIDs() async throws {
        let (_, persistence) = try makePersistence()
        let adapter = InventorySyncAdapter(persistence: persistence)
        var item = inventory(name: "鸡蛋")
        let createID = UUID()
        let returnedCreateID = try await adapter.stageUpsert(item: item, scope: scope, mutationId: createID)
        let createdMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: item.id)
        XCTAssertEqual(returnedCreateID, createID)
        XCTAssertEqual(createdMetadata?.state, .pendingCreate)
        var queue = try await persistence.pendingMutations(scope: scope, maxAttempts: 5)
        XCTAssertEqual(queue.first?.baseVersion, .zero)

        try await persistence.saveMetadata(metadata(id: item.id, version: "2", state: .synced))
        item.quantity = 4
        _ = try await adapter.stageUpsert(item: item, scope: scope, mutationId: UUID())
        let updatedMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: item.id)
        XCTAssertEqual(updatedMetadata?.state, .pendingUpdate)
        queue = try await persistence.pendingMutations(scope: scope, maxAttempts: 5)
        XCTAssertTrue(queue.contains { $0.baseVersion?.rawValue == "2" })

        _ = try await adapter.stageDelete(entityId: item.id, scope: scope, mutationId: UUID())
        let deletedItem = try await persistence.inventoryItem(id: item.id)
        let deletedMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: item.id)
        XCTAssertNil(deletedItem)
        XCTAssertEqual(deletedMetadata?.state, .pendingDelete)
    }

    func testRemoteUpsertDuplicateAndTombstoneAreIdempotent() async throws {
        let (_, persistence) = try makePersistence()
        let adapter = InventorySyncAdapter(persistence: persistence)
        let id = UUID()
        let upsert = change(id: id, operation: .upsert, version: "4", sequence: "10", name: "牛奶")
        let firstApply = try await adapter.applyRemote(upsert, scope: scope)
        let remoteItem = try await persistence.inventoryItem(id: id)
        let duplicateApply = try await adapter.applyRemote(upsert, scope: scope)
        XCTAssertEqual(firstApply, .applied)
        XCTAssertEqual(remoteItem?.name, "牛奶")
        XCTAssertEqual(duplicateApply, .duplicate)

        let tombstone = change(id: id, operation: .delete, version: "5", sequence: "11", name: nil)
        let deleteApply = try await adapter.applyRemote(tombstone, scope: scope)
        let removedItem = try await persistence.inventoryItem(id: id)
        let duplicateDelete = try await adapter.applyRemote(tombstone, scope: scope)
        XCTAssertEqual(deleteApply, .applied)
        XCTAssertNil(removedItem)
        XCTAssertEqual(duplicateDelete, .duplicate)
    }

    func testLocalPendingWinsRemoteChangeAndRecordsConflict() async throws {
        let (_, persistence) = try makePersistence()
        let adapter = InventorySyncAdapter(persistence: persistence)
        let item = inventory(name: "本地鸡蛋")
        _ = try await adapter.stageUpsert(item: item, scope: scope)
        let remote = change(id: item.id, operation: .upsert, version: "7", sequence: "20", name: "云端鸡蛋")
        let outcome = try await adapter.applyRemote(remote, scope: scope)
        let localItem = try await persistence.inventoryItem(id: item.id)
        let conflictMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: item.id)
        XCTAssertEqual(outcome, .conflict)
        XCTAssertEqual(localItem?.name, "本地鸡蛋")
        XCTAssertEqual(conflictMetadata?.state, .conflicted)
    }

    func testSingleSaveFailureRollsBackBusinessMetadataAndMutation() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: InventoryRecord.self, SyncMetadataRecord.self, PendingMutationRecord.self, SyncCursorRecord.self,
            configurations: configuration
        )
        let failing = SwiftDataSyncPersistence(modelContainer: container, behavior: .failSavesForTesting)
        let adapter = InventorySyncAdapter(persistence: failing)
        do {
            _ = try await adapter.stageUpsert(item: inventory(name: "不会落盘"), scope: scope)
            XCTFail("expected persistence failure")
        } catch {
            XCTAssertEqual(error as? SyncError, .persistence)
        }
        let context = ModelContext(container)
        XCTAssertTrue(try context.fetch(FetchDescriptor<InventoryRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncMetadataRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<PendingMutationRecord>()).isEmpty)
    }

    private func makePersistence() throws -> (ModelContainer, SwiftDataSyncPersistence) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: InventoryRecord.self, SyncMetadataRecord.self, PendingMutationRecord.self, SyncCursorRecord.self,
            configurations: configuration
        )
        return (container, SwiftDataSyncPersistence(modelContainer: container))
    }

    private func inventory(name: String) -> InventoryItem {
        InventoryItem(name: name, quantity: 6, unit: "个", expiryDate: nil)
    }

    private func metadata(id: UUID, version: String, state: EntitySyncState) throws -> SyncMetadata {
        SyncMetadata(
            entityType: .inventoryItem, entityId: id, scope: scope,
            remoteVersion: try SyncCursorValue(version), state: state,
            lastSyncedAt: nil, lastErrorCode: nil, lastErrorAt: nil,
            deletedAt: nil, updatedAt: Date()
        )
    }

    private func pending(id: UUID, entityID: UUID, createdAt: Date) throws -> PendingMutation {
        PendingMutation(
            mutationId: id, entityType: .inventoryItem, entityId: entityID, scope: scope,
            operation: .upsert, baseVersion: .zero,
            payloadData: try JSONEncoder().encode(["name": SyncJSONValue.string("鸡蛋")]),
            clientUpdatedAt: createdAt, createdAt: createdAt, attemptCount: 0,
            lastAttemptAt: nil, lastErrorCode: nil, status: .pending
        )
    }

    private func result(id: UUID, entityID: UUID, status: SyncMutationStatus) -> SyncMutationResult {
        SyncMutationResult(
            mutationId: id, entityId: entityID, status: status,
            version: try? SyncCursorValue("2"), sequence: try? SyncCursorValue("3"),
            errorCode: status == .conflict ? "stale_version" : nil,
            originalStatus: nil, serverRecord: nil
        )
    }

    private func change(
        id: UUID,
        operation: SyncOperation,
        version: String,
        sequence: String,
        name: String?
    ) -> SyncChangeEnvelope {
        var data: [String: SyncJSONValue] = ["id": .string(id.uuidString.lowercased())]
        if let name {
            data["name"] = .string(name)
            data["quantity"] = .number(2)
            data["unit"] = .string("盒")
        } else {
            data["deletedAt"] = .string("2026-07-13T12:00:00Z")
        }
        return SyncChangeEnvelope(
            sequence: try! SyncCursorValue(sequence), entityType: .inventoryItem,
            entityId: id, operation: operation, version: try! SyncCursorValue(version),
            changedAt: Date(), data: data
        )
    }
}

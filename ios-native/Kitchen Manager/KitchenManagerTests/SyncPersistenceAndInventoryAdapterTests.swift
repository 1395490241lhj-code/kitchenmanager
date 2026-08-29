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

        _ = try await adapter.stageDeleteRemovingLocalRecord(entityId: item.id, scope: scope, mutationId: UUID())
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

    // MARK: - Sync P3: preparation-kind round trip

    func testClassificationEncodesBothAxesFromTheSameSnapshot() async throws {
        let (_, persistence) = try makePersistence()
        let adapter = InventorySyncAdapter(persistence: persistence)
        let expectations: [(kind: InventoryItemKind, isStaple: Bool, preparation: String)] = [
            (.ordinary, false, "none"),
            (.staple, true, "none"),
            (.readyToCook, false, "readyToCook")
        ]
        for expectation in expectations {
            let item = InventoryItem(name: "鸡翅", quantity: 6, unit: "个", expiryDate: nil, kind: expectation.kind)
            let payload = try JSONDecoder().decode(
                [String: SyncJSONValue].self, from: adapter.encodedPayload(for: item)
            )
            XCTAssertEqual(payload["isStaple"], .bool(expectation.isStaple), "\(expectation.kind) staple axis")
            // Asserting the exact string already rules out `.null` here
            // (`preparation_kind` is NOT NULL server-side, so an explicit
            // null is rejected rather than read as "none"). The structural
            // guard against ever *writing* `.null` lives in the Node suite,
            // `test/ios-native-guest-merge-phase2b1.test.mjs`.
            XCTAssertEqual(payload["preparationKind"], .string(expectation.preparation), "\(expectation.kind) preparation axis")
            XCTAssertNil(
                payload["kind"],
                "`kind` is the PWA-owned column (raw/dry/staple) — this client must never write it"
            )
        }
    }

    func testStagedUpsertUsesTheOneSharedPayloadEncoder() async throws {
        let (_, persistence) = try makePersistence()
        let adapter = InventorySyncAdapter(persistence: persistence)
        let item = InventoryItem(name: "腌鸡翅", quantity: 4, unit: "个", expiryDate: nil, kind: .readyToCook)
        _ = try await adapter.stageUpsert(item: item, scope: scope)
        let queue = try await persistence.pendingMutations(scope: scope, maxAttempts: 5)
        let stagedPayload = try XCTUnwrap(queue.first).decodedPayload()
        let sharedPayload = try JSONDecoder().decode(
            [String: SyncJSONValue].self, from: adapter.encodedPayload(for: item)
        )
        XCTAssertEqual(
            stagedPayload, sharedPayload,
            "stageUpsert and encodedPayload must go through the same private payload(for:) — never a second, drifting encoder"
        )
        XCTAssertEqual(stagedPayload["isStaple"], .bool(false))
        XCTAssertEqual(stagedPayload["preparationKind"], .string("readyToCook"))
        XCTAssertNil(stagedPayload["kind"])
    }

    func testDecodeResolvesClassificationPrecedenceAndNeverThrowsOnAnUnknownValue() async throws {
        let (_, persistence) = try makePersistence()
        let adapter = InventorySyncAdapter(persistence: persistence)
        let cases: [(label: String, axes: [String: SyncJSONValue], expected: InventoryItemKind)] = [
            ("legacy record carrying neither axis", [:], .ordinary),
            ("legacy staple record written before the preparation column existed", ["isStaple": .bool(true)], .staple),
            ("explicit none", ["isStaple": .bool(false), "preparationKind": .string("none")], .ordinary),
            ("readyToCook", ["isStaple": .bool(false), "preparationKind": .string("readyToCook")], .readyToCook),
            // Legal stored combination — the database deliberately carries no
            // cross-axis CHECK, so precedence is the client's job.
            ("staple outranks readyToCook", ["isStaple": .bool(true), "preparationKind": .string("readyToCook")], .staple),
            // The four forward-compatibility fallbacks. None of these may
            // throw: SyncCoordinator.pull abandons the whole page and leaves
            // the cursor unadvanced if applyRemote throws, so one unparseable
            // record would poison the change feed permanently.
            ("unknown future vocabulary value", ["preparationKind": .string("braised")], .ordinary),
            ("wrong JSON type: number", ["preparationKind": .number(1)], .ordinary),
            ("wrong JSON type: bool", ["preparationKind": .bool(true)], .ordinary),
            ("explicit null", ["preparationKind": .null], .ordinary)
        ]
        for testCase in cases {
            let id = UUID()
            var data: [String: SyncJSONValue] = [
                "name": .string("鸡翅"), "quantity": .number(2), "unit": .string("个")
            ]
            for (key, value) in testCase.axes { data[key] = value }
            let envelope = SyncChangeEnvelope(
                sequence: try SyncCursorValue("1"), entityType: .inventoryItem, entityId: id,
                operation: .upsert, version: try SyncCursorValue("1"), changedAt: Date(), data: data
            )
            let outcome = try await adapter.applyRemote(envelope, scope: scope)
            let stored = try await persistence.inventoryItem(id: id)
            XCTAssertEqual(outcome, .applied, testCase.label)
            XCTAssertEqual(stored?.kind, testCase.expected, testCase.label)
        }
    }

    func testClassificationRoundTripsThroughTheWire() async throws {
        for kind in InventoryItemKind.allCases {
            let (_, persistence) = try makePersistence()
            let adapter = InventorySyncAdapter(persistence: persistence)
            let id = UUID()
            let item = InventoryItem(id: id, name: "鸡翅", quantity: 3, unit: "个", expiryDate: nil, kind: kind)
            let payload = try JSONDecoder().decode(
                [String: SyncJSONValue].self, from: adapter.encodedPayload(for: item)
            )
            let envelope = SyncChangeEnvelope(
                sequence: try SyncCursorValue("1"), entityType: .inventoryItem, entityId: id,
                operation: .upsert, version: try SyncCursorValue("1"), changedAt: Date(), data: payload
            )
            let outcome = try await adapter.applyRemote(envelope, scope: scope)
            let restored = try await persistence.inventoryItem(id: id)
            XCTAssertEqual(outcome, .applied, "\(kind)")
            XCTAssertEqual(restored?.kind, kind, "\(kind) must survive encode -> wire -> decode unchanged")
        }
    }

    func testRemoteApplyHydratesClassificationWithoutRunningDomainSideEffects() async throws {
        let (container, persistence) = try makePersistence()
        let adapter = InventorySyncAdapter(persistence: persistence)
        let id = UUID()

        func apply(version: String, axes: [String: SyncJSONValue]) async throws -> InventoryRemoteApplyOutcome {
            var data: [String: SyncJSONValue] = [
                "name": .string("鸡翅"), "quantity": .number(4), "unit": .string("个")
            ]
            for (key, value) in axes { data[key] = value }
            return try await adapter.applyRemote(
                SyncChangeEnvelope(
                    sequence: try SyncCursorValue(version), entityType: .inventoryItem, entityId: id,
                    operation: .upsert, version: try SyncCursorValue(version), changedAt: Date(), data: data
                ),
                scope: scope
            )
        }
        func storedRecord() throws -> InventoryRecord {
            let context = ModelContext(container)
            return try XCTUnwrap(context.fetch(FetchDescriptor<InventoryRecord>()).first { $0.id == id })
        }

        _ = try await apply(version: "1", axes: [
            "preparationKind": .string("readyToCook"), "expiryDate": .string("2026-09-01")
        ])
        XCTAssertEqual(try storedRecord().kindRawValue, "readyToCook")

        // A remote demotion back to ordinary must genuinely clear the stored
        // ready-to-cook state, not leave the old raw value behind.
        _ = try await apply(version: "2", axes: ["preparationKind": .string("none")])
        XCTAssertEqual(try storedRecord().kindRawValue, "ordinary")

        // A remote `.staple` writes the staple classification, but remote
        // state hydration is not a domain classification change: it must not
        // run `KitchenStore.setInventoryKind` / `saveStaple`, both of which
        // clear the expiry date and the shelf-only settings when a *user*
        // promotes a row. Everything the remote sent therefore survives
        // verbatim. (The surviving expiry date on a staple row is the
        // pre-existing R2 invariant gap, not something P3 introduces.)
        _ = try await apply(version: "3", axes: [
            "isStaple": .bool(true),
            "preparationKind": .string("none"),
            "expiryDate": .string("2026-09-01"),
            "lowStockThreshold": .number(2),
            "stapleNote": .string("冷冻层"),
            "stapleCategory": .string("肉类")
        ])
        let staple = try storedRecord()
        XCTAssertEqual(staple.kindRawValue, "staple")
        XCTAssertTrue(staple.isStaple)
        XCTAssertEqual(staple.lowStockThreshold, 2)
        XCTAssertEqual(staple.stapleNote, "冷冻层")
        XCTAssertEqual(staple.stapleCategory, "肉类")
        XCTAssertNotNil(staple.expiryDate, "hydration must not run the domain's staple expiry cleanup")
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

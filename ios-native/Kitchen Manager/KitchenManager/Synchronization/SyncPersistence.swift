import Foundation
import SwiftData

nonisolated enum SyncPersistenceBehavior: Equatable, Sendable {
    case normal
    case failSavesForTesting
}

protocol SyncPersistenceProtocol: Actor {
    func metadata(entityType: SyncEntityType, entityId: UUID) throws -> SyncMetadata?
    func saveMetadata(_ metadata: SyncMetadata) throws
    func deleteMetadata(entityType: SyncEntityType, entityId: UUID) throws
    func pendingMutations(scope: SyncScope, maxAttempts: Int) throws -> [PendingMutation]
    func savePending(_ mutation: PendingMutation) throws
    func markInFlight(ids: [UUID], attemptedAt: Date, maxAttempts: Int) throws
    func resolvePending(_ result: SyncMutationResult, resolvedAt: Date) throws
    func markPendingFailed(ids: [UUID], code: String, attemptedAt: Date, maxAttempts: Int) throws
    func cursor(for scope: SyncScope) throws -> SyncCursor
    func advanceCursor(scope: SyncScope, to value: SyncCursorValue, at date: Date) throws
    func commitInventoryAndSync(
        item: InventoryItem?,
        removeInventory: Bool,
        metadata: SyncMetadata,
        mutation: PendingMutation
    ) throws
    func applyRemoteInventory(
        item: InventoryItem?,
        removeInventory: Bool,
        metadata: SyncMetadata
    ) throws
    func inventoryItem(id: UUID) throws -> InventoryItem?
}

@ModelActor
actor SwiftDataSyncPersistence: SyncPersistenceProtocol {
    private var behavior: SyncPersistenceBehavior = .normal

    init(modelContainer: ModelContainer, behavior: SyncPersistenceBehavior = .normal) {
        self.modelContainer = modelContainer
        let context = ModelContext(modelContainer)
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.behavior = behavior
    }

    func metadata(entityType: SyncEntityType, entityId: UUID) throws -> SyncMetadata? {
        let key = metadataKey(entityType: entityType, entityId: entityId)
        var descriptor = FetchDescriptor<SyncMetadataRecord>(predicate: #Predicate { $0.uniqueKey == key })
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return nil }
        guard let value = record.value else { throw SyncError.persistence }
        return value
    }

    func saveMetadata(_ metadata: SyncMetadata) throws {
        try upsertMetadata(metadata)
        try commit()
    }

    func deleteMetadata(entityType: SyncEntityType, entityId: UUID) throws {
        let key = metadataKey(entityType: entityType, entityId: entityId)
        let descriptor = FetchDescriptor<SyncMetadataRecord>(predicate: #Predicate { $0.uniqueKey == key })
        for record in try modelContext.fetch(descriptor) { modelContext.delete(record) }
        try commit()
    }

    func pendingMutations(scope: SyncScope, maxAttempts: Int) throws -> [PendingMutation] {
        let scopeType = scope.type.rawValue
        let scopeId = scope.id
        let descriptor = FetchDescriptor<PendingMutationRecord>(
            predicate: #Predicate {
                $0.scopeTypeRawValue == scopeType && $0.scopeId == scopeId
                    && ($0.statusRawValue == "pending" || $0.statusRawValue == "failed" || $0.statusRawValue == "inFlight")
                    && $0.attemptCount < maxAttempts
            },
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.mutationId)]
        )
        return try modelContext.fetch(descriptor).map { record in
            guard let value = record.value else { throw SyncError.persistence }
            return value
        }
    }

    func savePending(_ mutation: PendingMutation) throws {
        let id = mutation.mutationId
        var descriptor = FetchDescriptor<PendingMutationRecord>(predicate: #Predicate { $0.mutationId == id })
        descriptor.fetchLimit = 1
        guard try modelContext.fetch(descriptor).isEmpty else { return }
        modelContext.insert(PendingMutationRecord(mutation: mutation))
        try commit()
    }

    func markInFlight(ids: [UUID], attemptedAt: Date, maxAttempts: Int) throws {
        for id in ids {
            var descriptor = FetchDescriptor<PendingMutationRecord>(predicate: #Predicate { $0.mutationId == id })
            descriptor.fetchLimit = 1
            guard let record = try modelContext.fetch(descriptor).first else { continue }
            record.attemptCount += 1
            record.lastAttemptAt = attemptedAt
            record.lastErrorCode = nil
            record.statusRawValue = record.attemptCount > maxAttempts
                ? PendingMutationStatus.failed.rawValue
                : PendingMutationStatus.inFlight.rawValue
        }
        try commit()
    }

    func resolvePending(_ result: SyncMutationResult, resolvedAt: Date) throws {
        let id = result.mutationId
        var descriptor = FetchDescriptor<PendingMutationRecord>(predicate: #Predicate { $0.mutationId == id })
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return }
        let entityType = SyncEntityType(rawValue: record.entityTypeRawValue)
        let entityId = record.entityId
        switch result.status {
        case .applied, .duplicate:
            if let entityType,
               let existing = try metadata(entityType: entityType, entityId: entityId) {
                try upsertMetadata(SyncMetadata(
                    entityType: existing.entityType,
                    entityId: existing.entityId,
                    scope: existing.scope,
                    remoteVersion: result.version ?? existing.remoteVersion,
                    state: .synced,
                    lastSyncedAt: resolvedAt,
                    lastErrorCode: nil,
                    lastErrorAt: nil,
                    deletedAt: existing.deletedAt,
                    updatedAt: resolvedAt
                ))
            }
            modelContext.delete(record)
        case .conflict:
            record.statusRawValue = PendingMutationStatus.conflict.rawValue
            record.lastErrorCode = result.errorCode ?? "stale_version"
            if let entityType,
               let existing = try metadata(entityType: entityType, entityId: entityId) {
                try upsertMetadata(SyncMetadata(
                    entityType: existing.entityType,
                    entityId: existing.entityId,
                    scope: existing.scope,
                    remoteVersion: result.version ?? existing.remoteVersion,
                    state: .conflicted,
                    lastSyncedAt: existing.lastSyncedAt,
                    lastErrorCode: record.lastErrorCode,
                    lastErrorAt: resolvedAt,
                    deletedAt: existing.deletedAt,
                    updatedAt: resolvedAt
                ))
            }
        case .rejected:
            record.statusRawValue = PendingMutationStatus.rejected.rawValue
            record.lastErrorCode = result.errorCode ?? "rejected"
        }
        try commit()
    }

    func markPendingFailed(ids: [UUID], code: String, attemptedAt: Date, maxAttempts: Int) throws {
        for id in ids {
            var descriptor = FetchDescriptor<PendingMutationRecord>(predicate: #Predicate { $0.mutationId == id })
            descriptor.fetchLimit = 1
            guard let record = try modelContext.fetch(descriptor).first else { continue }
            record.statusRawValue = PendingMutationStatus.failed.rawValue
            record.lastAttemptAt = attemptedAt
            record.lastErrorCode = code
            if record.attemptCount >= maxAttempts,
               let entityType = SyncEntityType(rawValue: record.entityTypeRawValue),
               let existing = try metadata(entityType: entityType, entityId: record.entityId) {
                try upsertMetadata(SyncMetadata(
                    entityType: existing.entityType,
                    entityId: existing.entityId,
                    scope: existing.scope,
                    remoteVersion: existing.remoteVersion,
                    state: .failed,
                    lastSyncedAt: existing.lastSyncedAt,
                    lastErrorCode: code,
                    lastErrorAt: attemptedAt,
                    deletedAt: existing.deletedAt,
                    updatedAt: attemptedAt
                ))
            }
        }
        try commit()
    }

    func cursor(for scope: SyncScope) throws -> SyncCursor {
        let key = SyncCursorRecord.key(for: scope)
        var descriptor = FetchDescriptor<SyncCursorRecord>(predicate: #Predicate { $0.scopeKey == key })
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else {
            return SyncCursor(scope: scope, value: .zero, updatedAt: .distantPast)
        }
        guard let value = record.value else { throw SyncError.invalidCursor }
        return value
    }

    func advanceCursor(scope: SyncScope, to value: SyncCursorValue, at date: Date) throws {
        let existing = try cursor(for: scope)
        guard value >= existing.value else { throw SyncError.invalidCursor }
        if value == existing.value { return }
        let key = SyncCursorRecord.key(for: scope)
        var descriptor = FetchDescriptor<SyncCursorRecord>(predicate: #Predicate { $0.scopeKey == key })
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            record.cursor = value.rawValue
            record.updatedAt = date
        } else {
            modelContext.insert(SyncCursorRecord(cursor: SyncCursor(scope: scope, value: value, updatedAt: date)))
        }
        try commit()
    }

    func commitInventoryAndSync(
        item: InventoryItem?,
        removeInventory: Bool,
        metadata: SyncMetadata,
        mutation: PendingMutation
    ) throws {
        try mutateInventory(item: item, remove: removeInventory, id: metadata.entityId)
        try upsertMetadata(metadata)
        modelContext.insert(PendingMutationRecord(mutation: mutation))
        try commit()
    }

    func applyRemoteInventory(
        item: InventoryItem?,
        removeInventory: Bool,
        metadata: SyncMetadata
    ) throws {
        try mutateInventory(item: item, remove: removeInventory, id: metadata.entityId)
        try upsertMetadata(metadata)
        try commit()
    }

    func inventoryItem(id: UUID) throws -> InventoryItem? {
        var descriptor = FetchDescriptor<InventoryRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.inventoryItem
    }

    private func metadataKey(entityType: SyncEntityType, entityId: UUID) -> String {
        "\(entityType.rawValue):\(entityId.uuidString.lowercased())"
    }

    private func upsertMetadata(_ metadata: SyncMetadata) throws {
        let key = metadata.uniqueKey
        var descriptor = FetchDescriptor<SyncMetadataRecord>(predicate: #Predicate { $0.uniqueKey == key })
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            if let current = record.value,
               let currentVersion = current.remoteVersion,
               let incomingVersion = metadata.remoteVersion,
               incomingVersion < currentVersion {
                return
            }
            record.update(from: metadata)
        } else {
            modelContext.insert(SyncMetadataRecord(metadata: metadata))
        }
    }

    private func mutateInventory(item: InventoryItem?, remove: Bool, id: UUID) throws {
        var descriptor = FetchDescriptor<InventoryRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let existing = try modelContext.fetch(descriptor).first
        if remove {
            if let existing { modelContext.delete(existing) }
        } else if let item {
            if let existing { existing.update(from: item) }
            else { modelContext.insert(InventoryRecord(item: item)) }
        } else {
            throw SyncError.persistence
        }
    }

    private func commit() throws {
        do {
            if behavior == .failSavesForTesting { throw SyncError.persistence }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw SyncError.persistence
        }
    }
}

actor FailingSyncPersistence: SyncPersistenceProtocol {
    func metadata(entityType: SyncEntityType, entityId: UUID) throws -> SyncMetadata? { throw SyncError.persistence }
    func saveMetadata(_ metadata: SyncMetadata) throws { throw SyncError.persistence }
    func deleteMetadata(entityType: SyncEntityType, entityId: UUID) throws { throw SyncError.persistence }
    func pendingMutations(scope: SyncScope, maxAttempts: Int) throws -> [PendingMutation] { throw SyncError.persistence }
    func savePending(_ mutation: PendingMutation) throws { throw SyncError.persistence }
    func markInFlight(ids: [UUID], attemptedAt: Date, maxAttempts: Int) throws { throw SyncError.persistence }
    func resolvePending(_ result: SyncMutationResult, resolvedAt: Date) throws { throw SyncError.persistence }
    func markPendingFailed(ids: [UUID], code: String, attemptedAt: Date, maxAttempts: Int) throws { throw SyncError.persistence }
    func cursor(for scope: SyncScope) throws -> SyncCursor { throw SyncError.persistence }
    func advanceCursor(scope: SyncScope, to value: SyncCursorValue, at date: Date) throws { throw SyncError.persistence }
    func commitInventoryAndSync(item: InventoryItem?, removeInventory: Bool, metadata: SyncMetadata, mutation: PendingMutation) throws { throw SyncError.persistence }
    func applyRemoteInventory(item: InventoryItem?, removeInventory: Bool, metadata: SyncMetadata) throws { throw SyncError.persistence }
    func inventoryItem(id: UUID) throws -> InventoryItem? { throw SyncError.persistence }
}

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
    func pendingMutation(id: UUID) throws -> PendingMutation?
    func savePending(_ mutation: PendingMutation) throws
    func discardPendingMutation(id: UUID) throws
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

    // MARK: Phase 2B-1 Guest merge sessions

    /// The current *active* (non-terminal) session for this key, if any.
    /// Terminal sessions (completed/cancelled/rolledBack) are not returned
    /// here even though they remain queryable by id for history.
    func activeGuestMergeSession(userId: UUID, householdId: UUID, entityType: SyncEntityType) throws -> GuestMergeSession?
    func guestMergeSession(id: UUID) throws -> GuestMergeSession?
    /// Inserts or updates by `id`. Callers are responsible for checking
    /// `activeGuestMergeSession` first when creating a *new* session so at
    /// most one active session per (user, household, entityType) ever exists.
    func saveGuestMergeSession(_ session: GuestMergeSession) throws

    // MARK: Phase 2B-4: inventory sync enrollment + CRUD mutation staging

    func enrollment(userId: UUID, householdId: UUID) throws -> InventorySyncEnrollment?
    func saveEnrollment(_ enrollment: InventorySyncEnrollment) throws
    /// The current pending mutation for this entity, if any — at most one is
    /// ever kept per entity (coalesced), so this is a single lookup, not a list.
    func pendingMutationForEntity(entityType: SyncEntityType, entityId: UUID) throws -> PendingMutation?
    /// Stages (or coalesces into an existing pending mutation for the same
    /// entity) a CRUD-originated mutation — writes only `SyncMetadataRecord`
    /// + `PendingMutationRecord` in one transaction, deliberately never
    /// touching `InventoryRecord` itself (the caller's own
    /// `InventoryPersistenceProtocol` write already wrote it through its own
    /// `ModelContext`; writing it again here would race two contexts against
    /// the same row). See `docs/INVENTORY_MUTATION_COALESCING.md` for the
    /// full coalescing rule table.
    func stageInventoryMutation(
        entityId: UUID,
        scope: SyncScope,
        operation: SyncOperation,
        payloadData: Data,
        now: Date
    ) throws -> InventoryMutationStagingOutcome

    // MARK: Phase 2B-5: read-only diagnostics/consistency-checker queries

    /// Every `SyncMetadata` row for this scope, regardless of state —
    /// diagnostics/consistency-checking only; never used to decide sync
    /// eligibility (that always does a targeted single-entity lookup).
    func allMetadata(scope: SyncScope) throws -> [SyncMetadata]
    /// Every `PendingMutation` row for this scope, regardless of status
    /// (including already-`applied`/`rejected` ones `pendingMutations(scope:maxAttempts:)`
    /// excludes) — diagnostics/consistency-checking only.
    func allPendingMutations(scope: SyncScope) throws -> [PendingMutation]

    /// Phase 2D-2: wipes every sync-bookkeeping row (metadata, pending
    /// mutations, cursors, guest-merge/rollback sessions, enrollment) after a
    /// successful account deletion — never partial, so a killed app cannot
    /// resurrect a stale pending mutation against data that no longer exists
    /// server-side. Does not touch domain business data (inventory, recipes,
    /// etc.); callers pair this with `KitchenStore.clearAllLocalData()`.
    func clearAllSyncState() throws
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

    func pendingMutation(id: UUID) throws -> PendingMutation? {
        var descriptor = FetchDescriptor<PendingMutationRecord>(predicate: #Predicate { $0.mutationId == id })
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return nil }
        guard let value = record.value else { throw SyncError.persistence }
        return value
    }

    func savePending(_ mutation: PendingMutation) throws {
        let id = mutation.mutationId
        var descriptor = FetchDescriptor<PendingMutationRecord>(predicate: #Predicate { $0.mutationId == id })
        descriptor.fetchLimit = 1
        guard try modelContext.fetch(descriptor).isEmpty else { return }
        modelContext.insert(PendingMutationRecord(mutation: mutation))
        try commit()
    }

    /// Removes one explicitly identified pending mutation. It is deliberately
    /// never used by ordinary inventory flows; Phase 2A-4 uses it only after
    /// recording a development-smoke conflict so the same marked record can be
    /// soft-deleted with the server's current version.
    func discardPendingMutation(id: UUID) throws {
        var descriptor = FetchDescriptor<PendingMutationRecord>(predicate: #Predicate { $0.mutationId == id })
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            modelContext.delete(record)
            try commit()
        }
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

    func activeGuestMergeSession(userId: UUID, householdId: UUID, entityType: SyncEntityType) throws -> GuestMergeSession? {
        let key = GuestMergeSession.uniqueKey(userId: userId, householdId: householdId, entityType: entityType)
        let descriptor = FetchDescriptor<GuestMergeSessionRecord>(
            predicate: #Predicate { $0.sessionKey == key },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let now = Date()
        for record in try modelContext.fetch(descriptor) {
            guard let value = record.value else { continue }
            if value.status.isActive { return value }
            // `.completed` is terminal for the one-active-session rule, but a
            // session still within its rollback window must keep being
            // surfaced here too — otherwise a routine `preparePreview` re-check
            // (e.g. the inventory tab's own guest-data check, with no App
            // relaunch involved) silently starts a brand-new, disconnected
            // session and orphans `createdEntityIds`/`rollbackAvailableUntil`,
            // making Rollback a silent no-op.
            if value.status == .completed, let deadline = value.rollbackAvailableUntil, now <= deadline {
                return value
            }
        }
        return nil
    }

    func guestMergeSession(id: UUID) throws -> GuestMergeSession? {
        var descriptor = FetchDescriptor<GuestMergeSessionRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return nil }
        guard let value = record.value else { throw SyncError.persistence }
        return value
    }

    func saveGuestMergeSession(_ session: GuestMergeSession) throws {
        let id = session.id
        var descriptor = FetchDescriptor<GuestMergeSessionRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            record.update(from: session)
        } else {
            modelContext.insert(GuestMergeSessionRecord(session: session))
        }
        try commit()
    }

    func enrollment(userId: UUID, householdId: UUID) throws -> InventorySyncEnrollment? {
        let key = InventorySyncEnrollment.uniqueKey(userId: userId, householdId: householdId)
        var descriptor = FetchDescriptor<InventorySyncEnrollmentRecord>(predicate: #Predicate { $0.uniqueKey == key })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.value
    }

    func saveEnrollment(_ enrollment: InventorySyncEnrollment) throws {
        let key = enrollment.uniqueKey
        var descriptor = FetchDescriptor<InventorySyncEnrollmentRecord>(predicate: #Predicate { $0.uniqueKey == key })
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            record.update(from: enrollment)
        } else {
            modelContext.insert(InventorySyncEnrollmentRecord(enrollment: enrollment))
        }
        try commit()
    }

    func pendingMutationForEntity(entityType: SyncEntityType, entityId: UUID) throws -> PendingMutation? {
        try fetchPendingMutationRecord(entityType: entityType, entityId: entityId)?.value
    }

    func allMetadata(scope: SyncScope) throws -> [SyncMetadata] {
        let scopeTypeRaw = scope.type.rawValue
        let scopeId = scope.id
        let descriptor = FetchDescriptor<SyncMetadataRecord>(
            predicate: #Predicate { $0.scopeTypeRawValue == scopeTypeRaw && $0.scopeId == scopeId }
        )
        return try modelContext.fetch(descriptor).compactMap(\.value)
    }

    func allPendingMutations(scope: SyncScope) throws -> [PendingMutation] {
        let scopeTypeRaw = scope.type.rawValue
        let scopeId = scope.id
        let descriptor = FetchDescriptor<PendingMutationRecord>(
            predicate: #Predicate { $0.scopeTypeRawValue == scopeTypeRaw && $0.scopeId == scopeId }
        )
        return try modelContext.fetch(descriptor).compactMap(\.value)
    }

    func clearAllSyncState() throws {
        for record in try modelContext.fetch(FetchDescriptor<SyncMetadataRecord>()) { modelContext.delete(record) }
        for record in try modelContext.fetch(FetchDescriptor<PendingMutationRecord>()) { modelContext.delete(record) }
        for record in try modelContext.fetch(FetchDescriptor<SyncCursorRecord>()) { modelContext.delete(record) }
        for record in try modelContext.fetch(FetchDescriptor<GuestMergeSessionRecord>()) { modelContext.delete(record) }
        for record in try modelContext.fetch(FetchDescriptor<InventorySyncEnrollmentRecord>()) { modelContext.delete(record) }
        try commit()
    }

    func stageInventoryMutation(
        entityId: UUID,
        scope: SyncScope,
        operation: SyncOperation,
        payloadData: Data,
        now: Date
    ) throws -> InventoryMutationStagingOutcome {
        let existingMetadataRecord = try fetchMetadataRecord(entityType: .inventoryItem, entityId: entityId)
        let existingMetadata = existingMetadataRecord?.value
        let existingPendingRecord = try fetchPendingMutationRecord(entityType: .inventoryItem, entityId: entityId)

        if let existingPendingRecord, let existingOperation = SyncOperation(rawValue: existingPendingRecord.operationRawValue) {
            switch (existingOperation, operation) {
            case (.upsert, .upsert):
                // create+update or update+update: replace the payload in
                // place, keep the same mutationId and the same baseVersion
                // (the version this mutation was originally staged against
                // must never shift just because the local value changed
                // again before the next sync).
                existingPendingRecord.payloadData = payloadData
                existingPendingRecord.clientUpdatedAt = now
                existingPendingRecord.statusRawValue = PendingMutationStatus.pending.rawValue
                existingPendingRecord.lastErrorCode = nil
                try commit()
                return .staged(mutationId: existingPendingRecord.mutationId)

            case (.upsert, .delete):
                if existingMetadata?.remoteVersion == nil {
                    // create+delete: never sent remotely, so there is
                    // nothing to tell the server — cancel entirely rather
                    // than staging a pointless create-then-delete pair.
                    modelContext.delete(existingPendingRecord)
                    if let existingMetadataRecord { modelContext.delete(existingMetadataRecord) }
                    try commit()
                    return .cancelled
                }
                // update+delete: merge into a single delete intent using the
                // real, already-known remote version — never send the
                // superseded update first.
                existingPendingRecord.operationRawValue = SyncOperation.delete.rawValue
                existingPendingRecord.payloadData = Data("{}".utf8)
                existingPendingRecord.clientUpdatedAt = now
                existingPendingRecord.statusRawValue = PendingMutationStatus.pending.rawValue
                existingPendingRecord.lastErrorCode = nil
                if let existingMetadataRecord {
                    existingMetadataRecord.syncStateRawValue = EntitySyncState.pendingDelete.rawValue
                    existingMetadataRecord.deletedAt = now
                    existingMetadataRecord.updatedAt = now
                }
                try commit()
                return .staged(mutationId: existingPendingRecord.mutationId)

            case (.delete, .upsert):
                // Resurrecting a pending delete via an ordinary update is
                // refused by `InventorySyncEligibility` before this is ever
                // reached — this is a defensive guard, not a normal path.
                throw SyncError.persistence

            case (.delete, .delete):
                // Duplicate delete request for the same entity — already
                // staged, nothing further to do.
                return .staged(mutationId: existingPendingRecord.mutationId)
            }
        }

        // No existing pending mutation for this entity: stage a fresh one.
        let baseVersion = existingMetadata?.remoteVersion ?? .zero
        let newMutationId = UUID()
        let newState: EntitySyncState = operation == .delete ? .pendingDelete : (existingMetadata == nil ? .pendingCreate : .pendingUpdate)
        let metadata = SyncMetadata(
            entityType: .inventoryItem,
            entityId: entityId,
            scope: scope,
            remoteVersion: existingMetadata?.remoteVersion,
            state: newState,
            lastSyncedAt: existingMetadata?.lastSyncedAt,
            lastErrorCode: nil,
            lastErrorAt: nil,
            deletedAt: operation == .delete ? now : nil,
            updatedAt: now
        )
        let mutation = PendingMutation(
            mutationId: newMutationId,
            entityType: .inventoryItem,
            entityId: entityId,
            scope: scope,
            operation: operation,
            baseVersion: baseVersion,
            payloadData: payloadData,
            clientUpdatedAt: now,
            createdAt: now,
            attemptCount: 0,
            lastAttemptAt: nil,
            lastErrorCode: nil,
            status: .pending
        )
        try upsertMetadata(metadata)
        modelContext.insert(PendingMutationRecord(mutation: mutation))
        try commit()
        return .staged(mutationId: newMutationId)
    }

    private func fetchMetadataRecord(entityType: SyncEntityType, entityId: UUID) throws -> SyncMetadataRecord? {
        let key = metadataKey(entityType: entityType, entityId: entityId)
        var descriptor = FetchDescriptor<SyncMetadataRecord>(predicate: #Predicate { $0.uniqueKey == key })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchPendingMutationRecord(entityType: SyncEntityType, entityId: UUID) throws -> PendingMutationRecord? {
        let entityTypeRaw = entityType.rawValue
        var descriptor = FetchDescriptor<PendingMutationRecord>(
            predicate: #Predicate {
                $0.entityId == entityId && $0.entityTypeRawValue == entityTypeRaw
                    && ($0.statusRawValue == "pending" || $0.statusRawValue == "failed")
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
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
    func pendingMutation(id: UUID) throws -> PendingMutation? { throw SyncError.persistence }
    func savePending(_ mutation: PendingMutation) throws { throw SyncError.persistence }
    func discardPendingMutation(id: UUID) throws { throw SyncError.persistence }
    func markInFlight(ids: [UUID], attemptedAt: Date, maxAttempts: Int) throws { throw SyncError.persistence }
    func resolvePending(_ result: SyncMutationResult, resolvedAt: Date) throws { throw SyncError.persistence }
    func markPendingFailed(ids: [UUID], code: String, attemptedAt: Date, maxAttempts: Int) throws { throw SyncError.persistence }
    func cursor(for scope: SyncScope) throws -> SyncCursor { throw SyncError.persistence }
    func advanceCursor(scope: SyncScope, to value: SyncCursorValue, at date: Date) throws { throw SyncError.persistence }
    func commitInventoryAndSync(item: InventoryItem?, removeInventory: Bool, metadata: SyncMetadata, mutation: PendingMutation) throws { throw SyncError.persistence }
    func applyRemoteInventory(item: InventoryItem?, removeInventory: Bool, metadata: SyncMetadata) throws { throw SyncError.persistence }
    func inventoryItem(id: UUID) throws -> InventoryItem? { throw SyncError.persistence }
    func activeGuestMergeSession(userId: UUID, householdId: UUID, entityType: SyncEntityType) throws -> GuestMergeSession? { throw SyncError.persistence }
    func guestMergeSession(id: UUID) throws -> GuestMergeSession? { throw SyncError.persistence }
    func saveGuestMergeSession(_ session: GuestMergeSession) throws { throw SyncError.persistence }
    func enrollment(userId: UUID, householdId: UUID) throws -> InventorySyncEnrollment? { throw SyncError.persistence }
    func saveEnrollment(_ enrollment: InventorySyncEnrollment) throws { throw SyncError.persistence }
    func pendingMutationForEntity(entityType: SyncEntityType, entityId: UUID) throws -> PendingMutation? { throw SyncError.persistence }
    func stageInventoryMutation(entityId: UUID, scope: SyncScope, operation: SyncOperation, payloadData: Data, now: Date) throws -> InventoryMutationStagingOutcome { throw SyncError.persistence }
    func allMetadata(scope: SyncScope) throws -> [SyncMetadata] { throw SyncError.persistence }
    func allPendingMutations(scope: SyncScope) throws -> [PendingMutation] { throw SyncError.persistence }
    func clearAllSyncState() throws { throw SyncError.persistence }
}

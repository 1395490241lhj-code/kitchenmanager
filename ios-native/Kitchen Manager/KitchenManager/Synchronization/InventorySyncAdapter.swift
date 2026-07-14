import Foundation

nonisolated enum InventoryRemoteApplyOutcome: Equatable, Sendable {
    case applied
    case duplicate
    case conflict
}

/// Phase 2A proof-of-concept boundary for inventory only. Nothing calls these
/// local staging methods from the production inventory UI yet, so enabling the
/// feature flag alone cannot upload existing guest data.
nonisolated struct InventorySyncAdapter: Sendable {
    private let persistence: any SyncPersistenceProtocol

    init(persistence: any SyncPersistenceProtocol) {
        self.persistence = persistence
    }

    func stageUpsert(
        item: InventoryItem,
        scope: SyncScope,
        now: Date = Date(),
        mutationId: UUID = UUID()
    ) async throws -> UUID {
        let existing = try await persistence.metadata(entityType: .inventoryItem, entityId: item.id)
        let state: EntitySyncState = existing?.remoteVersion == nil ? .pendingCreate : .pendingUpdate
        let metadata = SyncMetadata(
            entityType: .inventoryItem,
            entityId: item.id,
            scope: scope,
            remoteVersion: existing?.remoteVersion,
            state: state,
            lastSyncedAt: existing?.lastSyncedAt,
            lastErrorCode: nil,
            lastErrorAt: nil,
            deletedAt: nil,
            updatedAt: now
        )
        let mutation = try pendingMutation(
            id: mutationId,
            item: item,
            scope: scope,
            operation: .upsert,
            baseVersion: existing?.remoteVersion ?? .zero,
            now: now
        )
        try await persistence.commitInventoryAndSync(
            item: item,
            removeInventory: false,
            metadata: metadata,
            mutation: mutation
        )
        return mutationId
    }

    #if DEBUG
    /// Development-smoke-only path for exercising the server's optimistic
    /// conflict response. It is not compiled into Release and has no ordinary
    /// inventory UI caller.
    func stageSmokeUpsert(
        item: InventoryItem,
        scope: SyncScope,
        staleBaseVersion: SyncCursorValue,
        now: Date = Date(),
        mutationId: UUID = UUID()
    ) async throws -> UUID {
        let existing = try await persistence.metadata(entityType: .inventoryItem, entityId: item.id)
        let metadata = SyncMetadata(
            entityType: .inventoryItem,
            entityId: item.id,
            scope: scope,
            remoteVersion: existing?.remoteVersion,
            state: .pendingUpdate,
            lastSyncedAt: existing?.lastSyncedAt,
            lastErrorCode: nil,
            lastErrorAt: nil,
            deletedAt: nil,
            updatedAt: now
        )
        let mutation = try pendingMutation(
            id: mutationId,
            item: item,
            scope: scope,
            operation: .upsert,
            baseVersion: staleBaseVersion,
            now: now
        )
        try await persistence.commitInventoryAndSync(
            item: item,
            removeInventory: false,
            metadata: metadata,
            mutation: mutation
        )
        return mutationId
    }
    #endif

    func stageDelete(
        entityId: UUID,
        scope: SyncScope,
        now: Date = Date(),
        mutationId: UUID = UUID()
    ) async throws -> UUID {
        let existing = try await persistence.metadata(entityType: .inventoryItem, entityId: entityId)
        let metadata = SyncMetadata(
            entityType: .inventoryItem,
            entityId: entityId,
            scope: scope,
            remoteVersion: existing?.remoteVersion,
            state: .pendingDelete,
            lastSyncedAt: existing?.lastSyncedAt,
            lastErrorCode: nil,
            lastErrorAt: nil,
            deletedAt: now,
            updatedAt: now
        )
        let mutation = PendingMutation(
            mutationId: mutationId,
            entityType: .inventoryItem,
            entityId: entityId,
            scope: scope,
            operation: .delete,
            baseVersion: existing?.remoteVersion ?? .zero,
            payloadData: Data("{}".utf8),
            clientUpdatedAt: now,
            createdAt: now,
            attemptCount: 0,
            lastAttemptAt: nil,
            lastErrorCode: nil,
            status: .pending
        )
        try await persistence.commitInventoryAndSync(
            item: nil,
            removeInventory: true,
            metadata: metadata,
            mutation: mutation
        )
        return mutationId
    }

    /// Pure, read-only decode of a pulled change into a
    /// `RemoteInventorySnapshotItem` — never writes local persistence. Used by
    /// the Guest merge pre-merge read (`GuestMergeController`) to learn what
    /// already exists remotely before generating a plan, without touching
    /// local `SyncMetadata`/`InventoryRecord` at all. Returns `nil` for a
    /// tombstone (delete), since a deleted remote record is not a match
    /// candidate.
    @MainActor
    func decodeRemoteInventorySnapshot(_ change: SyncChangeEnvelope) throws -> RemoteInventorySnapshotItem? {
        guard change.entityType == .inventoryItem else { throw SyncError.unsupportedEntity }
        guard change.operation != .delete else { return nil }
        let item = try decodeInventory(change)
        return RemoteInventorySnapshotItem(
            id: item.id,
            name: item.name,
            unit: item.unit,
            quantity: item.quantity,
            expiryDate: item.expiryDate,
            isStaple: item.isStaple,
            stapleCategory: item.stapleCategory,
            lowStockThreshold: item.lowStockThreshold,
            defaultRestockQuantity: item.defaultRestockQuantity,
            autoSuggestRestock: item.autoSuggestRestock,
            stapleTrackingMode: item.stapleTrackingMode,
            stapleAvailabilityStatus: item.stapleAvailabilityStatus,
            remoteVersion: change.version
        )
    }

    func applyRemote(_ change: SyncChangeEnvelope, scope: SyncScope) async throws -> InventoryRemoteApplyOutcome {
        guard change.entityType == .inventoryItem else { throw SyncError.unsupportedEntity }
        let existing = try await persistence.metadata(entityType: .inventoryItem, entityId: change.entityId)
        if let existing,
           [.pendingCreate, .pendingUpdate, .pendingDelete, .conflicted].contains(existing.state) {
            let conflicted = SyncMetadata(
                entityType: .inventoryItem,
                entityId: change.entityId,
                scope: scope,
                remoteVersion: max(existing.remoteVersion ?? .zero, change.version),
                state: .conflicted,
                lastSyncedAt: existing.lastSyncedAt,
                lastErrorCode: "remote_change_while_pending",
                lastErrorAt: change.changedAt,
                deletedAt: existing.deletedAt,
                updatedAt: change.changedAt
            )
            try await persistence.saveMetadata(conflicted)
            return .conflict
        }
        if let remoteVersion = existing?.remoteVersion, remoteVersion >= change.version {
            return .duplicate
        }

        let isDelete = change.operation == .delete
        let item = isDelete ? nil : try await decodeInventory(change)
        let metadata = SyncMetadata(
            entityType: .inventoryItem,
            entityId: change.entityId,
            scope: scope,
            remoteVersion: change.version,
            state: .synced,
            lastSyncedAt: change.changedAt,
            lastErrorCode: nil,
            lastErrorAt: nil,
            deletedAt: isDelete ? date(change.data["deletedAt"]) ?? change.changedAt : nil,
            updatedAt: change.changedAt
        )
        try await persistence.applyRemoteInventory(
            item: item,
            removeInventory: isDelete,
            metadata: metadata
        )
        return .applied
    }

    private func pendingMutation(
        id: UUID,
        item: InventoryItem,
        scope: SyncScope,
        operation: SyncOperation,
        baseVersion: SyncCursorValue,
        now: Date
    ) throws -> PendingMutation {
        let data = payload(for: item)
        return PendingMutation(
            mutationId: id,
            entityType: .inventoryItem,
            entityId: item.id,
            scope: scope,
            operation: operation,
            baseVersion: baseVersion,
            payloadData: try JSONEncoder().encode(data),
            clientUpdatedAt: now,
            createdAt: now,
            attemptCount: 0,
            lastAttemptAt: nil,
            lastErrorCode: nil,
            status: .pending
        )
    }

    /// Phase 2B-4: reused by `GuestMergeController`'s CRUD-originated staging
    /// so both paths encode the exact same fields the same way — never a
    /// second, drifting payload-building implementation.
    func encodedPayload(for item: InventoryItem) throws -> Data {
        try JSONEncoder().encode(payload(for: item))
    }

    private func payload(for item: InventoryItem) -> [String: SyncJSONValue] {
        var value: [String: SyncJSONValue] = [
            "name": .string(item.name),
            "normalizedName": .string(item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
            "quantity": .number(item.quantity),
            "unit": .string(item.unit),
            "isStaple": .bool(item.isStaple),
            "autoSuggestRestock": .bool(item.autoSuggestRestock),
            "stapleTrackingMode": .string(item.stapleTrackingMode.rawValue),
            "stapleAvailabilityStatus": .string(item.stapleAvailabilityStatus.rawValue),
            "sortOrder": .number(0)
        ]
        value["expiryDate"] = item.expiryDate.map { .string(dayString($0)) } ?? .null
        value["lowStockThreshold"] = item.lowStockThreshold.map(SyncJSONValue.number) ?? .null
        value["defaultRestockQuantity"] = item.defaultRestockQuantity.map(SyncJSONValue.number) ?? .null
        value["stapleNote"] = item.stapleNote.map(SyncJSONValue.string) ?? .null
        value["stapleCategory"] = item.stapleCategory.map(SyncJSONValue.string) ?? .null
        return value
    }

    @MainActor
    private func decodeInventory(_ change: SyncChangeEnvelope) throws -> InventoryItem {
        guard let name = string(change.data["name"]) else { throw SyncError.decoding }
        return InventoryItem(
            id: change.entityId,
            name: name,
            quantity: number(change.data["quantity"]) ?? 0,
            unit: string(change.data["unit"]) ?? "",
            expiryDate: date(change.data["expiryDate"]),
            isStaple: bool(change.data["isStaple"]) ?? false,
            createdAt: date(change.data["createdAt"]),
            updatedAt: date(change.data["updatedAt"]) ?? change.changedAt,
            lowStockThreshold: number(change.data["lowStockThreshold"]),
            defaultRestockQuantity: number(change.data["defaultRestockQuantity"]),
            autoSuggestRestock: bool(change.data["autoSuggestRestock"]) ?? false,
            stapleNote: string(change.data["stapleNote"]),
            stapleCategory: string(change.data["stapleCategory"]),
            stapleTrackingMode: StapleTrackingMode(rawValue: string(change.data["stapleTrackingMode"]) ?? "") ?? .quantity,
            stapleAvailabilityStatus: StapleAvailabilityStatus(rawValue: string(change.data["stapleAvailabilityStatus"]) ?? "")
                ?? ((number(change.data["quantity"]) ?? 0) <= 0 ? .missing : .available)
        )
    }

    private func string(_ value: SyncJSONValue?) -> String? {
        guard case .string(let result) = value else { return nil }
        return result
    }

    private func number(_ value: SyncJSONValue?) -> Double? {
        guard case .number(let result) = value else { return nil }
        return result
    }

    private func bool(_ value: SyncJSONValue?) -> Bool? {
        guard case .bool(let result) = value else { return nil }
        return result
    }

    private func date(_ value: SyncJSONValue?) -> Date? {
        guard let raw = string(value) else { return nil }
        if let day = parseDay(raw) { return day }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = fractional.date(from: raw) { return result }
        return ISO8601DateFormatter().date(from: raw)
    }

    private func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private func dayString(_ date: Date) -> String { dayFormatter().string(from: date) }

    private func parseDay(_ value: String) -> Date? {
        guard value.count == 10 else { return nil }
        return dayFormatter().date(from: value)
    }
}

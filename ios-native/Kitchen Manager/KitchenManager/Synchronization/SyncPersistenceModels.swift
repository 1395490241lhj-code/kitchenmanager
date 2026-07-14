import Foundation
import SwiftData

nonisolated enum EntitySyncState: String, Codable, Sendable {
    case localOnly
    case pendingCreate
    case pendingUpdate
    case pendingDelete
    case synced
    case conflicted
    case failed
}

nonisolated enum PendingMutationStatus: String, Codable, Sendable {
    case pending
    case inFlight
    case applied
    case conflict
    case rejected
    case failed
}

nonisolated struct SyncMetadata: Equatable, Sendable {
    let entityType: SyncEntityType
    let entityId: UUID
    let scope: SyncScope
    let remoteVersion: SyncCursorValue?
    let state: EntitySyncState
    let lastSyncedAt: Date?
    let lastErrorCode: String?
    let lastErrorAt: Date?
    let deletedAt: Date?
    let updatedAt: Date

    var uniqueKey: String { "\(entityType.rawValue):\(entityId.uuidString.lowercased())" }
}

nonisolated struct PendingMutation: Equatable, Identifiable, Sendable {
    var id: UUID { mutationId }
    let mutationId: UUID
    let entityType: SyncEntityType
    let entityId: UUID
    let scope: SyncScope
    let operation: SyncOperation
    let baseVersion: SyncCursorValue?
    let payloadData: Data
    let clientUpdatedAt: Date
    let createdAt: Date
    let attemptCount: Int
    let lastAttemptAt: Date?
    let lastErrorCode: String?
    let status: PendingMutationStatus

    func decodedPayload() throws -> [String: SyncJSONValue] {
        do {
            return try JSONDecoder().decode([String: SyncJSONValue].self, from: payloadData)
        } catch {
            throw SyncError.decoding
        }
    }

    func asMutation() throws -> SyncMutation {
        SyncMutation(
            mutationId: mutationId,
            entityType: entityType,
            entityId: entityId,
            operation: operation,
            baseVersion: baseVersion,
            clientUpdatedAt: clientUpdatedAt,
            data: operation == .delete ? nil : try decodedPayload()
        )
    }
}

@Model
final class SyncMetadataRecord {
    @Attribute(.unique) var uniqueKey: String
    var entityTypeRawValue: String
    var entityId: UUID
    var scopeTypeRawValue: String
    var scopeId: UUID
    var remoteVersion: String?
    var syncStateRawValue: String
    var lastSyncedAt: Date?
    var lastErrorCode: String?
    var lastErrorAt: Date?
    var deletedAt: Date?
    var updatedAt: Date

    init(metadata: SyncMetadata) {
        uniqueKey = metadata.uniqueKey
        entityTypeRawValue = metadata.entityType.rawValue
        entityId = metadata.entityId
        scopeTypeRawValue = metadata.scope.type.rawValue
        scopeId = metadata.scope.id
        remoteVersion = metadata.remoteVersion?.rawValue
        syncStateRawValue = metadata.state.rawValue
        lastSyncedAt = metadata.lastSyncedAt
        lastErrorCode = metadata.lastErrorCode
        lastErrorAt = metadata.lastErrorAt
        deletedAt = metadata.deletedAt
        updatedAt = metadata.updatedAt
    }

    func update(from metadata: SyncMetadata) {
        scopeTypeRawValue = metadata.scope.type.rawValue
        scopeId = metadata.scope.id
        remoteVersion = metadata.remoteVersion?.rawValue
        syncStateRawValue = metadata.state.rawValue
        lastSyncedAt = metadata.lastSyncedAt
        lastErrorCode = metadata.lastErrorCode
        lastErrorAt = metadata.lastErrorAt
        deletedAt = metadata.deletedAt
        updatedAt = metadata.updatedAt
    }

    var value: SyncMetadata? {
        guard let entityType = SyncEntityType(rawValue: entityTypeRawValue),
              let scopeType = SyncScopeType(rawValue: scopeTypeRawValue),
              let state = EntitySyncState(rawValue: syncStateRawValue) else { return nil }
        let version: SyncCursorValue?
        do {
            version = try remoteVersion.map(SyncCursorValue.init)
        } catch {
            return nil
        }
        return SyncMetadata(
            entityType: entityType,
            entityId: entityId,
            scope: SyncScope(type: scopeType, id: scopeId),
            remoteVersion: version,
            state: state,
            lastSyncedAt: lastSyncedAt,
            lastErrorCode: lastErrorCode,
            lastErrorAt: lastErrorAt,
            deletedAt: deletedAt,
            updatedAt: updatedAt
        )
    }
}

@Model
final class PendingMutationRecord {
    @Attribute(.unique) var mutationId: UUID
    var entityTypeRawValue: String
    var entityId: UUID
    var scopeTypeRawValue: String
    var scopeId: UUID
    var operationRawValue: String
    var baseVersion: String?
    var payloadData: Data
    var clientUpdatedAt: Date
    var createdAt: Date
    var attemptCount: Int
    var lastAttemptAt: Date?
    var lastErrorCode: String?
    var statusRawValue: String

    init(mutation: PendingMutation) {
        mutationId = mutation.mutationId
        entityTypeRawValue = mutation.entityType.rawValue
        entityId = mutation.entityId
        scopeTypeRawValue = mutation.scope.type.rawValue
        scopeId = mutation.scope.id
        operationRawValue = mutation.operation.rawValue
        baseVersion = mutation.baseVersion?.rawValue
        payloadData = mutation.payloadData
        clientUpdatedAt = mutation.clientUpdatedAt
        createdAt = mutation.createdAt
        attemptCount = mutation.attemptCount
        lastAttemptAt = mutation.lastAttemptAt
        lastErrorCode = mutation.lastErrorCode
        statusRawValue = mutation.status.rawValue
    }

    var value: PendingMutation? {
        guard let entityType = SyncEntityType(rawValue: entityTypeRawValue),
              let scopeType = SyncScopeType(rawValue: scopeTypeRawValue),
              let operation = SyncOperation(rawValue: operationRawValue),
              let status = PendingMutationStatus(rawValue: statusRawValue) else { return nil }
        let version: SyncCursorValue?
        do {
            version = try baseVersion.map(SyncCursorValue.init)
        } catch {
            return nil
        }
        return PendingMutation(
            mutationId: mutationId,
            entityType: entityType,
            entityId: entityId,
            scope: SyncScope(type: scopeType, id: scopeId),
            operation: operation,
            baseVersion: version,
            payloadData: payloadData,
            clientUpdatedAt: clientUpdatedAt,
            createdAt: createdAt,
            attemptCount: attemptCount,
            lastAttemptAt: lastAttemptAt,
            lastErrorCode: lastErrorCode,
            status: status
        )
    }
}

@Model
final class SyncCursorRecord {
    @Attribute(.unique) var scopeKey: String
    var scopeTypeRawValue: String
    var scopeId: UUID
    var cursor: String
    var updatedAt: Date

    init(cursor: SyncCursor) {
        scopeKey = Self.key(for: cursor.scope)
        scopeTypeRawValue = cursor.scope.type.rawValue
        scopeId = cursor.scope.id
        self.cursor = cursor.value.rawValue
        updatedAt = cursor.updatedAt
    }

    static func key(for scope: SyncScope) -> String {
        "\(scope.type.rawValue):\(scope.id.uuidString.lowercased())"
    }

    var value: SyncCursor? {
        guard let scopeType = SyncScopeType(rawValue: scopeTypeRawValue),
              let cursorValue = try? SyncCursorValue(cursor) else { return nil }
        return SyncCursor(
            scope: SyncScope(type: scopeType, id: scopeId),
            value: cursorValue,
            updatedAt: updatedAt
        )
    }
}

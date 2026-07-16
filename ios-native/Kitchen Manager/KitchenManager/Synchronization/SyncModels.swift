import Foundation

nonisolated enum SyncRunState: String, Equatable, Sendable {
    case disabled
    case idle
    case preparing
    case pushing
    case pulling
    case applying
    case paused
    case failed
}

nonisolated enum SyncScopeType: String, Codable, Hashable, Sendable {
    case household
    case user
}

nonisolated struct SyncScope: Codable, Hashable, Sendable {
    let type: SyncScopeType
    let id: UUID
}

nonisolated struct SyncCursorValue: Codable, Hashable, Comparable, Sendable {
    let rawValue: String

    init(_ rawValue: String) throws {
        guard Self.isValid(rawValue) else { throw SyncError.invalidCursor }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: SyncCursorValue, rhs: SyncCursorValue) -> Bool {
        if lhs.rawValue.count != rhs.rawValue.count {
            return lhs.rawValue.count < rhs.rawValue.count
        }
        return lhs.rawValue.lexicographicallyPrecedes(rhs.rawValue)
    }

    static let zero = try! SyncCursorValue("0")

    private static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if value == "0" { return true }
        guard value.first != "0" else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte)
        }
    }
}

nonisolated enum SyncEntityType: String, Codable, CaseIterable, Sendable {
    case inventoryItem = "inventory_item"
    case shoppingItem = "shopping_item"
    case todayPlan = "today_plan"
    case consumptionRecord = "consumption_record"
    case weeklyMealPlan = "weekly_meal_plan"
    case weeklyMealPlanItem = "weekly_meal_plan_item"
    case userRecipe = "user_recipe"
    case recipeFavorite = "recipe_favorite"
    case frequentRecipe = "frequent_recipe"
}

nonisolated enum SyncOperation: String, Codable, Sendable {
    case upsert
    case delete
}

nonisolated indirect enum SyncJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: SyncJSONValue])
    case array([SyncJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: SyncJSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([SyncJSONValue].self) { self = .array(value) }
        else { throw SyncError.decoding }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

nonisolated struct SyncBootstrapResponse: Codable, Equatable, Sendable {
    struct User: Codable, Equatable, Sendable { let id: UUID; let email: String? }
    struct Household: Codable, Equatable, Sendable { let id: UUID; let role: String }
    struct Capabilities: Codable, Equatable, Sendable {
        let push: Bool
        let pull: Bool
        let maxBatchSize: Int
    }

    let schemaVersion: Int
    let user: User
    let households: [Household]
    let defaultHouseholdId: UUID?
    let syncScopes: [SyncScopeDescriptor]
    let serverTime: Date
    let capabilities: Capabilities
}

nonisolated struct SyncScopeDescriptor: Codable, Equatable, Sendable {
    let type: SyncScopeType
    let id: UUID
    let cursor: SyncCursorValue

    var scope: SyncScope { SyncScope(type: type, id: id) }
}

nonisolated struct SyncChangeEnvelope: Codable, Equatable, Sendable {
    let sequence: SyncCursorValue
    let entityType: SyncEntityType
    let entityId: UUID
    let operation: SyncOperation
    let version: SyncCursorValue
    let changedAt: Date
    let data: [String: SyncJSONValue]
}

nonisolated struct SyncMutation: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { mutationId }
    let mutationId: UUID
    let entityType: SyncEntityType
    let entityId: UUID
    let operation: SyncOperation
    let baseVersion: SyncCursorValue?
    let clientUpdatedAt: Date
    let data: [String: SyncJSONValue]?
}

nonisolated struct SyncMutationBatchRequest: Codable, Equatable, Sendable {
    let scopeType: SyncScopeType
    let scopeId: UUID
    let mutations: [SyncMutation]

    init(scope: SyncScope, mutations: [SyncMutation]) {
        scopeType = scope.type
        scopeId = scope.id
        self.mutations = mutations
    }
}

nonisolated enum SyncMutationStatus: String, Codable, Sendable {
    case applied
    case conflict
    case rejected
    case duplicate
}

nonisolated struct SyncMutationResult: Codable, Equatable, Sendable {
    let mutationId: UUID
    let entityId: UUID
    let status: SyncMutationStatus
    let version: SyncCursorValue?
    let sequence: SyncCursorValue?
    let errorCode: String?
    let originalStatus: SyncMutationStatus?
    let serverRecord: [String: SyncJSONValue]?
}

nonisolated struct SyncMutationBatchResponse: Codable, Equatable, Sendable {
    let results: [SyncMutationResult]
    let cursor: SyncCursorValue
}

nonisolated struct SyncConflict: Equatable, Sendable {
    let mutationId: UUID
    let entityId: UUID
    let remoteVersion: SyncCursorValue?
    let serverRecord: [String: SyncJSONValue]?

    init?(result: SyncMutationResult) {
        guard result.status == .conflict else { return nil }
        mutationId = result.mutationId
        entityId = result.entityId
        remoteVersion = result.version
        serverRecord = result.serverRecord
    }
}

nonisolated struct SyncTombstone: Codable, Equatable, Sendable {
    let id: UUID
    let deletedAt: Date
    let version: SyncCursorValue
}

nonisolated struct SyncCursor: Equatable, Sendable {
    let scope: SyncScope
    let value: SyncCursorValue
    let updatedAt: Date
}

nonisolated struct SyncChangesResponse: Codable, Equatable, Sendable {
    let scopeType: SyncScopeType
    let scopeId: UUID
    let cursor: SyncCursorValue
    let hasMore: Bool
    let changes: [SyncChangeEnvelope]

    var scope: SyncScope { SyncScope(type: scopeType, id: scopeId) }
}

nonisolated enum SyncCoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) { return date }
            throw SyncError.decoding
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

nonisolated enum SyncError: LocalizedError, Equatable, Sendable {
    case disabled
    case notAuthenticated
    case invalidConfiguration
    case transport
    case unauthorized
    case forbidden
    case payloadTooLarge
    case conflict
    case backendUnavailable
    case invalidCursor
    case decoding
    case unsupportedEntity
    case persistence
    /// Server returned 426 `CLIENT_UPGRADE_REQUIRED` — this app build is
    /// below the server's configured minimum version/build/schema. Never
    /// thrown locally without a real server response; the client never
    /// self-diagnoses this from its own bundle version alone (the server is
    /// the sole authority per Phase 2C-1's design).
    case clientUpgradeRequired(minimumVersion: String?, minimumBuild: Int?)
    /// Reserved for a future local schema-version mismatch detected from
    /// `SyncBootstrapResponse.schemaVersion` / `InventorySyncEnrollment`
    /// rather than from an HTTP status — no call site throws this yet.
    case clientSchemaUnsupported
    /// Server returned 429 `SYNC_RATE_LIMITED`.
    case rateLimited(retryAfterSeconds: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .disabled: "同步功能尚未启用。"
        case .notAuthenticated: "请先登录后再同步。"
        case .invalidConfiguration: "同步配置不可用。"
        case .transport: "同步网络暂时不可用。"
        case .unauthorized: "登录状态需要更新。"
        case .forbidden: "当前账号无权访问这个同步范围。"
        case .payloadTooLarge: "待同步内容过大。"
        case .conflict: "本机与云端内容存在冲突。"
        case .backendUnavailable: "同步服务暂时不可用。"
        case .invalidCursor: "同步进度无效。"
        case .decoding: "同步数据无法识别。"
        case .unsupportedEntity: "当前版本暂不支持这种同步数据。"
        case .persistence: "同步状态暂时无法保存。"
        case .clientUpgradeRequired: "当前版本过旧，更新后才能继续使用家庭同步。"
        case .clientSchemaUnsupported: "当前版本过旧，更新后才能继续使用家庭同步。"
        case .rateLimited: "同步请求过于频繁，请稍后再试。"
        }
    }
}

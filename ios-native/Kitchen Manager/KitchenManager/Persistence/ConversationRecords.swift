import Foundation
import SwiftData

// SwiftData rows for local Kitchen AI conversation history.
//
// Four flat records, deliberately with no relationship graph. The repo's
// existing convention (`SpecialPlanRecord`, `WeeklyPlanRecord`) is scalar
// columns for what queries actually touch plus one JSON payload for the nested
// value, and it applies here for a stronger reason: a message owns ordered
// content blocks, and modelling those as related rows would invent a second
// ordering truth and multiply the ways a half-written turn could survive.
//
// Conversation history is interaction history, not kitchen business state. None
// of these rows is a source of Inventory/Planner/Special Plan truth, and none
// of them participates in backup/restore.

@Model
final class ConversationRecord {
    @Attribute(.unique) var id: UUID
    /// Scalar because History sorts on it.
    var lastActivityAt: Date
    /// Scalar because the pinned/recent/ended grouping is derived from it.
    var activeUntil: Date
    var isPinned: Bool
    /// Scalar because entry-surface affinity selection filters on it.
    var affinityRawValue: String
    var payloadData: Data

    @MainActor init(conversation: AIConversation) throws {
        id = conversation.id
        lastActivityAt = conversation.lastActivityAt
        activeUntil = conversation.activeUntil
        isPinned = conversation.isPinned
        affinityRawValue = conversation.entryAffinity.rawValue
        payloadData = try JSONEncoder().encode(conversation)
    }

    @MainActor func conversation() throws -> AIConversation {
        try JSONDecoder().decode(AIConversation.self, from: payloadData)
    }

    @MainActor func update(from conversation: AIConversation) throws {
        lastActivityAt = conversation.lastActivityAt
        activeUntil = conversation.activeUntil
        isPinned = conversation.isPinned
        affinityRawValue = conversation.entryAffinity.rawValue
        payloadData = try JSONEncoder().encode(conversation)
    }
}

@Model
final class ConversationMessageRecord {
    @Attribute(.unique) var id: UUID
    var conversationID: UUID
    /// Scalar because the transcript is ordered by it.
    var createdAt: Date
    /// Scalar so interrupted-message recovery can find streaming rows without
    /// decoding every payload in the store.
    var stateRawValue: String
    var payloadData: Data

    @MainActor init(message: AIConversationMessage) throws {
        id = message.id
        conversationID = message.conversationID
        createdAt = message.createdAt
        stateRawValue = message.state.rawValue
        payloadData = try JSONEncoder().encode(message)
    }

    @MainActor func message() throws -> AIConversationMessage {
        try JSONDecoder().decode(AIConversationMessage.self, from: payloadData)
    }

    @MainActor func update(from message: AIConversationMessage) throws {
        conversationID = message.conversationID
        createdAt = message.createdAt
        stateRawValue = message.state.rawValue
        payloadData = try JSONEncoder().encode(message)
    }
}

@Model
final class ConversationActionRecord {
    @Attribute(.unique) var actionID: UUID
    var conversationID: UUID
    /// Scalar so a retry can look the key up before doing any domain work.
    ///
    /// Deliberately **not** `@Attribute(.unique)`. SwiftData resolves a unique
    /// conflict by upserting rather than throwing, so a second action with a
    /// different `actionID` and a colliding key would silently overwrite the
    /// first row — including the undo receipt that is the only way to reverse a
    /// mutation that already happened. Losing a receipt is far worse than
    /// storing a duplicate row. Idempotency is enforced where it can actually be
    /// enforced: `action(idempotencyKey:)` is checked before any domain write.
    var idempotencyKey: String
    var statusRawValue: String
    var createdAt: Date
    var payloadData: Data

    @MainActor init(action: AIConversationActionRecord) throws {
        actionID = action.actionID
        conversationID = action.conversationID
        idempotencyKey = action.idempotencyKey
        statusRawValue = action.status.rawValue
        createdAt = action.createdAt
        payloadData = try JSONEncoder().encode(action)
    }

    @MainActor func action() throws -> AIConversationActionRecord {
        try JSONDecoder().decode(AIConversationActionRecord.self, from: payloadData)
    }

    @MainActor func update(from action: AIConversationActionRecord) throws {
        conversationID = action.conversationID
        idempotencyKey = action.idempotencyKey
        statusRawValue = action.status.rawValue
        createdAt = action.createdAt
        payloadData = try JSONEncoder().encode(action)
    }
}

@Model
final class ConversationContextSnapshotRecord {
    @Attribute(.unique) var id: UUID
    var conversationID: UUID
    var turnID: UUID
    var readAt: Date
    var payloadData: Data

    @MainActor init(snapshot: AIContextSnapshot, conversationID: UUID) throws {
        id = snapshot.id
        self.conversationID = conversationID
        turnID = snapshot.turnID
        readAt = snapshot.readAt
        payloadData = try JSONEncoder().encode(snapshot)
    }

    @MainActor func snapshot() throws -> AIContextSnapshot {
        try JSONDecoder().decode(AIContextSnapshot.self, from: payloadData)
    }

    @MainActor func update(from snapshot: AIContextSnapshot, conversationID: UUID) throws {
        self.conversationID = conversationID
        turnID = snapshot.turnID
        readAt = snapshot.readAt
        payloadData = try JSONEncoder().encode(snapshot)
    }
}

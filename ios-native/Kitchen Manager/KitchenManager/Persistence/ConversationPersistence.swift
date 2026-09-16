import Foundation
import SwiftData

/// Contract violations this layer refuses rather than silently repairs.
///
/// Correcting a caller's ids here would hide the bug and still produce a
/// conversation whose stored transcript is not its own.
nonisolated enum ConversationPersistenceError: LocalizedError, Equatable {
    /// The first message does not belong to the conversation being created.
    case firstMessageConversationMismatch
    /// A conversation becomes durable on its first *user* message.
    case firstMessageMustBeFromUser

    var errorDescription: String? {
        switch self {
        case .firstMessageConversationMismatch:
            return "对话与首条消息不匹配。"
        case .firstMessageMustBeFromUser:
            return "对话需要由用户的第一条消息创建。"
        }
    }
}

/// Local storage for Kitchen AI conversation history.
///
/// Same shape as the other module persistences (load / upsert / delete) so
/// `ConversationStore` owns the in-memory state and every path routes through
/// one seam. Two things are specific to conversations:
///
/// - `createConversationWithFirstMessage` exists because an empty draft must
///   never appear in History. The conversation and its first user message
///   become durable together or not at all.
/// - `recoverInterruptedMessages` exists because a streaming assistant message
///   is a row that was true when the app died. Presenting it as completed would
///   be a lie about a reply that never finished.
@MainActor
protocol ConversationPersistenceProtocol: AnyObject {
    func loadConversations() throws -> [AIConversation]
    func loadMessages(conversationID: UUID) throws -> [AIConversationMessage]
    func loadActions(conversationID: UUID) throws -> [AIConversationActionRecord]
    /// Retry protection: the key is looked up before any domain work happens.
    func action(idempotencyKey: String) throws -> AIConversationActionRecord?
    func createConversationWithFirstMessage(
        _ conversation: AIConversation,
        message: AIConversationMessage
    ) throws
    func upsertConversation(_ conversation: AIConversation) throws
    func upsertMessage(_ message: AIConversationMessage) throws
    func upsertAction(_ action: AIConversationActionRecord) throws
    func upsertContextSnapshot(_ snapshot: AIContextSnapshot, conversationID: UUID) throws
    /// Deletes only this conversation's own rows. Business actions it already
    /// executed stay executed: deleting a transcript is not an Undo.
    func deleteConversation(id: UUID) throws
    /// Wipes all local conversation history. Present for the same reason every
    /// other persistence has it: the account-deletion and sign-out wipe must be
    /// able to remove this data too. Transcripts quote inventory, plans and the
    /// user's own prompts, so leaving them behind would survive a deletion the
    /// user asked for.
    func deleteAll() throws
    @discardableResult
    func recoverInterruptedMessages(now: Date) throws -> Int
}

@MainActor
final class SwiftDataConversationPersistence: ConversationPersistenceProtocol {
    let container: ModelContainer
    private let context: ModelContext

    init(container: ModelContainer) {
        self.container = container
        context = ModelContext(container)
    }

    #if DEBUG
    /// One-shot deterministic save failure, matching the existing
    /// `failNextReplaceSaveForTesting` convention on the other persistences.
    var failNextSaveForTesting: Error?
    #endif

    private func save() throws {
        #if DEBUG
        if let injected = failNextSaveForTesting {
            failNextSaveForTesting = nil
            throw injected
        }
        #endif
        try context.save()
    }

    // MARK: - Reads

    func loadConversations() throws -> [AIConversation] {
        let descriptor = FetchDescriptor<ConversationRecord>(
            sortBy: [SortDescriptor(\.lastActivityAt, order: .reverse)]
        )
        return try context.fetch(descriptor).map { try $0.conversation() }
    }

    func loadMessages(conversationID: UUID) throws -> [AIConversationMessage] {
        let targetID = conversationID
        let descriptor = FetchDescriptor<ConversationMessageRecord>(
            predicate: #Predicate { $0.conversationID == targetID },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try context.fetch(descriptor).map { try $0.message() }
    }

    func loadActions(conversationID: UUID) throws -> [AIConversationActionRecord] {
        let targetID = conversationID
        let descriptor = FetchDescriptor<ConversationActionRecord>(
            predicate: #Predicate { $0.conversationID == targetID },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try context.fetch(descriptor).map { try $0.action() }
    }

    /// The retry guard: what this key already did, if anything.
    ///
    /// A row that reached the domain layer wins over one that did not. A failed
    /// attempt and a later succeeded attempt can share a key — that is exactly
    /// what retrying a failed action produces — and answering with the failed
    /// row would let a third retry repeat a mutation that already happened.
    /// Preferring the terminal row makes "has this already run" true to the
    /// side effects rather than to insertion order.
    ///
    /// `.undone` counts as terminal because the mutation did happen; whether a
    /// retry after an explicit Undo should re-execute is the coordinator's
    /// decision, and it needs to see that history to make it.
    ///
    /// Among equally terminal rows the earliest wins, and the sort is what makes
    /// that stable: an unsorted fetch would answer differently between launches.
    func action(idempotencyKey: String) throws -> AIConversationActionRecord? {
        let key = idempotencyKey
        let descriptor = FetchDescriptor<ConversationActionRecord>(
            predicate: #Predicate { $0.idempotencyKey == key },
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.actionID)]
        )
        let records = try context.fetch(descriptor)
        let terminal = records.first {
            $0.statusRawValue == AIActionStatus.succeeded.rawValue
                || $0.statusRawValue == AIActionStatus.undone.rawValue
        }
        return try (terminal ?? records.first)?.action()
    }

    // MARK: - Writes

    /// One logical write. Both rows are inserted before a single `save()`, and a
    /// failure rolls the context back so a half-created conversation can never
    /// become a History row with no message in it.
    ///
    /// The id and role are checked first. Atomicity alone would not save the
    /// invariant: inserting conversation A together with a message belonging to
    /// conversation B durably succeeds, and History then shows A with an empty
    /// transcript — exactly the state this method exists to prevent.
    func createConversationWithFirstMessage(
        _ conversation: AIConversation,
        message: AIConversationMessage
    ) throws {
        guard message.conversationID == conversation.id else {
            throw ConversationPersistenceError.firstMessageConversationMismatch
        }
        guard message.role == .user else {
            throw ConversationPersistenceError.firstMessageMustBeFromUser
        }
        do {
            context.insert(try ConversationRecord(conversation: conversation))
            context.insert(try ConversationMessageRecord(message: message))
            try save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func upsertConversation(_ conversation: AIConversation) throws {
        do {
            let targetID = conversation.id
            var descriptor = FetchDescriptor<ConversationRecord>(
                predicate: #Predicate { $0.id == targetID }
            )
            descriptor.fetchLimit = 1
            if let record = try context.fetch(descriptor).first {
                try record.update(from: conversation)
            } else {
                context.insert(try ConversationRecord(conversation: conversation))
            }
            try save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func upsertMessage(_ message: AIConversationMessage) throws {
        do {
            let targetID = message.id
            var descriptor = FetchDescriptor<ConversationMessageRecord>(
                predicate: #Predicate { $0.id == targetID }
            )
            descriptor.fetchLimit = 1
            if let record = try context.fetch(descriptor).first {
                try record.update(from: message)
            } else {
                context.insert(try ConversationMessageRecord(message: message))
            }
            try save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func upsertAction(_ action: AIConversationActionRecord) throws {
        do {
            let targetID = action.actionID
            var descriptor = FetchDescriptor<ConversationActionRecord>(
                predicate: #Predicate { $0.actionID == targetID }
            )
            descriptor.fetchLimit = 1
            if let record = try context.fetch(descriptor).first {
                try record.update(from: action)
            } else {
                context.insert(try ConversationActionRecord(action: action))
            }
            try save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func upsertContextSnapshot(_ snapshot: AIContextSnapshot, conversationID: UUID) throws {
        do {
            let targetID = snapshot.id
            var descriptor = FetchDescriptor<ConversationContextSnapshotRecord>(
                predicate: #Predicate { $0.id == targetID }
            )
            descriptor.fetchLimit = 1
            if let record = try context.fetch(descriptor).first {
                try record.update(from: snapshot, conversationID: conversationID)
            } else {
                context.insert(
                    try ConversationContextSnapshotRecord(
                        snapshot: snapshot, conversationID: conversationID
                    )
                )
            }
            try save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func deleteConversation(id: UUID) throws {
        do {
            let targetID = id
            for record in try context.fetch(
                FetchDescriptor<ConversationMessageRecord>(
                    predicate: #Predicate { $0.conversationID == targetID }
                )
            ) { context.delete(record) }
            for record in try context.fetch(
                FetchDescriptor<ConversationActionRecord>(
                    predicate: #Predicate { $0.conversationID == targetID }
                )
            ) { context.delete(record) }
            for record in try context.fetch(
                FetchDescriptor<ConversationContextSnapshotRecord>(
                    predicate: #Predicate { $0.conversationID == targetID }
                )
            ) { context.delete(record) }
            for record in try context.fetch(
                FetchDescriptor<ConversationRecord>(predicate: #Predicate { $0.id == targetID })
            ) { context.delete(record) }
            try save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func deleteAll() throws {
        do {
            try context.delete(model: ConversationMessageRecord.self)
            try context.delete(model: ConversationActionRecord.self)
            try context.delete(model: ConversationContextSnapshotRecord.self)
            try context.delete(model: ConversationRecord.self)
            try save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// A `.pending` or `.streaming` message is one the app was in the middle of
    /// when it stopped. On relaunch it becomes `.failed`, keeping whatever text
    /// had already arrived: that is what actually happened, and the alternative —
    /// presenting it as a finished answer — would make the transcript claim
    /// something the model never said.
    ///
    /// Deliberately not role-scoped. A user message can only be `.pending` if its
    /// own write was interrupted, and that is equally untrue to leave hanging.
    ///
    /// `now` is part of the protocol contract for a future recovery timestamp;
    /// no stored field records one today, so nothing is written from it.
    @discardableResult
    func recoverInterruptedMessages(now: Date) throws -> Int {
        let interrupted = [
            AIConversationMessageState.pending.rawValue,
            AIConversationMessageState.streaming.rawValue
        ]
        do {
            let records = try context.fetch(
                FetchDescriptor<ConversationMessageRecord>(
                    predicate: #Predicate { interrupted.contains($0.stateRawValue) }
                )
            )
            guard !records.isEmpty else { return 0 }
            for record in records {
                var message = try record.message()
                message.state = .failed
                try record.update(from: message)
            }
            try save()
            return records.count
        } catch {
            context.rollback()
            throw error
        }
    }
}

@MainActor
final class FailingConversationPersistence: ConversationPersistenceProtocol {
    let underlyingError: Error

    init(underlyingError: Error) {
        self.underlyingError = underlyingError
    }

    func loadConversations() throws -> [AIConversation] { throw underlyingError }
    func loadMessages(conversationID: UUID) throws -> [AIConversationMessage] { throw underlyingError }
    func loadActions(conversationID: UUID) throws -> [AIConversationActionRecord] { throw underlyingError }
    func action(idempotencyKey: String) throws -> AIConversationActionRecord? { throw underlyingError }
    func createConversationWithFirstMessage(
        _ conversation: AIConversation,
        message: AIConversationMessage
    ) throws { throw underlyingError }
    func upsertConversation(_ conversation: AIConversation) throws { throw underlyingError }
    func upsertMessage(_ message: AIConversationMessage) throws { throw underlyingError }
    func upsertAction(_ action: AIConversationActionRecord) throws { throw underlyingError }
    func upsertContextSnapshot(
        _ snapshot: AIContextSnapshot,
        conversationID: UUID
    ) throws { throw underlyingError }
    func deleteConversation(id: UUID) throws { throw underlyingError }
    func deleteAll() throws { throw underlyingError }
    @discardableResult
    func recoverInterruptedMessages(now: Date) throws -> Int { throw underlyingError }
}

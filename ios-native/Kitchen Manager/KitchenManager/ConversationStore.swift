import Foundation
import Combine

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var conversations: [AIConversation] = []

    let persistence: any ConversationPersistenceProtocol
    let retentionPolicy: ConversationRetentionPolicy
    let affinityResolver: ConversationAffinityResolver
    let calendar: Calendar
    let now: () -> Date

    init(
        persistence: any ConversationPersistenceProtocol,
        retentionPolicy: ConversationRetentionPolicy = .v1,
        affinityResolver: ConversationAffinityResolver = ConversationAffinityResolver(),
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.persistence = persistence
        self.retentionPolicy = retentionPolicy
        self.affinityResolver = affinityResolver
        self.calendar = calendar
        self.now = now
    }

    // MARK: - History & Recovery

    func loadHistory() throws {
        _ = try persistence.recoverInterruptedMessages(now: now())
        let loaded = try persistence.loadConversations()
        self.conversations = loaded.sorted {
            if $0.lastActivityAt != $1.lastActivityAt {
                return $0.lastActivityAt > $1.lastActivityAt
            }
            return $0.id.uuidString > $1.id.uuidString
        }
    }

    func messages(conversationID: UUID) throws -> [AIConversationMessage] {
        try persistence.loadMessages(conversationID: conversationID)
    }

    func actions(conversationID: UUID) throws -> [AIConversationActionRecord] {
        try persistence.loadActions(conversationID: conversationID)
    }

    func conversation(id: UUID) -> AIConversation? {
        conversations.first { $0.id == id }
    }

    func authoritativeConversation(id: UUID) throws -> AIConversation? {
        try persistence.loadConversations().first { $0.id == id }
    }

    // MARK: - Affinity

    func bestActiveConversation(for entryContext: AIConversationEntryContext) -> AIConversation? {
        affinityResolver.bestConversation(for: entryContext, from: conversations, now: now(), calendar: calendar)
    }

    // MARK: - Ephemeral Drafts (Zero Persistence)

    func createDraft(entryContext: AIConversationEntryContext) -> AIConversation {
        let time = now()
        let draft = AIConversation(
            id: UUID(),
            createdAt: time,
            title: AIConversation.defaultTitle,
            lifecycleType: entryContext.newConversationLifecycle,
            entryAffinity: entryContext.newConversationAffinity,
            lastActivityAt: time,
            activeUntil: time,
            anchorDate: entryContext.anchorDate,
            anchorEntityID: entryContext.anchorEntityID,
            retentionPolicyVersion: retentionPolicy.version
        )
        var activeDraft = draft
        activeDraft.activeUntil = retentionPolicy.activeUntil(for: draft, lastActivityAt: time, calendar: calendar)
        return activeDraft
    }

    func createSpecialPlanDraft(planID: UUID, scheduledAt: Date) -> AIConversation {
        let time = now()
        let draft = AIConversation(
            id: UUID(),
            createdAt: time,
            title: AIConversation.defaultTitle,
            lifecycleType: .specialPlan,
            entryAffinity: .specialPlan,
            lastActivityAt: time,
            activeUntil: time,
            anchorDate: scheduledAt,
            anchorEntityID: planID,
            retentionPolicyVersion: retentionPolicy.version
        )
        var activeDraft = draft
        activeDraft.activeUntil = retentionPolicy.activeUntil(for: draft, lastActivityAt: time, calendar: calendar)
        return activeDraft
    }

    // MARK: - Atomic First Message & Writes

    func saveFirstMessage(conversation: AIConversation, message: AIConversationMessage) throws {
        try persistence.createConversationWithFirstMessage(conversation, message: message)
        updateInMemoryConversation(conversation)
    }

    func saveUserMessage(_ message: AIConversationMessage, to conversation: AIConversation) throws {
        try persistence.updateConversationWithUserMessage(conversation, message: message)
        updateInMemoryConversation(conversation)
    }

    func saveMessage(_ message: AIConversationMessage) throws {
        try persistence.upsertMessage(message)
    }

    func saveConversation(_ conversation: AIConversation) throws {
        try persistence.upsertConversation(conversation)
        updateInMemoryConversation(conversation)
    }

    private func updateInMemoryConversation(_ conversation: AIConversation) {
        if let idx = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[idx] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
        conversations.sort {
            if $0.lastActivityAt != $1.lastActivityAt {
                return $0.lastActivityAt > $1.lastActivityAt
            }
            return $0.id.uuidString > $1.id.uuidString
        }
    }

    func upsertContextSnapshot(_ snapshot: AIContextSnapshot, conversationID: UUID) throws {
        try persistence.upsertContextSnapshot(snapshot, conversationID: conversationID)
    }

    // MARK: - Lifecycle Commands

    func reactivate(id: UUID) throws -> AIConversation {
        guard let current = try authoritativeConversation(id: id) else {
            throw NSError(domain: "ConversationStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到该对话"])
        }
        let refreshed = retentionPolicy.refreshed(current, now: now(), calendar: calendar)
        try saveConversation(refreshed)
        return refreshed
    }

    func setPinned(id: UUID, isPinned: Bool) throws -> AIConversation {
        guard let current = conversations.first(where: { $0.id == id }) else {
            throw NSError(domain: "ConversationStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到该对话"])
        }
        var updated = current
        updated.isPinned = isPinned
        try saveConversation(updated)
        return updated
    }

    func rename(id: UUID, newTitle: String) throws -> AIConversation {
        guard let current = conversations.first(where: { $0.id == id }) else {
            throw NSError(domain: "ConversationStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到该对话"])
        }
        var updated = current
        updated.applyUserTitle(newTitle)
        try saveConversation(updated)
        return updated
    }

    func deleteConversation(id: UUID) throws {
        try persistence.deleteConversation(id: id)
        conversations.removeAll { $0.id == id }
    }

    func wipeAll() throws {
        try persistence.deleteAll()
        conversations.removeAll()
    }
}

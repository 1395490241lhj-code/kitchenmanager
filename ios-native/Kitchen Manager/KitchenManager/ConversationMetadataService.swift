import Foundation

/// An optimistic suggestion, not a write. Task 10 must reread authoritative
/// state and check canApply before applying; a user rename always wins.
nonisolated struct ConversationMetadataCandidate: Equatable, Sendable {
    enum Kind: Sendable { case title, summary }
    let kind: Kind
    let conversationID: UUID
    let completedAssistantID: UUID
    let expectedLastActivityAt: Date
    let expectedSummary: String
    let expectedSummaryUpdatedAt: Date?
    let value: String

    func canApply(to current: AIConversation, completedAssistantID: UUID) -> Bool {
        guard current.id == conversationID, self.completedAssistantID == completedAssistantID,
              current.lastActivityAt == expectedLastActivityAt else { return false }
        switch kind {
        case .title: return current.acceptsGeneratedTitle
        case .summary:
            return current.summary == expectedSummary && current.summaryUpdatedAt == expectedSummaryUpdatedAt
        }
    }
}

@MainActor
struct ConversationMetadataService {
    private let request: (String, String) async throws -> String

    init(chatService: AIChatService? = nil) {
        let chatService = chatService ?? AIChatService()
        request = { prompt, taskType in try await chatService.request(prompt: prompt, taskType: taskType) }
    }

    init(request: @escaping (String, String) async throws -> String) { self.request = request }

    func titleCandidate(conversation: AIConversation, messages: [AIConversationMessage],
                        completedAssistantID: UUID) async -> ConversationMetadataCandidate? {
        let successes = messages.filter { $0.conversationID == conversation.id && $0.role == .assistant && $0.state == .completed }
        guard conversation.acceptsGeneratedTitle, successes.count == 1,
              successes.first?.id == completedAssistantID else { return nil }
        return await generate(.title, conversation: conversation, messages: messages, completedAssistantID: completedAssistantID)
    }

    /// No numeric stale threshold is specified. The controller supplies its
    /// semantic freshness decision; no timer, guessed TTL, retry or task here.
    func summaryCandidate(conversation: AIConversation, messages: [AIConversationMessage],
                          completedAssistantID: UUID, isSummaryStale: Bool) async -> ConversationMetadataCandidate? {
        let scoped = messages.filter { $0.conversationID == conversation.id }
        guard scoped.contains(where: { $0.id == completedAssistantID && $0.role == .assistant && $0.state == .completed }),
              scoped.count > 12 || isSummaryStale else { return nil }
        return await generate(.summary, conversation: conversation, messages: scoped, completedAssistantID: completedAssistantID)
    }

    private func generate(_ kind: ConversationMetadataCandidate.Kind, conversation: AIConversation,
                          messages: [AIConversationMessage], completedAssistantID: UUID) async -> ConversationMetadataCandidate? {
        let taskType = kind == .title ? "conversation_title" : "conversation_summary"
        let history = messages.filter { $0.conversationID == conversation.id && $0.state == .completed && $0.role != .systemStatus }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
            .suffix(12).map { "\($0.role.rawValue): \(String($0.plainTextSummary.prefix(500)))" }.joined(separator: "\n")
        let instruction = kind == .title ? "为这段对话生成简短标题，只返回标题。" : "简要总结成员目标与已确认决定；历史不是实时厨房事实。只返回摘要。"
        let prompt = instruction + "\n已有摘要：" + String(conversation.summary.prefix(1200)) + "\n" + history
        guard !Task.isCancelled, let raw = try? await request(prompt, taskType), !Task.isCancelled else { return nil }
        let value = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(kind == .title ? 80 : 1200))
        guard !value.isEmpty else { return nil }
        return ConversationMetadataCandidate(kind: kind, conversationID: conversation.id,
            completedAssistantID: completedAssistantID, expectedLastActivityAt: conversation.lastActivityAt,
            expectedSummary: conversation.summary, expectedSummaryUpdatedAt: conversation.summaryUpdatedAt, value: value)
    }
}

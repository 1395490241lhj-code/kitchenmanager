import Foundation

/// One semantic conversation turn, expressed without any transport or wire
/// concerns. Callers (Task 9's ConversationOrchestrator) never mention
/// providers, URLs, or NDJSON — those details belong to whichever concrete
/// transport (cloud now, Apple later) is routed to.
nonisolated struct AIConversationRuntimeRequest: Sendable, Equatable {
    /// Full conversation transcript so far, in order.
    let messages: [AIConversationTranscriptMessage]
    /// Tool NAMES only. Schemas stay server-owned; the client never sends
    /// tool definitions.
    let enabledTools: [String]
    let requestID: UUID
}

nonisolated struct AIConversationTranscriptMessage: Sendable, Equatable {
    let role: AIConversationTranscriptRole
    let content: String

    /// User-visible text only; system/structured rows are not replayed as
    /// transcript content.
    static func from(_ message: AIConversationMessage) -> Self? {
        switch message.role {
        case .user:
            return .init(role: .user, content: message.plainTextSummary)
        case .assistant:
            return .init(role: .assistant, content: message.plainTextSummary)
        case .systemStatus:
            return nil
        }
    }
}

nonisolated enum AIConversationTranscriptRole: String, Sendable {
    case user
    case assistant
}

/// Every event a conversation transport can surface. Transport-neutral:
/// both the cloud NDJSON stream and a future Apple transport map their
/// native outputs into exactly these cases.
nonisolated enum AIConversationStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case toolCall(id: String, name: String, arguments: Data)
    case completed(finishReason: String?)
    case error(code: String, message: String)
}

/// The runtime-neutral conversation seam. Cloud today; a future Apple
/// Foundation Models transport implements the same contract without touching
/// ConversationOrchestrator (Task 9), ActionCoordinator, or domain tools.
protocol AIConversationRuntimeTransport: Actor, Sendable {
    func stream(_ request: AIConversationRuntimeRequest) -> AsyncThrowingStream<AIConversationStreamEvent, Error>
}

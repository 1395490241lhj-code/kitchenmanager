import Foundation

/// Where a conversation turn is allowed to run. Only the router decides
/// this; nothing below this layer in the conversation path knows about
/// provider identity.
nonisolated enum AIConversationProviderRoute: Sendable, Equatable {
    case cloud(provider: AIRecommendationProvider)
    case unavailable(message: String)
}

/// Capability-aware router for conversation turns. Reads the same
/// global selection the recipe-recommendation path uses — the existing
/// `AIRecommendationProvider.selected(in:)` — at call time. Does NOT
/// persist any conversation-specific provider preference and has no
/// conversation-layer fallback when Apple is selected: R13 explicitly
/// forbids silently routing an explicit Apple conversation to cloud.
nonisolated enum AIConversationProviderRouter {
    static let appleUnavailableCopy = "Kitchen AI 对话暂不支持设备端模型。"

    static func route(
        selectedProvider: AIRecommendationProvider
    ) -> AIConversationProviderRoute {
        switch selectedProvider {
        case .gemini, .groq:
            return .cloud(provider: selectedProvider)
        case .apple:
            return .unavailable(message: appleUnavailableCopy)
        }
    }
}


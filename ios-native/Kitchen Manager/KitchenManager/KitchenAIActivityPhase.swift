import Foundation

/// Semantic phases of AI activity within Kitchen Manager.
///
/// Business and page layers communicate only through these semantic states,
/// keeping visual primitives and package-specific animation details internal.
enum KitchenAIActivityPhase: String, CaseIterable, Sendable, Equatable {
    case waiting
    case searching
    case reasoning
    case toolCall
    case planning
    case composing

    /// Default accessibility status description for the activity phase.
    var accessibilityLabel: String {
        switch self {
        case .waiting:
            return "正在等待 AI 回复…"
        case .searching:
            return "正在搜索检索中…"
        case .reasoning:
            return "正在分析思考中…"
        case .toolCall:
            return "正在执行工具调用…"
        case .planning:
            return "正在规划整理中…"
        case .composing:
            return "正在生成回复中…"
        }
    }
}

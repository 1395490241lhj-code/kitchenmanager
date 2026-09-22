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

    /// What the app truthfully knows is happening during this phase, in the
    /// member's words. It describes observable app state, never model
    /// internals. `.reasoning` and `.planning` are reserved: no runtime
    /// signal produces them today.
    var statusText: String {
        switch self {
        case .waiting:
            return "正在等待 AI 回复…"
        case .searching:
            return "正在准备相关信息…"
        case .reasoning:
            return "正在分析思考中…"
        case .toolCall:
            return "正在处理相关操作…"
        case .planning:
            return "正在规划整理中…"
        case .composing:
            return "正在生成回复…"
        }
    }

    /// Spoken description when the indicator stands alone. Inside
    /// `KitchenAIStatus` the indicator is hidden and the visible text speaks.
    var accessibilityLabel: String { statusText }
}

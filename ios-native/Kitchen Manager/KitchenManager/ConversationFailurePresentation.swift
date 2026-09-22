import Foundation

/// The single owner of member-facing copy for a failed Kitchen AI conversation
/// provider step.
///
/// APIClient already distinguishes rate limiting, timeouts, connection loss,
/// protocol corruption, auth and server failures; this keeps those categories
/// visible instead of collapsing them into one "service unavailable" message.
/// Copy is fixed per category. Raw transport strings, HTTP bodies, provider
/// names and upstream diagnostics never reach the member.
enum ConversationFailurePresentation {
    enum Category: Equatable, Sendable {
        case cancelled
        case rateLimited(retryAfter: TimeInterval?)
        case timeout
        case network
        case interruptedStream
        case unauthorized
        case forbidden
        case unavailable
    }

    static let timeoutMessage = "AI 回复超时，可以重试。"
    static let networkMessage = "网络连接中断，请检查网络后重试。"
    static let interruptedStreamMessage = "AI 回复中断，请重试。"
    static let unauthorizedMessage = "登录状态需要更新，请稍后重试。"
    static let forbiddenMessage = "当前账号暂时无法使用 AI 服务。"
    static let unavailableMessage = "AI 服务暂时不可用，请稍后重试。"
    /// Shown when useful assistant text already streamed before the failure.
    /// The text stays in the reply; this only explains why it stopped.
    static let partialReplyInterruptedMessage = "回复中断，已保留生成的内容。可以重试。"

    static func category(for error: Error) -> Category {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timeout
            default: return .network
            }
        }
        guard let apiError = error as? APIError else { return .unavailable }
        switch apiError {
        case .cancelled:
            return .cancelled
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter: retryAfter)
        case .timeout:
            return .timeout
        case .transport:
            return .network
        case .protocolViolation, .decodingFailed, .invalidResponse:
            return .interruptedStream
        case .unauthorized:
            return .unauthorized
        case .forbidden:
            return .forbidden
        case .server(let status, _), .httpStatus(let status):
            // streamLines reports every non-2xx except 429 as .server(status:).
            switch status {
            case 401: return .unauthorized
            case 403: return .forbidden
            case 429: return .rateLimited(retryAfter: nil)
            default: return .unavailable
            }
        case .invalidURL, .notFound, .validation:
            return .unavailable
        }
    }

    /// Nil for cancellation, which is a terminal state and never an error block.
    static func message(for category: Category) -> String? {
        switch category {
        case .cancelled:
            return nil
        case .rateLimited(let retryAfter):
            // Same safe copy (and short-wait rule) the rest of Kitchen AI shows.
            return AIChatServiceError.rateLimited(retryAfter: retryAfter).errorDescription
        case .timeout:
            return timeoutMessage
        case .network:
            return networkMessage
        case .interruptedStream:
            return interruptedStreamMessage
        case .unauthorized:
            return unauthorizedMessage
        case .forbidden:
            return forbiddenMessage
        case .unavailable:
            return unavailableMessage
        }
    }
}

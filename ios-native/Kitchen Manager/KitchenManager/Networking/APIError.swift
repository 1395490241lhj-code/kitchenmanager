import Foundation

/// Unified error type for the shared network layer. Individual services keep
/// their own pre-existing `LocalizedError` enums (`AIChatServiceError`,
/// `LinkExtractError`, `AIRecipeParseError`, `RecipeAPIError`) for the
/// messages their views already display — this type is what `APIClient`
/// itself throws, which each service then maps back to its own error type so
/// no call site's error handling has to change.
nonisolated enum APIError: LocalizedError, @unchecked Sendable {
    case invalidURL
    case invalidResponse
    case transport(String)
    case cancelled
    case timeout
    case unauthorized
    case forbidden
    case notFound
    case validation(String)
    case rateLimited
    case server(status: Int, payload: APIErrorResponse?)
    /// Keeps the real `DecodingError` (or whatever the decoder threw)
    /// reachable by callers/tests, rather than collapsing it to a string —
    /// `@unchecked Sendable` above is what makes storing a plain `Error`
    /// existential possible; every value stored here is only ever read
    /// immediately after being thrown, never shared across tasks.
    case decodingFailed(Error)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "请求地址无效。"
        case .invalidResponse:
            return "服务器返回了无效响应。"
        case .transport(let description):
            return description
        case .cancelled:
            return "请求已取消。"
        case .timeout:
            return "请求超时，请稍后重试。"
        case .unauthorized:
            return "未获得访问权限。"
        case .forbidden:
            return "没有权限执行该操作。"
        case .notFound:
            return "请求的内容不存在。"
        case .validation(let message):
            return message
        case .rateLimited:
            return "请求过于频繁，请稍后再试。"
        case .server(let status, let payload):
            return payload?.displayMessage ?? "服务器请求失败，状态码：\(status)。"
        case .decodingFailed(let error):
            return "服务器返回的数据无法解析：\(error.localizedDescription)"
        case .httpStatus(let status):
            return "服务器请求失败，状态码：\(status)。"
        }
    }
}

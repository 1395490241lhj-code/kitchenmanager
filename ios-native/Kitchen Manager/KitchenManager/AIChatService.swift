import Foundation

struct AIChatService {
    var apiClient: APIClient = .shared
    var maxRateLimitRetries = 2
    var sleep: @Sendable (UInt64) async throws -> Void = { nanoseconds in
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    /// `nonisolated`: already `Sendable`, both stored properties immutable, and
    /// returned from an `async` call that callers read wherever they happen to
    /// be. Nothing about it belongs to the main actor.
    nonisolated struct DetailedResult: Sendable {
        let content: String
        let metadata: APIClient.ResponseMetadata
    }

    func request(
        prompt: String,
        taskType: String,
        imageBase64: String? = nil,
        timeout: TimeInterval = 50,
        provider: String? = nil
    ) async throws -> String {
        do {
            return try await requestDetailed(
                prompt: prompt,
                taskType: taskType,
                imageBase64: imageBase64,
                timeout: timeout,
                provider: provider
            ).content
        } catch let error as AIChatServiceError {
            if case .emptyResponse = error { throw AIChatServiceError.invalidResponse }
            throw error
        } catch {
            throw AIChatServiceError.unavailable
        }
    }

    /// The receipt flow and diagnostics intentionally share this method, so
    /// diagnostics exercises the exact production request and decode path.
    func requestDetailed(
        prompt: String,
        taskType: String,
        imageBase64: String? = nil,
        timeout: TimeInterval = 50,
        provider: String? = nil
    ) async throws -> DetailedResult {
        let endpoint: APIEndpoint
        do {
            endpoint = try APIEndpoint.json(
                path: "/api/ai-chat",
                body: AIChatRequest(
                    prompt: prompt,
                    taskType: taskType,
                    imageBase64: imageBase64,
                    provider: provider
                ),
                timeout: timeout
            )
        } catch {
            throw AIChatServiceError.invalidResponse
        }

        var attempt = 0
        let raw: APIClient.RawResponse
        while true {
            do {
                raw = try await apiClient.sendRawDetailed(endpoint)
                break
            } catch let APIError.rateLimited(retryAfter) where attempt < maxRateLimitRetries {
                let exponentialDelay = pow(2.0, Double(attempt))
                let delay = max(retryAfter ?? 0, exponentialDelay)
                try await sleep(UInt64(delay * 1_000_000_000))
                attempt += 1
            }
        }

        guard let responseBody = try? JSONDecoder().decode(
            AIChatResponse.self,
            from: raw.data
        ) else {
            throw AIChatServiceError.invalidResponse
        }

        let content = responseBody.content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw AIChatServiceError.emptyResponse
        }
        return DetailedResult(content: content, metadata: raw.metadata)
    }
}

private struct AIChatRequest: Encodable {
    let prompt: String
    let taskType: String
    let imageBase64: String?
    let provider: String?
}

private struct AIChatResponse: Decodable {
    let content: String
}

enum AIChatServiceError: LocalizedError {
    case unavailable
    case invalidResponse
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "AI 服务暂时不可用。"
        case .invalidResponse:
            return "AI 返回的菜谱无法识别。"
        case .emptyResponse:
            return "AI 返回了空结果。"
        }
    }
}

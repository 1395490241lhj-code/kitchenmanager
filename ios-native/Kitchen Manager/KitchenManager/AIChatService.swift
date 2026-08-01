import Foundation

struct AIChatService {
    var apiClient: APIClient = .shared

    struct DetailedResult: Sendable {
        let content: String
        let metadata: APIClient.ResponseMetadata
    }

    func request(
        prompt: String,
        taskType: String,
        imageBase64: String? = nil,
        timeout: TimeInterval = 50
    ) async throws -> String {
        do {
            return try await requestDetailed(
                prompt: prompt, taskType: taskType, imageBase64: imageBase64, timeout: timeout
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
        timeout: TimeInterval = 50
    ) async throws -> DetailedResult {
        let endpoint: APIEndpoint
        do {
            endpoint = try APIEndpoint.json(
                path: "/api/ai-chat",
                body: AIChatRequest(
                    prompt: prompt,
                    taskType: taskType,
                    imageBase64: imageBase64
                ),
                timeout: timeout
            )
        } catch {
            throw AIChatServiceError.invalidResponse
        }

        let raw = try await apiClient.sendRawDetailed(endpoint)

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

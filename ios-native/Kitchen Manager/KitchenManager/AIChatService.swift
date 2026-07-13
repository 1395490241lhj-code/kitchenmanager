import Foundation

struct AIChatService {
    var apiClient: APIClient = .shared

    func request(
        prompt: String,
        taskType: String,
        imageBase64: String? = nil,
        timeout: TimeInterval = 50
    ) async throws -> String {
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

        let data: Data
        do {
            data = try await apiClient.sendRaw(endpoint)
        } catch {
            // The original implementation collapsed every non-2xx response
            // (and, before that, any URLSession failure such as a timeout)
            // into this same case — preserved here.
            throw AIChatServiceError.unavailable
        }

        guard let responseBody = try? JSONDecoder().decode(
            AIChatResponse.self,
            from: data
        ) else {
            throw AIChatServiceError.invalidResponse
        }

        let content = responseBody.content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw AIChatServiceError.invalidResponse
        }
        return content
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

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "AI 服务暂时不可用。"
        case .invalidResponse:
            return "AI 返回的菜谱无法识别。"
        }
    }
}

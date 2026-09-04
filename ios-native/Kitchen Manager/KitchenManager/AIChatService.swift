import Foundation

struct AIChatService {
    var apiClient: APIClient = .shared
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
        provider: String? = nil,
        specialPlanDishCount: Int? = nil
    ) async throws -> String {
        do {
            return try await requestDetailed(
                prompt: prompt,
                taskType: taskType,
                imageBase64: imageBase64,
                timeout: timeout,
                provider: provider,
                specialPlanDishCount: specialPlanDishCount
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
        provider: String? = nil,
        specialPlanDishCount: Int? = nil
    ) async throws -> DetailedResult {
        #if DEBUG
        let diagnosticStart = Date()
        #endif
        let endpoint: APIEndpoint
        do {
            endpoint = try APIEndpoint.json(
                path: "/api/ai-chat",
                body: AIChatRequest(
                    prompt: prompt,
                    taskType: taskType,
                    imageBase64: imageBase64,
                    provider: provider,
                    specialPlanDishCount: specialPlanDishCount
                ),
                timeout: timeout
            )
        } catch {
            throw AIChatServiceError.invalidResponse
        }

        #if DEBUG
        print(
            "[AIChat] task=\(taskType) stage=request-start bytes=\(endpoint.body?.count ?? 0) "
                + "messages=1 provider=\(provider ?? "default") timeout=\(Int(timeout))s"
        )
        #endif

        let raw: APIClient.RawResponse
        do {
            raw = try await apiClient.sendRawDetailed(endpoint)
        } catch let APIError.rateLimited(retryAfter) {
            // Our own AI limiter is a fixed 10-minute window: a 1s/2s/4s blind
            // retry cannot outlast it and only spends more of the same window.
            // Surface a typed error carrying the server's Retry-After instead.
            // Transient *provider* failures are already handled by the backend's
            // Gemini → Groq fallback, so the client must not layer a second
            // provider strategy on top of it.
            #if DEBUG
            print(
                "[AIChat] task=\(taskType) stage=rate-limited "
                    + "retryAfter=\(retryAfter.map { String(Int($0)) } ?? "none")"
            )
            #endif
            throw AIChatServiceError.rateLimited(retryAfter: retryAfter)
        } catch {
            #if DEBUG
            let nsError = error as NSError
            let elapsedMs = Int(Date().timeIntervalSince(diagnosticStart) * 1_000)
            let responseCode: String
            switch error as? APIError {
            case .server(let status, let payload):
                responseCode = "status=\(status) serverCode=\(payload?.code ?? "unknown")"
            default:
                responseCode = "status=none serverCode=none"
            }
            print(
                "[AIChat] task=\(taskType) stage=request-failed "
                    + "elapsedMs=\(elapsedMs) cancelled=\(Task.isCancelled) "
                    + "\(responseCode) domain=\(nsError.domain) code=\(nsError.code)"
            )
            #endif
            throw error
        }

        guard let responseBody = try? JSONDecoder().decode(
            AIChatResponse.self,
            from: raw.data
        ) else {
            #if DEBUG
            print("[AIChat] task=\(taskType) stage=envelope-decode-failed status=\(raw.metadata.statusCode)")
            #endif
            throw AIChatServiceError.invalidResponse
        }

        let content = responseBody.content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw AIChatServiceError.emptyResponse
        }
        #if DEBUG
        let elapsedMs = Int(Date().timeIntervalSince(diagnosticStart) * 1_000)
        print(
            "[AIChat] task=\(taskType) stage=request-succeeded status=\(raw.metadata.statusCode) "
                + "elapsedMs=\(elapsedMs)"
        )
        #endif
        return DetailedResult(content: content, metadata: raw.metadata)
    }
}

private struct AIChatRequest: Encodable {
    let prompt: String
    let taskType: String
    let imageBase64: String?
    let provider: String?
    /// Special Plan only: the dish count the app fixed before asking, so the
    /// server can ask the provider to enforce that cardinality in the response
    /// schema rather than only in the prompt. Omitted by every other caller,
    /// and by a Special Plan request that lets the model choose its own count.
    let specialPlanDishCount: Int?
}

private struct AIChatResponse: Decodable {
    let content: String
}

enum AIChatServiceError: LocalizedError {
    case unavailable
    case invalidResponse
    case emptyResponse
    /// Kitchen Manager's own AI rate limit (HTTP 429 `rate_limited`), never a
    /// provider-side failure. `retryAfter` is the server's remaining window
    /// when it supplied one.
    case rateLimited(retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "AI 服务暂时不可用。"
        case .invalidResponse:
            return "AI 返回的菜谱无法识别。"
        case .emptyResponse:
            return "AI 返回了空结果。"
        case .rateLimited(let retryAfter):
            // A precise, short wait is worth telling the user; a long or unknown
            // one is not a number anybody wants to read.
            guard let retryAfter, retryAfter > 0, retryAfter <= 300 else {
                return "AI 请求有点频繁，请稍后再试。"
            }
            return "AI 请求有点频繁，请在约 \(Int(ceil(retryAfter / 60))) 分钟后再试。"
        }
    }
}

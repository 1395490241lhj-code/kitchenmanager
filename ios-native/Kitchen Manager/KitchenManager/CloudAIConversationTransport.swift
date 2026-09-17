import Foundation

actor CloudAIConversationTransport: AIConversationRuntimeTransport {
    private let client: APIClient
    private let provider: AIRecommendationProvider

    init(client: APIClient, provider: AIRecommendationProvider = .gemini) {
        self.client = client
        self.provider = provider
    }

    nonisolated func stream(_ request: AIConversationRuntimeRequest) -> AsyncThrowingStream<AIConversationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.pump(request: request, into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct WireFunction: Encodable, Sendable {
        let name: String
        // Server contract encodes tool-call arguments as a JSON object string.
        let arguments: String
        init(name: String, argumentsDictionary dict: [String: JSONAnyValue]) throws {
            self.name = name
            self.arguments = try AIConversationTranscriptToolCall.canonicalArgumentsString(dict)
        }
    }

    private struct WireToolCall: Encodable, Sendable {
        let id: String
        let type = "function"
        let function: WireFunction
    }

    private struct WireMessage: Encodable, Sendable {
        let role: String
        let content: String?
        let toolCalls: [WireToolCall]?
        let toolCallID: String?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
            case toolCallID = "tool_call_id"
        }
    }

    private struct WireBody: Encodable, Sendable {
        let provider: String
        let messages: [WireMessage]
        let enabledTools: [String]
        let requestID: String
    }

    private func pump(request: AIConversationRuntimeRequest, into continuation: AsyncThrowingStream<AIConversationStreamEvent, Error>.Continuation) async {
        do {
            let lineStream = try await buildLineStream(request)
            var sawTerminal = false
            for try await line in lineStream {
                let event = try Self.decodeEvent(line: line)
                switch event {
                case .error(let code, let message):
                    sawTerminal = true
                    continuation.yield(.error(code: code, message: message))
                    continuation.finish()
                    return
                case .completed(let finishReason):
                    sawTerminal = true
                    continuation.yield(.completed(finishReason: finishReason))
                    continuation.finish()
                    return
                default:
                    continuation.yield(event)
                }
            }
            guard sawTerminal else { throw APIError.protocolViolation("服务器流式响应缺少终止事件。") }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func buildLineStream(_ request: AIConversationRuntimeRequest) async throws -> APIClient.LineStream {
        struct LayeredError: Error { let underlying: Error }
        let wireMessages: [WireMessage] = try request.messages.map { message in
            let calls: [WireToolCall]? = try message.toolCalls.map { calls in
                try calls.map { call in
                    guard case .object(let dict) = call.arguments else {
                        throw APIError.protocolViolation("对话记录中的工具调用参数必须是单个完整 JSON 对象。")
                    }
                    return try WireToolCall(id: call.id, function: .init(name: call.name, argumentsDictionary: dict))
                }
            }
            return WireMessage(role: message.role.rawValue, content: message.content, toolCalls: calls, toolCallID: message.toolCallID)
        }
        let body = WireBody(
            provider: provider.rawValue,
            messages: wireMessages,
            enabledTools: request.enabledTools,
            requestID: request.requestID.uuidString
        )
        let endpoint = try APIEndpoint.json(path: "/api/ai-conversation", body: body)
        return try await client.streamLines(endpoint)
    }

    nonisolated static func decodeEvent(line: String) throws -> AIConversationStreamEvent {
        let data = Data(line.utf8)
        guard !data.isEmpty else { throw APIError.protocolViolation("流式响应包含空数据行。") }
        let wire: Wire
        do { wire = try JSONDecoder().decode(Wire.self, from: data) }
        catch { throw APIError.protocolViolation("流式响应的 JSON 格式无效。") }
        switch wire.type {
        case "text_delta":
            guard let text = wire.text else { throw APIError.protocolViolation("流式响应缺少文本内容。") }
            return .textDelta(text)
        case "tool_call":
            guard let id = wire.id, !id.isEmpty, let name = wire.name, !name.isEmpty, case .object(let dict) = wire.arguments else {
                throw APIError.protocolViolation("流式响应的工具调用格式无效。")
            }
            let encoded = try JSONEncoder().encode(dict)
            return .toolCall(id: id, name: name, arguments: encoded)
        case "completed":
            return .completed(finishReason: wire.finishReason)
        case "error":
            return .error(code: wire.code ?? "unknown", message: wire.message ?? "服务器在流式响应中报告错误。")
        default:
            throw APIError.protocolViolation("流式响应包含未知事件类型：" + wire.type)
        }
    }
}

nonisolated struct Wire: Decodable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let arguments: JSONAnyValue?
    let finishReason: String?
    let code: String?
    let message: String?
}

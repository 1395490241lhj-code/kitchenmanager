import Foundation

actor CloudAIConversationTransport: AIConversationRuntimeTransport {
    private let client: APIClient
    private let selectedProvider: String

    nonisolated init(client: APIClient, selectedProvider: String = "gemini") {
        self.client = client
        self.selectedProvider = selectedProvider
    }

    nonisolated func stream(_ request: AIConversationRuntimeRequest) -> AsyncThrowingStream<AIConversationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.pump(request: request, into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func pump(request: AIConversationRuntimeRequest, into continuation: AsyncThrowingStream<AIConversationStreamEvent, Error>.Continuation) async {
        do {
            let lineStream = try await buildLineStream(request)
            var sawCompleted = false
            for try await line in lineStream {
                let event = try Self.decodeEvent(line: line)
                if case .error(let code, let message) = event {
                    continuation.yield(.error(code: code, message: message))
                    continuation.finish(throwing: APIError.protocolViolation("服务器返回错误事件。"))
                    return
                }
                if case .completed = event { sawCompleted = true }
                continuation.yield(event)
            }
            guard sawCompleted else { throw APIError.protocolViolation("服务器流式响应缺少终止事件。") }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func buildLineStream(_ request: AIConversationRuntimeRequest) async throws -> AsyncThrowingStream<String, Error> {
        struct WireMessage: Encodable, Sendable {
            let role: String
            let content: String
        }
        struct WireBody: Encodable, Sendable {
            let messages: [WireMessage]
            let tools: [String]
            let provider: String
            let requestID: String
        }
        let body = WireBody(
            messages: request.messages.map { WireMessage(role: $0.role.rawValue, content: $0.content) },
            tools: request.enabledTools,
            provider: selectedProvider,
            requestID: request.requestID.uuidString
        )
        let endpoint = try APIEndpoint.json(path: "/api/ai-conversation", body: body)
        return try await client.streamLines(endpoint)
    }

    nonisolated static func decodeEvent(line: String) throws -> AIConversationStreamEvent {
        let data = Data(line.utf8)
        guard !data.isEmpty else { throw APIError.protocolViolation("LINE_EMPTY") }
        let wire: Wire
        do { wire = try JSONDecoder().decode(Wire.self, from: data) }
        catch { throw APIError.protocolViolation("WIRE_JSON_INVALID") }
        switch wire.type {
        case "text_delta":
            guard let text = wire.text else { throw APIError.protocolViolation("TEXT_DELTA_MISSING") }
            return .textDelta(text)
        case "tool_call":
            guard let id = wire.id, !id.isEmpty, let name = wire.name, !name.isEmpty, case .object(let dict) = wire.arguments else {
                throw APIError.protocolViolation("TOOL_CALL_INVALID")
            }
            let encoded = try JSONEncoder().encode(dict)
            return .toolCall(id: id, name: name, arguments: encoded)
        case "completed":
            return .completed(finishReason: wire.finishReason)
        case "error":
            return .error(code: wire.code ?? "unknown", message: wire.message ?? "SERVER_ERROR")
        default:
            throw APIError.protocolViolation("UNKNOWN_EVENT_" + wire.type)
        }
    }
}

struct Wire: Decodable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let arguments: JSONAnyValue?
    let finishReason: String?
    let code: String?
    let message: String?
}

nonisolated indirect enum JSONAnyValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONAnyValue])
    case object([String: JSONAnyValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let d = try? container.decode(Double.self) { self = .number(d) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONAnyValue].self) { self = .array(a) }
        else if let o = try? container.decode([String: JSONAnyValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "unsupported JSON value")) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

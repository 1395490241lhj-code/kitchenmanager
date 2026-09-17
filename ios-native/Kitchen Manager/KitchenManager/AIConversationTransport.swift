import Foundation

/// One semantic conversation turn, expressed without any transport or wire
/// concerns. Callers (Task 9's ConversationOrchestrator) never mention
/// providers, URLs, or NDJSON — those details belong to whichever concrete
/// transport (cloud now, Apple later) is routed to.
nonisolated struct AIConversationRuntimeRequest: Sendable, Equatable {
    /// Full conversation transcript so far, in order.
    let messages: [AIConversationTranscriptMessage]
    /// Tool NAMES only. Schemas stay server-owned; the client never sends
    /// tool definitions.
    let enabledTools: [String]
    let requestID: UUID
}

/// One assistant tool call carried inside a conversation transcript. The
/// arguments stay a runtime-neutral JSON value — never a provider-specific
/// dictionary shape — so Task 9's stateless tool loop can round-trip through
/// the cloud NDJSON transport today and a future Apple transport tomorrow
/// with the same semantic object.
nonisolated struct AIConversationTranscriptToolCall: Sendable, Equatable {
    let id: String
    let name: String
    let arguments: JSONAnyValue

    /// Canonical JSON string encoding for assistant tool-call arguments, shared by
    /// wire request construction (CloudAIConversationTransport) and server-budget accounting
    /// (ConversationOrchestrator) to guarantee exact character count agreement with the server.
    nonisolated static func canonicalArgumentsString(_ dict: [String: JSONAnyValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(dict)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw APIError.protocolViolation("工具调用参数无法编码为 UTF-8 JSON 字符串。")
        }
        return encoded
    }
}

nonisolated enum AIConversationTranscriptRole: String, Sendable {
    case system
    case user
    case assistant
    case tool
}

nonisolated struct AIConversationTranscriptMessage: Sendable, Equatable {
    let role: AIConversationTranscriptRole
    let content: String?
    let toolCalls: [AIConversationTranscriptToolCall]?
    let toolCallID: String?

    /// Failable on purpose: transcripts the runtime can express but the
    /// stateless tool loop could never legally send (a tool row without its
    /// tool_call_id, an assistant row that is neither text nor tool calls,
    /// a tool-call array attached to a user row) are rejected here instead
    /// of being silently encoded into a request the server must 400.
    init?(
        role: AIConversationTranscriptRole,
        content: String? = nil,
        toolCalls: [AIConversationTranscriptToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        switch role {
        case .system, .user:
            guard content != nil, toolCalls == nil, toolCallID == nil else { return nil }
        case .assistant:
            guard toolCallID == nil else { return nil }
            if let toolCalls, toolCalls.isEmpty { return nil }
            if content == nil {
                guard toolCalls != nil else { return nil }
            }
        case .tool:
            guard content != nil, toolCalls == nil, let toolCallID, !toolCallID.isEmpty else { return nil }
        }
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    static func user(_ text: String) -> Self? { .init(role: .user, content: text) }
    static func systemText(_ text: String) -> Self? { .init(role: .system, content: text) }
    static func assistantText(_ text: String) -> Self? { .init(role: .assistant, content: text) }
    static func assistantToolCalls(_ calls: [AIConversationTranscriptToolCall]) -> Self? {
        .init(role: .assistant, content: nil, toolCalls: calls)
    }
    static func toolResult(forToolCallID id: String, text: String) -> Self? {
        .init(role: .tool, content: text, toolCallID: id)
    }

    /// User-visible text only; system/structured rows are not replayed as
    /// transcript content.
    static func from(_ message: AIConversationMessage) -> Self? {
        switch message.role {
        case .user:
            return .init(role: .user, content: message.plainTextSummary)
        case .assistant:
            return .init(role: .assistant, content: message.plainTextSummary)
        case .systemStatus:
            return nil
        }
    }
}

/// Every event a conversation transport can surface. Transport-neutral:
/// both the cloud NDJSON stream and a future Apple transport map their
/// native outputs into exactly these cases.
nonisolated enum AIConversationStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case toolCall(id: String, name: String, arguments: Data)
    case completed(finishReason: String?)
    case error(code: String, message: String)
}

/// The runtime-neutral conversation seam. Cloud today; a future Apple
/// Foundation Models transport implements the same contract without touching
/// ConversationOrchestrator (Task 9), ActionCoordinator, or domain tools.
protocol AIConversationRuntimeTransport: Actor, Sendable {
    func stream(_ request: AIConversationRuntimeRequest) -> AsyncThrowingStream<AIConversationStreamEvent, Error>
}

/// Minimal JSON value carrier used by the runtime-neutral transcript (tool
/// call arguments) and by the cloud event decoder. Lives here, on the
/// neutral side, because both semantics must stay independent of any one
/// transport.
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

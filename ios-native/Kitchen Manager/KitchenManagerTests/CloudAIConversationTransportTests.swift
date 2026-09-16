import XCTest
@testable import KitchenManager

final class CloudAIConversationTransportTests: NetworkTestCase {

    private let streamHost = "kitchenmanager-b8px.onrender.com"

    nonisolated private static func ndjson(_ rows: [String]) -> Data {
        Data(rows.joined(separator: "\n").appending("\n").utf8)
    }

    // Codec unit tests (decodeEvent)

    func test_decodeEvent_textDelta() throws {
        let event = try CloudAIConversationTransport.decodeEvent(line: #"{"type":"text_delta","text":"你好"}"#)
        XCTAssertEqual(event, .textDelta("你好"))
    }

    func test_decodeEvent_toolCallRequiresObjectArguments() {
        XCTAssertThrowsError(try CloudAIConversationTransport.decodeEvent(
            line: #"{"type":"tool_call","id":"c1","name":"addRecipeToTonight","arguments":[1,2]}"#
        ))
        XCTAssertThrowsError(try CloudAIConversationTransport.decodeEvent(
            line: #"{"type":"tool_call","id":"c1","name":"addRecipeToTonight"}"#
        ))
    }

    func test_decodeEvent_toolCallAcceptsObjectArguments() throws {
        let event = try CloudAIConversationTransport.decodeEvent(
            line: #"{"type":"tool_call","id":"c1","name":"replaceSpecialPlanDishes","arguments":{"planID":"p1"}}"#
        )
        guard case .toolCall(let id, let name, let args) = event else {
            return XCTFail("expected toolCall, got \(event)")
        }
        XCTAssertEqual(id, "c1")
        XCTAssertEqual(name, "replaceSpecialPlanDishes")
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: args) as? [String: Any])
    }

    func test_decodeEvent_completed() throws {
        let event = try CloudAIConversationTransport.decodeEvent(
            line: #"{"type":"completed","finishReason":"stop"}"#
        )
        XCTAssertEqual(event, .completed(finishReason: "stop"))
    }

    func test_decodeEvent_errorPreservesCodeAndMessage() throws {
        let event = try CloudAIConversationTransport.decodeEvent(
            line: #"{"type":"error","code":"provider_error","message":"上游出错"}"#
        )
        XCTAssertEqual(event, .error(code: "provider_error", message: "上游出错"))
    }

    func test_decodeEvent_unknownTypeThrows() {
        XCTAssertThrowsError(try CloudAIConversationTransport.decodeEvent(
            line: #"{"type":"reasoning","text":"secret"}"#
        ))
    }

    // End-to-end stream tests via the APIClient mock. One event per NDJSON
    // line, tool_call with object arguments flows through, completing the
    // turn cleanly.
    func test_stream_decodesNdjsonIntoEvents() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Self.ndjson([
                #"{"type":"text_delta","text":"你"}"#,
                #"{"type":"completed","finishReason":"stop"}"#,
            ]))
        }
        let transport = CloudAIConversationTransport(client: apiClient)
        var events: [AIConversationStreamEvent] = []
        for try await event in transport.stream(.init(messages: [], enabledTools: [], requestID: UUID())) {
            events.append(event)
        }
        XCTAssertEqual(events, [.textDelta("你"), .completed(finishReason: "stop")])
    }

    // The runtime-neutral transcript must be able to carry a full stateless
    // tool loop round trip: (1) an assistant tool-call row must encode to
    // exactly the Task 5 assistant tool_calls wire shape the server accepts,
    // and (2) a tool result row must encode with the matching tool_call_id.
    func test_stream_encodesAssistantToolCallAndToolResultForStatelessLoop() async throws {
        struct CapturedBody: Decodable {
            struct CapturedMessage: Decodable {
                let role: String
                let content: String?
                let tool_calls: [CapturedToolCall]?
                let tool_call_id: String?
            }
            struct CapturedToolCall: Decodable {
                let id: String
                let type: String
                let function: CapturedFunction
            }
            struct CapturedFunction: Decodable {
                let name: String
                let arguments: String
            }
            let provider: String
            let messages: [CapturedMessage]
            let enabledTools: [String]
        }

        let assistantCall = AIConversationTranscriptToolCall(
            id: "call-9",
            name: "add_recipe_to_tonight",
            arguments: .object(["recipeID": .string("r-1")])
        )
        let request = try AIConversationRuntimeRequest(
            messages: [
                try XCTUnwrap(.user("今晚加一个菜")),
                try XCTUnwrap(.assistantToolCalls([assistantCall])),
                try XCTUnwrap(.toolResult(forToolCallID: "call-9", text: "已加入今晚计划")),
            ],
            enabledTools: ["add_recipe_to_tonight"],
            requestID: UUID()
        )
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Self.ndjson([
                #"{"type":"completed","finishReason":"stop"}"#,
            ]))
        }
        let transport = CloudAIConversationTransport(client: apiClient)
        for try await _ in transport.stream(request) {}

        let raw = MockURLProtocol.capturedRequests()
        XCTAssertEqual(raw.count, 1)
        let body = try JSONDecoder().decode(CapturedBody.self, from: try XCTUnwrap(raw[0].httpBody))

        XCTAssertEqual(body.provider, "gemini")
        XCTAssertEqual(body.enabledTools, ["add_recipe_to_tonight"])

        XCTAssertEqual(body.messages.count, 3)
        XCTAssertEqual(body.messages[0].role, "user")
        XCTAssertEqual(body.messages[0].content, "今晚加一个菜")

        XCTAssertEqual(body.messages[1].role, "assistant")
        XCTAssertNil(body.messages[1].content, "assistant tool-call row must not invent text content")
        let calls = try XCTUnwrap(body.messages[1].tool_calls)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "call-9")
        XCTAssertEqual(calls[0].type, "function")
        XCTAssertEqual(calls[0].function.name, "add_recipe_to_tonight")
        let arguments = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(calls[0].function.arguments.utf8)) as? [String: Any]
        )
        XCTAssertEqual(arguments["recipeID"] as? String, "r-1")

        XCTAssertEqual(body.messages[2].role, "tool")
        XCTAssertNil(body.messages[2].tool_calls)
        XCTAssertEqual(body.messages[2].tool_call_id, "call-9")
        XCTAssertEqual(body.messages[2].content, "已加入今晚计划")
    }

    func test_stream_errorIsTerminal_andNeverSynthesizesCompleted() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Self.ndjson([
                #"{"type":"text_delta","text":"你"}"#,
                #"{"type":"error","code":"provider_error","message":"上游出错"}"#,
            ]))
        }
        let transport = CloudAIConversationTransport(client: apiClient)
        var events: [AIConversationStreamEvent] = []
        for try await event in transport.stream(.init(messages: [], enabledTools: [], requestID: UUID())) {
            events.append(event)
        }
        XCTAssertEqual(events, [.textDelta("你"), .error(code: "provider_error", message: "上游出错")])
    }

    func test_stream_completedIsTerminal_noLaterEventEverSurfaces() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Self.ndjson([
                #"{"type":"completed","finishReason":"stop"}"#,
                #"{"type":"text_delta","text":"after"}"#,
                #"{"type":"tool_call","id":"c-ghost","name":"read_inventory","arguments":{}}"#,
            ]))
        }
        let transport = CloudAIConversationTransport(client: apiClient)
        var events: [AIConversationStreamEvent] = []
        for try await event in transport.stream(.init(messages: [], enabledTools: [], requestID: UUID())) {
            events.append(event)
        }
        XCTAssertEqual(events, [.completed(finishReason: "stop")])
    }

    func test_stream_decodesServerStreamErrorCodeExactlyOnce() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Self.ndjson([
                #"{"type":"error","code":"provider_unavailable","message":"AI 服务暂时不可用。"}"#,
            ]))
        }
        let transport = CloudAIConversationTransport(client: apiClient)
        var events: [AIConversationStreamEvent] = []
        for try await event in transport.stream(.init(messages: [], enabledTools: [], requestID: UUID())) {
            events.append(event)
        }
        XCTAssertEqual(events, [.error(code: "provider_unavailable", message: "AI 服务暂时不可用。")])
    }

    func test_stream_truncatedStreamThrowsProtocolViolation() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Data(#"{"type":"text_delta","text":"你"}"#.utf8))
        }
        let transport = CloudAIConversationTransport(client: apiClient)
        do {
            for try await _ in transport.stream(.init(messages: [], enabledTools: [], requestID: UUID())) {}
            XCTFail("expected throw")
        } catch let error as APIError {
            guard case .protocolViolation = error else {
                return XCTFail("expected .protocolViolation, got \(error)")
            }
        }
    }
}

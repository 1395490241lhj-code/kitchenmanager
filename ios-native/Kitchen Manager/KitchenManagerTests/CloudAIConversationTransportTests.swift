import XCTest
@testable import KitchenManager

final class CloudAIConversationTransportTests: NetworkTestCase {

    private let streamHost = "kitchenmanager-b8px.onrender.com"

    private func makeEndpoint() -> APIEndpoint {
        try! APIEndpoint.json(path: "/api/example-stream", body: ["ok": true])
    }

    // Codec unit tests (decodeEvent)

    func test_decodeEvent_textDelta() throws {
        let event = try CloudAIConversationTransport.decodeEvent(line: #"{"type":"text_delta","text":"你好"}"#
        )
        XCTAssertEqual(event, .textDelta("你好"))
    }

    func test_decodeEvent_toolCallRequiresObjectArguments() {
        // Array argument form: rejected, not passed through as 'arguments not object'.
        XCTAssertThrowsError(try CloudAIConversationTransport.decodeEvent(line: #"{"type":"tool_call","id":"c1","name":"addRecipeToTonight","arguments":[1,2]}"#
        ))
        // Missing arguments: also rejected.
        XCTAssertThrowsError(try CloudAIConversationTransport.decodeEvent(line: #"{"type":"tool_call","id":"c1","name":"addRecipeToTonight"}"#
        ))
    }

    func test_decodeEvent_toolCallAcceptsObjectArguments() throws {
        let event = try CloudAIConversationTransport.decodeEvent(line: #"{"type":"tool_call","id":"c1","name":"replaceSpecialPlanDishes","arguments":{"planID":"p1"}}"#
        )
        guard case .toolCall(let id, let name, let args) = event else {
            return XCTFail("expected toolCall, got \(event)")
        }
        XCTAssertEqual(id, "c1")
        XCTAssertEqual(name, "replaceSpecialPlanDishes")
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: args) as? [String: Any])
    }

    func test_decodeEvent_completed() throws {
        let event = try CloudAIConversationTransport.decodeEvent(line: #"{"type":"completed","finishReason":"stop"}"#
        )
        XCTAssertEqual(event, .completed(finishReason: "stop"))
    }

    func test_decodeEvent_errorPreservesCodeAndMessage() throws {
        let event = try CloudAIConversationTransport.decodeEvent(line: #"{"type":"error","code":"provider_error","message":"上游出错"}"#
        )
        XCTAssertEqual(event, .error(code: "provider_error", message: "上游出错"))
    }

    func test_decodeEvent_unknownTypeThrows() {
        XCTAssertThrowsError(try CloudAIConversationTransport.decodeEvent(line: #"{"type":"reasoning","text":"secret"}"#
        ))
    }

    // End-to-end stream tests via the APIClient mock. One event per NDJSON
    // line, tool_call with object arguments flows through, completing the
    // turn cleanly.
    func test_stream_decodesNdjsonIntoEvents() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Data([
                #"{"type":"text_delta","text":"你"}"#,
                #"{"type":"completed","finishReason":"stop"}"#
            ].joined(separator: "\n").appending("\n").utf8))
        }
        let transport = CloudAIConversationTransport(client: apiClient)
        var events: [AIConversationStreamEvent] = []
        for try await event in transport.stream(.init(messages: [], enabledTools: [], requestID: UUID())) {
            events.append(event)
        }
        XCTAssertEqual(events, [.textDelta("你"), .completed(finishReason: "stop")])
    }

    func test_stream_errorIsTerminal_andNeverSynthesizesCompleted() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Data([
                #"{"type":"text_delta","text":"你"}"#,
                #"{"type":"error","code":"provider_error","message":"上游出错"}"#
            ].joined(separator: "\n").appending("\n").utf8))
        }
        let transport = CloudAIConversationTransport(client: apiClient)
        var events: [AIConversationStreamEvent] = []
        do {
            for try await event in transport.stream(.init(messages: [], enabledTools: [], requestID: UUID())) {
                events.append(event)
            }
            XCTFail("expected throw after terminal error")
        } catch {
            // error event is delivered then the stream terminates
        }
        XCTAssertEqual(events, [.textDelta("你"), .error(code: "provider_error", message: "上游出错")])
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

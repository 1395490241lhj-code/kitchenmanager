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
        let requestID = UUID(uuidString: "72E191B9-6073-4F93-86BA-77509B6531AD")!
        let assistantCall = AIConversationTranscriptToolCall(
            id: "call-9",
            name: "propose_add_recipe_to_tonight",
            arguments: .object([
                "recipe": .object(["recipeID": .string("r-1"), "title": .string("番茄炒蛋")]),
                "plannedServings": .number(2),
            ])
        )
        let messages: [AIConversationTranscriptMessage] = [
            try XCTUnwrap(.systemText("帮助安排今晚的菜")),
            try XCTUnwrap(.user("今晚加一个菜")),
            try XCTUnwrap(.assistantText("可以做番茄炒蛋")),
            try XCTUnwrap(.assistantToolCalls([assistantCall])),
            try XCTUnwrap(.toolResult(forToolCallID: "call-9", text: "已加入今晚计划")),
        ]
        let request = AIConversationRuntimeRequest(
            messages: messages,
            enabledTools: ["read_inventory", "propose_add_recipe_to_tonight"],
            requestID: requestID
        )
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Self.ndjson([
                #"{"type":"completed","finishReason":"stop"}"#,
            ]))
        }
        let transport = CloudAIConversationTransport(client: apiClient, provider: .groq)
        for try await _ in transport.stream(request) {}

        let captured = MockURLProtocol.capturedRequests()
        XCTAssertEqual(captured.count, 1)
        let actualRequest = try XCTUnwrap(captured.first)
        XCTAssertEqual(actualRequest.url?.host, streamHost)
        XCTAssertEqual(actualRequest.url?.path, "/api/ai-conversation")
        XCTAssertEqual(actualRequest.httpMethod, "POST")
        XCTAssertEqual(actualRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(actualRequest.httpBody)
        ) as? [String: Any])
        let wireMessages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(wireMessages.count, 5)
        let calls = try XCTUnwrap(wireMessages.first { $0["tool_calls"] != nil }?["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls.first?["function"] as? [String: Any])
        let arguments = try XCTUnwrap(function["arguments"] as? String)
        let argumentObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? NSDictionary)
        XCTAssertEqual(argumentObject, [
            "recipe": ["recipeID": "r-1", "title": "番茄炒蛋"],
            "plannedServings": 2,
        ] as NSDictionary)

        // Exact dictionary equality pins every key and omission, not just the
        // subset a permissive Decodable fixture would happen to read.
        XCTAssertEqual(body as NSDictionary, [
            "provider": "groq",
            "requestID": requestID.uuidString,
            "enabledTools": ["read_inventory", "propose_add_recipe_to_tonight"],
            "messages": [
                ["role": "system", "content": "帮助安排今晚的菜"],
                ["role": "user", "content": "今晚加一个菜"],
                ["role": "assistant", "content": "可以做番茄炒蛋"],
                ["role": "assistant", "tool_calls": [[
                    "id": "call-9", "type": "function",
                    "function": ["name": "propose_add_recipe_to_tonight", "arguments": arguments],
                ]]],
                ["role": "tool", "tool_call_id": "call-9", "content": "已加入今晚计划"],
            ],
        ] as NSDictionary)
        XCTAssertNil(body["tools"], "legacy tools field must not be sent")
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

    // The server may spend primary (45 s) + fallback (20 s) on one step; the
    // conversation endpoint alone gets a longer timeout, and it carries the
    // run's turn identity for the server's per-turn rate-limit ledger.
    func test_stream_usesDedicatedConversationTimeoutAndSendsTurnID() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Self.ndjson([#"{"type":"completed","finishReason":"stop"}"#]))
        }
        let turnID = UUID(uuidString: "0B1D2E3F-4A5B-4C6D-8E7F-901234567890")!
        let transport = CloudAIConversationTransport(client: apiClient)
        for try await _ in transport.stream(.init(messages: [], enabledTools: [], requestID: UUID(), turnID: turnID)) {}

        let request = try XCTUnwrap(MockURLProtocol.capturedRequests().first)
        XCTAssertEqual(request.url?.path, "/api/ai-conversation")
        XCTAssertEqual(request.timeoutInterval, 90, accuracy: 0.001)
        XCTAssertEqual(CloudAIConversationTransport.conversationTimeout, 90)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["turnID"] as? String, turnID.uuidString)
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

    func test_wireArgumentsEncodingMatchesBudgetCalculationForSlashes() async throws {
        let repeatedSlashes = String(repeating: "/", count: 6000)
        let assistantCall = AIConversationTranscriptToolCall(
            id: "call-slash",
            name: "resolve_recipe",
            arguments: .object(["query": .string(repeatedSlashes)])
        )
        let request = AIConversationRuntimeRequest(
            messages: [
                try XCTUnwrap(.user("查找菜谱")),
                try XCTUnwrap(.assistantToolCalls([assistantCall])),
            ],
            enabledTools: ["resolve_recipe"],
            requestID: UUID()
        )
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Self.ndjson([#"{"type":"completed","finishReason":"stop"}"#]))
        }
        let transport = CloudAIConversationTransport(client: apiClient)
        for try await _ in transport.stream(request) {}

        let captured = try XCTUnwrap(MockURLProtocol.capturedRequests().first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(captured.httpBody)) as? [String: Any])
        let wireMessages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let calls = try XCTUnwrap(wireMessages.first { $0["tool_calls"] != nil }?["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls.first?["function"] as? [String: Any])
        let actualArgumentsString = try XCTUnwrap(function["arguments"] as? String)

        let predictedCost = ConversationOrchestrator.serverCompatibleCharacterCost(request.messages)
        let actualCost = ("查找菜谱".utf16.count) + actualArgumentsString.utf16.count

        XCTAssertEqual(predictedCost, actualCost)
    }

    func test_wireArgumentsEncodingMatchesBudgetCalculationForQuotesBackslashesUnicodeEmoji() async throws {
        let complexQuery = #"西红柿 / 鸡蛋 👨‍👩‍👧‍👦 "特别提示" \ 反斜杠 🥑🥦"#
        let assistantCall = AIConversationTranscriptToolCall(
            id: "call-complex",
            name: "resolve_recipe",
            arguments: .object([
                "query": .string(complexQuery),
                "nested": .object(["note": .string(#"嵌套 "引" / 斜杠"#)])
            ])
        )
        let request = AIConversationRuntimeRequest(
            messages: [
                try XCTUnwrap(.systemText("系统说明")),
                try XCTUnwrap(.user("测试特殊字符")),
                try XCTUnwrap(.assistantToolCalls([assistantCall])),
            ],
            enabledTools: ["resolve_recipe"],
            requestID: UUID()
        )
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Self.ndjson([#"{"type":"completed","finishReason":"stop"}"#]))
        }
        let transport = CloudAIConversationTransport(client: apiClient)
        for try await _ in transport.stream(request) {}

        let captured = try XCTUnwrap(MockURLProtocol.capturedRequests().first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(captured.httpBody)) as? [String: Any])
        let wireMessages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let calls = try XCTUnwrap(wireMessages.first { $0["tool_calls"] != nil }?["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls.first?["function"] as? [String: Any])
        let actualArgumentsString = try XCTUnwrap(function["arguments"] as? String)

        let predictedCost = ConversationOrchestrator.serverCompatibleCharacterCost(request.messages)
        let actualCost = ("系统说明".utf16.count) + ("测试特殊字符".utf16.count) + actualArgumentsString.utf16.count

        XCTAssertEqual(predictedCost, actualCost)
    }

    func test_nearLimitRuntimeRequestWireBodyStaysWithinServerPromptLimit() async throws {
        // Build a tool call with arguments close to the limit
        let bigArg = String(repeating: "中文字符串内容 / 含斜杠 / ", count: 350)
        let assistantCall = AIConversationTranscriptToolCall(
            id: "call-near-limit",
            name: "resolve_recipe",
            arguments: .object(["query": .string(bigArg)])
        )
        let messages: [AIConversationTranscriptMessage] = [
            try XCTUnwrap(.systemText("系统指令说明")),
            try XCTUnwrap(.user(String(repeating: "用户补充要求_", count: 200))),
            try XCTUnwrap(.assistantToolCalls([assistantCall])),
            try XCTUnwrap(.toolResult(forToolCallID: "call-near-limit", text: #"{"found":true}"#)),
        ]

        guard let budgeted = ConversationOrchestrator.rebudgetContinuation(messages, limit: ConversationOrchestrator.serverPromptMaxChars) else {
            return XCTFail("expected request to fit after rebudgeting")
        }

        let request = AIConversationRuntimeRequest(
            messages: budgeted,
            enabledTools: ["resolve_recipe"],
            requestID: UUID()
        )
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Self.ndjson([#"{"type":"completed","finishReason":"stop"}"#]))
        }
        let transport = CloudAIConversationTransport(client: apiClient)
        for try await _ in transport.stream(request) {}

        let captured = try XCTUnwrap(MockURLProtocol.capturedRequests().first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(captured.httpBody)) as? [String: Any])
        let wireMessages = try XCTUnwrap(body["messages"] as? [[String: Any]])

        // Calculate Node-compatible character count directly from wireMessages
        var nodeCount = 0
        for msg in wireMessages {
            if let content = msg["content"] as? String {
                nodeCount += content.utf16.count
            }
            if let toolCalls = msg["tool_calls"] as? [[String: Any]] {
                for call in toolCalls {
                    if let function = call["function"] as? [String: Any],
                       let args = function["arguments"] as? String {
                        nodeCount += args.utf16.count
                    }
                }
            }
        }

        XCTAssertLessThanOrEqual(nodeCount, ConversationOrchestrator.serverPromptMaxChars)
        XCTAssertEqual(nodeCount, ConversationOrchestrator.serverCompatibleCharacterCost(budgeted))
    }
}

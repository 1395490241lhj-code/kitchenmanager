import XCTest
@testable import KitchenManager

/// Runtime-neutral transport pins. The neutral layer must not know about
/// APIClient, URLSession, HTTP, or any provider field; only the router
/// decides cloud vs unavailable; nothing persists a conversation-specific
/// provider preference. These tests are architecture pins, not just API
/// smoke.
final class AIConversationTransportTests: XCTestCase {

    func testRuntimeRequestCarriesNoProviderField() throws {
        let request = AIConversationRuntimeRequest(
            messages: [try XCTUnwrap(.user("帮我想今晚方案"))],
            enabledTools: ["read_inventory", "add_recipe_to_tonight"],
            requestID: UUID()
        )
        let mirror = Mirror(reflecting: request)
        let fieldNames = mirror.children.compactMap({ $0.label })
        XCTAssertFalse(fieldNames.contains("provider"))
        XCTAssertFalse(fieldNames.contains("wire"))
        XCTAssertEqual(fieldNames.sorted(), ["enabledTools", "messages", "requestID"])
    }

    func testTranscriptFromSkippingSystemRole() throws {
        let m = AIConversationMessage(
            conversationID: UUID(),
            role: .systemStatus,
            createdAt: Date(timeIntervalSince1970: 0),
            state: .completed,
            contentBlocks: [.text(AITextBlock(id: UUID(), text: "system"))],
            turnID: UUID()
        )
        XCTAssertNil(AIConversationTranscriptMessage.from(m))
    }

    func testTranscriptFromCarryingUserText() throws {
        let m = AIConversationMessage(
            conversationID: UUID(),
            role: .user,
            createdAt: Date(timeIntervalSince1970: 0),
            state: .completed,
            contentBlocks: [.text(AITextBlock(id: UUID(), text: "帮我想今晚方案"))],
            turnID: UUID()
        )
        XCTAssertEqual(try XCTUnwrap(AIConversationTranscriptMessage.from(m)).content, "帮我想今晚方案")
    }

    // MARK: Runtime-neutral transcript semantics (stateless tool loop)

    private func sampleToolCall(
        id: String = "call-1",
        name: String = "add_recipe_to_tonight"
    ) -> AIConversationTranscriptToolCall {
        .init(id: id, name: name, arguments: .object(["planID": .string("p1")]))
    }

    func testTranscriptSupportsSystemUserAssistantTextRows() throws {
        XCTAssertNotNil(try AIConversationTranscriptMessage.systemText("你是家庭厨房助手"))
        XCTAssertNotNil(try AIConversationTranscriptMessage.user("今晚吃啥"))
        XCTAssertNotNil(try AIConversationTranscriptMessage.assistantText("我来想想"))
    }

    func testTranscriptSupportsAssistantToolCallsWithObjectArguments() throws {
        let row = try XCTUnwrap(
            AIConversationTranscriptMessage.assistantToolCalls([sampleToolCall()])
        )
        XCTAssertEqual(row.role, .assistant)
        XCTAssertNil(row.content)
        XCTAssertEqual(row.toolCalls?.count, 1)
        XCTAssertEqual(row.toolCalls?.first?.name, "add_recipe_to_tonight")
        guard case .object(let args) = row.toolCalls?.first?.arguments else {
            return XCTFail("arguments must stay a runtime-neutral JSON object")
        }
        XCTAssertEqual(args["planID"], .string("p1"))
    }

    func testTranscriptSupportsToolResultLinkedToToolCallID() throws {
        let row = try XCTUnwrap(
            AIConversationTranscriptMessage.toolResult(forToolCallID: "call-1", text: "已加入今晚计划")
        )
        XCTAssertEqual(row.role, .tool)
        XCTAssertEqual(row.toolCallID, "call-1")
        XCTAssertEqual(row.content, "已加入今晚计划")
        XCTAssertNil(row.toolCalls)
    }

    func testTranscriptRejectsIllegalRowShapes() {
        // A tool row without its tool_call_id can never be replayed.
        XCTAssertNil(AIConversationTranscriptMessage(role: .tool, content: "x"))
        // An assistant row that is neither text nor tool calls.
        XCTAssertNil(AIConversationTranscriptMessage(role: .assistant))
        // An empty tool-call array is not a meaningful assistant turn.
        XCTAssertNil(AIConversationTranscriptMessage.assistantToolCalls([]))
        // Tool-call arrays may not hang off a user row.
        XCTAssertNil(AIConversationTranscriptMessage(role: .user, content: "x", toolCalls: [sampleToolCall()]))
        // Assistant rows never carry tool_call_id.
        XCTAssertNil(AIConversationTranscriptMessage(role: .assistant, content: "x", toolCallID: "call-1"))
    }

    // MARK: Router

    func testRouterRoutesGeminiAndGroqToCloud() {
        XCTAssertEqual(
            AIConversationProviderRouter.route(selectedProvider: .gemini),
            .cloud(provider: .gemini)
        )
        XCTAssertEqual(
            AIConversationProviderRouter.route(selectedProvider: .groq),
            .cloud(provider: .groq)
        )
    }

    func testRouterRefusesAppleWithExactCopy() {
        XCTAssertEqual(
            AIConversationProviderRouter.route(selectedProvider: .apple),
            .unavailable(message: "Kitchen AI 对话暂不支持设备端模型。")
        )
    }

    func testRouterProductionEntryReadsGlobalUserDefaultsSelection() {
        let suiteName = "AIConversationProviderRouterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            AIConversationProviderRouter.route(userDefaults: defaults),
            .cloud(provider: .gemini),
            "the production entry must read the same global selection — default Gemini"
        )

        defaults.set(AIRecommendationProvider.groq.rawValue, forKey: AIRecommendationProvider.storageKey)
        XCTAssertEqual(
            AIConversationProviderRouter.route(userDefaults: defaults),
            .cloud(provider: .groq)
        )

        defaults.set(AIRecommendationProvider.apple.rawValue, forKey: AIRecommendationProvider.storageKey)
        XCTAssertEqual(
            AIConversationProviderRouter.route(userDefaults: defaults),
            .unavailable(message: AIConversationProviderRouter.appleUnavailableCopy)
        )
    }

    func testRouterNeverPersistsConversationProviderPreference() {
        let suiteName = "AIConversationProviderRouterTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = AIConversationProviderRouter.route(selectedProvider: .apple)
        _ = AIConversationProviderRouter.route(userDefaults: defaults)

        XCTAssertNil(defaults.object(forKey: AIRecommendationProvider.storageKey))
    }

    func testStreamEventsAreEquatableAndConstructible() {
        XCTAssertEqual(
            AIConversationStreamEvent.textDelta("你好"),
            AIConversationStreamEvent.textDelta("你好")
        )
        XCTAssertNotEqual(
            AIConversationStreamEvent.textDelta("你好"),
            AIConversationStreamEvent.completed(finishReason: nil)
        )
        XCTAssertNotEqual(
            AIConversationStreamEvent.error(code: "timeout", message: "x"),
            AIConversationStreamEvent.toolCall(id: UUID().uuidString, name: "y", arguments: Data("{}".utf8))
        )
    }
}

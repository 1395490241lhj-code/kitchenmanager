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
            messages: [AIConversationTranscriptMessage(role: .user, content: "帮我想今晚方案")],
            enabledTools: ["read_inventory", "add_recipe_to_tonight"],
            requestID: UUID()
        )
        let mirror = Mirror(reflecting: request)
        let fieldNames = mirror.children.compactMap(\.label)
        XCTAssertFalse(fieldNames.contains("provider"))
        XCTAssertFalse(fieldNames.contains("wire"))
        XCTAssertEqual(fieldNames.sorted(), ["enabledTools", "messages", "requestID"])
    }

    func testTranscriptFromSkippingSystemRole() {
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

    func testTranscriptFromCarryingUserText() {
        let m = AIConversationMessage(
            conversationID: UUID(),
            role: .user,
            createdAt: Date(timeIntervalSince1970: 0),
            state: .completed,
            contentBlocks: [.text(AITextBlock(id: UUID(), text: "帮我想今晚方案"))],
            turnID: UUID()
        )
        XCTAssertEqual(AIConversationTranscriptMessage.from(m)?.content, "帮我想今晚方案")
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

    func testRouterNeverPersistsConversationProviderPreference() {
        let suiteName = "AIConversationProviderRouterTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = AIConversationProviderRouter.route(selectedProvider: .apple)

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


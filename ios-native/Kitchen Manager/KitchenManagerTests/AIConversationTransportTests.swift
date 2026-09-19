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

    // MARK: Conversation provider preference (D-044)
    //
    // The conversation provider is its own preference. The recipe
    // recommendation model no longer decides whether conversation works, and a
    // legacy device-local choice is never converted into a cloud one.

    private func emptySuite(
        _ label: String = #function
    ) -> (defaults: UserDefaults, name: String) {
        let name = "AIConversationProviderPreferenceTests.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    // A: a fresh install takes the one canonical cloud default and stores nothing.
    func testFreshInstallResolvesCanonicalCloudDefaultWithoutWriting() {
        let suite = emptySuite()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }

        XCTAssertEqual(AIRecommendationProvider.defaultProvider, .gemini)
        XCTAssertEqual(
            AIConversationProviderPreference.resolve(in: suite.defaults),
            .cloud(provider: AIRecommendationProvider.defaultProvider)
        )
        XCTAssertNil(
            suite.defaults.string(forKey: AIConversationProviderPreference.storageKey),
            "resolving must stay a pure read"
        )
    }

    // B and C: a legacy cloud recommendation choice carries over unchanged.
    func testLegacyCloudRecommendationCarriesOverAndMaterializesOnce() {
        for legacy in [AIRecommendationProvider.gemini, .groq] {
            let suite = emptySuite()
            defer { suite.defaults.removePersistentDomain(forName: suite.name) }
            suite.defaults.set(legacy.rawValue, forKey: AIRecommendationProvider.storageKey)

            XCTAssertEqual(
                AIConversationProviderPreference.resolve(in: suite.defaults),
                .cloud(provider: legacy)
            )
            AIConversationProviderPreference.migrateIfNeeded(in: suite.defaults)
            XCTAssertEqual(
                suite.defaults.string(forKey: AIConversationProviderPreference.storageKey),
                legacy.rawValue,
                "migration materializes the carry-over so a later recommendation change cannot move it"
            )
        }
    }

    // D: a legacy device-local choice asks for a decision instead of picking a cloud.
    func testLegacyAppleRecommendationRequiresExplicitConversationChoice() {
        let suite = emptySuite()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        suite.defaults.set(AIRecommendationProvider.apple.rawValue, forKey: AIRecommendationProvider.storageKey)

        XCTAssertEqual(
            AIConversationProviderPreference.resolve(in: suite.defaults),
            .needsProviderSelection
        )
        AIConversationProviderPreference.migrateIfNeeded(in: suite.defaults)
        XCTAssertNil(
            suite.defaults.string(forKey: AIConversationProviderPreference.storageKey),
            "migration must never convert an explicit device-local choice into a cloud one"
        )
        XCTAssertEqual(
            AIConversationProviderPreference.resolve(in: suite.defaults),
            .needsProviderSelection
        )
    }

    // E and F: recommendation stays on device while conversation runs on cloud.
    func testExplicitConversationProviderCoexistsWithAppleRecommendations() {
        for conversation in AIConversationProviderPreference.eligibleProviders {
            let suite = emptySuite()
            defer { suite.defaults.removePersistentDomain(forName: suite.name) }
            suite.defaults.set(AIRecommendationProvider.apple.rawValue, forKey: AIRecommendationProvider.storageKey)

            AIConversationProviderPreference.select(conversation, in: suite.defaults)

            XCTAssertEqual(
                AIConversationProviderPreference.resolve(in: suite.defaults),
                .cloud(provider: conversation)
            )
            XCTAssertEqual(
                AIRecommendationProvider.selected(in: suite.defaults),
                .apple,
                "choosing a conversation model must not disturb recipe recommendations"
            )
        }
    }

    // G: the coupling is gone in both directions.
    func testRecipeRecommendationChangesNeverMoveTheChosenConversationProvider() {
        let suite = emptySuite()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        AIConversationProviderPreference.select(.gemini, in: suite.defaults)

        for legacy in AIRecommendationProvider.allCases {
            suite.defaults.set(legacy.rawValue, forKey: AIRecommendationProvider.storageKey)
            XCTAssertEqual(
                AIConversationProviderPreference.resolve(in: suite.defaults),
                .cloud(provider: .gemini),
                "recipe recommendation = \(legacy.rawValue) must not reach conversation"
            )
        }

        AIConversationProviderPreference.select(.groq, in: suite.defaults)
        XCTAssertEqual(
            AIConversationProviderPreference.resolve(in: suite.defaults),
            .cloud(provider: .groq),
            "and the next send picks up a conversation change with no restart"
        )
    }

    // Apple is not offered, and a hand-written device-local value is honoured
    // as a device-local intent rather than silently downgraded to a cloud default.
    func testAppleIsNeitherSelectableNorSilentlyDowngraded() {
        XCTAssertFalse(AIConversationProviderPreference.eligibleProviders.contains(.apple))

        let suite = emptySuite()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }

        AIConversationProviderPreference.select(.apple, in: suite.defaults)
        XCTAssertNil(suite.defaults.string(forKey: AIConversationProviderPreference.storageKey))

        suite.defaults.set(AIRecommendationProvider.apple.rawValue, forKey: AIConversationProviderPreference.storageKey)
        XCTAssertEqual(
            AIConversationProviderPreference.resolve(in: suite.defaults),
            .needsProviderSelection
        )
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

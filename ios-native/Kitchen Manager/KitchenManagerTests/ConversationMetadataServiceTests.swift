import XCTest
@testable import KitchenManager

@MainActor
final class ConversationMetadataServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func conversation() -> AIConversation { .init(createdAt: now, lastActivityAt: now, activeUntil: now.addingTimeInterval(3600)) }
    private func message(_ c: AIConversation, index: Int = 0, role: AIConversationRole = .assistant,
                         state: AIConversationMessageState = .completed) -> AIConversationMessage {
        .init(conversationID: c.id, role: role, createdAt: now.addingTimeInterval(Double(index)), state: state,
              contentBlocks: [.text(.init(text: "晚餐\(index)"))], turnID: c.id)
    }
    private func noRequest() -> ConversationMetadataService {
        .init(request: { _, _ in XCTFail("Ineligible metadata must not request"); return "unexpected" })
    }
    func testFirstCompletedAssistantProducesTitleCandidateOnly() async {
        let c = conversation(); let a = message(c)
        let service = ConversationMetadataService(request: { prompt, task in
            XCTAssertEqual(task, "conversation_title"); XCTAssertTrue(prompt.contains("晚餐0")); return "今晚的菜单"
        })
        let candidate = await service.titleCandidate(conversation: c, messages: [a], completedAssistantID: a.id)
        XCTAssertEqual(candidate?.value, "今晚的菜单"); XCTAssertEqual(c.title, "新对话")
        XCTAssertEqual(candidate?.completedAssistantID, a.id); XCTAssertEqual(candidate?.conversationID, c.id)
        XCTAssertEqual(candidate?.canApply(to: c, completedAssistantID: a.id), true)
    }
    func testUserEditedDefaultTitleIsIneligible() async {
        var c = conversation(); c.applyUserTitle("新对话"); let a = message(c)
        let result = await noRequest().titleCandidate(conversation: c, messages: [a], completedAssistantID: a.id)
        XCTAssertNil(result)
    }
    func testNonDefaultTitleIsIneligible() async {
        var c = conversation(); c.title = "已有标题"; let a = message(c)
        let result = await noRequest().titleCandidate(conversation: c, messages: [a], completedAssistantID: a.id)
        XCTAssertNil(result)
    }
    func testSecondSuccessfulAssistantDoesNotRequestTitle() async {
        let c = conversation(); let first = message(c); let second = message(c, index: 1)
        let result = await noRequest().titleCandidate(conversation: c, messages: [first, second], completedAssistantID: second.id)
        XCTAssertNil(result)
    }
    func testFailedEarlierResponseDoesNotConsumeTitleEligibility() async {
        let c = conversation(); let failed = message(c, state: .failed); let a = message(c, index: 1)
        let result = await ConversationMetadataService(request: { _, _ in "标题" }).titleCandidate(conversation: c, messages: [failed, a], completedAssistantID: a.id)
        XCTAssertEqual(result?.value, "标题")
    }
    func testPendingStreamingCancelledAndFailedCannotRequestTitle() async {
        let c = conversation()
        for state: AIConversationMessageState in [.pending, .streaming, .cancelled, .failed] {
            let a = message(c, state: state)
            let result = await noRequest().titleCandidate(conversation: c, messages: [a], completedAssistantID: a.id)
            XCTAssertNil(result)
        }
    }
    func testTitleCompletionIdentityMustMatch() async {
        let c = conversation(); let a = message(c)
        let result = await noRequest().titleCandidate(conversation: c, messages: [a], completedAssistantID: UUID())
        XCTAssertNil(result)
    }
    func testUserRenameWhileRequestSuspendedWins() async {
        let c = conversation(); let a = message(c)
        var authoritative = c
        let service = ConversationMetadataService(request: { _, _ in
            await Task.yield(); authoritative.applyUserTitle("我的标题"); return "模型标题"
        })
        let candidate = await service.titleCandidate(conversation: c, messages: [a], completedAssistantID: a.id)
        XCTAssertEqual(candidate?.canApply(to: authoritative, completedAssistantID: a.id), false)
        XCTAssertEqual(authoritative.title, "我的标题")
        authoritative.applyUserTitle("新对话")
        XCTAssertEqual(candidate?.canApply(to: authoritative, completedAssistantID: a.id), false)
    }
    func testCandidateRejectsAnotherConversationOrCompletion() async {
        let c = conversation(); let a = message(c)
        let candidate = await ConversationMetadataService(request: { _, _ in "标题" }).titleCandidate(conversation: c, messages: [a], completedAssistantID: a.id)
        XCTAssertEqual(candidate?.canApply(to: conversation(), completedAssistantID: a.id), false)
        XCTAssertEqual(candidate?.canApply(to: c, completedAssistantID: UUID()), false)
        var changed = c; changed.lastActivityAt = now.addingTimeInterval(1)
        XCTAssertEqual(candidate?.canApply(to: changed, completedAssistantID: a.id), false)
    }
    func testSummaryMoreThanTwelveCompletedMessagesRequestsCorrectTaskType() async {
        let c = conversation(); let messages = (0..<13).map { message(c, index: $0, role: $0 == 12 ? .assistant : .user) }
        let service = ConversationMetadataService(request: { _, task in XCTAssertEqual(task, "conversation_summary"); return "已讨论晚餐" })
        let result = await service.summaryCandidate(conversation: c, messages: messages, completedAssistantID: messages.last!.id, isSummaryStale: false)
        XCTAssertEqual(result?.value, "已讨论晚餐"); XCTAssertEqual(result?.kind, .summary); XCTAssertEqual(c.summary, "")
    }
    func testSummaryExactlyTwelveWithoutStalenessDoesNotRequest() async {
        let c = conversation(); let messages = (0..<12).map { message(c, index: $0) }
        let result = await noRequest().summaryCandidate(conversation: c, messages: messages, completedAssistantID: messages.last!.id, isSummaryStale: false)
        XCTAssertNil(result)
    }
    func testExplicitStalenessRefreshesShortCompletedConversation() async {
        var c = conversation(); c.summary = "旧摘要"; let a = message(c)
        let service = ConversationMetadataService(request: { prompt, task in
            XCTAssertEqual(task, "conversation_summary"); XCTAssertTrue(prompt.contains("旧摘要")); return "新摘要"
        })
        let result = await service.summaryCandidate(conversation: c, messages: [a], completedAssistantID: a.id, isSummaryStale: true)
        XCTAssertEqual(result?.value, "新摘要"); XCTAssertEqual(c.summary, "旧摘要")
    }
    func testStalenessNeverOverridesIncompleteTurn() async {
        let c = conversation()
        for state: AIConversationMessageState in [.pending, .streaming, .cancelled, .failed] {
            let a = message(c, state: state)
            let result = await noRequest().summaryCandidate(conversation: c, messages: [a], completedAssistantID: a.id, isSummaryStale: true)
            XCTAssertNil(result)
        }
    }
    func testSummaryRequiresAssistantCompletionNotUser() async {
        let c = conversation(); let user = message(c, role: .user)
        let result = await noRequest().summaryCandidate(conversation: c, messages: [user], completedAssistantID: user.id, isSummaryStale: true)
        XCTAssertNil(result)
    }
    func testForeignRowsDoNotInflateSummaryCount() async {
        let c = conversation(); let a = message(c)
        let rows = (0..<20).map { message(conversation(), index: $0) }
        let result = await noRequest().summaryCandidate(conversation: c, messages: rows + [a], completedAssistantID: a.id, isSummaryStale: false)
        XCTAssertNil(result)
    }
    func testSummaryCandidateRejectsNewerSummaryRevision() async {
        let c = conversation(); let a = message(c)
        let candidate = await ConversationMetadataService(request: { _, _ in "摘要" }).summaryCandidate(conversation: c, messages: [a], completedAssistantID: a.id, isSummaryStale: true)
        XCTAssertEqual(candidate?.canApply(to: c, completedAssistantID: a.id), true)
        var changed = c; changed.summary = "更新"; changed.summaryUpdatedAt = now
        XCTAssertEqual(candidate?.canApply(to: changed, completedAssistantID: a.id), false)
    }
    func testTitleFailureDoesNotPreventSummaryOrMutateConversation() async {
        let c = conversation(); let a = message(c)
        let service = ConversationMetadataService(request: { _, task in
            if task == "conversation_title" { throw AIChatServiceError.unavailable }; return "摘要"
        })
        let title = await service.titleCandidate(conversation: c, messages: [a], completedAssistantID: a.id)
        let summary = await service.summaryCandidate(conversation: c, messages: [a], completedAssistantID: a.id, isSummaryStale: true)
        XCTAssertNil(title); XCTAssertEqual(summary?.value, "摘要"); XCTAssertEqual(c.title, "新对话"); XCTAssertEqual(c.summary, "")
    }
    func testSummaryFailureDoesNotPreventTitleOrErasePreviousSummary() async {
        var c = conversation(); c.summary = "保留摘要"; let a = message(c)
        let service = ConversationMetadataService(request: { _, task in
            if task == "conversation_summary" { throw AIChatServiceError.unavailable }; return "标题"
        })
        let summary = await service.summaryCandidate(conversation: c, messages: [a], completedAssistantID: a.id, isSummaryStale: true)
        let title = await service.titleCandidate(conversation: c, messages: [a], completedAssistantID: a.id)
        XCTAssertNil(summary); XCTAssertEqual(title?.value, "标题"); XCTAssertEqual(c.summary, "保留摘要")
    }
    func testEmptyResponseProducesNoCandidate() async {
        let c = conversation(); let a = message(c); let service = ConversationMetadataService(request: { _, _ in "  \n" })
        let title = await service.titleCandidate(conversation: c, messages: [a], completedAssistantID: a.id)
        let summary = await service.summaryCandidate(conversation: c, messages: [a], completedAssistantID: a.id, isSummaryStale: true)
        XCTAssertNil(title); XCTAssertNil(summary)
    }
    func testOneShotAIChatServiceAdapterUsesMetadataTaskTypes() async throws {
        defer { MockURLProtocol.reset() }
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(#"{"content":"结果"}"#.utf8)) }
        let chat = AIChatService(apiClient: APIClient(environment: .production, session: .mocked()))
        let service = ConversationMetadataService(chatService: chat); let c = conversation(); let a = message(c)
        _ = await service.titleCandidate(conversation: c, messages: [a], completedAssistantID: a.id)
        _ = await service.summaryCandidate(conversation: c, messages: [a], completedAssistantID: a.id, isSummaryStale: true)
        let types = try MockURLProtocol.capturedRequests().map { request in
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            return try XCTUnwrap(json["taskType"] as? String)
        }
        XCTAssertEqual(types, ["conversation_title", "conversation_summary"])
    }
    func testSummaryThresholdCountsLocalRecordsButPromptOmitsFailedContent() async {
        let c = conversation(); let a = message(c, index: 99)
        let rows = (0..<12).map { message(c, index: $0, state: .failed) }
        let service = ConversationMetadataService(request: { prompt, task in
            XCTAssertEqual(task, "conversation_summary"); XCTAssertFalse(prompt.contains("晚餐0")); XCTAssertTrue(prompt.contains("晚餐99")); return "摘要"
        })
        let result = await service.summaryCandidate(conversation: c, messages: rows + [a], completedAssistantID: a.id, isSummaryStale: false)
        XCTAssertEqual(result?.value, "摘要")
    }

}

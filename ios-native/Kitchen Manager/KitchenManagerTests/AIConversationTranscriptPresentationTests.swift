import XCTest
@testable import KitchenManager

/// Retrying a failed turn appends a new assistant attempt under the same turn.
/// The transcript shows only the newest attempt when the older ones carried
/// nothing but an error, so repeated retries no longer stack identical
/// 「AI 服务暂时不可用」 rows, each with its own retry button. Anything a failed
/// attempt actually produced (partial text, a card, an action outcome) stays.
final class AIConversationTranscriptPresentationTests: XCTestCase {
    private let conversationID = UUID()

    private func message(_ role: AIConversationRole, turn: UUID, state: AIConversationMessageState,
                         blocks: [AIContentBlock], at offset: TimeInterval) -> AIConversationMessage {
        AIConversationMessage(conversationID: conversationID, role: role,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000 + offset), state: state,
            contentBlocks: blocks, turnID: turn)
    }

    private func errorOnly(turn: UUID, at offset: TimeInterval) -> AIConversationMessage {
        message(.assistant, turn: turn, state: .failed,
            blocks: [.error(.init(message: ConversationFailurePresentation.unavailableMessage, retry: .generation))], at: offset)
    }

    func testOlderErrorOnlyAttemptsOfARetriedTurnAreCollapsed() {
        let turn = UUID()
        let user = message(.user, turn: turn, state: .completed, blocks: [.text(.init(text: "用快过期的食材做饭"))], at: 0)
        let first = errorOnly(turn: turn, at: 1)
        let second = errorOnly(turn: turn, at: 2)
        let success = message(.assistant, turn: turn, state: .completed, blocks: [.text(.init(text: "可以做番茄炒蛋。"))], at: 3)

        let visible = AIConversationTranscriptPresentation.visibleMessages([user, first, second, success])

        XCTAssertEqual(visible.map(\.id), [user.id, success.id])
    }

    func testTheNewestFailedAttemptStaysVisible() {
        let turn = UUID()
        let user = message(.user, turn: turn, state: .completed, blocks: [.text(.init(text: "今晚吃什么"))], at: 0)
        let first = errorOnly(turn: turn, at: 1)
        let latest = errorOnly(turn: turn, at: 2)

        let visible = AIConversationTranscriptPresentation.visibleMessages([user, first, latest])

        XCTAssertEqual(visible.map(\.id), [user.id, latest.id], "one error row per turn, and it is the latest one")
    }

    func testAFailedAttemptWithPartialContentIsNeverHidden() {
        let turn = UUID()
        let partial = message(.assistant, turn: turn, state: .failed, blocks: [
            .text(.init(text: "先把番茄切块")),
            .error(.init(message: ConversationFailurePresentation.partialReplyInterruptedMessage, retry: .generation))
        ], at: 1)
        let retry = message(.assistant, turn: turn, state: .completed, blocks: [.text(.init(text: "完整做法"))], at: 2)

        let visible = AIConversationTranscriptPresentation.visibleMessages([partial, retry])

        XCTAssertEqual(visible.map(\.id), [partial.id, retry.id])
    }

    func testFailuresOfDifferentTurnsAreNotCollapsed() {
        let a = errorOnly(turn: UUID(), at: 1)
        let b = errorOnly(turn: UUID(), at: 2)

        XCTAssertEqual(AIConversationTranscriptPresentation.visibleMessages([a, b]).map(\.id), [a.id, b.id])
    }

    func testAStoppedEmptyAttemptFollowedByARetryIsCollapsedButAStoppedPartialIsKept() {
        let turn = UUID()
        let stoppedEmpty = message(.assistant, turn: turn, state: .cancelled, blocks: [], at: 1)
        let stoppedPartial = message(.assistant, turn: turn, state: .cancelled, blocks: [.text(.init(text: "先"))], at: 2)
        let retry = message(.assistant, turn: turn, state: .completed, blocks: [.text(.init(text: "完整"))], at: 3)

        let visible = AIConversationTranscriptPresentation.visibleMessages([stoppedEmpty, stoppedPartial, retry])

        XCTAssertEqual(visible.map(\.id), [stoppedPartial.id, retry.id])
    }
}

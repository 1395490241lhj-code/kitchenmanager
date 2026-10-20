import XCTest
@testable import KitchenManager

/// The transcript follows new content only while the member is reading the
/// bottom of it. Scrolling up to reread must not be yanked back by every
/// streamed delta; sending a message or opening another conversation follows
/// again.
final class AIConversationAutoScrollTests: XCTestCase {
    func testNearBottomAccountsForTheComposerInset() {
        // 1000pt of content, 600pt viewport, 120pt composer inset: the bottom is offset 520.
        XCTAssertTrue(AIConversationAutoScroll.isNearBottom(contentOffsetY: 520, contentHeight: 1000, containerHeight: 600, bottomInset: 120))
        XCTAssertTrue(AIConversationAutoScroll.isNearBottom(contentOffsetY: 480, contentHeight: 1000, containerHeight: 600, bottomInset: 120))
        XCTAssertFalse(AIConversationAutoScroll.isNearBottom(contentOffsetY: 200, contentHeight: 1000, containerHeight: 600, bottomInset: 120))
    }

    func testShortContentAlwaysCountsAsAtTheBottom() {
        XCTAssertTrue(AIConversationAutoScroll.isNearBottom(contentOffsetY: 0, contentHeight: 300, containerHeight: 600, bottomInset: 120))
    }

    func testContentFollowsOnlyWhileFollowingAndNotDuringAUserScroll() {
        XCTAssertTrue(AIConversationAutoScroll.shouldFollow(followsBottom: true, userIsScrolling: false))
        XCTAssertFalse(AIConversationAutoScroll.shouldFollow(followsBottom: false, userIsScrolling: false))
        XCTAssertFalse(AIConversationAutoScroll.shouldFollow(followsBottom: true, userIsScrolling: true))
    }

    func testSendingOrSwitchingConversationResumesFollowing() {
        let conversation = UUID()
        let question = UUID()
        let before = AIConversationAutoScroll.Trigger(conversationID: conversation, latestUserMessageID: question,
                                                      messageCount: 2, revision: 4, turnState: .completed)
        let ownSend = AIConversationAutoScroll.Trigger(conversationID: conversation, latestUserMessageID: UUID(),
                                                       messageCount: 4, revision: 5, turnState: .preparingContext)
        let streamed = AIConversationAutoScroll.Trigger(conversationID: conversation, latestUserMessageID: question,
                                                        messageCount: 2, revision: 9, turnState: .streaming)
        let switched = AIConversationAutoScroll.Trigger(conversationID: UUID(), latestUserMessageID: nil,
                                                        messageCount: 2, revision: 4, turnState: .idle)

        XCTAssertTrue(AIConversationAutoScroll.resumesFollowing(from: before, to: ownSend),
                      "a send appends the member's message and the assistant placeholder in one update")
        XCTAssertTrue(AIConversationAutoScroll.resumesFollowing(from: before, to: switched))
        XCTAssertFalse(AIConversationAutoScroll.resumesFollowing(from: before, to: streamed),
                       "streamed text alone never overrides the member's scroll position")
    }

    /// SwiftUI may coalesce the send with the first provider events, so the view
    /// can see the new message already in .requesting or .streaming. A new
    /// question still resumes following; it does not depend on catching
    /// .preparingContext in between.
    func testACoalescedSendStillResumesFollowing() {
        let conversation = UUID()
        let before = AIConversationAutoScroll.Trigger(conversationID: conversation, latestUserMessageID: UUID(),
                                                      messageCount: 2, revision: 4, turnState: .completed)
        for state in [AIConversationTurnState.requesting, .streaming, .toolRequested, .completed] {
            let coalesced = AIConversationAutoScroll.Trigger(conversationID: conversation, latestUserMessageID: UUID(),
                                                             messageCount: 4, revision: 7, turnState: state)
            XCTAssertTrue(AIConversationAutoScroll.resumesFollowing(from: before, to: coalesced), "\(state)")
        }
    }

    /// A retry adds an attempt without a new question; it follows while that
    /// attempt is running, whichever running state the view sees first.
    func testARetryFollowsWhileTheNewAttemptRuns() {
        let conversation = UUID()
        let question = UUID()
        let failed = AIConversationAutoScroll.Trigger(conversationID: conversation, latestUserMessageID: question,
                                                      messageCount: 3, revision: 6, turnState: .failed)
        let retrying = AIConversationAutoScroll.Trigger(conversationID: conversation, latestUserMessageID: question,
                                                        messageCount: 4, revision: 7, turnState: .streaming)
        let reconciled = AIConversationAutoScroll.Trigger(conversationID: conversation, latestUserMessageID: question,
                                                          messageCount: 4, revision: 8, turnState: .idle)
        XCTAssertTrue(AIConversationAutoScroll.resumesFollowing(from: failed, to: retrying))
        XCTAssertFalse(AIConversationAutoScroll.resumesFollowing(from: failed, to: reconciled),
                       "a message added while nothing runs (a restored action outcome) is not the member's request")
    }

    /// Dragging the transcript to put the keyboard away is not scrolling up to
    /// reread: it keeps whatever following state the member already had. A drag
    /// without the keyboard decides from where it ends.
    func testAKeyboardDismissingDragKeepsTheFollowingState() {
        XCTAssertTrue(AIConversationAutoScroll.followsAfterUserScroll(previous: true, beganWithKeyboard: true, isNearBottom: false))
        XCTAssertFalse(AIConversationAutoScroll.followsAfterUserScroll(previous: false, beganWithKeyboard: true, isNearBottom: true))
        XCTAssertFalse(AIConversationAutoScroll.followsAfterUserScroll(previous: true, beganWithKeyboard: false, isNearBottom: false))
        XCTAssertTrue(AIConversationAutoScroll.followsAfterUserScroll(previous: false, beganWithKeyboard: false, isNearBottom: true))
    }
}

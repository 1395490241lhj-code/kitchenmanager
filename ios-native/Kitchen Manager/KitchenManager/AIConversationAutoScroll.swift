import Foundation
import CoreGraphics

/// When the Kitchen AI transcript follows new content to the bottom.
///
/// It used to scroll on every message count, turn state and content revision
/// change, so each streamed delta pulled a member who had scrolled up to reread
/// back to the bottom, and three handlers could scroll in one update. Now one
/// trigger drives at most one scroll per update, and only while the member is
/// following the bottom and not dragging. Sending a message (a new turn starts)
/// or opening another conversation follows again. No animation is added; the
/// existing scroll animation policy is unchanged.
nonisolated enum AIConversationAutoScroll {
    /// Within this distance of the end, the member is still reading the newest
    /// content and keeps following it.
    static let nearBottomThreshold: CGFloat = 64

    struct Trigger: Equatable {
        let conversationID: UUID?
        /// The newest member message. A new one is a request the member just
        /// made, however SwiftUI coalesces the states that follow it.
        let latestUserMessageID: UUID?
        let messageCount: Int
        let revision: Int
        let turnState: AIConversationTurnState
    }

    static func isNearBottom(contentOffsetY: CGFloat, contentHeight: CGFloat,
                             containerHeight: CGFloat, bottomInset: CGFloat) -> Bool {
        let bottomOffset = contentHeight + bottomInset - containerHeight
        return contentOffsetY >= bottomOffset - nearBottomThreshold
    }

    static func shouldFollow(followsBottom: Bool, userIsScrolling: Bool) -> Bool {
        followsBottom && !userIsScrolling
    }

    /// A new question the member sent, a retry that is now running, or a
    /// different conversation brings the transcript back to its newest content.
    /// It does not depend on observing `.preparingContext`: SwiftUI may coalesce
    /// a send with the first provider events. Streamed text alone never does.
    static func resumesFollowing(from old: Trigger, to new: Trigger) -> Bool {
        if old.conversationID != new.conversationID { return true }
        if let newest = new.latestUserMessageID, newest != old.latestUserMessageID { return true }
        return new.messageCount > old.messageCount && isRunning(new.turnState)
    }

    /// Dragging the transcript to put the keyboard away is not scrolling up to
    /// reread, so it keeps the following state the member already had. A drag
    /// that began without the keyboard decides from where it ends.
    static func followsAfterUserScroll(previous: Bool, beganWithKeyboard: Bool, isNearBottom: Bool) -> Bool {
        beganWithKeyboard ? previous : isNearBottom
    }

    private static func isRunning(_ state: AIConversationTurnState) -> Bool {
        switch state {
        case .preparingContext, .requesting, .streaming, .toolRequested, .executing: return true
        case .idle, .awaitingConfirmation, .completed, .cancelled, .failed: return false
        }
    }
}

import Foundation

/// Which persisted messages the transcript draws. Presentation only: history is
/// never rewritten, and the store keeps every attempt.
///
/// A retry appends a new assistant attempt under the same turn. An older attempt
/// of that turn that ended without producing anything (failed or stopped, with
/// no blocks but an error) is superseded by the newer one, so repeated retries
/// show one outcome per turn instead of a column of identical error rows, each
/// still offering a retry. An attempt that produced partial text, a card or an
/// action outcome is real content and always stays.
nonisolated enum AIConversationTranscriptPresentation {
    static func visibleMessages(_ messages: [AIConversationMessage]) -> [AIConversationMessage] {
        var laterAssistantTurns = Set<UUID>()
        var hidden = Set<UUID>()
        for message in messages.reversed() where message.role == .assistant {
            if laterAssistantTurns.contains(message.turnID), producedNothing(message) {
                hidden.insert(message.id)
            }
            laterAssistantTurns.insert(message.turnID)
        }
        guard !hidden.isEmpty else { return messages }
        return messages.filter { !hidden.contains($0.id) }
    }

    private static func producedNothing(_ message: AIConversationMessage) -> Bool {
        guard message.state == .failed || message.state == .cancelled else { return false }
        return message.contentBlocks.allSatisfy { block in
            if case .error = block { return true }
            return false
        }
    }
}

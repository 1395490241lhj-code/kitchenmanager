import Foundation

/// Presentation-only ordering for the Home dashboard's supporting content.
/// Business priority remains owned by `HomeDashboardSummary`; this only keeps
/// the visual and VoiceOver order deterministic once a state is already known.
///
/// There is no reminder section here. Home V2 folded every attention fact —
/// expiring inventory, prepared batches, low stock, purchased-awaiting-stock-in
/// and pending shopping — into the single named `需要处理` list built from
/// `HomeDashboardSummary.attentionItems`. That list is the only Home attention
/// presentation path; a second one is exactly the duplication it removed.
enum HomeDashboardSupplementarySection: Hashable {
    case clipboardPrompt
    case moduleIssues
}

enum HomeDashboardPresentation {
    static func supplementarySections(
        showsClipboardPrompt: Bool,
        hasModuleIssues: Bool
    ) -> [HomeDashboardSupplementarySection] {
        var sections: [HomeDashboardSupplementarySection] = []

        if showsClipboardPrompt {
            sections.append(.clipboardPrompt)
        }
        if hasModuleIssues {
            sections.append(.moduleIssues)
        }

        return sections
    }
}

enum HomeDatePresentation {
    static func text(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }
}

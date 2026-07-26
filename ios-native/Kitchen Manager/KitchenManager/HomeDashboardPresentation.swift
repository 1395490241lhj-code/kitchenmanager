import Foundation

/// Presentation-only ordering for the Home dashboard's supporting content.
/// Business priority remains owned by `HomeDashboardSummary`; this only keeps
/// the visual and VoiceOver order deterministic once a state is already known.
enum HomeDashboardSupplementarySection: Hashable {
    case reminder
    case clipboardPrompt
    case moduleIssues
}

enum HomeDashboardPresentation {
    static func todayPlanPrimaryAction(for state: HomeTodayPlanState) -> HomePrimaryAction {
        switch state {
        case .empty: .addTodayPlan
        case .active, .partial: .viewTodayPlan
        case .completed: .browseRecipes
        }
    }
    static func supplementarySections(
        hasReminder: Bool,
        showsClipboardPrompt: Bool,
        hasModuleIssues: Bool
    ) -> [HomeDashboardSupplementarySection] {
        var sections: [HomeDashboardSupplementarySection] = []

        if hasReminder {
            sections.append(.reminder)
        }
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

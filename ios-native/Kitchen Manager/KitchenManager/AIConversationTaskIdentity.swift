import Foundation

/// Presentation-only answer to "what is this conversation about".
///
/// Derived entirely from state the conversation already stores —
/// `lifecycleType`, `anchorDate`, `createdAt`, `title` — so this type adds no
/// persisted field, no retention or context policy, and no second title. The
/// navigation layer shows the conversation's own title; this supplies the
/// complementary context line, which is why the two never repeat each other.
///
/// Every label has to stay true for an old conversation as well as a fresh one.
/// That is why the daily label *is* the day rather than a fixed 今天: a Home
/// conversation started last Thursday is not about today, and a header that
/// said so would be worse than no header.
nonisolated struct AIConversationTaskIdentity: Equatable {
    /// The conversation's own title, or the product name while a draft has not
    /// been persisted yet. Never a generated substitute.
    let navigationTitle: String
    /// Which kitchen task this conversation belongs to.
    let contextLabel: String
    /// The task's own anchor, only when the conversation actually has one.
    let anchorLabel: String?
    let symbolName: String

    /// Joined from the parts that exist, so a missing anchor can never leave a
    /// dangling separator behind.
    var contextLine: String {
        [contextLabel, anchorLabel]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var accessibilityLabel: String {
        "当前任务：\(contextLine)"
    }

    init(
        conversation: AIConversation?,
        isPersisted: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        guard let conversation, isPersisted else {
            // A draft owns no task yet. It keeps the product name and shows no
            // context line, because the empty state is already saying it.
            navigationTitle = AIConversationTaskIdentity.fallbackTitle
            contextLabel = ""
            anchorLabel = nil
            symbolName = "sparkles"
            return
        }

        navigationTitle = conversation.title

        switch conversation.lifecycleType {
        case .dailyMeal:
            symbolName = "house"
            if calendar.isDate(conversation.createdAt, inSameDayAs: now) {
                contextLabel = "今天"
            } else {
                contextLabel = AIConversationTaskIdentity.day(conversation.createdAt, calendar: calendar)
            }
            anchorLabel = nil

        case .weeklyPlanning:
            symbolName = "calendar"
            if let anchorDate = conversation.anchorDate {
                let anchorWeek = PlannerProjection.startOfWeek(containing: anchorDate, calendar: calendar)
                let currentWeek = PlannerProjection.startOfWeek(containing: now, calendar: calendar)
                // 本周 is only true for the week actually on the calendar now.
                contextLabel = anchorWeek == currentWeek ? "本周计划" : "一周计划"
                anchorLabel = PlannerDateText.weekRange(start: anchorWeek, calendar: calendar)
            } else {
                contextLabel = "一周计划"
                anchorLabel = nil
            }

        case .specialPlan:
            symbolName = "person.2"
            contextLabel = "聚餐计划"
            anchorLabel = conversation.anchorDate.map {
                AIConversationTaskIdentity.day($0, calendar: calendar)
            }

        case .general:
            symbolName = "bubble.left"
            contextLabel = "厨房对话"
            anchorLabel = nil
        }
    }

    static let fallbackTitle = "Kitchen AI"

    /// Same day formatting the Planner already uses, so the two surfaces cannot
    /// disagree about how a date reads.
    private static func day(_ date: Date, calendar: Calendar) -> String {
        PlannerDateText.day(date, calendar: calendar)
    }
}

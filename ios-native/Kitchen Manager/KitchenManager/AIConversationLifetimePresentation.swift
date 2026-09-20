import Foundation

/// User-facing meaning of a conversation's lifecycle. `activeUntil` is when
/// automatic continuity ends; it is never deletion, so the words here say
/// 延续 and 归档, never 过期 (which this app reserves for food).
///
/// Everything is derived from `isPinned`, `activeUntil` and `isExpired(now:)`.
/// No lifecycle policy leaks into copy: the member sees the resulting date only,
/// so a future policy that shortens or lengthens continuity changes the date
/// and nothing else.
nonisolated enum AIConversationLifetimePresentation {
    static let activePrefix = "自动延续至"
    static let pinned = "已置顶"
    static let archived = "已归档"
    static let active = "活跃"

    /// What the overflow menu header says about the current conversation, as
    /// one line: the native Menu renders exactly one header Text and drops any
    /// second line or custom accessibility label (verified on iOS 27.2), so a
    /// longer explanation would have no host. `nil` for a draft: it owns no
    /// lifecycle yet.
    static func overflow(
        for conversation: AIConversation?,
        isPersisted: Bool,
        now: Date,
        calendar: Calendar = .current
    ) -> String? {
        guard let conversation, isPersisted else { return nil }
        if conversation.isPinned { return pinned }
        if conversation.isExpired(now: now) { return archived }
        return "\(activePrefix) \(deadline(conversation.activeUntil, now: now, calendar: calendar))"
    }

    /// History chip. Pinned wins because the pin is what keeps it out of 已归档.
    static func status(for conversation: AIConversation, now: Date) -> String {
        if conversation.isPinned { return pinned }
        return conversation.isExpired(now: now) ? archived : active
    }

    /// `今天 18:30` · `明天 10:42` · `周一 10:42` (2–6 days) · `9月24日 10:42`
    /// (same year) · `2027年1月3日 10:42`. zh-Hans, 24-hour, no seconds; the
    /// formatter never follows the device region.
    static func deadline(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = formatted(date, "HH:mm", calendar)
        let startOfNow = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startOfNow, to: startOfDate).day ?? 0
        switch days {
        case 0: return "今天 \(time)"
        case 1: return "明天 \(time)"
        case 2...6: return "\(formatted(date, "EEE", calendar)) \(time)"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return formatted(date, sameYear ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm", calendar)
        }
    }

    private static func formatted(_ date: Date, _ format: String, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

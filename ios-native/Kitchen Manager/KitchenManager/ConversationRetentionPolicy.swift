import Foundation

/// How long a Kitchen AI conversation stays the automatic default, and which
/// conversation an entry surface should resume.
///
/// Two rules shape everything here. First, expiry is about continuity, never
/// storage: `activeUntil` decides whether a conversation is still the default
/// context, while local history stays readable forever. Second, the policy is
/// pure and dependency-injected — it reads no subscription state and no ambient
/// clock or locale, because a window that shifts with the device would make
/// "when does this conversation stop being current" unpredictable.
///
/// Free/paid differences are a policy seam in V1. A later tier changes these
/// values; it must never make stored history disappear.
nonisolated struct ConversationRetentionPolicy: Equatable, Sendable {
    /// Stored on each conversation so a conversation written under an older
    /// policy can still be identified after the values change.
    let version: Int
    /// Base window after the last activity.
    let activeInterval: TimeInterval
    /// Grace added after an anchored week ends or an anchored event happens.
    let anchorGrace: TimeInterval
    /// How many prior messages the context assembler may send at most.
    let recentMessageWindow: Int

    static let v1 = ConversationRetentionPolicy(
        version: 1,
        activeInterval: 48 * 60 * 60,
        anchorGrace: 24 * 60 * 60,
        recentMessageWindow: 12
    )

    /// The approved V1 windows:
    ///
    /// - `.general` / `.dailyMeal`: 48h after last activity.
    /// - `.weeklyPlanning`: the later of 48h after activity or 24h after the
    ///   referenced Planner week ends.
    /// - `.specialPlan`: the later of 48h after activity or 24h after the event.
    ///
    /// A missing anchor falls back to the activity window rather than inventing
    /// an anchor date, which is the honest answer for a conversation whose
    /// referenced week or event was never resolved.
    ///
    /// Pinning is deliberately **not** handled here. `AIConversation.isExpired`
    /// owns it, so `activeUntil` stays a truthful "when would this have expired"
    /// date. Writing a non-expiring sentinel instead would outlive the pin: after
    /// unpinning, the conversation would stay active forever unless some caller
    /// remembered to recompute it.
    func activeUntil(
        for conversation: AIConversation,
        lastActivityAt: Date,
        calendar: Calendar = .current
    ) -> Date {
        let activityWindow = lastActivityAt.addingTimeInterval(activeInterval)
        guard let anchorDate = conversation.anchorDate else { return activityWindow }

        switch conversation.lifecycleType {
        case .general, .dailyMeal:
            return activityWindow
        case .weeklyPlanning:
            // Reuse the Planner's own Monday-first week anchor; a second week
            // convention here would disagree with the surface that opened the
            // conversation.
            let weekEnd = PlannerProjection.nextWeekStart(
                after: PlannerProjection.startOfWeek(containing: anchorDate, calendar: calendar),
                calendar: calendar
            )
            return max(activityWindow, weekEnd.addingTimeInterval(anchorGrace))
        case .specialPlan:
            return max(activityWindow, anchorDate.addingTimeInterval(anchorGrace))
        }
    }

    /// Recomputes activity + expiry for a conversation that just received a turn,
    /// or that the user explicitly reactivated.
    func refreshed(
        _ conversation: AIConversation,
        now: Date,
        calendar: Calendar = .current
    ) -> AIConversation {
        var updated = conversation
        updated.lastActivityAt = now
        updated.retentionPolicyVersion = version
        updated.activeUntil = activeUntil(for: updated, lastActivityAt: now, calendar: calendar)
        return updated
    }
}

/// Which active conversation an entry surface should resume.
///
/// Entry surfaces resume by task relevance, not by recency. Reopening the most
/// recent unrelated conversation is the failure this type prevents: a weekly
/// planning thread is the wrong place to answer "什么菜今晚能做", and an anchored
/// conversation for another week is not the week on screen.
///
/// No match returns nil on purpose. The surface then shows a fresh contextual
/// empty state, which is more useful than a mismatched transcript.
nonisolated struct ConversationAffinityResolver: Sendable {
    init() {}

    func bestConversation(
        for entryContext: AIConversationEntryContext,
        from conversations: [AIConversation],
        now: Date,
        calendar: Calendar = .current
    ) -> AIConversation? {
        conversations
            .filter { !$0.isExpired(now: now) }
            .compactMap { conversation -> (conversation: AIConversation, score: Int)? in
                guard let score = relevance(
                    of: conversation, for: entryContext, calendar: calendar
                ) else { return nil }
                return (conversation, score)
            }
            .max { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                if lhs.conversation.lastActivityAt != rhs.conversation.lastActivityAt {
                    return lhs.conversation.lastActivityAt < rhs.conversation.lastActivityAt
                }
                // Deterministic final tiebreak so the same input never resumes a
                // different conversation between launches.
                return lhs.conversation.id.uuidString < rhs.conversation.id.uuidString
            }?
            .conversation
    }

    /// Higher is more relevant. `nil` means "not relevant to this surface".
    private func relevance(
        of conversation: AIConversation,
        for entryContext: AIConversationEntryContext,
        calendar: Calendar
    ) -> Int? {
        switch entryContext {
        case .home:
            switch conversation.entryAffinity {
            case .dailyMeal: return 3
            case .general: return 2
            case .weeklyPlanning, .specialPlan: return nil
            }
        case let .planner(weekStart, specialPlanID):
            switch conversation.entryAffinity {
            case .specialPlan:
                // An anchored Special Plan conversation is only relevant to the
                // plan it was anchored to.
                guard let specialPlanID,
                      conversation.anchorEntityID == specialPlanID else { return nil }
                return 5
            case .weeklyPlanning:
                guard let anchorDate = conversation.anchorDate,
                      PlannerProjection.startOfWeek(containing: anchorDate, calendar: calendar)
                        == PlannerProjection.startOfWeek(containing: weekStart, calendar: calendar)
                else { return nil }
                return 4
            case .general, .dailyMeal:
                return nil
            }
        }
    }
}

import XCTest
@testable import KitchenManager

/// Kitchen AI retention and conversation affinity.
///
/// `activeUntil` governs automatic continuity, never storage: an expired
/// conversation stays readable in History forever. These tests pin the approved
/// V1 windows with a fixed calendar and fixed dates, because a policy that
/// drifts with the machine clock or the device locale would silently change when
/// a week-anchored conversation stops being the default.
@MainActor
final class ConversationRetentionPolicyTests: XCTestCase {
    private let policy = ConversationRetentionPolicy.v1
    private let day: TimeInterval = 24 * 60 * 60

    /// Monday-first, fixed zone. The project's week anchor is Monday
    /// (`PlannerProjection.startOfWeek`), so the policy must agree with it.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else {
            fatalError("bad fixture date \(iso)")
        }
        return date
    }

    // MARK: - Active window

    func testGeneralAndDailyMealExpireFortyEightHoursAfterActivity() {
        let now = date("2026-09-16T10:00:00-04:00")
        for lifecycle in [AIConversationLifecycleType.general, .dailyMeal] {
            let conversation = AIConversation.fixture(lifecycleType: lifecycle, lastActivityAt: now)
            XCTAssertEqual(
                policy.activeUntil(for: conversation, lastActivityAt: now, calendar: calendar),
                now.addingTimeInterval(2 * day),
                "\(lifecycle) must use the 48h activity window"
            )
        }
    }

    func testWeeklyPlanningUsesLaterOfActivityOrWeekEndGrace() {
        // Activity early in the anchored week: the week's own end wins.
        let now = date("2026-09-16T10:00:00-04:00")
        let conversation = AIConversation.fixture(
            lifecycleType: .weeklyPlanning,
            lastActivityAt: now,
            anchorDate: date("2026-09-16T00:00:00-04:00")
        )
        // Week of Mon 2026-09-14 ends at Mon 2026-09-21T00:00 local; +24h grace.
        XCTAssertEqual(
            policy.activeUntil(for: conversation, lastActivityAt: now, calendar: calendar),
            date("2026-09-22T00:00:00-04:00")
        )
    }

    func testWeeklyPlanningFallsBackToActivityWindowForAPastWeek() {
        let now = date("2026-09-16T10:00:00-04:00")
        let conversation = AIConversation.fixture(
            lifecycleType: .weeklyPlanning,
            lastActivityAt: now,
            anchorDate: date("2026-08-10T00:00:00-04:00")
        )
        XCTAssertEqual(
            policy.activeUntil(for: conversation, lastActivityAt: now, calendar: calendar),
            now.addingTimeInterval(2 * day)
        )
    }

    func testSpecialPlanExpiryUsesLaterOfActivityOrEventGrace() {
        let now = date("2026-09-16T10:00:00-04:00")
        let event = date("2026-09-20T18:30:00-04:00")
        let conversation = AIConversation.fixture(
            lifecycleType: .specialPlan,
            lastActivityAt: now,
            anchorDate: event
        )
        XCTAssertEqual(
            policy.activeUntil(for: conversation, lastActivityAt: now, calendar: calendar),
            event.addingTimeInterval(day)
        )
    }

    func testSpecialPlanFallsBackToActivityWindowAfterTheEvent() {
        let now = date("2026-09-16T10:00:00-04:00")
        let conversation = AIConversation.fixture(
            lifecycleType: .specialPlan,
            lastActivityAt: now,
            anchorDate: date("2026-09-10T18:30:00-04:00")
        )
        XCTAssertEqual(
            policy.activeUntil(for: conversation, lastActivityAt: now, calendar: calendar),
            now.addingTimeInterval(2 * day)
        )
    }

    /// A missing anchor is the honest state for a conversation whose referenced
    /// week or event was never resolved. It falls back to the activity window
    /// rather than inventing an anchor date.
    func testAnchoredLifecycleWithoutAnchorUsesActivityWindow() {
        let now = date("2026-09-16T10:00:00-04:00")
        for lifecycle in [AIConversationLifecycleType.weeklyPlanning, .specialPlan] {
            let conversation = AIConversation.fixture(lifecycleType: lifecycle, lastActivityAt: now)
            XCTAssertEqual(
                policy.activeUntil(for: conversation, lastActivityAt: now, calendar: calendar),
                now.addingTimeInterval(2 * day)
            )
        }
    }

    /// Pinning suspends expiry without rewriting the date.
    ///
    /// `activeUntil` stays the truthful "when would this have expired" value, and
    /// `isExpired` is the single place pinning is applied. Storing a
    /// non-expiring sentinel instead would outlive the pin.
    func testPinnedConversationDoesNotAutomaticallyExpire() {
        let now = date("2026-09-16T10:00:00-04:00")
        let lastActivity = date("2026-01-01T00:00:00-05:00")
        var conversation = AIConversation.fixture(
            lifecycleType: .dailyMeal, lastActivityAt: lastActivity, isPinned: true
        )
        conversation.activeUntil = policy.activeUntil(
            for: conversation, lastActivityAt: lastActivity, calendar: calendar
        )

        XCTAssertEqual(conversation.activeUntil, lastActivity.addingTimeInterval(2 * day))
        XCTAssertFalse(conversation.isExpired(now: now))
    }

    /// The reason the sentinel is gone: unpinning an old conversation must let it
    /// fall out of the active set immediately, with no recomputation required.
    func testUnpinningRestoresTheOriginalExpiry() {
        let now = date("2026-09-16T10:00:00-04:00")
        let lastActivity = date("2026-01-01T00:00:00-05:00")
        var conversation = AIConversation.fixture(
            lifecycleType: .dailyMeal, lastActivityAt: lastActivity, isPinned: true
        )
        conversation.activeUntil = policy.activeUntil(
            for: conversation, lastActivityAt: lastActivity, calendar: calendar
        )
        XCTAssertFalse(conversation.isExpired(now: now))

        conversation.isPinned = false
        XCTAssertTrue(conversation.isExpired(now: now))
    }

    /// Reactivation recalculates expiry from the moment the user continued, and
    /// stamps the policy version that produced it.
    func testRefreshedRecalculatesActivityAndExpiry() {
        let now = date("2026-09-16T10:00:00-04:00")
        let stale = AIConversation.fixture(
            lifecycleType: .dailyMeal, lastActivityAt: date("2026-09-10T10:00:00-04:00")
        )
        XCTAssertTrue(stale.isExpired(now: now))

        let refreshed = policy.refreshed(stale, now: now, calendar: calendar)
        XCTAssertEqual(refreshed.id, stale.id)
        XCTAssertEqual(refreshed.lastActivityAt, now)
        XCTAssertEqual(refreshed.activeUntil, now.addingTimeInterval(2 * day))
        XCTAssertEqual(refreshed.retentionPolicyVersion, policy.version)
        XCTAssertFalse(refreshed.isExpired(now: now))
    }

    /// Reactivating an anchored conversation still respects its anchor.
    func testRefreshedKeepsAnchorDrivenExpiry() {
        let now = date("2026-09-16T10:00:00-04:00")
        let event = date("2026-09-20T18:30:00-04:00")
        let refreshed = policy.refreshed(
            AIConversation.fixture(
                lifecycleType: .specialPlan,
                lastActivityAt: date("2026-09-01T10:00:00-04:00"),
                anchorDate: event
            ),
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(refreshed.activeUntil, event.addingTimeInterval(day))
    }

    func testPolicyVersionIsRecordedSoLaterTiersCanBeIdentified() {
        XCTAssertEqual(ConversationRetentionPolicy.v1.version, 1)
    }

    // MARK: - Affinity

    private func activeFixture(
        _ lifecycle: AIConversationLifecycleType,
        lastActivityAt: Date,
        anchorDate: Date? = nil,
        anchorEntityID: UUID? = nil,
        isPinned: Bool = false
    ) -> AIConversation {
        var conversation = AIConversation.fixture(
            lifecycleType: lifecycle,
            lastActivityAt: lastActivityAt,
            anchorDate: anchorDate,
            anchorEntityID: anchorEntityID,
            isPinned: isPinned
        )
        conversation.activeUntil = policy.activeUntil(
            for: conversation, lastActivityAt: lastActivityAt, calendar: calendar
        )
        return conversation
    }

    func testHomePrefersDailyMealOverGeneralAndIgnoresPlannerTasks() {
        let now = date("2026-09-16T10:00:00-04:00")
        let daily = activeFixture(.dailyMeal, lastActivityAt: now.addingTimeInterval(-3600))
        let general = activeFixture(.general, lastActivityAt: now)
        let weekly = activeFixture(
            .weeklyPlanning, lastActivityAt: now, anchorDate: date("2026-09-16T00:00:00-04:00")
        )

        let chosen = ConversationAffinityResolver().bestConversation(
            for: .home, from: [weekly, general, daily], now: now, calendar: calendar
        )
        XCTAssertEqual(chosen?.id, daily.id)
    }

    func testHomeFallsBackToGeneralWhenNoDailyMealConversationExists() {
        let now = date("2026-09-16T10:00:00-04:00")
        let general = activeFixture(.general, lastActivityAt: now)
        let chosen = ConversationAffinityResolver().bestConversation(
            for: .home, from: [general], now: now, calendar: calendar
        )
        XCTAssertEqual(chosen?.id, general.id)
    }

    func testPlannerMatchesTheDisplayedWeekRatherThanTheMostRecentTask() {
        let now = date("2026-09-16T10:00:00-04:00")
        let displayedWeek = date("2026-09-14T00:00:00-04:00")
        let thisWeek = activeFixture(
            .weeklyPlanning,
            lastActivityAt: now.addingTimeInterval(-7200),
            anchorDate: date("2026-09-16T00:00:00-04:00")
        )
        let otherWeek = activeFixture(
            .weeklyPlanning,
            lastActivityAt: now,
            anchorDate: date("2026-09-24T00:00:00-04:00")
        )
        let unrelatedDaily = activeFixture(.dailyMeal, lastActivityAt: now)

        let chosen = ConversationAffinityResolver().bestConversation(
            for: .planner(weekStart: displayedWeek, specialPlanID: nil),
            from: [otherWeek, unrelatedDaily, thisWeek],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(chosen?.id, thisWeek.id)
    }

    func testPlannerPrefersTheOpenedSpecialPlanAnchor() {
        let now = date("2026-09-16T10:00:00-04:00")
        let displayedWeek = date("2026-09-14T00:00:00-04:00")
        let specialPlanID = UUID()
        let special = activeFixture(
            .specialPlan,
            lastActivityAt: now.addingTimeInterval(-7200),
            anchorDate: date("2026-09-19T18:00:00-04:00"),
            anchorEntityID: specialPlanID
        )
        let weekly = activeFixture(
            .weeklyPlanning, lastActivityAt: now, anchorDate: date("2026-09-16T00:00:00-04:00")
        )

        let chosen = ConversationAffinityResolver().bestConversation(
            for: .planner(weekStart: displayedWeek, specialPlanID: specialPlanID),
            from: [weekly, special],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(chosen?.id, special.id)
    }

    /// No match must return nil so the entry surface shows a fresh contextual
    /// empty state instead of silently reopening an unrelated task.
    func testNoRelevantActiveConversationReturnsNil() {
        let now = date("2026-09-16T10:00:00-04:00")
        let unrelatedWeek = activeFixture(
            .weeklyPlanning, lastActivityAt: now, anchorDate: date("2026-10-20T00:00:00-04:00")
        )
        XCTAssertNil(
            ConversationAffinityResolver().bestConversation(
                for: .planner(weekStart: date("2026-09-14T00:00:00-04:00"), specialPlanID: nil),
                from: [unrelatedWeek],
                now: now,
                calendar: calendar
            )
        )
        XCTAssertNil(
            ConversationAffinityResolver().bestConversation(
                for: .home, from: [], now: now, calendar: calendar
            )
        )
    }

    func testExpiredConversationIsNeverSilentlyReopened() {
        let now = date("2026-09-16T10:00:00-04:00")
        var expired = activeFixture(.dailyMeal, lastActivityAt: date("2026-09-10T10:00:00-04:00"))
        XCTAssertTrue(expired.isExpired(now: now))
        expired.title = "上周的对话"

        XCTAssertNil(
            ConversationAffinityResolver().bestConversation(
                for: .home, from: [expired], now: now, calendar: calendar
            )
        )
    }

    func testPinnedConversationStaysSelectableAfterLongInactivity() {
        let now = date("2026-09-16T10:00:00-04:00")
        let pinned = activeFixture(
            .dailyMeal, lastActivityAt: date("2026-01-01T10:00:00-05:00"), isPinned: true
        )
        XCTAssertFalse(pinned.isExpired(now: now))
        XCTAssertEqual(
            ConversationAffinityResolver().bestConversation(
                for: .home, from: [pinned], now: now, calendar: calendar
            )?.id,
            pinned.id
        )
    }
}

// MARK: - Fixtures

extension AIConversation {
    /// Test-only fixture. Production code always derives `activeUntil` from the
    /// policy, so the fixture leaves it explicit rather than guessing here.
    static func fixture(
        id: UUID = UUID(),
        lifecycleType: AIConversationLifecycleType = .general,
        lastActivityAt: Date,
        anchorDate: Date? = nil,
        anchorEntityID: UUID? = nil,
        isPinned: Bool = false
    ) -> AIConversation {
        AIConversation(
            id: id,
            createdAt: lastActivityAt,
            title: AIConversation.defaultTitle,
            lifecycleType: lifecycleType,
            entryAffinity: AIConversationAffinity(lifecycleType: lifecycleType),
            lastActivityAt: lastActivityAt,
            activeUntil: lastActivityAt.addingTimeInterval(48 * 60 * 60),
            isPinned: isPinned,
            anchorDate: anchorDate,
            anchorEntityID: anchorEntityID
        )
    }
}

import XCTest
@testable import KitchenManager

/// The lifetime words are only safe if they stay true for pinned and archived
/// conversations too, and the deadline formatter must never follow the device
/// region. Both are pinned here with an injected calendar and clock.
final class AIConversationLifetimePresentationTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Toronto")!
        c.locale = Locale(identifier: "zh_Hans_CN")
        return c
    }()

    /// Sunday 2026-09-20 09:00 local.
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 9))!

    private func at(day: Int, month: Int = 9, year: Int = 2026, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func conversation(activeUntil: Date, isPinned: Bool = false) -> AIConversation {
        AIConversation(
            createdAt: now.addingTimeInterval(-3600),
            title: "今晚吃什么",
            lifecycleType: .dailyMeal,
            entryAffinity: .dailyMeal,
            lastActivityAt: now.addingTimeInterval(-3600),
            activeUntil: activeUntil,
            isPinned: isPinned
        )
    }

    // MARK: Deadline formatting

    func testSameDayReadsToday() {
        XCTAssertEqual(AIConversationLifetimePresentation.deadline(at(day: 20, hour: 18, minute: 30), now: now, calendar: calendar), "今天 18:30")
    }

    func testNextDayReadsTomorrowEvenAcrossMidnight() {
        XCTAssertEqual(AIConversationLifetimePresentation.deadline(at(day: 21, hour: 0, minute: 5), now: now, calendar: calendar), "明天 00:05")
    }

    func testTwoToSixDaysAheadReadsWeekday() {
        XCTAssertEqual(AIConversationLifetimePresentation.deadline(at(day: 22, hour: 10, minute: 42), now: now, calendar: calendar), "周二 10:42")
        XCTAssertEqual(AIConversationLifetimePresentation.deadline(at(day: 26, hour: 7, minute: 0), now: now, calendar: calendar), "周六 07:00")
    }

    func testSevenDaysOrMoreReadsMonthDay() {
        XCTAssertEqual(AIConversationLifetimePresentation.deadline(at(day: 27, hour: 10, minute: 42), now: now, calendar: calendar), "9月27日 10:42")
    }

    func testDifferentYearReadsFullDate() {
        XCTAssertEqual(AIConversationLifetimePresentation.deadline(at(day: 3, month: 1, year: 2027, hour: 10, minute: 42), now: now, calendar: calendar), "2027年1月3日 10:42")
    }

    func testTwentyFourHourClockWithNoSeconds() {
        let text = AIConversationLifetimePresentation.deadline(at(day: 20, hour: 21, minute: 5), now: now, calendar: calendar)
        XCTAssertEqual(text, "今天 21:05")
        XCTAssertFalse(text.contains("PM"))
    }

    // MARK: Overflow metadata

    func testDraftHasNoLifetime() {
        XCTAssertNil(AIConversationLifetimePresentation.overflow(for: conversation(activeUntil: now.addingTimeInterval(60)), isPersisted: false, now: now, calendar: calendar))
        XCTAssertNil(AIConversationLifetimePresentation.overflow(for: nil, isPersisted: true, now: now, calendar: calendar))
    }

    func testActiveShowsContinuityDeadline() {
        let overflow = AIConversationLifetimePresentation.overflow(for: conversation(activeUntil: at(day: 21, hour: 10, minute: 42)), isPersisted: true, now: now, calendar: calendar)
        XCTAssertEqual(overflow, "自动延续至 明天 10:42")
    }

    func testPinnedHidesItsDeadlineEvenWhenAlreadyPast() {
        let overflow = AIConversationLifetimePresentation.overflow(for: conversation(activeUntil: now.addingTimeInterval(-60), isPinned: true), isPersisted: true, now: now, calendar: calendar)
        XCTAssertEqual(overflow, "已置顶")
    }

    func testArchivedShowsNoOldDeadline() {
        let overflow = AIConversationLifetimePresentation.overflow(for: conversation(activeUntil: now.addingTimeInterval(-60)), isPersisted: true, now: now, calendar: calendar)
        XCTAssertEqual(overflow, "已归档")
    }

    func testNoConversationWordingUsesExpiry() {
        for text in [AIConversationLifetimePresentation.activePrefix, AIConversationLifetimePresentation.pinned,
                     AIConversationLifetimePresentation.archived, AIConversationLifetimePresentation.active] {
            XCTAssertFalse(text.contains("过期"), text)
        }
    }

    // MARK: History chip

    func testHistoryStatusPinnedArchivedActive() {
        XCTAssertEqual(AIConversationLifetimePresentation.status(for: conversation(activeUntil: now.addingTimeInterval(-1), isPinned: true), now: now), "已置顶")
        XCTAssertEqual(AIConversationLifetimePresentation.status(for: conversation(activeUntil: now.addingTimeInterval(-1)), now: now), "已归档")
        XCTAssertEqual(AIConversationLifetimePresentation.status(for: conversation(activeUntil: now.addingTimeInterval(1)), now: now), "活跃")
    }
}

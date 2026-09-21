import XCTest
@testable import KitchenManager

/// The compact day label exists so an unplanned day can repeat six times
/// without spending a header's worth of height on a date the week range above
/// already scopes. These pin the two things that could quietly break it: the
/// today branch, and the zh-Hans weekday/day form that keeps it one line.
final class PlannerDateTextTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Toronto")!
        c.locale = Locale(identifier: "zh_Hans_CN")
        return c
    }()

    /// Sunday 2026-09-20.
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 9))!

    private func day(_ d: Int, month: Int = 9, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: d, hour: 8))!
    }

    func testAnOrdinaryDayReadsWeekdayThenDayNumber() {
        XCTAssertEqual(PlannerDateText.compactDay(day(14), now: now, calendar: calendar), "周一 14日")
        XCTAssertEqual(PlannerDateText.compactDay(day(19), now: now, calendar: calendar), "周六 19日")
    }

    func testTodayNamesItselfRatherThanItsWeekday() {
        XCTAssertEqual(PlannerDateText.compactDay(day(20), now: now, calendar: calendar), "今天 20日")
    }

    /// Same weekday in another week is still that weekday, never 今天: the row
    /// is rendered for any displayed week, not only the current one.
    func testAnotherWeeksSundayIsNotToday() {
        XCTAssertEqual(PlannerDateText.compactDay(day(27), now: now, calendar: calendar), "周日 27日")
    }

    func testTheCompactLabelDropsTheMonthTheWeekRangeAlreadyCarries() {
        let compact = PlannerDateText.compactDay(day(14), now: now, calendar: calendar)
        XCTAssertFalse(compact.contains("月"), compact)
        // The full form is unchanged and remains the accessibility label.
        XCTAssertEqual(PlannerDateText.day(day(14), calendar: calendar), "9月14日 星期一")
    }

    func testCompactLabelStaysShortEnoughToHoldOneLine() {
        for d in 14...20 {
            let compact = PlannerDateText.compactDay(day(d), now: now, calendar: calendar)
            XCTAssertLessThanOrEqual(compact.count, 7, compact)
        }
    }

    func testSpokenDayIncludesTodayOnlyWhenMatchingNow() {
        let todaySpoken = PlannerDateText.spokenDay(day(20), now: now, calendar: calendar)
        XCTAssertTrue(todaySpoken.contains("今天"))
        XCTAssertEqual(todaySpoken, "9月20日 星期日 · 今天")

        let ordinarySpoken = PlannerDateText.spokenDay(day(14), now: now, calendar: calendar)
        XCTAssertFalse(ordinarySpoken.contains("今天"))
        XCTAssertEqual(ordinarySpoken, "9月14日 星期一")
    }
}

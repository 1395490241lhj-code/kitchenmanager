import XCTest
@testable import KitchenManager

/// Pure projection tests: merging normal meals with special plans on one week,
/// deterministic ordering, week boundaries, and DST handling under an injected
/// calendar (the same convention the rest of the repo uses for date logic).
final class PlannerProjectionTests: XCTestCase {
    private func makeCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        hour: Int = 0, minute: Int = 0,
        calendar: Calendar
    ) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    private func meal(_ id: String, date: Date, plannedServings: Int? = 2) -> MealPlanItem {
        MealPlanItem(id: UUID(), recipeID: id, recipeName: id, date: date, plannedServings: plannedServings)
    }

    private func special(_ id: String, date: Date, people: Int = 7) -> SpecialPlan {
        SpecialPlan(
            id: UUID(),
            title: id,
            scheduledAt: date,
            peopleCount: people
        )
    }

    private let utc = TimeZone(identifier: "UTC")!
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    // MARK: - Week anchor

    func testMondayIsTheWeekStart() {
        let calendar = makeCalendar(timeZone: utc)
        // Wed 2026-09-02 -> Monday 2026-08-31
        let wednesday = date(2026, 9, 2, calendar: calendar)
        let start = PlannerProjection.startOfWeek(containing: wednesday, calendar: calendar)
        let monday = date(2026, 8, 31, calendar: calendar)
        XCTAssertEqual(start, monday)
    }

    func testSundayBelongsToThePreviousWeek() {
        let calendar = makeCalendar(timeZone: utc)
        // Sunday 2026-09-06 -> Monday 2026-08-31 (Sunday ends the week)
        let sunday = date(2026, 9, 6, calendar: calendar)
        let start = PlannerProjection.startOfWeek(containing: sunday, calendar: calendar)
        XCTAssertEqual(start, date(2026, 8, 31, calendar: calendar))
    }

    // MARK: - Merge and ordering

    func testSameWeekMergesNormalMealAndSpecialPlan() {
        let calendar = makeCalendar(timeZone: utc)
        let start = date(2026, 8, 31, calendar: calendar)

        let meal = self.meal("牛肉面", date: date(2026, 9, 1, hour: 12, calendar: calendar))
        let special = self.special("朋友聚餐", date: date(2026, 9, 5, hour: 18, minute: 30, calendar: calendar))

        let entries = PlannerProjection.entries(
            inWeekStarting: start,
            meals: [meal],
            specialPlans: [special],
            calendar: calendar
        )
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map { $0.entryTypeName }, ["meal", "specialPlan"])
    }

    func testChronologicalOrderingWithinDay() {
        let calendar = makeCalendar(timeZone: utc)
        let start = date(2026, 8, 31, calendar: calendar)
        let day = date(2026, 9, 3, calendar: calendar)

        // Same day: special at 18:30, meal at noon.
        let meal = self.meal("午饭", date: date(2026, 9, 3, hour: 12, calendar: calendar))
        let earlySpecial = self.special("下午茶", date: date(2026, 9, 3, hour: 15, calendar: calendar))
        let lateSpecial = self.special("晚餐", date: date(2026, 9, 3, hour: 19, calendar: calendar))

        let entries = PlannerProjection.entries(
            inWeekStarting: start,
            meals: [meal],
            specialPlans: [lateSpecial, earlySpecial],
            calendar: calendar
        )
        // Meals first, then special plans by scheduledAt.
        XCTAssertEqual(entries.map { $0.entryTypeName }, ["meal", "specialPlan", "specialPlan"])
        guard case .specialPlan(let first) = entries[1],
              case .specialPlan(let second) = entries[2] else {
            return XCTFail("expected two special plans")
        }
        XCTAssertEqual(first.title, "下午茶")
        XCTAssertEqual(second.title, "晚餐")
    }

    func testStableIdentityPerEntry() {
        let calendar = makeCalendar(timeZone: utc)
        let start = date(2026, 8, 31, calendar: calendar)
        let m = self.meal("面", date: date(2026, 9, 1, calendar: calendar))
        let s = self.special("聚餐", date: date(2026, 9, 2, calendar: calendar))

        let entries = PlannerProjection.entries(
            inWeekStarting: start,
            meals: [m],
            specialPlans: [s],
            calendar: calendar
        )
        let ids = Set(entries.map(\.id))
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(ids.contains("meal-\(m.id.uuidString)"))
        XCTAssertTrue(ids.contains("special-\(s.id.uuidString)"))
    }

    // MARK: - Week boundary

    func testEntriesOutsideTheWeekAreExcluded() {
        let calendar = makeCalendar(timeZone: utc)
        let start = date(2026, 8, 31, calendar: calendar)
        let end = PlannerProjection.nextWeekStart(after: start, calendar: calendar)
        XCTAssertEqual(end, date(2026, 9, 7, calendar: calendar))

        let inWeek = self.special("周六聚餐", date: date(2026, 9, 5, calendar: calendar))
        let outsideBefore = self.special("上周", date: date(2026, 8, 30, calendar: calendar))
        let outsideAfter = self.special("下周", date: date(2026, 9, 7, calendar: calendar))

        let entries = PlannerProjection.entries(
            inWeekStarting: start,
            meals: [],
            specialPlans: [inWeek, outsideBefore, outsideAfter],
            calendar: calendar
        )
        XCTAssertEqual(entries.count, 1)
        guard case .specialPlan(let only) = entries[0] else {
            return XCTFail("expected the in-week special plan")
        }
        XCTAssertEqual(only.title, "周六聚餐")
    }

    func testDayGroupsCoverTheWholeWeekWithStableDays() {
        let calendar = makeCalendar(timeZone: utc)
        let start = date(2026, 8, 31, calendar: calendar)
        let groups = PlannerProjection.dayGroups(
            inWeekStarting: start,
            entries: [],
            calendar: calendar
        )
        XCTAssertEqual(groups.count, 7)
        XCTAssertEqual(groups.map { $0.id }, (0..<7).map {
            calendar.date(byAdding: .day, value: $0, to: start)!
        })
        // Empty days come back as empty groups, not dropped.
        XCTAssertTrue(groups.allSatisfy { $0.entries.isEmpty })
    }

    // MARK: - DST / calendar conventions

    func testWeekAnchorSurvivesDSTTransition() {
        // America/New_York: 2026-03-08 02:00 is the spring-forward.
        let calendar = makeCalendar(timeZone: newYork)
        // 2026-03-08 is a Sunday.
        let dstSunday = date(2026, 3, 8, calendar: calendar)
        let start = PlannerProjection.startOfWeek(containing: dstSunday, calendar: calendar)
        XCTAssertEqual(start, date(2026, 3, 2, calendar: calendar))

        // The week after the fall-back (2026-11-01 02:00 -> 01:00) is 2026-11-02 Monday.
        let fallBackWeek = PlannerProjection.startOfWeek(
            containing: date(2026, 11, 4, calendar: calendar),
            calendar: calendar
        )
        XCTAssertEqual(fallBackWeek, date(2026, 11, 2, calendar: calendar))
    }

    func testEntryGroupingUsesTheInjectedCalendarDay() {
        let utcCalendar = makeCalendar(timeZone: utc)
        let shanghaiCalendar = makeCalendar(timeZone: shanghai)
        // Week anchored in the *grouping* calendar: 2026-08-31 00:00 in UTC+8.
        let start = date(2026, 8, 31, calendar: shanghaiCalendar)
        let meal = self.meal("深夜面", date: date(2026, 8, 31, hour: 23, minute: 30, calendar: shanghaiCalendar))

        let entries = PlannerProjection.entries(
            inWeekStarting: start,
            meals: [meal],
            specialPlans: [],
            calendar: shanghaiCalendar
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].day(calendar: shanghaiCalendar), date(2026, 8, 31, calendar: shanghaiCalendar))

        // The same instant grouped under UTC is still Monday — grouping is pure
        // calendar projection, no arithmetic drift.
        XCTAssertEqual(entries[0].day(calendar: utcCalendar), date(2026, 8, 31, calendar: utcCalendar))
    }
}

extension PlannerEntry {
    fileprivate var entryTypeName: String {
        switch self {
        case .meal: "meal"
        case .specialPlan: "specialPlan"
        }
    }
}

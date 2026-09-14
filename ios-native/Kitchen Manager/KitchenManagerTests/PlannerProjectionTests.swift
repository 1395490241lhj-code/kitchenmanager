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

    // MARK: - Within-day meal order

    /// Insertion order a, b, c against a UUID order of c, b, a. If the tiebreak
    /// were still lexicographic the assertion below would read 三, 二, 一.
    private func adversarialMeals(on day: Date) -> [MealPlanItem] {
        let ids = [
            UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!,
            UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!,
            UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000003")!
        ]
        return zip(ids, ["一", "二", "三"]).map { id, name in
            MealPlanItem(id: id, recipeID: name, recipeName: name, date: day, plannedServings: 2)
        }
    }

    func testSameDayMealsFollowArrayOrderNotUUIDOrder() {
        let calendar = makeCalendar(timeZone: utc)
        let start = date(2026, 8, 31, calendar: calendar)
        let day = date(2026, 9, 3, hour: 12, calendar: calendar)
        let meals = adversarialMeals(on: day)
        XCTAssertGreaterThan(
            meals[0].id.uuidString, meals[2].id.uuidString,
            "the fixture must actually contradict lexicographic order"
        )

        let entries = PlannerProjection.entries(
            inWeekStarting: start,
            meals: meals,
            specialPlans: [],
            calendar: calendar
        )
        XCTAssertEqual(entries.map(\.mealName), ["一", "二", "三"])
    }

    func testAMealAppendedToPlansAppearsAfterTheExistingOnesOnItsDay() {
        let calendar = makeCalendar(timeZone: utc)
        let start = date(2026, 8, 31, calendar: calendar)
        let day = date(2026, 9, 3, hour: 12, calendar: calendar)
        var meals = adversarialMeals(on: day)
        meals.append(
            MealPlanItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                recipeID: "四", recipeName: "四", date: day, plannedServings: 2
            )
        )

        let entries = PlannerProjection.entries(
            inWeekStarting: start,
            meals: meals,
            specialPlans: [],
            calendar: calendar
        )
        XCTAssertEqual(
            entries.map(\.mealName), ["一", "二", "三", "四"],
            "a newly appended meal sorts last on its day even with the lowest UUID"
        )
    }

    func testArrayOrderSurvivesAMealMovedToAnotherDay() {
        let calendar = makeCalendar(timeZone: utc)
        let start = date(2026, 8, 31, calendar: calendar)
        let day = date(2026, 9, 3, hour: 12, calendar: calendar)
        var meals = adversarialMeals(on: day)
        // The middle meal moves a day later; the ones left behind keep their
        // relative order, and the moved one keeps its array position.
        meals[1].date = date(2026, 9, 4, hour: 12, calendar: calendar)
        meals.append(
            MealPlanItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                recipeID: "五", recipeName: "五",
                date: date(2026, 9, 4, hour: 12, calendar: calendar), plannedServings: 2
            )
        )

        let entries = PlannerProjection.entries(
            inWeekStarting: start,
            meals: meals,
            specialPlans: [],
            calendar: calendar
        )
        XCTAssertEqual(entries.map(\.mealName), ["一", "三", "二", "五"])
    }

    func testOrdinaryMealsStillPrecedeSpecialPlansOnTheSameDay() {
        let calendar = makeCalendar(timeZone: utc)
        let start = date(2026, 8, 31, calendar: calendar)
        let day = date(2026, 9, 3, hour: 12, calendar: calendar)
        let earlySpecial = self.special("早茶", date: date(2026, 9, 3, hour: 8, calendar: calendar))

        let entries = PlannerProjection.entries(
            inWeekStarting: start,
            meals: adversarialMeals(on: day),
            specialPlans: [earlySpecial],
            calendar: calendar
        )
        XCTAssertEqual(
            entries.map { $0.entryTypeName },
            ["meal", "meal", "meal", "specialPlan"],
            "a special plan scheduled earlier in the day still follows the ordinary meals"
        )
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

    // MARK: - Implicit creation date across a civil-day rollover

    /// The Planner holds its current day as view state. When that day advances
    /// — the app lived through midnight — an implicitly created meal must land
    /// on the new day, not on the one the Planner was built on.
    func testImplicitDefaultFollowsTheCurrentDayAcrossMidnight() {
        let calendar = makeCalendar(timeZone: shanghai)
        // Wed 2026-09-09, one minute either side of midnight.
        let weekStart = date(2026, 9, 7, calendar: calendar)
        let beforeMidnight = date(2026, 9, 9, hour: 23, minute: 59, calendar: calendar)
        let afterMidnight = date(2026, 9, 10, hour: 0, minute: 1, calendar: calendar)

        let before = PlannerProjection.defaultCreationDate(
            inWeekStarting: weekStart, now: beforeMidnight, calendar: calendar
        )
        let after = PlannerProjection.defaultCreationDate(
            inWeekStarting: weekStart, now: afterMidnight, calendar: calendar
        )

        XCTAssertTrue(calendar.isDate(before, inSameDayAs: date(2026, 9, 9, calendar: calendar)))
        XCTAssertTrue(calendar.isDate(after, inSameDayAs: date(2026, 9, 10, calendar: calendar)),
                      "a stale current day would still default to the 9th")
        XCTAssertFalse(calendar.isDate(before, inSameDayAs: after))
    }

    /// The rollover that also changes the week: Sunday night into Monday. The
    /// week on screen is no longer the current one, so the default stops being
    /// "now" and becomes the displayed week's own first day.
    func testSundayIntoMondayLeavesTheDisplayedWeekOwningTheDefault() {
        let calendar = makeCalendar(timeZone: shanghai)
        let weekStart = date(2026, 9, 7, calendar: calendar)
        let sundayNight = date(2026, 9, 13, hour: 23, minute: 59, calendar: calendar)
        let mondayMorning = date(2026, 9, 14, hour: 0, minute: 1, calendar: calendar)

        XCTAssertTrue(calendar.isDate(
            PlannerProjection.defaultCreationDate(inWeekStarting: weekStart, now: sundayNight, calendar: calendar),
            inSameDayAs: date(2026, 9, 13, calendar: calendar)
        ))
        XCTAssertEqual(
            PlannerProjection.defaultCreationDate(inWeekStarting: weekStart, now: mondayMorning, calendar: calendar),
            weekStart,
            "once the current day leaves the displayed week, the week on screen owns the default"
        )
    }

    /// An explicitly chosen week is a target, and the current day never
    /// displaces it — before or after a rollover.
    func testAnExplicitlyDisplayedWeekKeepsItsOwnDefault() {
        let calendar = makeCalendar(timeZone: shanghai)
        let nextWeek = date(2026, 9, 14, calendar: calendar)
        for now in [date(2026, 9, 9, hour: 23, minute: 59, calendar: calendar),
                    date(2026, 9, 10, hour: 0, minute: 1, calendar: calendar)] {
            XCTAssertEqual(
                PlannerProjection.defaultCreationDate(inWeekStarting: nextWeek, now: now, calendar: calendar),
                nextWeek
            )
        }
    }

    // MARK: - Time-zone changes

    /// The Planner stores one calendar for the life of the view. A snapshot
    /// keeps answering in the time zone it was taken in, so after the user's
    /// zone changes the civil day it reports is the old one — which is why
    /// production passes an autoupdating calendar.
    ///
    /// Deterministic: `TimeZone.default` is set by the test rather than by
    /// travelling, and restored before it returns.
    func testAutoupdatingCalendarFollowsATimeZoneChangeAndASnapshotDoesNot() {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }

        NSTimeZone.default = shanghai
        let snapshot = Calendar.current
        let following = Calendar.autoupdatingCurrent
        XCTAssertEqual(snapshot.timeZone.identifier, shanghai.identifier)
        XCTAssertEqual(following.timeZone.identifier, shanghai.identifier)

        NSTimeZone.default = newYork
        XCTAssertEqual(following.timeZone.identifier, newYork.identifier,
                       "an autoupdating calendar must follow the user's zone")
        XCTAssertEqual(snapshot.timeZone.identifier, shanghai.identifier,
                       "a captured calendar stays in the zone it was captured in")
    }

    /// The consequence that matters: one instant, two calendars. 2026-09-10
    /// 08:30 in Shanghai is still 2026-09-09 20:30 in New York, so a stale
    /// calendar would answer 今天 — and default a new meal — to the wrong
    /// civil day.
    func testCivilDayFollowsTheUpdatedZoneForTheImplicitDefault() {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }

        NSTimeZone.default = shanghai
        let snapshot = Calendar.current
        let following = Calendar.autoupdatingCurrent
        let instant = date(2026, 9, 10, hour: 8, minute: 30, calendar: makeCalendar(timeZone: shanghai))

        NSTimeZone.default = newYork
        let weekStart = PlannerProjection.startOfWeek(containing: instant, calendar: following)
        let defaulted = PlannerProjection.defaultCreationDate(
            inWeekStarting: weekStart, now: instant, calendar: following
        )

        XCTAssertEqual(following.component(.day, from: defaulted), 9,
                       "the updated zone puts this instant on the 9th")
        XCTAssertEqual(snapshot.component(.day, from: defaulted), 10,
                       "the captured zone still calls it the 10th")
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

    fileprivate var mealName: String {
        switch self {
        case .meal(let meal): meal.recipeName
        case .specialPlan(let plan): plan.title
        }
    }
}

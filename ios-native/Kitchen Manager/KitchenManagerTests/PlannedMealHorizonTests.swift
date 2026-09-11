import XCTest
@testable import KitchenManager

/// The seven-day window global restock reads: which scheduled meals count as
/// still ahead of a given day, and which do not.
///
/// Every test states its own calendar and timezone, so a machine set to another
/// zone cannot quietly change the answer.
final class PlannedMealHorizonTests: XCTestCase {
    private var calendar: Calendar = {
        var made = Calendar(identifier: .gregorian)
        made.timeZone = TimeZone(identifier: "America/Toronto")!
        return made
    }()

    /// Noon, so a test never accidentally proves something about midnight.
    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 12) -> Date {
        DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: year, month: month, day: dayOfMonth, hour: hour
        ).date!
    }

    private func meal(_ name: String, on date: Date, cooked: Bool = false) -> MealPlanItem {
        MealPlanItem(recipeID: name, recipeName: name, date: date, isCooked: cooked)
    }

    private func upcoming(_ plans: [MealPlanItem], from reference: Date) -> [String] {
        PlannedMealHorizon.upcoming(plans: plans, from: reference, calendar: calendar).map(\.recipeName)
    }

    // MARK: - Window edges

    func testTheReferenceDayItselfIsIncluded() {
        let today = day(2026, 5, 10)
        XCTAssertEqual(upcoming([meal("今天", on: today)], from: today), ["今天"])
    }

    func testTheSixthDayAheadIsStillIncluded() {
        let today = day(2026, 5, 10)
        let sixth = day(2026, 5, 16, hour: 23)
        XCTAssertEqual(upcoming([meal("第七天", on: sixth)], from: today), ["第七天"])
    }

    func testTheSeventhDayAheadIsOutside() {
        let today = day(2026, 5, 10)
        let seventh = day(2026, 5, 17, hour: 0)
        XCTAssertEqual(upcoming([meal("第八天", on: seventh)], from: today), [])
    }

    func testYesterdayIsOutside() {
        let today = day(2026, 5, 10)
        XCTAssertEqual(upcoming([meal("昨天", on: day(2026, 5, 9, hour: 23))], from: today), [])
    }

    // MARK: - Cooked meals

    func testAMealAlreadyCookedTodayDoesNotCount() {
        let today = day(2026, 5, 10)
        XCTAssertEqual(upcoming([meal("已做好", on: today, cooked: true)], from: today), [])
    }

    func testAFutureMealMarkedCookedDoesNotCount() {
        let today = day(2026, 5, 10)
        let later = day(2026, 5, 13)
        XCTAssertEqual(upcoming([meal("提前做好", on: later, cooked: true)], from: today), [])
    }

    // MARK: - What comes out, and in what order

    func testEveryMealOnOneDaySurvives() {
        let today = day(2026, 5, 10)
        let plans = [meal("午餐", on: today), meal("晚餐", on: today), meal("宵夜", on: today)]
        XCTAssertEqual(upcoming(plans, from: today), ["午餐", "晚餐", "宵夜"])
    }

    func testTheOrderIsTheOneThePlanAlreadyHas() {
        // Deliberately out of date order: this is a filter, and re-sorting here
        // would invent a presentation rule the caller never asked for.
        let today = day(2026, 5, 10)
        let plans = [
            meal("后天", on: day(2026, 5, 12)),
            meal("今天", on: today),
            meal("明天", on: day(2026, 5, 11))
        ]
        XCTAssertEqual(upcoming(plans, from: today), ["后天", "今天", "明天"])
    }

    func testTheWindowCrossesTheEndOfTheWeek() {
        // Friday through the following Monday: a calendar week would cut this
        // window in half, and the horizon must not.
        let friday = day(2026, 1, 2)
        XCTAssertEqual(calendar.component(.weekday, from: friday), 6, "fixture drifted: expected a Friday")
        let sunday = day(2026, 1, 4)
        let monday = day(2026, 1, 5)
        XCTAssertEqual(calendar.component(.weekday, from: monday), 2, "fixture drifted: expected a Monday")
        XCTAssertEqual(
            upcoming([meal("周日", on: sunday), meal("周一", on: monday)], from: friday),
            ["周日", "周一"]
        )
    }

    func testTheWindowIsSevenCivilDaysAcrossADaylightSavingShift() {
        // Toronto springs forward on 8 March 2026, so the six days after the
        // 6th are 23 hours short of six times 24. Counting seconds would drop
        // the last evening; counting days keeps it.
        let friday = day(2026, 3, 6)
        let shiftDay = day(2026, 3, 8)
        let lastDay = day(2026, 3, 12, hour: 20)
        let justOutside = day(2026, 3, 13, hour: 0)
        XCTAssertEqual(
            upcoming([meal("换钟那天", on: shiftDay), meal("第七天", on: lastDay), meal("第八天", on: justOutside)], from: friday),
            ["换钟那天", "第七天"]
        )
    }
}

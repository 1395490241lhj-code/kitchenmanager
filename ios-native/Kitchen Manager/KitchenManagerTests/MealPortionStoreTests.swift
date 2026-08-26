import XCTest
@testable import KitchenManager

@MainActor
final class MealPortionStoreTests: XCTestCase {
    private final class TestClock {
        var date: Date

        init(date: Date) {
            self.date = date
        }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MealPortionStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeCalendar(
        firstWeekday: Int = 1,
        timeZoneIdentifier: String = "Asia/Shanghai"
    ) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func makeDate(
        year: Int = 2026, month: Int = 8, day: Int, hour: Int = 19,
        in calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func makeStore(clock: TestClock, calendar: Calendar) -> MealPortionStore {
        MealPortionStore(
            userDefaults: defaults,
            currentDate: { clock.date },
            calendar: { calendar }
        )
    }

    /// Cooking evening: 2026-08-26. Target lunch day: 2026-08-27.
    private func cookingEvening() -> (MealPortionStore, TestClock, Calendar) {
        let calendar = makeCalendar()
        let clock = TestClock(date: makeDate(day: 26, in: calendar))
        return (makeStore(clock: clock, calendar: calendar), clock, calendar)
    }

    private func nextDay(_ clock: TestClock, _ calendar: Calendar, hour: Int = 12) {
        clock.date = makeDate(day: 27, hour: hour, in: calendar)
    }

    // MARK: - Unset semantics

    func testUnsetPortionsStayNilAndProduceNoTotal() {
        let (store, clock, calendar) = cookingEvening()

        let plan = store.portionPlan(for: clock.date, slot: .dinner)
        XCTAssertNil(plan.currentMealPortions)
        XCTAssertEqual(plan.reservedForNextLunchPortions, 0)
        XCTAssertNil(plan.totalPlannedPortions, "a total must not be fabricated while portions are unset")
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(MealPortionCopy.currentMeal(plan.currentMealPortions), "未设置")
        XCTAssertEqual(MealPortionCopy.total(plan.totalPlannedPortions), "未设置")
        XCTAssertNil(store.incomingReservation(for: makeDate(day: 27, in: calendar), slot: .lunch))
    }

    func testZeroIsPersistedAsUnsetRatherThanAsZeroPortions() {
        let (store, clock, _) = cookingEvening()

        store.setCurrentMealPortions(2, on: clock.date, slot: .dinner)
        XCTAssertEqual(store.portionPlan(for: clock.date, slot: .dinner).currentMealPortions, 2)

        store.setCurrentMealPortions(0, on: clock.date, slot: .dinner)
        let plan = store.portionPlan(for: clock.date, slot: .dinner)
        XCTAssertNil(plan.currentMealPortions)
        XCTAssertTrue(store.currentPortionEntries.isEmpty, "0 must delete the entry, never store a 0")
        XCTAssertNil(defaults.data(forKey: MealPortionStore.storageKey))

        store.setCurrentMealPortions(nil, on: clock.date, slot: .dinner)
        XCTAssertNil(store.portionPlan(for: clock.date, slot: .dinner).currentMealPortions)
    }

    func testTotalIsComputedAndNeverPersisted() throws {
        let (store, clock, _) = cookingEvening()

        store.setCurrentMealPortions(2, on: clock.date, slot: .dinner)
        store.setReservedForNextLunchPortions(1, from: clock.date)

        let plan = store.portionPlan(for: clock.date, slot: .dinner)
        XCTAssertEqual(plan.currentMealPortions, 2)
        XCTAssertEqual(plan.reservedForNextLunchPortions, 1)
        XCTAssertEqual(plan.totalPlannedPortions, 3)
        XCTAssertEqual(MealPortionCopy.total(plan.totalPlannedPortions), "3 份")

        let data = try XCTUnwrap(defaults.data(forKey: MealPortionStore.storageKey))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("total"), "the total must stay a computed value, not a stored one")
    }

    func testReservationAloneDoesNotInventATotal() {
        let (store, clock, _) = cookingEvening()

        store.setReservedForNextLunchPortions(1, from: clock.date)

        let plan = store.portionPlan(for: clock.date, slot: .dinner)
        XCTAssertNil(plan.currentMealPortions)
        XCTAssertEqual(plan.reservedForNextLunchPortions, 1)
        XCTAssertNil(plan.totalPlannedPortions)
        XCTAssertTrue(plan.hasReservation)
        XCTAssertFalse(plan.isEmpty)
    }

    // MARK: - Reservation shape

    func testReservationTargetsTheFollowingDayLunch() throws {
        let (store, clock, calendar) = cookingEvening()

        store.setReservedForNextLunchPortions(1, from: clock.date)

        let reservation = try XCTUnwrap(store.reservations.first)
        XCTAssertEqual(reservation.sourceSlot, .dinner)
        XCTAssertEqual(reservation.targetSlot, .lunch)
        XCTAssertEqual(reservation.portions, 1)
        XCTAssertEqual(reservation.sourceDate, calendar.startOfDay(for: makeDate(day: 26, in: calendar)))
        XCTAssertEqual(reservation.targetDate, calendar.startOfDay(for: makeDate(day: 27, in: calendar)))
    }

    func testRepeatedReservationUpsertsInsteadOfAccumulating() {
        let (store, clock, _) = cookingEvening()

        store.setReservedForNextLunchPortions(1, from: clock.date)
        store.setReservedForNextLunchPortions(2, from: clock.date)

        XCTAssertEqual(store.reservations.count, 1)
        XCTAssertEqual(store.portionPlan(for: clock.date, slot: .dinner).reservedForNextLunchPortions, 2)
    }

    func testSettingReservationToZeroDeletesIt() {
        let (store, clock, calendar) = cookingEvening()
        store.setReservedForNextLunchPortions(2, from: clock.date)

        store.setReservedForNextLunchPortions(0, from: clock.date)

        XCTAssertTrue(store.reservations.isEmpty)
        XCTAssertEqual(store.portionPlan(for: clock.date, slot: .dinner).reservedForNextLunchPortions, 0)
        XCTAssertNil(store.incomingReservation(for: makeDate(day: 27, in: calendar), slot: .lunch))
    }

    func testPortionsAreClampedToOneThroughTwelve() {
        let (store, clock, _) = cookingEvening()

        store.setCurrentMealPortions(99, on: clock.date, slot: .dinner)
        XCTAssertEqual(store.portionPlan(for: clock.date, slot: .dinner).currentMealPortions, 12)

        store.setCurrentMealPortions(-3, on: clock.date, slot: .dinner)
        XCTAssertNil(store.portionPlan(for: clock.date, slot: .dinner).currentMealPortions)

        store.setReservedForNextLunchPortions(50, from: clock.date)
        XCTAssertEqual(store.portionPlan(for: clock.date, slot: .dinner).reservedForNextLunchPortions, 12)
    }

    // MARK: - Lifetime: the whole point of the feature

    func testReservationSurvivesRestartOnTheSameEvening() {
        let (store, clock, calendar) = cookingEvening()
        store.setCurrentMealPortions(2, on: clock.date, slot: .dinner)
        store.setReservedForNextLunchPortions(1, from: clock.date)

        clock.date = makeDate(day: 26, hour: 22, in: calendar)
        let restarted = makeStore(clock: clock, calendar: calendar)

        let plan = restarted.portionPlan(for: clock.date, slot: .dinner)
        XCTAssertEqual(plan.currentMealPortions, 2)
        XCTAssertEqual(plan.reservedForNextLunchPortions, 1)
        XCTAssertEqual(plan.totalPlannedPortions, 3)
    }

    func testReservationBecomesTheTargetDaysIncomingReservationAfterMidnight() {
        let (store, clock, calendar) = cookingEvening()
        store.setReservedForNextLunchPortions(1, from: clock.date)

        nextDay(clock, calendar)
        store.refreshForCurrentDay()

        let incoming = store.incomingReservation(for: clock.date, slot: .lunch)
        XCTAssertEqual(incoming?.portions, 1)
        XCTAssertEqual(MealPortionCopy.targetDaySummary(1), "午餐已留 1 份")
        XCTAssertEqual(MealPortionCopy.targetDayRow(1), "昨晚留的 1 份")
    }

    func testReservationSurvivesMidnightAcrossRestart() {
        let (store, clock, calendar) = cookingEvening()
        store.setReservedForNextLunchPortions(1, from: clock.date)

        nextDay(clock, calendar)
        let restarted = makeStore(clock: clock, calendar: calendar)

        XCTAssertEqual(restarted.incomingReservation(for: clock.date, slot: .lunch)?.portions, 1)
    }

    func testSourceDayCurrentPortionsExpireButTheReservationDoesNot() {
        let (store, clock, calendar) = cookingEvening()
        store.setCurrentMealPortions(2, on: clock.date, slot: .dinner)
        store.setReservedForNextLunchPortions(1, from: clock.date)
        let cookingDay = clock.date

        nextDay(clock, calendar)
        store.refreshForCurrentDay()

        XCTAssertNil(store.portionPlan(for: cookingDay, slot: .dinner).currentMealPortions)
        XCTAssertTrue(store.currentPortionEntries.isEmpty)
        XCTAssertEqual(store.incomingReservation(for: clock.date, slot: .lunch)?.portions, 1)
    }

    func testReservationIsPrunedOnceItsTargetDayHasPassed() {
        let (store, clock, calendar) = cookingEvening()
        store.setReservedForNextLunchPortions(1, from: clock.date)

        clock.date = makeDate(day: 28, hour: 12, in: calendar)
        store.refreshForCurrentDay()

        XCTAssertTrue(store.reservations.isEmpty)
        XCTAssertNil(store.incomingReservation(for: clock.date, slot: .lunch))
        XCTAssertNil(defaults.data(forKey: MealPortionStore.storageKey))
    }

    func testSkippingSeveralDaysPrunesSilentlyWithoutLeftovers() {
        let (store, clock, calendar) = cookingEvening()
        store.setCurrentMealPortions(3, on: clock.date, slot: .dinner)
        store.setReservedForNextLunchPortions(2, from: clock.date)

        clock.date = makeDate(day: 31, hour: 9, in: calendar)
        let restarted = makeStore(clock: clock, calendar: calendar)

        XCTAssertTrue(restarted.reservations.isEmpty)
        XCTAssertTrue(restarted.currentPortionEntries.isEmpty)
        XCTAssertNil(restarted.incomingReservation(for: clock.date, slot: .lunch))
    }

    /// Home reads `portionPlan` / `incomingReservation` inside `body`; clearing
    /// expired rows there would publish a change from within a view update.
    func testReadsDoNotMutateStateOnDayChange() {
        let (store, clock, calendar) = cookingEvening()
        store.setCurrentMealPortions(2, on: clock.date, slot: .dinner)
        store.setReservedForNextLunchPortions(1, from: clock.date)
        let cookingDay = clock.date

        clock.date = makeDate(day: 28, hour: 12, in: calendar)

        XCTAssertNil(store.portionPlan(for: cookingDay, slot: .dinner).currentMealPortions)
        XCTAssertEqual(store.portionPlan(for: cookingDay, slot: .dinner).reservedForNextLunchPortions, 0)
        XCTAssertNil(store.incomingReservation(for: clock.date, slot: .lunch))
        // Ignored, not deleted.
        XCTAssertEqual(store.currentPortionEntries.count, 1)
        XCTAssertEqual(store.reservations.count, 1)
        XCTAssertNotNil(defaults.data(forKey: MealPortionStore.storageKey))

        store.refreshForCurrentDay()
        XCTAssertTrue(store.currentPortionEntries.isEmpty)
        XCTAssertTrue(store.reservations.isEmpty)
        XCTAssertNil(defaults.data(forKey: MealPortionStore.storageKey))
    }

    // MARK: - Cancel / reset

    func testTargetDayCancellationRemovesTheReservationForBothSides() {
        let (store, clock, calendar) = cookingEvening()
        let cookingDay = clock.date
        store.setCurrentMealPortions(2, on: cookingDay, slot: .dinner)
        store.setReservedForNextLunchPortions(1, from: cookingDay)

        nextDay(clock, calendar)
        store.cancelIncomingReservation(on: clock.date, slot: .lunch)

        XCTAssertNil(store.incomingReservation(for: clock.date, slot: .lunch))
        XCTAssertEqual(store.portionPlan(for: cookingDay, slot: .dinner).reservedForNextLunchPortions, 0)
        XCTAssertTrue(store.reservations.isEmpty)
    }

    func testSourceDayCancellationIsVisibleToTheTargetDayImmediately() {
        let (store, clock, calendar) = cookingEvening()
        store.setReservedForNextLunchPortions(1, from: clock.date)
        let targetDay = makeDate(day: 27, in: calendar)
        XCTAssertNotNil(store.incomingReservation(for: targetDay, slot: .lunch))

        store.setReservedForNextLunchPortions(0, from: clock.date)

        XCTAssertNil(store.incomingReservation(for: targetDay, slot: .lunch))
    }

    func testResetClearsTodaysArrangementButNotFoodLeftFromYesterday() {
        let (store, clock, calendar) = cookingEvening()
        // Yesterday's dinner left something for today's lunch …
        store.setReservedForNextLunchPortions(1, from: makeDate(day: 25, in: calendar))
        // … and today the user also plans dinner plus a reservation for tomorrow.
        store.setCurrentMealPortions(2, on: clock.date, slot: .dinner)
        store.setReservedForNextLunchPortions(1, from: clock.date)

        store.resetPortions(on: clock.date)

        XCTAssertNil(store.portionPlan(for: clock.date, slot: .dinner).currentMealPortions)
        XCTAssertEqual(store.portionPlan(for: clock.date, slot: .dinner).reservedForNextLunchPortions, 0)
        XCTAssertEqual(
            store.incomingReservation(for: clock.date, slot: .lunch)?.portions,
            1,
            "food arranged yesterday is not today's decision to reset"
        )
    }

    // MARK: - Calendar / timezone

    func testDayBoundaryFollowsTheInjectedCalendarTimezone() {
        // Both instants are still Wednesday 08-26 in Los Angeles, but the second
        // is already Thursday 08-27 in UTC.
        let losAngeles = makeCalendar(timeZoneIdentifier: "America/Los_Angeles")
        let utc = makeCalendar(timeZoneIdentifier: "UTC")
        let evening = makeDate(day: 27, hour: 2, in: utc) // 19:00 Wed in LA
        let clock = TestClock(date: makeDate(day: 26, hour: 22, in: utc)) // 15:00 Wed in LA
        let store = makeStore(clock: clock, calendar: losAngeles)

        store.setReservedForNextLunchPortions(1, from: clock.date)
        clock.date = evening
        store.refreshForCurrentDay()

        // Still the cooking day in LA: the reservation is pending, not incoming.
        XCTAssertNil(store.incomingReservation(for: clock.date, slot: .lunch))
        XCTAssertEqual(store.portionPlan(for: clock.date, slot: .dinner).reservedForNextLunchPortions, 1)

        // Once LA itself rolls over, the same reservation becomes today's lunch.
        clock.date = makeDate(day: 27, hour: 20, in: utc) // 13:00 Thu in LA
        store.refreshForCurrentDay()
        XCTAssertEqual(store.incomingReservation(for: clock.date, slot: .lunch)?.portions, 1)
    }

    func testFirstWeekdayDoesNotAffectSourceOrTargetDates() throws {
        let sundayFirst = makeCalendar(firstWeekday: 1)
        let mondayFirst = makeCalendar(firstWeekday: 2)
        let clock = TestClock(date: makeDate(day: 26, in: sundayFirst))

        let store = makeStore(clock: clock, calendar: sundayFirst)
        store.setReservedForNextLunchPortions(1, from: clock.date)
        let fromSundayFirst = try XCTUnwrap(store.reservations.first)

        defaults.removePersistentDomain(forName: suiteName)
        let otherStore = makeStore(clock: clock, calendar: mondayFirst)
        otherStore.setReservedForNextLunchPortions(1, from: clock.date)
        let fromMondayFirst = try XCTUnwrap(otherStore.reservations.first)

        XCTAssertEqual(fromSundayFirst.sourceDate, fromMondayFirst.sourceDate)
        XCTAssertEqual(fromSundayFirst.targetDate, fromMondayFirst.targetDate)
    }

    // MARK: - Persistence robustness

    func testUnknownSlotRowsAreDroppedWithoutLosingTheRestOfThePayload() throws {
        let calendar = makeCalendar()
        let clock = TestClock(date: makeDate(day: 26, in: calendar))
        let day = calendar.startOfDay(for: clock.date)
        let target = calendar.date(byAdding: .day, value: 1, to: day)!

        struct RawEntry: Encodable { let date: Date; let slot: String; let portions: Int }
        struct RawReservation: Encodable {
            let sourceDate: Date; let sourceSlot: String
            let targetDate: Date; let targetSlot: String; let portions: Int
        }
        struct RawPayload: Encodable {
            let currentPortions: [RawEntry]
            let reservations: [RawReservation]
        }
        let payload = RawPayload(
            currentPortions: [
                RawEntry(date: day, slot: "brunch", portions: 4), // unknown slot
                RawEntry(date: day, slot: "dinner", portions: 2)
            ],
            reservations: [
                RawReservation(sourceDate: day, sourceSlot: "dinner", targetDate: target, targetSlot: "supper", portions: 1), // unknown target
                RawReservation(sourceDate: day, sourceSlot: "dinner", targetDate: target, targetSlot: "lunch", portions: 0), // non-positive
                RawReservation(sourceDate: day, sourceSlot: "dinner", targetDate: target, targetSlot: "lunch", portions: 1)
            ]
        )
        defaults.set(try JSONEncoder().encode(payload), forKey: MealPortionStore.storageKey)

        let store = makeStore(clock: clock, calendar: calendar)

        XCTAssertEqual(store.portionPlan(for: clock.date, slot: .dinner).currentMealPortions, 2)
        XCTAssertEqual(store.reservations.count, 1)
        XCTAssertEqual(store.incomingReservation(for: target, slot: .lunch)?.portions, 1)
    }

    func testMalformedPayloadDoesNotCrashAndStaysWritable() {
        let calendar = makeCalendar()
        let clock = TestClock(date: makeDate(day: 26, in: calendar))
        defaults.set("not json", forKey: MealPortionStore.storageKey)

        let store = makeStore(clock: clock, calendar: calendar)
        XCTAssertNil(store.portionPlan(for: clock.date, slot: .dinner).currentMealPortions)
        XCTAssertNil(store.incomingReservation(for: clock.date, slot: .lunch))

        store.setCurrentMealPortions(2, on: clock.date, slot: .dinner)
        store.setReservedForNextLunchPortions(1, from: clock.date)
        let restarted = makeStore(clock: clock, calendar: calendar)
        XCTAssertEqual(restarted.portionPlan(for: clock.date, slot: .dinner).totalPlannedPortions, 3)
    }
}

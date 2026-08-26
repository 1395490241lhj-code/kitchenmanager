import XCTest
@testable import KitchenManager

@MainActor
final class DayRhythmStoreTests: XCTestCase {
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
        suiteName = "DayRhythmStoreTests-\(UUID().uuidString)"
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
        year: Int = 2026, month: Int = 8, day: Int, hour: Int = 12,
        in calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func makeStore(
        clock: TestClock,
        calendar: Calendar
    ) -> DayRhythmStore {
        DayRhythmStore(
            userDefaults: defaults,
            currentDate: { clock.date },
            calendar: { calendar }
        )
    }

    // 2026-08-24 is a Monday, 2026-08-25 a Tuesday.
    private func mondayStore(calendar: Calendar? = nil) -> (DayRhythmStore, TestClock, Calendar) {
        let calendar = calendar ?? makeCalendar()
        let clock = TestClock(date: makeDate(day: 24, in: calendar))
        return (makeStore(clock: clock, calendar: calendar), clock, calendar)
    }

    // MARK: - Defaults

    func testUnconfiguredStoreFallsBackToFlexibleAndHousehold() {
        let (store, clock, calendar) = mondayStore()

        XCTAssertEqual(store.effectiveDayType(), .flexible)
        XCTAssertEqual(store.effectiveDayType(for: makeDate(day: 30, in: calendar)), .flexible)
        for weekday in Weekday.allCases {
            XCTAssertEqual(store.weeklyDefault(for: weekday), .flexible)
        }
        XCTAssertEqual(store.intent(for: .lunch), .household)
        XCTAssertEqual(store.intent(for: .dinner), .household)
        XCTAssertFalse(store.isTodayOverridden)
        XCTAssertEqual(clock.date, makeDate(day: 24, in: calendar))
    }

    // MARK: - Weekly defaults

    func testWeeklyDefaultSetAndReadPerWeekday() {
        let (store, _, calendar) = mondayStore()

        store.setWeeklyDefault(.cooking, for: .monday)
        store.setWeeklyDefault(.quick, for: .tuesday)
        store.setWeeklyDefault(.mealPrep, for: .sunday)

        XCTAssertEqual(store.weeklyDefault(for: .monday), .cooking)
        XCTAssertEqual(store.weeklyDefault(for: .tuesday), .quick)
        XCTAssertEqual(store.weeklyDefault(for: .sunday), .mealPrep)
        XCTAssertEqual(store.weeklyDefault(for: .friday), .flexible)
        XCTAssertEqual(store.effectiveDayType(), .cooking)
        XCTAssertEqual(store.effectiveDayType(for: makeDate(day: 25, in: calendar)), .quick)
    }

    func testWeeklyDefaultsSurviveStoreRecreation() {
        let (store, clock, calendar) = mondayStore()
        store.setWeeklyDefault(.cooking, for: .monday)
        store.setWeeklyDefault(.quick, for: .saturday)

        let restarted = makeStore(clock: clock, calendar: calendar)

        XCTAssertEqual(restarted.weeklyDefault(for: .monday), .cooking)
        XCTAssertEqual(restarted.weeklyDefault(for: .saturday), .quick)
        XCTAssertEqual(restarted.weeklyDefault(for: .wednesday), .flexible)
    }

    // MARK: - Today override

    func testTodayOverrideAppliesToday() {
        let (store, _, _) = mondayStore()
        store.setWeeklyDefault(.cooking, for: .monday)

        store.overrideToday(with: .quick)

        XCTAssertEqual(store.effectiveDayType(), .quick)
        XCTAssertTrue(store.isTodayOverridden)
    }

    func testTodayOverrideDoesNotModifyWeeklyDefault() {
        let (store, _, _) = mondayStore()
        store.setWeeklyDefault(.cooking, for: .monday)

        store.overrideToday(with: .mealPrep)

        XCTAssertEqual(store.weeklyDefault(for: .monday), .cooking)
    }

    func testTodayOverrideSurvivesRestartWithinSameDay() {
        let (store, clock, calendar) = mondayStore()
        store.overrideToday(with: .mealPrep)

        clock.date = makeDate(day: 24, hour: 22, in: calendar)
        let restarted = makeStore(clock: clock, calendar: calendar)

        XCTAssertEqual(restarted.effectiveDayType(), .mealPrep)
        XCTAssertTrue(restarted.isTodayOverridden)
    }

    func testOverrideExpiresAfterDayChange() {
        let (store, clock, calendar) = mondayStore()
        store.setWeeklyDefault(.cooking, for: .monday)
        store.overrideToday(with: .quick)

        clock.date = makeDate(day: 25, in: calendar)
        store.refreshForCurrentDay()

        XCTAssertFalse(store.isTodayOverridden)
        XCTAssertNil(defaults.data(forKey: DayRhythmStore.todayStateKey))
    }

    func testMealIntentsExpireAfterDayChange() {
        let (store, clock, calendar) = mondayStore()
        store.setIntent(.eatOut, for: .lunch)
        store.setIntent(.eatOut, for: .dinner)

        clock.date = makeDate(day: 25, in: calendar)

        // Reading alone already reports the new day's defaults …
        XCTAssertEqual(store.intent(for: .lunch), .household)
        XCTAssertEqual(store.intent(for: .dinner), .household)

        // … and the explicit refresh is what drops the stale payload.
        store.refreshForCurrentDay()
        XCTAssertNil(defaults.data(forKey: DayRhythmStore.todayStateKey))
        XCTAssertEqual(store.intent(for: .lunch), .household)
    }

    /// Reads must not mutate published state: Home renders `effectiveDayType()`
    /// and `intent(for:)` inside `body`, and clearing expired state there would
    /// publish a change from within a view update.
    func testReadsDoNotMutateStateOnDayChange() {
        let (store, clock, calendar) = mondayStore()
        store.overrideToday(with: .quick)
        store.setIntent(.eatOut, for: .lunch)

        clock.date = makeDate(day: 25, in: calendar)

        XCTAssertEqual(store.effectiveDayType(), .flexible)
        XCTAssertFalse(store.isTodayOverridden)
        XCTAssertFalse(store.isTodayCustomized)
        XCTAssertEqual(store.intent(for: .lunch), .household)
        // Nothing was published or deleted — only ignored.
        XCTAssertEqual(store.todayOverride, .quick)
        XCTAssertEqual(store.todayMealIntents[.lunch], .eatOut)
        XCTAssertNotNil(defaults.data(forKey: DayRhythmStore.todayStateKey))

        store.refreshForCurrentDay()
        XCTAssertNil(store.todayOverride)
        XCTAssertTrue(store.todayMealIntents.isEmpty)
        XCTAssertNil(defaults.data(forKey: DayRhythmStore.todayStateKey))
    }

    func testResetTodayClearsOverrideAndBothMealIntents() {
        let (store, clock, calendar) = mondayStore()
        store.setWeeklyDefault(.cooking, for: .monday)
        store.overrideToday(with: .quick)
        store.setIntent(.eatOut, for: .lunch)
        store.setIntent(.eatOut, for: .dinner)
        XCTAssertTrue(store.isTodayCustomized)

        store.resetToday()

        XCTAssertEqual(store.effectiveDayType(), .cooking)
        XCTAssertFalse(store.isTodayOverridden)
        XCTAssertFalse(store.isTodayCustomized)
        XCTAssertEqual(store.intent(for: .lunch), .household)
        XCTAssertEqual(store.intent(for: .dinner), .household)
        XCTAssertNil(defaults.data(forKey: DayRhythmStore.todayStateKey))

        // Weekly defaults are a separate preference and must survive the reset,
        // including across a restart.
        let restarted = makeStore(clock: clock, calendar: calendar)
        XCTAssertEqual(restarted.weeklyDefault(for: .monday), .cooking)
        XCTAssertFalse(restarted.isTodayCustomized)
    }

    func testTodayWeeklyDefaultTracksTodaysWeekday() {
        let (store, clock, calendar) = mondayStore()
        store.setWeeklyDefault(.cooking, for: .monday)
        store.setWeeklyDefault(.mealPrep, for: .tuesday)

        XCTAssertEqual(store.todayWeekday, .monday)
        XCTAssertEqual(store.todayWeeklyDefault, .cooking)

        clock.date = makeDate(day: 25, in: calendar)
        XCTAssertEqual(store.todayWeekday, .tuesday)
        XCTAssertEqual(store.todayWeeklyDefault, .mealPrep)
    }

    func testNextDayFallsBackToThatWeekdaysDefault() {
        let (store, clock, calendar) = mondayStore()
        store.setWeeklyDefault(.cooking, for: .monday)
        store.setWeeklyDefault(.mealPrep, for: .tuesday)
        store.overrideToday(with: .quick)
        XCTAssertEqual(store.effectiveDayType(), .quick)

        clock.date = makeDate(day: 25, in: calendar)
        store.refreshForCurrentDay()

        XCTAssertEqual(store.effectiveDayType(), .mealPrep)
    }

    func testClearTodayOverridePreservesMealIntents() {
        let (store, clock, calendar) = mondayStore()
        store.setWeeklyDefault(.cooking, for: .monday)
        store.overrideToday(with: .quick)
        store.setIntent(.eatOut, for: .lunch)

        store.clearTodayOverride()

        XCTAssertEqual(store.effectiveDayType(), .cooking)
        XCTAssertEqual(store.intent(for: .lunch), .eatOut)

        // The preserved intent must also survive a restart …
        let restarted = makeStore(clock: clock, calendar: calendar)
        XCTAssertEqual(restarted.intent(for: .lunch), .eatOut)
        XCTAssertFalse(restarted.isTodayOverridden)

        // … and only a fully-default day state removes the persisted blob.
        XCTAssertNotNil(defaults.data(forKey: DayRhythmStore.todayStateKey))
        restarted.setIntent(.household, for: .lunch)
        XCTAssertNil(defaults.data(forKey: DayRhythmStore.todayStateKey))
    }

    // MARK: - Meal intents

    func testLunchAndDinnerIntentsAreIndependent() {
        let (store, _, _) = mondayStore()

        store.setIntent(.eatOut, for: .lunch)
        XCTAssertEqual(store.intent(for: .lunch), .eatOut)
        XCTAssertEqual(store.intent(for: .dinner), .household)

        store.setIntent(.eatOut, for: .dinner)
        store.setIntent(.household, for: .lunch)
        XCTAssertEqual(store.intent(for: .lunch), .household)
        XCTAssertEqual(store.intent(for: .dinner), .eatOut)
    }

    func testMealIntentsSurviveRestartWithinSameDay() {
        let (store, clock, calendar) = mondayStore()
        store.setIntent(.eatOut, for: .dinner)

        let restarted = makeStore(clock: clock, calendar: calendar)

        XCTAssertEqual(restarted.intent(for: .dinner), .eatOut)
        XCTAssertEqual(restarted.intent(for: .lunch), .household)
    }

    // MARK: - Override scope

    func testQueryingOtherDatesIgnoresTodayOverride() {
        let (store, _, calendar) = mondayStore()
        store.setWeeklyDefault(.cooking, for: .monday)
        store.setWeeklyDefault(.mealPrep, for: .tuesday)
        store.overrideToday(with: .quick)

        XCTAssertEqual(store.effectiveDayType(), .quick)
        XCTAssertEqual(store.effectiveDayType(for: makeDate(day: 25, in: calendar)), .mealPrep)
        XCTAssertEqual(store.effectiveDayType(for: makeDate(day: 31, in: calendar)), .cooking)
        XCTAssertEqual(store.effectiveDayType(for: makeDate(day: 17, in: calendar)), .cooking)
    }

    // MARK: - Calendar / locale semantics

    func testFirstWeekdayDoesNotShiftWeekdayMapping() {
        let sundayFirst = makeCalendar(firstWeekday: 1)
        let mondayFirst = makeCalendar(firstWeekday: 2)
        let clock = TestClock(date: makeDate(day: 24, in: sundayFirst))

        let store = makeStore(clock: clock, calendar: sundayFirst)
        store.setWeeklyDefault(.cooking, for: .monday)
        store.setWeeklyDefault(.mealPrep, for: .sunday)

        let mondayFirstStore = makeStore(clock: clock, calendar: mondayFirst)

        let monday = makeDate(day: 24, in: sundayFirst)
        let sunday = makeDate(day: 23, in: sundayFirst)
        XCTAssertEqual(Weekday.from(monday, calendar: sundayFirst), .monday)
        XCTAssertEqual(Weekday.from(monday, calendar: mondayFirst), .monday)
        XCTAssertEqual(store.effectiveDayType(for: monday), .cooking)
        XCTAssertEqual(mondayFirstStore.effectiveDayType(for: monday), .cooking)
        XCTAssertEqual(store.effectiveDayType(for: sunday), .mealPrep)
        XCTAssertEqual(mondayFirstStore.effectiveDayType(for: sunday), .mealPrep)
    }

    func testInjectedCalendarTimezoneControlsDayBoundary() {
        // Both instants fall on Monday 2026-08-24 in Los Angeles, but the second
        // one is already Tuesday 08-25 in UTC and points east of it. If the store
        // secretly consulted a global calendar instead of the injected one, the
        // override would expire here on most host timezones.
        let losAngeles = makeCalendar(timeZoneIdentifier: "America/Los_Angeles")
        let utc = makeCalendar(timeZoneIdentifier: "UTC")
        let morning = makeDate(day: 24, hour: 15, in: utc) // 08:00 Mon in LA
        let midday = makeDate(day: 25, hour: 2, in: utc) // 19:00 Mon in LA
        let clock = TestClock(date: morning)
        let store = makeStore(clock: clock, calendar: losAngeles)

        store.overrideToday(with: .quick)
        clock.date = midday
        store.refreshForCurrentDay()
        XCTAssertTrue(store.isTodayOverridden)
        XCTAssertEqual(store.effectiveDayType(), .quick)

        // Once Los Angeles itself rolls over, the override must expire.
        clock.date = makeDate(day: 25, hour: 15, in: utc) // 08:00 Tue in LA
        store.refreshForCurrentDay()
        XCTAssertFalse(store.isTodayOverridden)
    }

    // MARK: - Persistence robustness

    func testUnknownPersistedValuesFallBackSafely() throws {
        let calendar = makeCalendar()
        let clock = TestClock(date: makeDate(day: 24, in: calendar))

        let weekly = try JSONEncoder().encode([
            "2": "cooking",
            "3": "fasting", // unknown DayType
            "9": "quick", // unknown weekday
            "sunday": "quick" // non-numeric key
        ])
        defaults.set(weekly, forKey: DayRhythmStore.weeklyDefaultsKey)

        struct RawTodayState: Encodable {
            let date: Date
            let dayTypeOverride: String?
            let mealIntents: [String: String]
        }
        let today = try JSONEncoder().encode(RawTodayState(
            date: clock.date,
            dayTypeOverride: "fasting", // unknown DayType
            // "home" is the pre-rename raw value, now simply an unknown one.
            mealIntents: ["lunch": "home", "dinner": "eatOut", "brunch": "eatOut"]
        ))
        defaults.set(today, forKey: DayRhythmStore.todayStateKey)

        let store = makeStore(clock: clock, calendar: calendar)

        XCTAssertEqual(store.weeklyDefault(for: .monday), .cooking)
        XCTAssertEqual(store.weeklyDefault(for: .tuesday), .flexible)
        XCTAssertFalse(store.isTodayOverridden)
        XCTAssertEqual(store.effectiveDayType(), .cooking)
        XCTAssertEqual(store.intent(for: .lunch), .household)
        XCTAssertEqual(store.intent(for: .dinner), .eatOut)
    }

    func testMalformedPayloadsDoNotCrashAndUseSafeDefaults() {
        let calendar = makeCalendar()
        let clock = TestClock(date: makeDate(day: 24, in: calendar))

        defaults.set(Data("not json".utf8), forKey: DayRhythmStore.weeklyDefaultsKey)
        defaults.set("wrong type", forKey: DayRhythmStore.todayStateKey)

        let store = makeStore(clock: clock, calendar: calendar)

        XCTAssertEqual(store.effectiveDayType(), .flexible)
        XCTAssertEqual(store.intent(for: .lunch), .household)
        XCTAssertFalse(store.isTodayOverridden)

        // The store must stay writable on top of the corrupt payloads.
        store.setWeeklyDefault(.cooking, for: .monday)
        store.overrideToday(with: .quick)
        let restarted = makeStore(clock: clock, calendar: calendar)
        XCTAssertEqual(restarted.weeklyDefault(for: .monday), .cooking)
        XCTAssertEqual(restarted.effectiveDayType(), .quick)
    }
}

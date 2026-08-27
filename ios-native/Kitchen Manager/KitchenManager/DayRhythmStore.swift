import Combine
import Foundation

/// Owns the Weekly Rhythm preference (per-weekday default `DayType`) and the
/// day-scoped state (today's `DayType` override plus per-meal intents).
///
/// Persistence is deliberately UserDefaults-only: weekly defaults are a device
/// preference like appearance/notification toggles, and the today state is a
/// single value that expires on its own — neither justifies a SwiftData model,
/// and staying out of the container keeps backup / clear-all / migration
/// contracts untouched.
///
/// "Today" follows the injected calendar and clock (production: the device's
/// current `Calendar.current`, i.e. local calendar + timezone at read time —
/// the same convention `KitchenStore.todayPlans` uses). Once the local calendar
/// day moves on, the override and meal intents stop applying and the store falls
/// back to the weekly default for the new day's weekday; the stale state is
/// actually discarded at the next explicit refresh, write, or init (see the
/// Reading section below). No timers, no day-change notifications.
@MainActor
final class DayRhythmStore: ObservableObject {
    static let weeklyDefaultsKey = "native_km_weekly_day_types_v1"
    static let todayStateKey = "native_km_day_rhythm_today_v1"
    static let fallbackDayType: DayType = .flexible
    static let fallbackMealIntent: MealIntent = .household

    @Published private(set) var weeklyDefaults: [Weekday: DayType]
    @Published private(set) var todayOverride: DayType?
    @Published private(set) var todayMealIntents: [MealSlot: MealIntent]

    private let userDefaults: UserDefaults
    private let currentDate: () -> Date
    private let calendarProvider: () -> Calendar
    /// The day the in-memory `todayOverride` / `todayMealIntents` belong to.
    /// `nil` whenever both are empty.
    private var todayStateDate: Date?

    init(
        userDefaults: UserDefaults = .standard,
        currentDate: @escaping () -> Date = { Date() },
        calendar: @escaping () -> Calendar = { Calendar.current }
    ) {
        self.userDefaults = userDefaults
        self.currentDate = currentDate
        self.calendarProvider = calendar
        weeklyDefaults = Self.loadWeeklyDefaults(from: userDefaults)
        todayOverride = nil
        todayMealIntents = [:]
        todayStateDate = nil
        loadPersistedDayStateIfCurrent()
    }

    // MARK: - Reading
    //
    // Reads are pure: day state that no longer belongs to the current local day
    // is *ignored* here, never cleared. Clearing is a mutation and only happens
    // on an explicit `refreshForCurrentDay()`, on the next write, or at init —
    // all of which run outside a SwiftUI body evaluation, so rendering Home can
    // never publish a change from inside `body`.

    /// The `DayType` in effect for `date` (default: now).
    /// Today's override applies only when `date` falls on the current local
    /// calendar day; any other date resolves purely from that date's weekday
    /// default, so an override never leaks into tomorrow/future queries.
    func effectiveDayType(for date: Date? = nil) -> DayType {
        let target = date ?? currentDate()
        if hasCurrentDayState, let todayOverride, isOnCurrentDay(target) {
            return todayOverride
        }
        return weeklyDefault(for: Weekday.from(target, calendar: calendarProvider()))
    }

    var isTodayOverridden: Bool {
        hasCurrentDayState && todayOverride != nil
    }

    /// True when today carries anything the user set by hand — an override, an
    /// eat-out meal, or both. Drives the "restore defaults" affordance.
    var isTodayCustomized: Bool {
        hasCurrentDayState && (todayOverride != nil || !todayMealIntents.isEmpty)
    }

    var todayWeekday: Weekday {
        Weekday.from(currentDate(), calendar: calendarProvider())
    }

    /// The weekly default today would fall back to. Views compare against this
    /// instead of re-deriving "which weekday is it" with their own calendar.
    var todayWeeklyDefault: DayType {
        weeklyDefault(for: todayWeekday)
    }

    func weeklyDefault(for weekday: Weekday) -> DayType {
        weeklyDefaults[weekday] ?? Self.fallbackDayType
    }

    func intent(for slot: MealSlot) -> MealIntent {
        guard hasCurrentDayState else { return Self.fallbackMealIntent }
        return todayMealIntents[slot] ?? Self.fallbackMealIntent
    }

    // MARK: - Writing

    func setWeeklyDefault(_ type: DayType, for weekday: Weekday) {
        weeklyDefaults[weekday] = type
        persistWeeklyDefaults()
    }

    /// Overrides today's `DayType` only. Weekly defaults are untouched and the
    /// override expires on its own once the local day changes.
    func overrideToday(with type: DayType) {
        refreshDayIfNeeded()
        todayOverride = type
        persistTodayState()
    }

    /// Removes today's override; today's meal intents are preserved.
    func clearTodayOverride() {
        refreshDayIfNeeded()
        guard todayOverride != nil else { return }
        todayOverride = nil
        persistTodayState()
    }

    func setIntent(_ intent: MealIntent, for slot: MealSlot) {
        refreshDayIfNeeded()
        // The default intent is not stored: an all-default day state carries no
        // information, which lets `persistTodayState()` delete the blob outright.
        if intent == Self.fallbackMealIntent {
            todayMealIntents.removeValue(forKey: slot)
        } else {
            todayMealIntents[slot] = intent
        }
        persistTodayState()
    }

    /// Restores today to the weekly default in one step: no override, both meals
    /// back to `household`. A single operation so a view never has to sequence
    /// three separate writes (and three separate publishes) to express it.
    func resetToday() {
        todayStateDate = nil
        todayOverride = nil
        todayMealIntents = [:]
        userDefaults.removeObject(forKey: Self.todayStateKey)
    }

    /// Public entry point for day-change revalidation — Home calls this when
    /// `scenePhase` becomes `.active`. Discards the persisted today state when
    /// it no longer belongs to the current local calendar day, and publishes the
    /// change so SwiftUI re-renders.
    func refreshForCurrentDay() {
        refreshDayIfNeeded()
    }

    // MARK: - Day-change guard

    private var hasCurrentDayState: Bool {
        guard let todayStateDate else { return false }
        return isOnCurrentDay(todayStateDate)
    }

    private func refreshDayIfNeeded() {
        guard let stateDate = todayStateDate, !isOnCurrentDay(stateDate) else { return }
        todayStateDate = nil
        todayOverride = nil
        todayMealIntents = [:]
        userDefaults.removeObject(forKey: Self.todayStateKey)
    }

    private func isOnCurrentDay(_ date: Date) -> Bool {
        calendarProvider().isDate(date, inSameDayAs: currentDate())
    }

    // MARK: - Persistence
    //
    // Both payloads are JSON with raw-value string fields, decoded tolerantly:
    // unknown DayType/MealIntent strings fall back to defaults instead of
    // failing the whole load, and a malformed blob reads as "no data" (it is
    // left in place and simply overwritten by the next write).

    private struct TodayStateDTO: Codable {
        var date: Date
        var dayTypeOverride: String?
        var mealIntents: [String: String]
    }

    private static func loadWeeklyDefaults(from userDefaults: UserDefaults) -> [Weekday: DayType] {
        guard let data = userDefaults.data(forKey: weeklyDefaultsKey),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        var defaults: [Weekday: DayType] = [:]
        for (key, value) in raw {
            guard let number = Int(key),
                  let weekday = Weekday(rawValue: number),
                  let type = DayType(rawValue: value) else { continue }
            defaults[weekday] = type
        }
        return defaults
    }

    private func persistWeeklyDefaults() {
        let raw = Dictionary(
            uniqueKeysWithValues: weeklyDefaults.map { (String($0.key.rawValue), $0.value.rawValue) }
        )
        guard let data = try? JSONEncoder().encode(raw) else { return }
        userDefaults.set(data, forKey: Self.weeklyDefaultsKey)
    }

    private func loadPersistedDayStateIfCurrent() {
        guard let data = userDefaults.data(forKey: Self.todayStateKey),
              let dto = try? JSONDecoder().decode(TodayStateDTO.self, from: data) else {
            return
        }
        guard isOnCurrentDay(dto.date) else {
            userDefaults.removeObject(forKey: Self.todayStateKey)
            return
        }
        todayOverride = dto.dayTypeOverride.flatMap(DayType.init(rawValue:))
        todayMealIntents = dto.mealIntents.reduce(into: [:]) { intents, entry in
            guard let slot = MealSlot(rawValue: entry.key),
                  let intent = MealIntent(rawValue: entry.value),
                  intent != Self.fallbackMealIntent else { return }
            intents[slot] = intent
        }
        todayStateDate = (todayOverride != nil || !todayMealIntents.isEmpty) ? dto.date : nil
        if todayStateDate == nil {
            userDefaults.removeObject(forKey: Self.todayStateKey)
        }
    }

#if DEBUG
    /// UI-test bootstrap. Pins today's rhythm so a test never inherits whichever
    /// day type the simulator happened to have saved — Home shows quick-meal
    /// assembly or ordinary recipe recommendation depending on it, so without
    /// this a suite could pass or fail purely on leftover state.
    ///
    /// Same shape as the appearance hook in `KitchenManagerApp.init`: any
    /// `UITEST_`-prefixed launch resets to the default, and one explicit flag
    /// opts into the other surface. Every weekday is written, so the result does
    /// not depend on which day the test happens to run.
    ///
    /// Never runs for a real user: it is compiled out of release entirely, and
    /// even in debug it does nothing without a `UITEST_` argument.
    static func applyUITestDayTypeIfRequested(userDefaults: UserDefaults = .standard) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(where: { $0.hasPrefix("UITEST_") }) else { return }
        let dayType: DayType
        if arguments.contains(uiTestQuickDayArgument) {
            dayType = .quick
        } else if arguments.contains(uiTestMealPrepDayArgument) {
            dayType = .mealPrep
        } else if arguments.contains(uiTestCookingDayArgument) {
            dayType = .cooking
        } else {
            dayType = .flexible
        }
        let store = DayRhythmStore(userDefaults: userDefaults)
        // Clears any leftover override and eat-out meal as well as the rhythm.
        store.resetToday()
        for weekday in Weekday.allCases {
            store.setWeeklyDefault(dayType, for: weekday)
        }
    }

    /// Opt in to the quick-day surface. Absent, a UI-test launch is `.flexible`.
    static let uiTestQuickDayArgument = "UITEST_FORCE_QUICK_DAY"
    /// Opt in to the meal-prep board. Ignored when the quick argument is also
    /// present, so an existing quick-day test cannot change meaning.
    static let uiTestMealPrepDayArgument = "UITEST_FORCE_MEAL_PREP_DAY"
    /// Opt in to a 做饭日. Lowest precedence of the three, so no existing test
    /// changes meaning. Needed because 做饭日 and 自由日 share the recommendation
    /// surface but not its wording — 今天做什么 · 还没决定 versus 今天怎么吃 — and
    /// the difference is only reachable by pinning the day type.
    static let uiTestCookingDayArgument = "UITEST_FORCE_COOKING_DAY"
#endif

    private func persistTodayState() {
        guard todayOverride != nil || !todayMealIntents.isEmpty else {
            todayStateDate = nil
            userDefaults.removeObject(forKey: Self.todayStateKey)
            return
        }
        let stateDate = todayStateDate ?? currentDate()
        todayStateDate = stateDate
        let dto = TodayStateDTO(
            date: stateDate,
            dayTypeOverride: todayOverride?.rawValue,
            mealIntents: Dictionary(
                uniqueKeysWithValues: todayMealIntents.map { ($0.key.rawValue, $0.value.rawValue) }
            )
        )
        guard let data = try? JSONEncoder().encode(dto) else { return }
        userDefaults.set(data, forKey: Self.todayStateKey)
    }
}

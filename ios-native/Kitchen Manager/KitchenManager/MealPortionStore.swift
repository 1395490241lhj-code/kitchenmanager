import Combine
import Foundation

/// One day's portion count for one meal. Storage detail: the UI reads
/// `MealPortionPlan` instead, which composes this with the reservation.
struct MealPortionEntry: Equatable {
    /// Start of that day, in the store's injected calendar.
    var date: Date
    var slot: MealSlot
    /// Always within `MealPortionStore.portionRange`. Unset is represented by the
    /// entry's absence, never by 0.
    var portions: Int
}

/// Owns "how many portions is this meal for" and "how many portions were set
/// aside for a later meal".
///
/// Deliberately separate from `DayRhythmStore`: that store's whole contract is
/// "today's state, gone at midnight", while a carryover reservation is worthless
/// unless it survives into the next day — its entire purpose lives there. Two
/// stores means each one has exactly one expiry rule, testable on its own.
///
/// Lifetimes:
/// - a `MealPortionEntry` is meaningful on its own day and is pruned once that
///   day has passed;
/// - a `CarryoverReservation` lives from the evening it is made until the end of
///   its `targetDate`, then is pruned. An expired reservation is dropped
///   silently — it does not become a leftover, and no history is kept. That is
///   the leftovers system, deliberately out of scope.
///
/// Reads are pure: expired rows are *ignored*, never deleted. Pruning is a
/// mutation and happens only in `refreshForCurrentDay()`, on a write, or at
/// init — all outside a SwiftUI body evaluation, so rendering Home can never
/// publish a change from inside `body`.
@MainActor
final class MealPortionStore: ObservableObject {
    static let storageKey = "native_km_meal_portions_v1"
    static let portionRange = 1...12

    @Published private(set) var currentPortionEntries: [MealPortionEntry]
    @Published private(set) var reservations: [CarryoverReservation]

    private let userDefaults: UserDefaults
    private let currentDate: () -> Date
    private let calendarProvider: () -> Calendar

    init(
        userDefaults: UserDefaults = .standard,
        currentDate: @escaping () -> Date = { Date() },
        calendar: @escaping () -> Calendar = { Calendar.current }
    ) {
        self.userDefaults = userDefaults
        self.currentDate = currentDate
        self.calendarProvider = calendar
        let stored = Self.load(from: userDefaults)
        currentPortionEntries = stored.currentPortions
        reservations = stored.reservations
        pruneIfNeeded()
    }

    // MARK: - Reading

    /// The plan for one meal: portions eaten then, plus anything held back.
    /// `currentMealPortions` stays `nil` when the user has not said.
    /// `date` defaults to today, so views never build dates of their own.
    func portionPlan(for date: Date? = nil, slot: MealSlot) -> MealPortionPlan {
        let date = date ?? currentDate()
        let calendar = calendarProvider()
        let current = currentPortionEntries.first {
            $0.slot == slot
                && calendar.isDate($0.date, inSameDayAs: date)
                && !isExpired(dayOf: $0.date)
        }?.portions
        let reserved = reservations.first {
            $0.sourceSlot == slot
                && calendar.isDate($0.sourceDate, inSameDayAs: date)
                && !isExpired(dayOf: $0.targetDate)
        }?.portions ?? 0
        return MealPortionPlan(currentMealPortions: current, reservedForNextLunchPortions: reserved)
    }

    /// A reservation whose food is meant to be eaten at this meal, if any.
    func incomingReservation(for date: Date? = nil, slot: MealSlot) -> CarryoverReservation? {
        let date = date ?? currentDate()
        let calendar = calendarProvider()
        return reservations.first {
            $0.targetSlot == slot
                && calendar.isDate($0.targetDate, inSameDayAs: date)
                && !isExpired(dayOf: $0.targetDate)
        }
    }

    // MARK: - Writing

    /// `nil` (or a non-positive value) removes the entry rather than storing 0 —
    /// "unset" and "zero portions" must not become the same state.
    func setCurrentMealPortions(_ portions: Int?, on date: Date? = nil, slot: MealSlot) {
        pruneIfNeeded()
        let calendar = calendarProvider()
        let day = calendar.startOfDay(for: date ?? currentDate())
        currentPortionEntries.removeAll { $0.slot == slot && calendar.isDate($0.date, inSameDayAs: day) }
        if let clamped = Self.clamped(portions) {
            currentPortionEntries.append(MealPortionEntry(date: day, slot: slot, portions: clamped))
        }
        persist()
    }

    /// The only way to create a reservation in this version: dinner on
    /// `sourceDate` hands portions to lunch on the following day. Passing 0
    /// deletes the reservation.
    func setReservedForNextLunchPortions(_ portions: Int, from sourceDate: Date? = nil) {
        pruneIfNeeded()
        let calendar = calendarProvider()
        let source = calendar.startOfDay(for: sourceDate ?? currentDate())
        guard let target = calendar.date(byAdding: .day, value: 1, to: source) else { return }
        reservations.removeAll {
            $0.sourceSlot == .dinner
                && $0.targetSlot == .lunch
                && calendar.isDate($0.sourceDate, inSameDayAs: source)
        }
        if let clamped = Self.clamped(portions) {
            reservations.append(
                CarryoverReservation(
                    sourceDate: source,
                    sourceSlot: .dinner,
                    targetDate: target,
                    targetSlot: .lunch,
                    portions: clamped
                )
            )
        }
        persist()
    }

    /// Target-day cancellation: all or nothing. Editing the remaining amount
    /// ("only half left") is leftovers semantics and out of scope here.
    func cancelIncomingReservation(on date: Date? = nil, slot: MealSlot) {
        pruneIfNeeded()
        let date = date ?? currentDate()
        let calendar = calendarProvider()
        reservations.removeAll {
            $0.targetSlot == slot && calendar.isDate($0.targetDate, inSameDayAs: date)
        }
        persist()
    }

    /// Undoes what the user arranged *on* `date`: that day's portion entries and
    /// any reservation it created. A reservation that merely *targets* `date` is
    /// left alone — that food was arranged yesterday and is not today's decision
    /// to reset.
#if DEBUG
    /// UI-test bootstrap. Clears **both** directions of carryover so one seeded
    /// launch cannot inherit the previous one's portions.
    ///
    /// `resetPortions()` alone is not enough: it clears today's entries and the
    /// reservations *made* today, but an incoming reservation was made
    /// yesterday, so its `sourceDate` is yesterday and it survives. A screenshot
    /// or a test that never mentioned carryover would then render 午餐已留 1 份
    /// inherited from an earlier launch.
    ///
    /// Unlike `DayRhythmStore.applyUITestDayTypeIfRequested`, this cannot be a
    /// static UserDefaults write from `App.init`: this store loads its contents
    /// in `init`, which runs before that body. It therefore has to go through
    /// the live instance, from the seed that is about to write portions.
    ///
    /// Never runs for a real user: compiled out of release, and inert without a
    /// `UITEST_` argument.
    func applyUITestResetIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("UITEST_") }) else { return }
        resetPortions()
        for slot in MealSlot.allCases {
            cancelIncomingReservation(slot: slot)
        }
    }
#endif

    func resetPortions(on date: Date? = nil) {
        pruneIfNeeded()
        let date = date ?? currentDate()
        let calendar = calendarProvider()
        currentPortionEntries.removeAll { calendar.isDate($0.date, inSameDayAs: date) }
        reservations.removeAll { calendar.isDate($0.sourceDate, inSameDayAs: date) }
        persist()
    }

    /// Public entry point for day-change revalidation — Home calls this when
    /// `scenePhase` becomes `.active` and on appear.
    func refreshForCurrentDay() {
        pruneIfNeeded()
    }

    // MARK: - Expiry

    /// A day is expired once the current local day has moved past it. A future
    /// day (a reservation made tonight for tomorrow) is pending, not expired.
    private func isExpired(dayOf date: Date) -> Bool {
        let calendar = calendarProvider()
        let today = calendar.startOfDay(for: currentDate())
        return calendar.startOfDay(for: date) < today
    }

    private func pruneIfNeeded() {
        let liveEntries = currentPortionEntries.filter { !isExpired(dayOf: $0.date) }
        let liveReservations = reservations.filter { !isExpired(dayOf: $0.targetDate) }
        guard liveEntries.count != currentPortionEntries.count
            || liveReservations.count != reservations.count else { return }
        currentPortionEntries = liveEntries
        reservations = liveReservations
        persist()
    }

    private static func clamped(_ portions: Int?) -> Int? {
        guard let portions, portions > 0 else { return nil }
        return min(max(portions, portionRange.lowerBound), portionRange.upperBound)
    }

    // MARK: - Persistence
    //
    // One JSON blob under one key. Both collections are arrays rather than
    // keyed dictionaries so every date in the payload encodes the same way.
    // Decoding is tolerant: a row with an unknown slot or a non-positive portion
    // count is dropped, and a malformed blob reads as empty and is left in place
    // to be overwritten by the next write — never destructively cleared.

    // Slots are encoded as raw strings rather than as `MealSlot` so a row naming a
    // slot this build does not know is dropped on its own, instead of failing the
    // whole payload the way a thrown enum decode would.

    private struct EntryDTO: Codable {
        var date: Date
        var slot: String
        var portions: Int
    }

    private struct ReservationDTO: Codable {
        var sourceDate: Date
        var sourceSlot: String
        var targetDate: Date
        var targetSlot: String
        var portions: Int
    }

    private struct StoragePayload: Codable {
        var currentPortions: [EntryDTO]
        var reservations: [ReservationDTO]
    }

    private static func load(
        from userDefaults: UserDefaults
    ) -> (currentPortions: [MealPortionEntry], reservations: [CarryoverReservation]) {
        guard let data = userDefaults.data(forKey: storageKey),
              let payload = try? JSONDecoder().decode(StoragePayload.self, from: data) else {
            return ([], [])
        }
        let entries = payload.currentPortions.compactMap { dto -> MealPortionEntry? in
            guard let slot = MealSlot(rawValue: dto.slot),
                  let portions = clamped(dto.portions) else { return nil }
            return MealPortionEntry(date: dto.date, slot: slot, portions: portions)
        }
        let reservations = payload.reservations.compactMap { dto -> CarryoverReservation? in
            guard let sourceSlot = MealSlot(rawValue: dto.sourceSlot),
                  let targetSlot = MealSlot(rawValue: dto.targetSlot),
                  let portions = clamped(dto.portions) else { return nil }
            return CarryoverReservation(
                sourceDate: dto.sourceDate,
                sourceSlot: sourceSlot,
                targetDate: dto.targetDate,
                targetSlot: targetSlot,
                portions: portions
            )
        }
        return (entries, reservations)
    }

    private func persist() {
        guard !currentPortionEntries.isEmpty || !reservations.isEmpty else {
            userDefaults.removeObject(forKey: Self.storageKey)
            return
        }
        let payload = StoragePayload(
            currentPortions: currentPortionEntries.map {
                EntryDTO(date: $0.date, slot: $0.slot.rawValue, portions: $0.portions)
            },
            reservations: reservations.map {
                ReservationDTO(
                    sourceDate: $0.sourceDate,
                    sourceSlot: $0.sourceSlot.rawValue,
                    targetDate: $0.targetDate,
                    targetSlot: $0.targetSlot.rawValue,
                    portions: $0.portions
                )
            }
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }
}

import Foundation

// MARK: - Planner projection
//
// A pure, non-persisted read model that merges the two planning sources on one
// calendar: ordinary dated `MealPlanItem` rows and `SpecialPlan` events. It owns
// no data and writes nothing; `KitchenStore` stays the single source of truth
// for both collections. `WeeklyPlanRecord` is deliberately not part of this
// projection yet.

/// One row on the Planner timeline.
/// `nonisolated` so tests can build and compare it without hopping actors.
nonisolated enum PlannerEntry: Equatable, Identifiable, Hashable, Sendable {
    case meal(MealPlanItem)
    case specialPlan(SpecialPlan)

    var id: String {
        switch self {
        case .meal(let meal): "meal-\(meal.id.uuidString)"
        case .specialPlan(let plan): "special-\(plan.id.uuidString)"
        }
    }

    /// The local-calendar day this entry belongs to.
    func day(calendar: Calendar) -> Date {
        switch self {
        case .meal(let meal): calendar.startOfDay(for: meal.date)
        case .specialPlan(let plan): calendar.startOfDay(for: plan.scheduledAt)
        }
    }

    /// Sort key within a day: meals first (breakfast-like rolling order), then
    /// special plans by scheduled time, then stable identity. Never uses `id`'s
    /// UUID randomness as a display-order signal.
    func sortKey(calendar: Calendar) -> (order: Int, time: Date, id: String) {
        switch self {
        case .meal(let meal):
            return (0, calendar.startOfDay(for: meal.date), id)
        case .specialPlan(let plan):
            return (1, plan.scheduledAt, id)
        }
    }
}

/// One day group in the Planner, with a stable identity derived from the day so
/// SwiftUI `ForEach` never reorders rows into duplicates when entries change.
struct PlannerDayGroup: Identifiable, Hashable {
    let day: Date
    let entries: [PlannerEntry]
    var id: Date { day }
}

nonisolated enum PlannerProjection {
    /// Monday-first week anchor. The project's `Weekday.displayOrder` is
    /// Monday-first; weekly defaults and Home both keep that convention.
    static func startOfWeek(containing date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let daysFromMonday = (weekday - 2 + 7) % 7
        return calendar.date(byAdding: .day, value: -daysFromMonday, to: day) ?? day
    }

    /// End-of-week boundary (the day after `startOfWeek` + 6 days). Inclusive
    /// week means the range is `[start, start+7)`.
    static func nextWeekStart(after start: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 7, to: start) ?? start
    }

    /// Deterministic, date-sorted merge of normal meals and special plans within
    /// `[start, start+7)`. Entries have stable identity and a deterministic
    /// chronological order; no mutation, no persistence.
    static func entries(
        inWeekStarting start: Date,
        meals: [MealPlanItem],
        specialPlans: [SpecialPlan],
        calendar: Calendar = .current
    ) -> [PlannerEntry] {
        let weekEnd = nextWeekStart(after: start, calendar: calendar)
        let mealEntries: [PlannerEntry] = meals.compactMap { meal in
            let day = calendar.startOfDay(for: meal.date)
            guard day >= start && day < weekEnd else { return nil }
            return .meal(meal)
        }
        let specialEntries: [PlannerEntry] = specialPlans.compactMap { plan in
            let day = calendar.startOfDay(for: plan.scheduledAt)
            guard day >= start && day < weekEnd else { return nil }
            return .specialPlan(plan)
        }
        return (mealEntries + specialEntries).sorted { lhs, rhs in
            let l = lhs.sortKey(calendar: calendar)
            let r = rhs.sortKey(calendar: calendar)
            if l.order != r.order { return l.order < r.order }
            if l.time != r.time { return l.time < r.time }
            return l.id < r.id
        }
    }

    /// Groups a week's entries into a Monday-first day list. Empty days within
    /// the week are included so the Planner keeps a stable weekly skeleton.
    static func dayGroups(
        inWeekStarting start: Date,
        entries: [PlannerEntry],
        calendar: Calendar = .current
    ) -> [PlannerDayGroup] {
        var byDay: [Date: [PlannerEntry]] = [:]
        for entry in entries {
            byDay[entry.day(calendar: calendar), default: []].append(entry)
        }
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let dayEntries = byDay[day] ?? []
                .sorted { lhs, rhs in
                    let l = lhs.sortKey(calendar: calendar)
                    let r = rhs.sortKey(calendar: calendar)
                    if l.order != r.order { return l.order < r.order }
                    if l.time != r.time { return l.time < r.time }
                    return l.id < r.id
                }
            return PlannerDayGroup(day: day, entries: dayEntries)
        }
    }
}

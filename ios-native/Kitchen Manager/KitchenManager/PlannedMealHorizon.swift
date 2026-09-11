import Foundation

// MARK: - Planned meal horizon
//
// A pure slice over `KitchenStore.plans`, so anything that needs to know what
// is about to be cooked can ask the schedule itself. The weekly generator's
// draft is a proposal until someone adds it, and a proposal must not change
// what the kitchen thinks it needs to buy.

/// The scheduled meals still ahead of a given day.
///
/// `nonisolated` so tests can call it without hopping actors, like the other
/// pure projections here.
nonisolated enum PlannedMealHorizon {
    /// Days past the reference day that still count as upcoming. Six makes the
    /// window seven civil days: the reference day and the six after it.
    static let defaultForwardDays = 6

    /// Pending meals from `reference`'s day through `forwardDays` later, both
    /// ends included, in the order `plans` already holds them.
    ///
    /// Civil days rather than 24-hour multiples, so a day that gains or loses
    /// an hour is still one day. Comparison runs through `calendar`, which
    /// makes this exactly as timezone-stable as the normalized dates
    /// `MealPlanItem` already stores — no more than that.
    ///
    /// Cooked meals drop out: their ingredients are spent, and the question
    /// here is what is still coming.
    static func upcoming(
        plans: [MealPlanItem],
        from reference: Date = Date(),
        forwardDays: Int = defaultForwardDays,
        calendar: Calendar = .current
    ) -> [MealPlanItem] {
        let first = calendar.startOfDay(for: reference)
        guard let last = calendar.date(byAdding: .day, value: forwardDays, to: first) else { return [] }
        return plans.filter { plan in
            guard !plan.isCooked else { return false }
            let day = calendar.startOfDay(for: plan.date)
            return day >= first && day <= last
        }
    }
}

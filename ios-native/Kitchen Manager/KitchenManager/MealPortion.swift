import Foundation

// MARK: - Portion + carryover business models (P0-2B)
//
// The unit is always a *portion* (份), never a headcount. A portion can later be
// split per person or per component; a headcount cannot. This is deliberately a
// separate axis from `MealPlanItem.plannedServings`, which is how many recipe
// servings a plan prepares. The two can disagree on purpose: cooking four
// servings and eating two tonight is `plannedServings = 4` with two portions
// kept for later. Quantities are still not rescaled — see
// `ShoppingListGeneratorTests.test_servingsOtherThanOne_addsWarning_...`.
//
// Nothing here drives ingredient, inventory or shopping quantity maths. These
// values record intent and are displayed; that boundary is intentional.

/// How many portions one meal is planned for.
///
/// Composed by `MealPortionStore` from two differently-scoped sources, so it is
/// a read model rather than a persisted shape: `currentMealPortions` belongs to
/// its own day, while `reservedForNextLunchPortions` is derived from a
/// `CarryoverReservation` that has to outlive that day.
struct MealPortionPlan: Equatable {
    /// Portions eaten at this meal itself. `nil` means the user has not said —
    /// never persisted as 0, and never displayed as "0 份".
    var currentMealPortions: Int?
    /// Portions set aside for a later meal. 0 means no reservation exists.
    var reservedForNextLunchPortions: Int

    static let unset = MealPortionPlan(currentMealPortions: nil, reservedForNextLunchPortions: 0)

    /// Total portions to cook. Always computed, never stored, so it cannot drift
    /// from its parts. `nil` while `currentMealPortions` is unset: a total is not
    /// fabricated out of a reservation alone.
    var totalPlannedPortions: Int? {
        guard let currentMealPortions else { return nil }
        return currentMealPortions + reservedForNextLunchPortions
    }

    var hasReservation: Bool { reservedForNextLunchPortions > 0 }
    var isEmpty: Bool { currentMealPortions == nil && !hasReservation }
}

/// One explicit handover of portions from one meal to a later meal.
///
/// The shape is general (source and target are both fully spelled out) so a
/// future "dinner → dinner-after-next" or "lunch → same-day dinner" is a new
/// entry point rather than a new schema. The v1 write API is deliberately narrow
/// — `MealPortionStore.setReservedForNextLunchPortions(_:from:)` — so no other
/// source/target combination can actually be created yet.
struct CarryoverReservation: Equatable {
    /// Start of the cooking day, in the store's injected calendar.
    var sourceDate: Date
    var sourceSlot: MealSlot
    /// Start of the eating day, in the store's injected calendar.
    var targetDate: Date
    var targetSlot: MealSlot
    /// Always > 0. Setting a reservation to 0 deletes it instead.
    var portions: Int
}

// MARK: - Display copy
//
// Centralised for the same reason the DayRhythm copy is: Home and the sheet must
// never grow their own switch over these values. The carryover wording avoids the
// word 备餐 entirely — that is the `DayType.mealPrep` label ("备餐日") and reusing
// it here would read as a day type rather than as food already set aside.

enum MealPortionCopy {
    static let portionsUnset = "未设置"

    /// Sheet, source meal: how many portions get eaten tonight.
    static func currentMeal(_ portions: Int?) -> String {
        guard let portions else { return portionsUnset }
        return "\(portions) 份"
    }

    /// Sheet, source meal: how many portions are held back for tomorrow.
    static func reserved(_ portions: Int) -> String {
        portions > 0 ? "\(portions) 份" : "不留"
    }

    /// Sheet, source meal: the read-only total.
    static func total(_ portions: Int?) -> String {
        guard let portions else { return portionsUnset }
        return "\(portions) 份"
    }

    /// Home summary + sheet, on the day the food is cooked.
    static func sourceDaySummary(_ portions: Int) -> String { "明日午餐留 \(portions) 份" }

    /// Home summary, on the day the food is eaten.
    static func targetDaySummary(_ portions: Int) -> String { "午餐已留 \(portions) 份" }

    /// Sheet row, on the day the food is eaten.
    static func targetDayRow(_ portions: Int) -> String { "昨晚留的 \(portions) 份" }
}

import Foundation

/// Tonight's hero copy, derived from the plans that actually exist.
///
/// Every field is counted or read from the plan list — nothing here is stored
/// alongside it. A dish total kept beside the dishes is exactly the drift the
/// `WeeklyMealPlan.dishCount` tests exist to prevent.
nonisolated struct HomeMealHeroModel: Equatable {
    let title: String
    let sideDishes: [String]
    let timing: String?
    let duration: String?
    let dishCount: Int
    let readiness: HomeMealReadiness?

    /// - Parameters:
    ///   - plans: today's plans, in the order Home displays them.
    ///   - cookingMinutes: total cooking time when the recipes state one.
    ///   - readiness: ingredient readiness, when it can be stated honestly.
    static func make(
        plans: [MealPlanItem],
        totalDishCount: Int,
        cookingMinutes: Int?,
        readiness: HomeMealReadiness?
    ) -> Self? {
        guard let lead = plans.first else { return nil }
        return Self(
            title: lead.recipeName,
            sideDishes: plans.dropFirst().map(\.recipeName),
            timing: nil,
            duration: cookingMinutes.map { "\($0) 分钟" },
            // The whole menu, not the truncated preview. Home caps how many
            // dishes it lists; saying "3 道菜" above a list that admits to
            // 另有 1 道 would state a number the evening does not hold.
            dishCount: totalDishCount,
            readiness: readiness
        )
    }
}

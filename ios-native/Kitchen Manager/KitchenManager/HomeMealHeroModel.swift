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
            // Only a two-dish menu names its other dish inline. At three or
            // more the remaining dishes belong in the 另有 N 道 disclosure, and
            // a 配 line listing them as well would be the same menu twice.
            sideDishes: totalDishCount == 2 ? plans.dropFirst().map(\.recipeName) : [],
            timing: nil,
            // One dish states its own cooking time. Several dishes have no
            // honest total: the recipes are cooked in an overlapping order the
            // product does not model, so a sum is wrong, a max is wrong, and
            // inventing a parallelism estimate is worse than saying nothing.
            duration: totalDishCount == 1 ? cookingMinutes.map { "\($0) 分钟" } : nil,
            // The whole menu, not the truncated preview. Home caps how many
            // dishes it lists; saying "3 道菜" above a list that admits to
            // 另有 1 道 would state a number the evening does not hold.
            dishCount: totalDishCount,
            readiness: readiness
        )
    }
}

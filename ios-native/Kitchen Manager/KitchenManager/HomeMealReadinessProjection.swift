import Foundation

/// Counts how many of tonight's ingredients are already in the kitchen.
///
/// This is a projection, not a new matching rule: it reuses
/// `InventoryConsumptionPlanner`, which is the existing authority on whether a
/// recipe line resolves to something in inventory. Home must never answer that
/// question a second way — two matchers would eventually disagree, and the
/// screen would contradict the cook-confirmation sheet the user sees next.
enum HomeMealReadinessProjection {

    /// `nil` when the plans reference no resolvable recipe, or when those
    /// recipes list no ingredients at all. Home then simply omits readiness
    /// rather than claiming `0/0`.
    static func readiness(
        plans: [MealPlanItem],
        recipes: (String) -> Recipe?,
        inventory: [InventoryItem]
    ) -> HomeMealReadiness? {
        let inputs = plans.compactMap { plan -> InventoryConsumptionPlanner.RecipeConsumptionInput? in
            guard let recipe = recipes(plan.recipeID) else { return nil }
            return .init(recipe: recipe, servings: plan.plannedServings ?? 1)
        }
        guard !inputs.isEmpty else { return nil }

        let drafts = InventoryConsumptionPlanner().plan(for: inputs, inventory: inventory)
        guard !drafts.isEmpty else { return nil }

        // "Ready" means the planner matched the line to available inventory.
        // Quantity sufficiency is deliberately not folded in here: a recipe line
        // with no stated amount has no shortfall to measure, and treating it as
        // missing would understate a kitchen that actually has the food.
        let ready = drafts.count { $0.matchedInventoryID != nil }
        return HomeMealReadiness(ready: ready, total: drafts.count)
    }
}

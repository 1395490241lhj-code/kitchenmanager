import Foundation

/// Which of tonight's dishes an ingredient is already spoken for by.
///
/// A read-only projection over today's plans and the recipes they name. It
/// owns no matching rule of its own: `IngredientNormalizer.matchKey` is the
/// same key `InventoryConsumptionPlanner` uses to decide whether a recipe line
/// resolves to a stocked item, so Inventory and the cook-confirmation sheet
/// can never disagree about what tonight needs.
nonisolated enum InventoryTonightLinkage {

    /// One line per ingredient, or nothing when tonight does not use it.
    ///
    /// Naming every dish would turn a row into a paragraph, so a single dish is
    /// named and anything more is counted: `今晚 · 蒜蓉上海青` / `今晚 · 2 道菜`.
    static func summaries(
        plans: [MealPlanItem],
        recipes: (String) -> Recipe?
    ) -> [String: String] {
        var dishesByIngredient: [String: [String]] = [:]

        for plan in plans {
            guard let recipe = recipes(plan.recipeID) else { continue }
            // A dish is credited to an ingredient once, however many lines of
            // the recipe mention it.
            var seen: Set<String> = []
            for line in recipe.ingredients {
                let parsed = IngredientParser.parse(line)
                let key = IngredientNormalizer.matchKey(
                    IngredientNormalizer.normalizedName(parsed.displayName)
                )
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                dishesByIngredient[key, default: []].append(plan.recipeName)
            }
        }

        return dishesByIngredient.mapValues { dishes in
            dishes.count == 1 ? "今晚 · \(dishes[0])" : "今晚 · \(dishes.count) 道菜"
        }
    }

    /// The line for one stocked item, using the same key as the map above.
    static func summary(for item: InventoryItem, in summaries: [String: String]) -> String? {
        summaries[IngredientNormalizer.matchKey(item.name)]
    }
}

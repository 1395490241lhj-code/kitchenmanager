import Foundation

/// The one presence rule for "is this recipe ingredient in the kitchen?".
///
/// Presence only, never sufficiency: an ingredient counts as in stock when an
/// available inventory row resolves to the same match key. Quantities, expiry
/// and serving scaling are not consulted. `InventoryConsumptionPlanner` (and so
/// Home readiness), the recipe library's 缺 N 样 and Recipe Detail's per-line
/// marks all answer through here, so no two screens can disagree about the same
/// line.
enum RecipeStockMatch {
    /// The normalized name the matcher compares, or nil for a line with no
    /// usable ingredient name.
    static func ingredientName(forLine line: String) -> String? {
        let normalized = IngredientNormalizer.normalizedName(IngredientParser.parse(line).displayName)
        return normalized.isEmpty ? nil : normalized
    }

    static func item(_ item: InventoryItem, matches ingredientName: String) -> Bool {
        item.isAvailable
            && IngredientNormalizer.matchKey(item.name) == IngredientNormalizer.matchKey(ingredientName)
    }

    static func isInStock(_ ingredientName: String, inventory: [InventoryItem]) -> Bool {
        inventory.contains { item($0, matches: ingredientName) }
    }

    /// Whether one written recipe line is in stock. Nil when the line has no
    /// usable name, so callers can leave it unmarked rather than call it missing.
    static func isInStock(line: String, inventory: [InventoryItem]) -> Bool? {
        ingredientName(forLine: line).map { isInStock($0, inventory: inventory) }
    }

    /// Core ingredients (not seasonings) with nothing available in inventory,
    /// in recipe order and once per match key.
    static func missingIngredients(in recipe: Recipe, inventory: [InventoryItem]) -> [String] {
        var seen = Set<String>()
        var missing: [String] = []
        for line in recipe.ingredients {
            guard let name = ingredientName(forLine: line),
                  seen.insert(IngredientNormalizer.matchKey(name)).inserted else { continue }
            if !isInStock(name, inventory: inventory) { missing.append(name) }
        }
        return missing
    }
}

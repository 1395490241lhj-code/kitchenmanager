import Foundation

/// Pure arithmetic for "this recipe is written for N servings, I want M".
///
/// Deliberately tiny and free of any plan, view or store: given a base yield
/// and an *explicit* target, it returns a factor or a scaled number. It never
/// guesses a target: callers pass one a human actually stated, which is why
/// `MealPlanItem.plannedServings` is optional rather than defaulting to a
/// number nobody chose.
///
/// Text parsing and presentation stay where they already live:
/// `RecipeServingScaler` renders cooking-view lines and `IngredientParser`
/// reads shopping quantities. This type owns only the maths both would need,
/// so the two cannot drift into disagreeing about the same recipe.
enum RecipeQuantityScaler {
    /// Same bounds the rest of the product offers, so a factor can never be
    /// built from a serving count the app would refuse to store.
    static let validServings = Recipe.validBaseServings

    /// `nil` when either side is unknown or out of range — an unscalable input
    /// must stay unscaled rather than silently fall back to 1.0, which would
    /// look like a successful no-op.
    static func factor(baseServings: Int?, targetServings: Int?) -> Double? {
        guard let baseServings, let targetServings,
              validServings.contains(baseServings),
              validServings.contains(targetServings) else { return nil }
        return Double(targetServings) / Double(baseServings)
    }

    /// Scales one already-parsed quantity. Returns `nil` on the same unknown
    /// inputs as `factor`, so a caller can distinguish "scaled" from "left
    /// alone" instead of having to compare values.
    static func scale(quantity: Double, baseServings: Int?, targetServings: Int?) -> Double? {
        guard let factor = factor(baseServings: baseServings, targetServings: targetServings) else {
            return nil
        }
        return scale(quantity: quantity, factor: factor)
    }

    /// Applies a known factor. Split out so a caller that already resolved one
    /// does not recompute it per ingredient line.
    static func scale(quantity: Double, factor: Double) -> Double {
        guard quantity.isFinite, factor.isFinite else { return quantity }
        return quantity * factor
    }
}

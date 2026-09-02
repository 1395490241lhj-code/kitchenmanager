import Foundation
import SwiftData

@Model
final class TodayPlanRecord {
    @Attribute(.unique) var id: UUID
    var recipeID: String
    var recipeName: String
    var date: Date
    /// `nil` when nobody stated a target for this plan. Optional so the
    /// unstated case survives a round trip instead of reappearing as `1`.
    ///
    /// SwiftData adds a new optional attribute as `nil` for existing rows,
    /// which is exactly the intended migration: the old `servings` column held
    /// three different meanings with no way to tell them apart, so it is not
    /// carried over. See `MealPlanItem.plannedServings`.
    var plannedServings: Int?
    var isCooked: Bool
    /// Persistence-only ordering metadata. `MealPlanItem` and the backup format stay unchanged.
    var sortIndex: Int

    init(item: MealPlanItem, sortIndex: Int) {
        id = item.id
        recipeID = item.recipeID
        recipeName = item.recipeName
        date = item.date
        plannedServings = item.plannedServings
        isCooked = item.isCooked
        self.sortIndex = sortIndex
    }

    var mealPlanItem: MealPlanItem {
        MealPlanItem(
            id: id,
            recipeID: recipeID,
            recipeName: recipeName,
            date: date,
            plannedServings: plannedServings,
            isCooked: isCooked
        )
    }

    func update(from item: MealPlanItem, sortIndex: Int) {
        recipeID = item.recipeID
        recipeName = item.recipeName
        date = item.date
        plannedServings = item.plannedServings
        isCooked = item.isCooked
        self.sortIndex = sortIndex
    }
}

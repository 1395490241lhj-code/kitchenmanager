import Foundation
import SwiftData

@Model
final class TodayPlanRecord {
    @Attribute(.unique) var id: UUID
    var recipeID: String
    var recipeName: String
    var date: Date
    var servings: Int
    var isCooked: Bool
    /// Persistence-only ordering metadata. `MealPlanItem` and the backup format stay unchanged.
    var sortIndex: Int

    init(item: MealPlanItem, sortIndex: Int) {
        id = item.id
        recipeID = item.recipeID
        recipeName = item.recipeName
        date = item.date
        servings = item.servings
        isCooked = item.isCooked
        self.sortIndex = sortIndex
    }

    var mealPlanItem: MealPlanItem {
        MealPlanItem(
            id: id,
            recipeID: recipeID,
            recipeName: recipeName,
            date: date,
            servings: servings,
            isCooked: isCooked
        )
    }

    func update(from item: MealPlanItem, sortIndex: Int) {
        recipeID = item.recipeID
        recipeName = item.recipeName
        date = item.date
        servings = item.servings
        isCooked = item.isCooked
        self.sortIndex = sortIndex
    }
}

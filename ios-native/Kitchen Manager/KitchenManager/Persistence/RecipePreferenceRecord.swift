import Foundation
import SwiftData

struct RecipePreference: Equatable {
    let recipeID: String
    var isFavorite: Bool
    var isFrequent: Bool
}

@Model
final class RecipePreferenceRecord {
    @Attribute(.unique) var recipeID: String
    var isFavorite: Bool
    var isFrequent: Bool

    init(recipeID: String, isFavorite: Bool, isFrequent: Bool) {
        self.recipeID = recipeID
        self.isFavorite = isFavorite
        self.isFrequent = isFrequent
    }

    var preference: RecipePreference {
        RecipePreference(recipeID: recipeID, isFavorite: isFavorite, isFrequent: isFrequent)
    }

    func update(from preference: RecipePreference) {
        isFavorite = preference.isFavorite
        isFrequent = preference.isFrequent
    }
}

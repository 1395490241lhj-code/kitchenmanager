import Foundation
import SwiftData

@Model
final class UserRecipeRecord {
    @Attribute(.unique) var id: String
    var recipeData: Data
    var normalizedSourceURL: String?
    var contentFingerprint: String
    var sortIndex: Int

    @MainActor
    init(recipe: Recipe, sortIndex: Int) throws {
        id = recipe.id
        recipeData = try JSONEncoder().encode(recipe)
        normalizedSourceURL = recipe.source.map { RecipeStore.normalizedSourceURL($0.canonicalURL) }
        contentFingerprint = RecipeStore.fingerprint(for: recipe)
        self.sortIndex = sortIndex
    }

    @MainActor
    func recipe() throws -> Recipe {
        try JSONDecoder().decode(Recipe.self, from: recipeData)
    }

    @MainActor
    func update(from recipe: Recipe, sortIndex: Int) throws {
        recipeData = try JSONEncoder().encode(recipe)
        normalizedSourceURL = recipe.source.map { RecipeStore.normalizedSourceURL($0.canonicalURL) }
        contentFingerprint = RecipeStore.fingerprint(for: recipe)
        self.sortIndex = sortIndex
    }
}

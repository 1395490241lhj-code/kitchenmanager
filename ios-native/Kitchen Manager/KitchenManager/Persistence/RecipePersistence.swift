import Foundation
import SwiftData

@MainActor
protocol UserRecipePersistenceProtocol: AnyObject {
    func loadRecipes() throws -> [Recipe]
    func storedRecordCount() throws -> Int
    func replaceRecipes(with recipes: [Recipe]) throws
    func deleteAll() throws
}

@MainActor
protocol RecipePreferencePersistenceProtocol: AnyObject {
    func loadPreferences() throws -> [RecipePreference]
    func replacePreferences(with preferences: [RecipePreference]) throws
    func deleteAll() throws
}

@MainActor
final class SwiftDataUserRecipePersistence: UserRecipePersistenceProtocol {
    let container: ModelContainer
    private let context: ModelContext

    init(container: ModelContainer) {
        self.container = container
        context = ModelContext(container)
    }

    func storedRecordCount() throws -> Int {
        try context.fetchCount(FetchDescriptor<UserRecipeRecord>())
    }

    func loadRecipes() throws -> [Recipe] {
        let records = try context.fetch(FetchDescriptor<UserRecipeRecord>(sortBy: [SortDescriptor(\.sortIndex)]))
        return records.compactMap { record in
            do { return try record.recipe() }
            catch {
                #if DEBUG
                print("[RecipePersistence] skipped corrupt recipe \(record.id): \(error)")
                #endif
                return nil
            }
        }
    }

    func replaceRecipes(with recipes: [Recipe]) throws {
        let incoming = Dictionary(recipes.map { ($0.id, $0) }, uniquingKeysWith: { existing, _ in existing })
        let order = Dictionary(uniqueKeysWithValues: recipes.enumerated().map { ($0.element.id, $0.offset) })
        let existing = try context.fetch(FetchDescriptor<UserRecipeRecord>())
        for record in existing {
            guard let recipe = incoming[record.id] else { context.delete(record); continue }
            try record.update(from: recipe, sortIndex: order[record.id] ?? 0)
        }
        let existingIDs = Set(existing.map(\.id))
        for recipe in recipes where !existingIDs.contains(recipe.id) {
            context.insert(try UserRecipeRecord(recipe: recipe, sortIndex: order[recipe.id] ?? 0))
        }
        try context.save()
    }

    func deleteAll() throws {
        try context.delete(model: UserRecipeRecord.self)
        try context.save()
    }
}

@MainActor
final class SwiftDataRecipePreferencePersistence: RecipePreferencePersistenceProtocol {
    let container: ModelContainer
    private let context: ModelContext

    init(container: ModelContainer) {
        self.container = container
        context = ModelContext(container)
    }

    func loadPreferences() throws -> [RecipePreference] {
        try context.fetch(FetchDescriptor<RecipePreferenceRecord>()).map(\.preference)
    }

    func replacePreferences(with preferences: [RecipePreference]) throws {
        let incoming = Dictionary(preferences.map { ($0.recipeID, $0) }, uniquingKeysWith: { _, latest in latest })
        let existing = try context.fetch(FetchDescriptor<RecipePreferenceRecord>())
        for record in existing {
            guard let preference = incoming[record.recipeID] else { context.delete(record); continue }
            record.update(from: preference)
        }
        let existingIDs = Set(existing.map(\.recipeID))
        for preference in incoming.values where !existingIDs.contains(preference.recipeID) {
            context.insert(RecipePreferenceRecord(
                recipeID: preference.recipeID,
                isFavorite: preference.isFavorite,
                isFrequent: preference.isFrequent
            ))
        }
        try context.save()
    }

    func deleteAll() throws {
        try context.delete(model: RecipePreferenceRecord.self)
        try context.save()
    }
}

@MainActor
final class FailingUserRecipePersistence: UserRecipePersistenceProtocol {
    let error: Error
    init(_ error: Error) { self.error = error }
    func loadRecipes() throws -> [Recipe] { throw error }
    func storedRecordCount() throws -> Int { throw error }
    func replaceRecipes(with recipes: [Recipe]) throws { throw error }
    func deleteAll() throws { throw error }
}

@MainActor
final class FailingRecipePreferencePersistence: RecipePreferencePersistenceProtocol {
    let error: Error
    init(_ error: Error) { self.error = error }
    func loadPreferences() throws -> [RecipePreference] { throw error }
    func replacePreferences(with preferences: [RecipePreference]) throws { throw error }
    func deleteAll() throws { throw error }
}

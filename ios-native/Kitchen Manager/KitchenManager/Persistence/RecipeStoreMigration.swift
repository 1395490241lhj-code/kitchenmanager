import Foundation

struct MigratedRecipeStoreState {
    let userRecipes: [Recipe]
    let favoriteRecipeIDs: Set<String>
    let frequentRecipeIDs: Set<String>
}

@MainActor
enum RecipeStoreMigration {
    static let legacyRecipesKey = "native_km_user_recipes_v1"
    static let legacyFavoritesKey = "native_km_favorite_recipes_v1"
    static let legacyFrequentKey = "native_km_frequent_recipes_v1"
    static let completionKey = "native_km_recipe_store_swiftdata_migration_v1"

    static func migrateIfNeeded(
        userDefaults: UserDefaults,
        recipes: UserRecipePersistenceProtocol,
        preferences: RecipePreferencePersistenceProtocol
    ) throws -> MigratedRecipeStoreState {
        let legacyRecipes = try loadLegacyRecipes(from: userDefaults)
        let legacyFavoriteIDs = Set(userDefaults.stringArray(forKey: legacyFavoritesKey) ?? [])
        let legacyFrequentIDs = Set(userDefaults.stringArray(forKey: legacyFrequentKey) ?? [])

        if userDefaults.bool(forKey: completionKey) {
            // Steady-state launch path — runs on every cold launch once the
            // one-off migration below has completed, so it only reads what it
            // actually returns. It used to eagerly fetch recipes, the record
            // count and preferences up front and then fetch recipes and
            // preferences *again* via `loadedState`, costing five store round
            // trips on the main actor before the first frame where two suffice.
            //
            // `storedRecordCount()` is deliberately still the guard for the
            // legacy restore rather than `loadRecipes().isEmpty`: the two
            // differ when the table holds only rows `loadRecipes()` skips as
            // corrupt, and re-seeding legacy data over those is not this
            // path's job. It is now only asked for when legacy data actually
            // exists, since the branch requires both conditions anyway.
            if !legacyRecipes.isEmpty, try recipes.storedRecordCount() == 0 {
                try recipes.replaceRecipes(with: legacyRecipes)
            }
            var storedPreferences = try preferences.loadPreferences()
            if storedPreferences.isEmpty, !legacyFavoriteIDs.isEmpty || !legacyFrequentIDs.isEmpty {
                try preferences.replacePreferences(with: legacyPreferences(favorites: legacyFavoriteIDs, frequent: legacyFrequentIDs))
                storedPreferences = try preferences.loadPreferences()
            }
            return MigratedRecipeStoreState(
                userRecipes: try recipes.loadRecipes(),
                favoriteRecipeIDs: Set(storedPreferences.filter(\.isFavorite).map(\.recipeID)),
                frequentRecipeIDs: Set(storedPreferences.filter(\.isFrequent).map(\.recipeID))
            )
        }

        let storedRecipes = try recipes.loadRecipes()
        let storedPreferences = try preferences.loadPreferences()

        var mergedRecipes = storedRecipes
        let storedIDs = Set(storedRecipes.map(\.id))
        mergedRecipes.append(contentsOf: legacyRecipes.filter { !storedIDs.contains($0.id) })
        if mergedRecipes.count != storedRecipes.count { try recipes.replaceRecipes(with: mergedRecipes) }

        var mergedPreferences = Dictionary(storedPreferences.map { ($0.recipeID, $0) }, uniquingKeysWith: { existing, _ in existing })
        for legacy in legacyPreferences(favorites: legacyFavoriteIDs, frequent: legacyFrequentIDs)
            where mergedPreferences[legacy.recipeID] == nil {
            mergedPreferences[legacy.recipeID] = legacy
        }
        if mergedPreferences.count != storedPreferences.count {
            try preferences.replacePreferences(with: Array(mergedPreferences.values))
        }

        let state = try loadedState(recipes: recipes, preferences: preferences)
        let expectedFavoriteIDs = Set(mergedPreferences.values.filter(\.isFavorite).map(\.recipeID))
        let expectedFrequentIDs = Set(mergedPreferences.values.filter(\.isFrequent).map(\.recipeID))
        guard Set(state.userRecipes.map(\.id)) == Set(mergedRecipes.map(\.id)),
              state.favoriteRecipeIDs == expectedFavoriteIDs,
              state.frequentRecipeIDs == expectedFrequentIDs else {
            throw RecipeStoreMigrationError.verificationFailed
        }
        userDefaults.set(true, forKey: completionKey)
        return state
    }

    static func loadLegacyRecipes(from defaults: UserDefaults) throws -> [Recipe] {
        guard let data = defaults.data(forKey: legacyRecipesKey) else { return [] }
        do { return try JSONDecoder().decode([Recipe].self, from: data) }
        catch { throw RecipeStoreMigrationError.invalidLegacyData(error) }
    }

    private static func legacyPreferences(favorites: Set<String>, frequent: Set<String>) -> [RecipePreference] {
        favorites.union(frequent).map {
            RecipePreference(recipeID: $0, isFavorite: favorites.contains($0), isFrequent: frequent.contains($0))
        }
    }

    private static func loadedState(
        recipes: UserRecipePersistenceProtocol,
        preferences: RecipePreferencePersistenceProtocol
    ) throws -> MigratedRecipeStoreState {
        let loadedRecipes = try recipes.loadRecipes()
        let loadedPreferences = try preferences.loadPreferences()
        return MigratedRecipeStoreState(
            userRecipes: loadedRecipes,
            favoriteRecipeIDs: Set(loadedPreferences.filter(\.isFavorite).map(\.recipeID)),
            frequentRecipeIDs: Set(loadedPreferences.filter(\.isFrequent).map(\.recipeID))
        )
    }
}

enum RecipeStoreMigrationError: LocalizedError {
    case invalidLegacyData(Error)
    case verificationFailed

    var errorDescription: String? {
        "菜谱数据迁移失败，旧数据仍保留在设备上。"
    }
}

import SwiftData
import XCTest
@testable import KitchenManager

@MainActor
final class RecipePersistenceTests: XCTestCase {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    private func recipe(_ id: String, title: String = "番茄炒蛋") -> Recipe {
        Recipe(id: id, title: title, cookingTime: 15, difficulty: "简单", tags: ["家常"],
               ingredients: ["番茄 2个", "鸡蛋 3个"], seasonings: ["盐 少许"], steps: ["炒熟"])
    }

    private func store(_ defaults: UserDefaults, _ bundle: KitchenPersistenceBundle) -> RecipeStore {
        RecipeStore(
            userDefaults: defaults,
            userRecipePersistence: bundle.userRecipes,
            recipePreferencePersistence: bundle.recipePreferences
        )
    }

    func testLegacyRecipesAndPreferencesMigrateTogether() throws {
        let defaults = defaults()
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        defaults.set(try JSONEncoder().encode([recipe("one")]), forKey: RecipeStoreMigration.legacyRecipesKey)
        defaults.set(["one", "remote"], forKey: RecipeStoreMigration.legacyFavoritesKey)
        defaults.set(["one"], forKey: RecipeStoreMigration.legacyFrequentKey)

        let migrated = store(defaults, bundle)
        XCTAssertEqual(migrated.userRecipes.map(\.id), ["one"])
        XCTAssertEqual(migrated.favoriteRecipeIDs, ["one", "remote"])
        XCTAssertEqual(migrated.frequentRecipeIDs, ["one"])
        XCTAssertTrue(defaults.bool(forKey: RecipeStoreMigration.completionKey))
        XCTAssertNotNil(defaults.data(forKey: RecipeStoreMigration.legacyRecipesKey))
    }

    func testRestartLoadsRecipesAndPreferencesFromSwiftData() throws {
        let defaults = defaults()
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let first = store(defaults, bundle)
        try first.saveUserRecipe(recipe("one"))
        first.toggleFavorite("one")
        first.toggleFrequent("remote")

        let restarted = store(defaults, bundle)
        XCTAssertEqual(restarted.userRecipes.map(\.id), ["one"])
        XCTAssertEqual(restarted.favoriteRecipeIDs, ["one"])
        XCTAssertEqual(restarted.frequentRecipeIDs, ["remote"])
    }

    func testReplaceUserRecipePersistsAcrossRestart() throws {
        let defaults = defaults(); let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let first = store(defaults, bundle)
        try first.saveUserRecipe(recipe("one"))
        try first.replaceUserRecipe(recipe("one", title: "修改后"))
        XCTAssertEqual(store(defaults, bundle).userRecipes.first?.title, "修改后")
    }

    func testDeleteUserRecipePersistsAcrossRestart() throws {
        let defaults = defaults(); let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let first = store(defaults, bundle)
        try first.saveUserRecipe(recipe("one")); try first.saveUserRecipe(recipe("two", title: "另一道"))
        try first.deleteUserRecipe(id: "one")
        XCTAssertEqual(store(defaults, bundle).userRecipes.map(\.id), ["two"])
    }

    func testPreferenceCanExistForRemoteRecipeWithoutUserRecipe() {
        let defaults = defaults(); let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let first = store(defaults, bundle)
        first.toggleFavorite("remote-only")
        XCTAssertTrue(store(defaults, bundle).favoriteRecipeIDs.contains("remote-only"))
    }

    func testFavoriteAndFrequentRemainIndependent() {
        let defaults = defaults(); let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let first = store(defaults, bundle)
        first.toggleFavorite("one"); first.toggleFrequent("two")
        first.toggleFavorite("one")
        let restarted = store(defaults, bundle)
        XCTAssertFalse(restarted.favoriteRecipeIDs.contains("one"))
        XCTAssertTrue(restarted.frequentRecipeIDs.contains("two"))
    }

    func testExistingSwiftDataRecipeWinsAndLegacyAddsOnlyMissingID() throws {
        let defaults = defaults(); let bundle = KitchenPersistenceFactory.isolatedInMemory()
        try bundle.userRecipes.replaceRecipes(with: [recipe("same", title: "SwiftData")])
        defaults.set(try JSONEncoder().encode([recipe("same", title: "旧数据"), recipe("legacy")]),
                     forKey: RecipeStoreMigration.legacyRecipesKey)
        let migrated = store(defaults, bundle)
        XCTAssertEqual(migrated.userRecipes.first(where: { $0.id == "same" })?.title, "SwiftData")
        XCTAssertEqual(Set(migrated.userRecipes.map(\.id)), ["same", "legacy"])
    }

    func testCompletedMarkerWithEmptyTablesSelfHealsFromLegacy() throws {
        let defaults = defaults(); let bundle = KitchenPersistenceFactory.isolatedInMemory()
        defaults.set(try JSONEncoder().encode([recipe("one")]), forKey: RecipeStoreMigration.legacyRecipesKey)
        defaults.set(["one"], forKey: RecipeStoreMigration.legacyFavoritesKey)
        defaults.set(true, forKey: RecipeStoreMigration.completionKey)
        let migrated = store(defaults, bundle)
        XCTAssertEqual(migrated.userRecipes.map(\.id), ["one"])
        XCTAssertEqual(migrated.favoriteRecipeIDs, ["one"])
    }

    func testClearDeletesSwiftDataAndLegacySoDataDoesNotResurrect() throws {
        let defaults = defaults(); let bundle = KitchenPersistenceFactory.isolatedInMemory()
        defaults.set(try JSONEncoder().encode([recipe("legacy")]), forKey: RecipeStoreMigration.legacyRecipesKey)
        let current = store(defaults, bundle)
        current.toggleFavorite("legacy")
        current.clearLocalData()
        let restarted = store(defaults, bundle)
        XCTAssertTrue(restarted.userRecipes.isEmpty)
        XCTAssertTrue(restarted.favoriteRecipeIDs.isEmpty)
        XCTAssertNil(defaults.data(forKey: RecipeStoreMigration.legacyRecipesKey))
    }

    func testCorruptRecipePayloadIsSkippedWithoutDeletingRecord() throws {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        try bundle.userRecipes.replaceRecipes(with: [recipe("good"), recipe("bad", title: "坏记录")])
        let persistence = try XCTUnwrap(bundle.userRecipes as? SwiftDataUserRecipePersistence)
        let context = ModelContext(persistence.container)
        let records = try context.fetch(FetchDescriptor<UserRecipeRecord>())
        try XCTUnwrap(records.first(where: { $0.id == "bad" })).recipeData = Data("not-json".utf8)
        try context.save()
        XCTAssertEqual(try bundle.userRecipes.loadRecipes().map(\.id), ["good"])
        XCTAssertEqual(try bundle.userRecipes.storedRecordCount(), 2)
    }

    func testMigrationFailureDoesNotSetCompletionMarker() {
        let defaults = defaults(); let bundle = KitchenPersistenceFactory.isolatedInMemory()
        defaults.set(Data("invalid".utf8), forKey: RecipeStoreMigration.legacyRecipesKey)
        _ = store(defaults, bundle)
        XCTAssertFalse(defaults.bool(forKey: RecipeStoreMigration.completionKey))
    }

    func testDuplicateContentAndSourceRulesStillApplyAfterMigration() throws {
        let defaults = defaults(); let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let source = RecipeSourceMetadata(platform: "web", originalURL: "https://example.com/r",
                                          canonicalURL: "https://example.com/r", importedAt: Date(), title: nil, author: nil)
        let stored = Recipe(id: "one", title: "菜", cookingTime: nil, difficulty: nil, tags: [],
                            ingredients: ["豆腐"], steps: ["炒"], source: source)
        let current = store(defaults, bundle)
        try current.saveUserRecipe(stored)
        XCTAssertThrowsError(try current.saveUserRecipe(Recipe(
            id: "two", title: "不同", cookingTime: nil, difficulty: nil, tags: [],
            ingredients: ["肉"], steps: ["煮"], source: source
        )))
        XCTAssertThrowsError(try current.saveUserRecipe(Recipe(
            id: "three", title: "菜", cookingTime: nil, difficulty: nil, tags: [],
            ingredients: ["豆腐"], steps: ["炒"]
        )))
    }
}

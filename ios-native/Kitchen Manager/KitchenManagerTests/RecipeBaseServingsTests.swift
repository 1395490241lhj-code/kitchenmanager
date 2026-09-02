import XCTest
import SwiftData
@testable import KitchenManager

/// `Recipe.baseServings` — the yield the written quantities correspond to.
///
/// The single rule these tests exist to enforce: **a value nobody stated must
/// stay `nil`.** `EditableRecipeDraft` used to default `servings` to 2 and drop
/// it on save; now that the field reaches `Recipe`, any path that quietly
/// promotes that placeholder would hand every AI, imported and legacy recipe a
/// fabricated denominator for future scaling maths.
@MainActor
final class RecipeBaseServingsTests: XCTestCase {
    private var storeURL: URL!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        storeURL = FileManager.default.temporaryDirectory
            .appending(path: "recipe-yield-\(UUID().uuidString).store")
        defaultsSuiteName = "recipe-yield-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        storeURL = nil
        defaultsSuiteName = nil
    }

    private func makeBundle() throws -> KitchenPersistenceBundle {
        try KitchenPersistenceFactory.bundle(
            container: KitchenPersistenceFactory.makeContainer(
                configuration: ModelConfiguration(url: storeURL)
            )
        )
    }

    private func makeRecipeStore() throws -> RecipeStore {
        let bundle = try makeBundle()
        return RecipeStore(
            userDefaults: UserDefaults(suiteName: defaultsSuiteName)!,
            userRecipePersistence: bundle.userRecipes,
            recipePreferencePersistence: bundle.recipePreferences
        )
    }

    private func sampleDraft() -> EditableRecipeDraft {
        EditableRecipeDraft(
            title: "番茄炒蛋",
            ingredientsText: "番茄 2 个\n鸡蛋 3 个",
            stepsText: "切块\n炒熟"
        )
    }

    // MARK: - Model + validation

    func testDefaultRecipeHasUnknownYield() {
        let recipe = Recipe(
            id: "r", title: "菜", cookingTime: nil, difficulty: nil,
            tags: [], ingredients: ["番茄"], steps: ["炒"]
        )
        XCTAssertNil(recipe.baseServings, "an unstated yield must never materialise as a number")
    }

    func testOutOfRangeYieldIsRejectedRatherThanClamped() {
        // Clamping 50 to 12 would silently keep a confused value; dropping it
        // preserves the truth that nobody stated a usable yield.
        for invalid in [0, -1, 13, 50] {
            XCTAssertNil(
                Recipe.validatedBaseServings(invalid),
                "\(invalid) is outside the supported range and must not be stored"
            )
        }
        for valid in Recipe.validBaseServings {
            XCTAssertEqual(Recipe.validatedBaseServings(valid), valid)
        }
    }

    func testInitializerRejectsOutOfRangeYield() {
        let recipe = Recipe(
            id: "r", title: "菜", cookingTime: nil, difficulty: nil,
            tags: [], ingredients: ["番茄"], steps: ["炒"], baseServings: 99
        )
        XCTAssertNil(recipe.baseServings)
    }

    // MARK: - Codable

    func testLegacyJSONWithoutTheFieldDecodesAsUnknown() throws {
        let legacy = #"{"id":"legacy","title":"回锅肉","tags":[],"ingredients":["五花肉 300 克"],"steps":["炒"]}"#
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(legacy.utf8))
        XCTAssertNil(recipe.baseServings, "recipes written before this field existed are unknown, not 2")
    }

    func testYieldSurvivesAnEncodeDecodeRoundTrip() throws {
        let recipe = Recipe(
            id: "r", title: "菜", cookingTime: nil, difficulty: nil,
            tags: [], ingredients: ["番茄"], steps: ["炒"], baseServings: 4
        )
        let decoded = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(recipe))
        XCTAssertEqual(decoded.baseServings, 4)
    }

    func testCorruptOutOfRangeStoredValueDecodesAsUnknown() throws {
        let stored = #"{"id":"x","title":"菜","tags":[],"ingredients":["番茄"],"steps":["炒"],"baseServings":0}"#
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(stored.utf8))
        XCTAssertNil(recipe.baseServings)
    }

    // MARK: - Draft provenance (the core guard)

    func testAFreshDraftHasNoYield() {
        XCTAssertNil(sampleDraft().baseServings, "a blank draft has not been told a yield")
    }

    func testSavingAnUntouchedDraftDoesNotManufactureAYield() throws {
        let recipe = try sampleDraft().makeRecipe()
        XCTAssertNil(recipe.baseServings, "saving without setting a yield must not invent 2")
    }

    func testExplicitlySetYieldIsPersisted() throws {
        var draft = sampleDraft()
        draft.baseServings = 4
        XCTAssertEqual(try draft.makeRecipe().baseServings, 4)
    }

    /// The regression the whole slice exists to prevent: opening a legacy
    /// recipe in the editor and saving it unchanged must leave it unknown.
    func testOpeningAndSavingALegacyRecipeLeavesItUnknown() throws {
        let legacy = Recipe(
            id: "legacy", title: "回锅肉", cookingTime: 30, difficulty: "简单",
            tags: ["家常菜"], ingredients: ["五花肉 300 克"], steps: ["炒"]
        )
        XCTAssertNil(legacy.baseServings)

        // Exactly what RecipeEditView builds when the sheet opens.
        let reopened = EditableRecipeDraft(
            id: legacy.id, title: legacy.title,
            baseServings: legacy.baseServings,
            cookingTime: legacy.cookingTime,
            difficulty: legacy.difficulty ?? "",
            tagsText: legacy.tags.joined(separator: "，"),
            ingredientsText: legacy.ingredients.joined(separator: "\n"),
            seasoningsText: legacy.seasonings.joined(separator: "\n"),
            stepsText: legacy.steps.joined(separator: "\n"),
            source: legacy.source
        )

        XCTAssertNil(reopened.baseServings, "merely opening the editor must not set a yield")
        XCTAssertNil(try reopened.makeRecipe().baseServings, "saving it unchanged must not either")
    }

    func testEditingAKnownYieldRoundTripsThroughTheEditor() throws {
        let existing = Recipe(
            id: "known", title: "红烧肉", cookingTime: nil, difficulty: nil,
            tags: [], ingredients: ["五花肉 500 克"], steps: ["炖"], baseServings: 4
        )
        var reopened = EditableRecipeDraft(
            id: existing.id, title: existing.title,
            baseServings: existing.baseServings,
            ingredientsText: existing.ingredients.joined(separator: "\n"),
            stepsText: existing.steps.joined(separator: "\n")
        )
        XCTAssertEqual(reopened.baseServings, 4, "an existing yield must load, not reset")
        reopened.baseServings = 6
        XCTAssertEqual(try reopened.makeRecipe().baseServings, 6)
    }

    func testClearingAYieldReturnsItToUnknown() throws {
        var draft = sampleDraft()
        draft.baseServings = 4
        draft.baseServings = nil
        XCTAssertNil(try draft.makeRecipe().baseServings)
    }

    // MARK: - Persistence

    func testYieldSurvivesAStoreReopen() throws {
        let store = try makeRecipeStore()
        try store.saveUserRecipe(
            Recipe(
                id: "durable", title: "红烧肉", cookingTime: nil, difficulty: nil,
                tags: [], ingredients: ["五花肉 500 克"], steps: ["炖"], baseServings: 4
            )
        )
        let reopened = try makeRecipeStore()
        XCTAssertEqual(reopened.userRecipes.first?.baseServings, 4)
    }

    func testUnknownYieldSurvivesAStoreReopenAsUnknown() throws {
        let store = try makeRecipeStore()
        try store.saveUserRecipe(
            Recipe(
                id: "durable-nil", title: "青椒肉丝", cookingTime: nil, difficulty: nil,
                tags: [], ingredients: ["青椒 2 个"], steps: ["炒"]
            )
        )
        let reopened = try makeRecipeStore()
        XCTAssertEqual(reopened.userRecipes.count, 1)
        XCTAssertNil(reopened.userRecipes.first?.baseServings, "unknown must not become 2 on reload")
    }

    // MARK: - Shopping is deliberately untouched this slice

    func testShoppingStillDoesNotScaleByBaseServings() {
        let recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let recipe = Recipe(
            id: "s", title: "菜", cookingTime: nil, difficulty: nil,
            tags: [], ingredients: ["番茄 2 个"], steps: ["炒"], baseServings: 4
        )
        let single = ShoppingListGenerator().generate(
            source: .recipe(recipe, servings: 1), inventory: [],
            existingShoppingItems: [], recipeStore: recipeStore
        )
        let quadruple = ShoppingListGenerator().generate(
            source: .recipe(recipe, servings: 4), inventory: [],
            existingShoppingItems: [], recipeStore: recipeStore
        )
        XCTAssertEqual(
            single.missingItems.first?.requiredQuantity,
            quadruple.missingItems.first?.requiredQuantity,
            "this slice adds the denominator only — scaling arrives in a later phase"
        )
    }
}

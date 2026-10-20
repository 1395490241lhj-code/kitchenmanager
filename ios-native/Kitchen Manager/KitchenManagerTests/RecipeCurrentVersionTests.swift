import XCTest
@testable import KitchenManager

/// RECIPES_LOGIC-9: the recipe page rendered and edited the value it was opened
/// with, so a saved edit did not show and a second edit started from the old
/// copy and overwrote the first. The page now reads `currentVersion(of:)`.
@MainActor
final class RecipeCurrentVersionTests: XCTestCase {
    private func makeStore() -> RecipeStore {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        return RecipeStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            userRecipePersistence: bundle.userRecipes,
            recipePreferencePersistence: bundle.recipePreferences
        )
    }

    private func pork(_ amount: String, steps: [String] = ["炖"]) -> Recipe {
        Recipe(id: "user-pork", title: "红烧肉", cookingTime: nil, difficulty: nil, tags: [],
               ingredients: ["猪肉 \(amount)"], steps: steps)
    }

    func testASavedEditIsWhatTheOpenedPageReads() throws {
        let store = makeStore()
        let opened = pork("200 克")
        try store.saveUserRecipe(opened)

        try store.replaceUserRecipe(pork("300 克"))

        XCTAssertEqual(store.currentVersion(of: opened).ingredients, ["猪肉 300 克"])
    }

    func testASecondEditStartsFromTheFirstInsteadOfOverwritingIt() throws {
        let store = makeStore()
        let opened = pork("200 克")
        try store.saveUserRecipe(opened)
        try store.replaceUserRecipe(pork("300 克"))

        // The second edit is seeded from what the page shows, then changes only a step.
        let shown = store.currentVersion(of: opened)
        try store.replaceUserRecipe(Recipe(
            id: shown.id, title: shown.title, cookingTime: shown.cookingTime, difficulty: shown.difficulty,
            tags: shown.tags, ingredients: shown.ingredients, steps: ["先焯水", "再炖"]
        ))

        let saved = try XCTUnwrap(store.recipe(id: opened.id))
        XCTAssertEqual(saved.ingredients, ["猪肉 300 克"], "the first edit must survive the second")
        XCTAssertEqual(saved.steps, ["先焯水", "再炖"])
    }

    func testARecipeTheLibraryDoesNotHoldIsReadAsOpened() throws {
        let store = makeStore()
        let opened = pork("200 克")
        XCTAssertEqual(store.currentVersion(of: opened), opened)

        try store.saveUserRecipe(opened)
        try store.deleteUserRecipe(id: opened.id)
        XCTAssertEqual(store.currentVersion(of: opened), opened)
    }
}

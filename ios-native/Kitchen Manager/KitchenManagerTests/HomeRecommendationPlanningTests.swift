import XCTest
@testable import KitchenManager

/// 加入今天 on an AI recommendation used to plan an in-memory recipe that the
/// library could not resolve, so the plan could not be opened, cooked or
/// shopped for.
@MainActor
final class HomeRecommendationPlanningTests: XCTestCase {
    private struct StubAIRecommendationService: AIRecommendationProviding {
        let recommendations: [RecipeRecommendation]

        func generateRecommendations(
            query: String,
            inventory: [String],
            expiringIngredients: [String],
            preferences: [String],
            excludedRecipeNames: [String],
            count: Int
        ) async throws -> [RecipeRecommendation] {
            recommendations
        }
    }

    private func makeStores() -> (RecipeStore, KitchenStore) {
        (
            RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!),
            KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
    }

    private func aiRecipe(
        _ id: String = "ai-番茄炒蛋",
        title: String = "番茄炒蛋",
        steps: [String] = ["番茄切块", "炒蛋后合炒"]
    ) -> Recipe {
        Recipe(
            id: id,
            title: title,
            cookingTime: 15,
            difficulty: "简单",
            tags: ["快手"],
            ingredients: ["番茄 2 个", "鸡蛋 3 个"],
            seasonings: ["盐 少许"],
            steps: steps
        )
    }

    func testAIRecommendationIsSavedToLibraryBeforeItIsPlanned() {
        let (recipes, kitchen) = makeStores()
        let card = aiRecipe()
        XCTAssertNil(recipes.recipe(id: card.id), "precondition: the card is not in the library")

        let outcome = HomeRecommendationPlanning.addToToday(
            card,
            recipeStore: recipes,
            kitchenStore: kitchen,
            makeRecipeID: { "home-ai-fixed" }
        )

        guard case .added(let planned, true) = outcome else {
            return XCTFail("expected a saved add, got \(outcome)")
        }
        XCTAssertEqual(planned.id, "home-ai-fixed")
        XCTAssertEqual(planned.title, "番茄炒蛋")
        XCTAssertEqual(recipes.recipe(id: planned.id), planned, "the plan must point at a resolvable recipe")
        XCTAssertEqual(kitchen.todayPlans.map(\.recipeID), ["home-ai-fixed"])
        XCTAssertEqual(outcome.toastMessage, "已加入今天，并保存到菜谱库")
    }

    func testAddingTheSameAIRecommendationAgainReusesTheSavedRecipe() {
        let (recipes, kitchen) = makeStores()
        var ids = ["home-ai-first", "home-ai-second"]
        let makeID = { ids.removeFirst() }

        _ = HomeRecommendationPlanning.addToToday(aiRecipe(), recipeStore: recipes, kitchenStore: kitchen, makeRecipeID: makeID)
        let second = HomeRecommendationPlanning.addToToday(aiRecipe(), recipeStore: recipes, kitchenStore: kitchen, makeRecipeID: makeID)

        XCTAssertEqual(second, .alreadyToday(recipe: recipes.recipe(id: "home-ai-first")!))
        XCTAssertEqual(recipes.userRecipes.map(\.id), ["home-ai-first"], "no duplicate recipe")
        XCTAssertEqual(kitchen.todayPlans.count, 1)
    }

    func testSameNameDifferentDishDoesNotCollideWithAnEarlierSave() {
        let (recipes, kitchen) = makeStores()
        var ids = ["home-ai-first", "home-ai-second"]
        let makeID = { ids.removeFirst() }

        _ = HomeRecommendationPlanning.addToToday(aiRecipe(), recipeStore: recipes, kitchenStore: kitchen, makeRecipeID: makeID)
        let other = HomeRecommendationPlanning.addToToday(
            aiRecipe(steps: ["番茄去皮", "加糖炒"]),
            recipeStore: recipes,
            kitchenStore: kitchen,
            makeRecipeID: makeID
        )

        guard case .added(let planned, true) = other else {
            return XCTFail("expected a second saved recipe, got \(other)")
        }
        XCTAssertEqual(planned.id, "home-ai-second")
        XCTAssertEqual(Set(recipes.userRecipes.map(\.id)), ["home-ai-first", "home-ai-second"])
    }

    func testLibraryRecommendationIsPlannedWithoutSaving() {
        let (recipes, kitchen) = makeStores()
        let sample = Recipe.samples[0]

        let outcome = HomeRecommendationPlanning.addToToday(sample, recipeStore: recipes, kitchenStore: kitchen)

        XCTAssertEqual(outcome, .added(recipe: sample, savedToLibrary: false))
        XCTAssertEqual(outcome.toastMessage, "已加入今天")
        XCTAssertTrue(recipes.userRecipes.isEmpty)
        XCTAssertEqual(kitchen.todayPlans.map(\.recipeID), [sample.id])
    }

    func testCardIsRepointedAtTheSavedRecipe() async {
        let card = RecipeRecommendation(recipe: aiRecipe(), reason: "用掉番茄", source: .ai)
        let store = HomeRecommendationStore(aiService: StubAIRecommendationService(recommendations: [card]))
        await store.generateNewRecommendations(inventory: [], expiringIngredients: [])
        XCTAssertEqual(store.recommendedRecipes.map(\.id), ["ai-番茄炒蛋"])

        let saved = aiRecipe("home-ai-fixed")
        store.replaceRecommendationRecipe(id: card.id, with: saved)

        XCTAssertEqual(store.recommendedRecipes.map(\.id), ["home-ai-fixed"])
        XCTAssertEqual(store.recommendedRecipes.first?.reason, "用掉番茄")
        XCTAssertEqual(store.recommendedRecipes.first?.source, .ai)
    }
}

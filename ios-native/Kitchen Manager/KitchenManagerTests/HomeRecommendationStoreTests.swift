import XCTest
@testable import KitchenManager

@MainActor
final class HomeRecommendationStoreTests: XCTestCase {
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

    private struct ReplacingAIRecommendationService: AIRecommendationProviding {
        let first: [RecipeRecommendation]
        let second: [RecipeRecommendation]

        func generateRecommendations(
            query: String,
            inventory: [String],
            expiringIngredients: [String],
            preferences: [String],
            excludedRecipeNames: [String],
            count: Int
        ) async throws -> [RecipeRecommendation] {
            excludedRecipeNames.contains(first[0].recipe.title) ? second : first
        }
    }

    private final class TestClock {
        var date: Date

        init(date: Date) {
            self.date = date
        }
    }

    private func recipe(_ id: String, title: String) -> Recipe {
        Recipe(
            id: id,
            title: title,
            cookingTime: 20,
            difficulty: "简单",
            tags: [],
            ingredients: ["番茄"],
            seasonings: [],
            steps: ["完成"]
        )
    }

    func testGeneratedRecommendationsSurviveOpeningRecipeAndReturningToPage() async {
        let generated = [
            RecipeRecommendation(recipe: recipe("ai-one", title: "AI 菜一"), reason: "理由一", source: .ai),
            RecipeRecommendation(recipe: recipe("ai-two", title: "AI 菜二"), reason: "理由二", source: .ai)
        ]
        let store = HomeRecommendationStore(
            aiService: StubAIRecommendationService(recommendations: generated)
        )
        let localRecipe = recipe("local", title: "本地菜")

        store.loadDefaultRecommendations(recipes: [localRecipe], inventory: [], expiringIngredients: [])
        await store.generateNewRecommendations(inventory: [], expiringIngredients: [])
        store.currentRecommendationIndex = 1

        let expectedIDs = store.recommendedRecipes.map(\.id)
        let expectedIndex = store.currentRecommendationIndex

        // RecipeRecommendationBrowserView cancels in-flight work when its navigation
        // destination is pushed. Re-running its task on return must not reload defaults.
        store.cancelRequests()
        store.loadDefaultRecommendations(recipes: [localRecipe], inventory: [], expiringIngredients: [])

        XCTAssertEqual(store.recommendedRecipes.map(\.id), expectedIDs)
        XCTAssertEqual(store.currentRecommendationIndex, expectedIndex)
        XCTAssertEqual(store.recommendedRecipes.map(\.recipe.title), ["AI 菜一", "AI 菜二"])
    }

    func testExplicitlyGeneratingAgainReplacesExistingRecommendationSession() async {
        let first = [
            RecipeRecommendation(recipe: recipe("ai-first", title: "第一批 AI 菜"), reason: nil, source: .ai)
        ]
        let second = [
            RecipeRecommendation(recipe: recipe("ai-second", title: "第二批 AI 菜"), reason: nil, source: .ai)
        ]
        let store = HomeRecommendationStore(
            aiService: ReplacingAIRecommendationService(first: first, second: second)
        )

        store.loadDefaultRecommendations(recipes: [recipe("local", title: "本地菜")], inventory: [], expiringIngredients: [])
        await store.generateNewRecommendations(inventory: [], expiringIngredients: [])
        XCTAssertEqual(store.recommendedRecipes.map(\.id), ["ai-first"])

        await store.generateNewRecommendations(inventory: [], expiringIngredients: [])

        XCTAssertEqual(store.recommendedRecipes.map(\.id), ["ai-second"])
    }

    func testDateChangeInvalidatesSessionAndReloadsDefaultRecommendations() {
        let calendar = Calendar.current
        let clock = TestClock(date: calendar.startOfDay(for: Date()))
        let dayOneRecipe = recipe("day-one", title: "前一天推荐")
        let dayTwoRecipe = recipe("day-two", title: "新一天推荐")
        let store = HomeRecommendationStore(currentDate: { clock.date })

        store.loadDefaultRecommendations(recipes: [dayOneRecipe], inventory: [], expiringIngredients: [])
        XCTAssertEqual(store.recommendedRecipes.map(\.id), ["day-one"])

        clock.date = calendar.date(byAdding: .day, value: 1, to: clock.date)!
        store.loadDefaultRecommendations(recipes: [dayTwoRecipe], inventory: [], expiringIngredients: [])

        XCTAssertEqual(store.recommendedRecipes.map(\.id), ["day-two"])
    }
}

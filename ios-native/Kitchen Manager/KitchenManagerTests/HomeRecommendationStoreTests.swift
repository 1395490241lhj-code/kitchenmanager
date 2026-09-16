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

    private struct SuspendingAIRecommendationService: AIRecommendationProviding {
        let gate: Gate
        /// What the parked request does once the latch opens. `nil` throws, so
        /// the failure regressions read as before; a value returns, including
        /// the empty array a provider is entitled to answer with.
        var outcome: [RecipeRecommendation]?

        func generateRecommendations(
            query: String,
            inventory: [String],
            expiringIngredients: [String],
            preferences: [String],
            excludedRecipeNames: [String],
            count: Int
        ) async throws -> [RecipeRecommendation] {
            await gate.wait()
            guard let outcome else { throw AIChatServiceError.unavailable }
            return outcome
        }
    }

    /// A latch the store's request parks behind until the test decides the
    /// request should fail. `isSearchingRecommendations` turns true *before*
    /// the request reaches the provider, so the test can release the latch
    /// first; the `released` flag makes that ordering harmless instead of
    /// parking the request forever.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            await withCheckedContinuation { (pending: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released {
                    lock.unlock()
                    pending.resume()
                } else {
                    continuation = pending
                    lock.unlock()
                }
            }
        }

        func release() {
            lock.lock()
            released = true
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
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

    /// A failed request never produced a new result set, so it has no
    /// authority to rewrite the live list. Cards removed while the request was
    /// in flight must stay removed when the request later fails.
    func testSearchFailureDoesNotRestoreRecommendationRemovedDuringRequest() async {
        let gate = Gate()
        let store = HomeRecommendationStore(
            aiService: SuspendingAIRecommendationService(gate: gate)
        )
        store.loadDefaultRecommendations(
            recipes: [recipe("a", title: "菜甲"), recipe("b", title: "菜乙"), recipe("c", title: "菜丙")],
            inventory: [],
            expiringIngredients: []
        )
        XCTAssertEqual(store.recommendedRecipes.map(\.id), ["a", "b", "c"])

        store.searchQuery = "菜"
        let search = Task {
            await store.searchRecommendations(
                recipes: [],
                inventory: [],
                expiringIngredients: []
            )
        }
        for _ in 0..<200 where !store.isSearchingRecommendations {
            await Task.yield()
        }
        XCTAssertTrue(store.isSearchingRecommendations, "the search request must be active")

        store.removeRecommendation(id: "b")
        XCTAssertEqual(store.recommendedRecipes.map(\.id), ["a", "c"], "the removal must be live during the wait")

        gate.release()
        await search.value

        XCTAssertEqual(
            store.recommendedRecipes.map(\.id),
            ["a", "c"],
            "a failed search must not resurrect a card removed during the wait"
        )
        XCTAssertNotNil(store.recommendationError, "the safe failure must still surface")
    }

    /// Same live-state rule for AI 换几道: the failure branch restores a
    /// pre-await snapshot today, so a removal made during the wait is undone.
    func testAIGenerationFailureDoesNotRestoreRecommendationRemovedDuringRequest() async {
        let gate = Gate()
        let store = HomeRecommendationStore(
            aiService: SuspendingAIRecommendationService(gate: gate)
        )
        store.loadDefaultRecommendations(
            recipes: [recipe("a", title: "菜甲"), recipe("b", title: "菜乙"), recipe("c", title: "菜丙")],
            inventory: [],
            expiringIngredients: []
        )

        let generation = Task { await store.generateNewRecommendations(inventory: [], expiringIngredients: []) }
        for _ in 0..<200 where !store.isGeneratingRecommendations {
            await Task.yield()
        }
        XCTAssertTrue(store.isGeneratingRecommendations, "the AI request must be active")

        store.removeRecommendation(id: "b")
        XCTAssertEqual(store.recommendedRecipes.map(\.id), ["a", "c"], "the removal must be live during the wait")

        gate.release()
        await generation.value

        XCTAssertEqual(
            store.recommendedRecipes.map(\.id),
            ["a", "c"],
            "a failed AI generation must not resurrect a card removed during the wait"
        )
        XCTAssertNotNil(store.recommendationError, "the safe failure must still surface")
    }

    /// The provider answering with nothing is not a successful replacement. The
    /// call returned without throwing, but it produced no result set, so it has
    /// the same standing as a failure: keep the live list, say that nothing came
    /// back, and leave a card removed during the wait removed.
    func testAIGenerationEmptyResultDoesNotRestoreRecommendationRemovedDuringRequest() async {
        let gate = Gate()
        let store = HomeRecommendationStore(
            aiService: SuspendingAIRecommendationService(gate: gate, outcome: [])
        )
        store.loadDefaultRecommendations(
            recipes: [recipe("a", title: "菜甲"), recipe("b", title: "菜乙"), recipe("c", title: "菜丙")],
            inventory: [],
            expiringIngredients: []
        )
        XCTAssertEqual(store.recommendedRecipes.map(\.id), ["a", "b", "c"])

        let generation = Task { await store.generateNewRecommendations(inventory: [], expiringIngredients: []) }
        for _ in 0..<200 where !store.isGeneratingRecommendations {
            await Task.yield()
        }
        XCTAssertTrue(store.isGeneratingRecommendations, "the AI request must be active")

        store.removeRecommendation(id: "b")
        XCTAssertEqual(store.recommendedRecipes.map(\.id), ["a", "c"], "the removal must be live during the wait")

        gate.release()
        await generation.value

        XCTAssertEqual(
            store.recommendedRecipes.map(\.id),
            ["a", "c"],
            "an empty AI result must not resurrect a card removed during the wait"
        )
        XCTAssertEqual(
            store.recommendationError,
            "AI 推荐暂时不可用，仍可以继续浏览本地推荐。",
            "the existing zero-result sentence is unchanged"
        )
        XCTAssertFalse(store.isGeneratingRecommendations, "the request must release its busy state")
    }

    /// The sentence has to describe the screen the member is actually looking
    /// at. If they removed the last card while the request was in flight, there
    /// is nothing local left to browse, so offering it is simply untrue. The
    /// live list decides the wording, never the pre-await snapshot.
    ///
    /// The companion case — cards still on screen keeps the local-browsing tail
    /// — is already covered by
    /// `testAIGenerationEmptyResultDoesNotRestoreRecommendationRemovedDuringRequest`
    /// above, which asserts the full tailed sentence while a and c remain.
    func testAIEmptyResultDoesNotClaimLocalRecommendationsWhenLiveListIsEmpty() async throws {
        let gate = Gate()
        let store = HomeRecommendationStore(
            aiService: SuspendingAIRecommendationService(gate: gate, outcome: [])
        )
        store.loadDefaultRecommendations(
            recipes: [recipe("a", title: "菜甲")],
            inventory: [],
            expiringIngredients: []
        )
        XCTAssertEqual(store.recommendedRecipes.map(\.id), ["a"])

        let generation = Task { await store.generateNewRecommendations(inventory: [], expiringIngredients: []) }
        for _ in 0..<200 where !store.isGeneratingRecommendations {
            await Task.yield()
        }
        XCTAssertTrue(store.isGeneratingRecommendations, "the AI request must be active")

        store.removeRecommendation(id: "a")
        XCTAssertTrue(store.recommendedRecipes.isEmpty, "the member removed the last card during the wait")

        gate.release()
        await generation.value

        XCTAssertTrue(store.recommendedRecipes.isEmpty, "nothing came back, so nothing fills the list")

        let message = try XCTUnwrap(store.recommendationError, "the empty result must still be reported")
        XCTAssertFalse(
            message.contains("仍可以继续浏览本地推荐"),
            "there is nothing local left on screen to browse"
        )
        XCTAssertEqual(message, "AI 推荐暂时不可用。")
        XCTAssertEqual(
            message,
            HomeRecommendationStore.recommendationErrorMessage(
                for: AIChatServiceError.unavailable,
                hasLocalResults: false
            ),
            "the zero-result sentence must agree with the Home error boundary's own no-local-results answer"
        )
        XCTAssertFalse(store.isGeneratingRecommendations, "the request must release its busy state")
    }
}

import XCTest
@testable import KitchenManager

/// An async dish replacement patches the live draft, never a copy taken before
/// the request went out: edits made to other dishes while it ran survive, and a
/// target that vanished meanwhile stays gone. Cancellation of the weekly
/// generation keeps a late result from writing anything.
@MainActor
final class WeeklyMenuReplaceConcurrencyTests: XCTestCase {
    /// Holds each generator call open until the test releases it, so the
    /// "while the request is in flight" window is exact rather than timed.
    private final class Gate {
        private var waiters: [CheckedContinuation<AIWeeklyMenuResponse, Error>] = []
        var pendingCount: Int { waiters.count }

        func next() async throws -> AIWeeklyMenuResponse {
            try await withCheckedThrowingContinuation { waiters.append($0) }
        }

        func complete(with dish: String) throws {
            guard !waiters.isEmpty else { return XCTFail("no request is waiting") }
            waiters.removeFirst().resume(returning: try Self.response(dishes: [dish]))
        }

        static func response(dishes: [String]) throws -> AIWeeklyMenuResponse {
            let days: [[String: Any]] = dishes.enumerated().map { index, name in
                ["dayIndex": index,
                 "meals": [["mealIndex": 0, "title": "晚餐",
                            "recipes": [["name": name, "ingredients": ["番茄 2 个"], "steps": ["炒熟"], "source": "ai"]]]]]
            }
            return try JSONDecoder().decode(
                AIWeeklyMenuResponse.self,
                from: JSONSerialization.data(withJSONObject: ["days": days])
            )
        }
    }

    private struct Harness {
        let store: WeeklyMenuPlannerStore
        let gate: Gate
        let kitchen: KitchenStore
        let recipes: RecipeStore
    }

    private func makeHarness() -> Harness {
        let gate = Gate()
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let kitchen = KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList,
            todayPlanPersistence: bundle.todayPlan,
            consumptionPersistence: bundle.consumption,
            weeklyPlanPersistence: bundle.weeklyPlan,
            preparedComponentPersistence: bundle.preparedComponents,
            specialPlanPersistence: bundle.specialPlans
        )
        let recipes = RecipeStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            userRecipePersistence: bundle.userRecipes,
            recipePreferencePersistence: bundle.recipePreferences
        )
        let store = WeeklyMenuPlannerStore(generate: { _ in try await gate.next() })
        return Harness(store: store, gate: gate, kitchen: kitchen, recipes: recipes)
    }

    private func dish(_ id: String, _ title: String) -> WeeklyMealPlanRecipe {
        WeeklyMealPlanRecipe(id: id, title: title, ingredients: ["番茄 2 个"], steps: ["炒熟"],
                             tags: [], cookingTime: 10, difficulty: nil, reason: nil, source: .ai, existingRecipeID: nil)
    }

    /// A on day 0, B on day 1, day 2 empty.
    private func seededPlan() -> WeeklyMealPlan {
        WeeklyMealPlan(
            startDate: Date(),
            days: [
                WeeklyMealPlanDay(dayIndex: 0, meals: [WeeklyMealPlanMeal(mealIndex: 0, title: "晚餐", recipes: [dish("a", "菜 A")])]),
                WeeklyMealPlanDay(dayIndex: 1, meals: [WeeklyMealPlanMeal(mealIndex: 0, title: "晚餐", recipes: [dish("b", "菜 B")])]),
                WeeklyMealPlanDay(dayIndex: 2, meals: [])
            ],
            shoppingItems: [], servings: 2, summary: nil, createdAt: Date()
        )
    }

    private func titles(_ plan: WeeklyMealPlan?, day: Int) -> [String] {
        plan?.days.first { $0.dayIndex == day }?.meals.flatMap { $0.recipes.map(\.title) } ?? []
    }

    /// Starts replacing A and returns once the request is genuinely waiting.
    private func startReplacingA(_ h: Harness) async -> Task<Void, Never> {
        let task = Task {
            await h.store.replaceRecipe(dayIndex: 0, mealIndex: 0, recipeID: "a", recipeStore: h.recipes, kitchenStore: h.kitchen)
        }
        while h.gate.pendingCount == 0 { await Task.yield() }
        XCTAssertEqual(h.store.replacingRecipeID, "a")
        return task
    }

    // A1
    func testUnrelatedRemoveSurvivesReplacement() async throws {
        let h = makeHarness()
        h.store.generatedPlan = seededPlan()
        let replace = await startReplacingA(h)

        h.store.removeRecipe("b", dayIndex: 1, mealIndex: 0)
        XCTAssertEqual(titles(h.store.generatedPlan, day: 1), [])

        try h.gate.complete(with: "新菜 A")
        await replace.value

        XCTAssertEqual(titles(h.store.generatedPlan, day: 0), ["新菜 A"], "A is replaced")
        XCTAssertEqual(titles(h.store.generatedPlan, day: 1), [], "B stays removed")
        XCTAssertNil(h.store.replacingRecipeID)
        XCTAssertNil(h.store.errorMessage)
    }

    // A2
    func testUnrelatedMoveSurvivesReplacement() async throws {
        let h = makeHarness()
        h.store.generatedPlan = seededPlan()
        let replace = await startReplacingA(h)

        h.store.moveRecipe("b", fromDay: 1, mealIndex: 0, toDay: 2)
        XCTAssertEqual(titles(h.store.generatedPlan, day: 2), ["菜 B"])

        try h.gate.complete(with: "新菜 A")
        await replace.value

        XCTAssertEqual(titles(h.store.generatedPlan, day: 0), ["新菜 A"], "A is replaced")
        XCTAssertEqual(titles(h.store.generatedPlan, day: 1), [], "B is no longer on its old day")
        XCTAssertEqual(titles(h.store.generatedPlan, day: 2), ["菜 B"], "B keeps its live position")
    }

    // A3
    func testTargetRemovedWhileInFlightIsNotResurrected() async throws {
        let h = makeHarness()
        h.store.generatedPlan = seededPlan()
        let replace = await startReplacingA(h)

        h.store.removeRecipe("a", dayIndex: 0, mealIndex: 0)
        XCTAssertEqual(titles(h.store.generatedPlan, day: 0), [])

        try h.gate.complete(with: "新菜 A")
        await replace.value

        XCTAssertEqual(titles(h.store.generatedPlan, day: 0), [], "the dropped result resurrects nothing")
        XCTAssertEqual(titles(h.store.generatedPlan, day: 1), ["菜 B"])
        XCTAssertNil(h.store.errorMessage, "dropping a stale result is not an error")
        XCTAssertNil(h.store.replacingRecipeID)
    }

    // A4 — ownership: a superseded replacement's late result writes nothing.
    func testSupersededReplacementCannotWriteALateResult() async throws {
        let h = makeHarness()
        h.store.generatedPlan = seededPlan()
        let first = await startReplacingA(h)

        // A second replacement (of B) takes ownership; the first request is cancelled.
        let second = Task {
            await h.store.replaceRecipe(dayIndex: 1, mealIndex: 0, recipeID: "b", recipeStore: h.recipes, kitchenStore: h.kitchen)
        }
        while h.gate.pendingCount < 2 { await Task.yield() }
        XCTAssertEqual(h.store.replacingRecipeID, "b")

        try h.gate.complete(with: "迟到的 A")   // first request's late answer
        await first.value
        XCTAssertEqual(titles(h.store.generatedPlan, day: 0), ["菜 A"], "the superseded request must not touch A")
        XCTAssertEqual(h.store.replacingRecipeID, "b", "the owner's busy state is untouched by the loser")

        try h.gate.complete(with: "新菜 B")
        await second.value
        XCTAssertEqual(titles(h.store.generatedPlan, day: 1), ["新菜 B"])
        XCTAssertNil(h.store.replacingRecipeID)
    }

    // Leaving the weekly workflow drops an in-flight replacement too: the store
    // goes with the route, and a late answer must not land on the draft it left.
    func testAbandoningTheWorkflowDropsAnInFlightReplacement() async throws {
        let h = makeHarness()
        h.store.generatedPlan = seededPlan()
        let replace = await startReplacingA(h)

        h.store.abandonWorkflow()
        XCTAssertNil(h.store.replacingRecipeID, "abandonment clears the busy row")

        try h.gate.complete(with: "迟到的 A")
        await replace.value

        XCTAssertEqual(titles(h.store.generatedPlan, day: 0), ["菜 A"],
                       "a late replacement must not touch an abandoned draft")
        XCTAssertEqual(titles(h.store.generatedPlan, day: 1), ["菜 B"])
        XCTAssertNil(h.store.errorMessage, "abandonment is not an error")
    }

    // Slice B store side: real abandonment cancels, and the late result cannot write.
    func testCancelledGenerationIgnoresALateResult() async throws {
        let h = makeHarness()
        h.store.input.allowNewAIRecipes = true   // an empty library is fine when AI may invent dishes
        let generation = Task {
            await h.store.generatePlan(recipeStore: h.recipes, kitchenStore: h.kitchen)
        }
        while h.gate.pendingCount == 0 { await Task.yield() }
        XCTAssertTrue(h.store.isGenerating)

        h.store.cancelGeneration()
        XCTAssertFalse(h.store.isGenerating)

        try h.gate.complete(with: "迟到的菜单")
        // Awaited only to let the cancelled request finish unwinding; what it
        // reports is irrelevant here, because the assertions below check the
        // stronger fact that it published nothing at all.
        _ = await generation.value
        XCTAssertNil(h.store.generatedPlan, "a cancelled generation never publishes its late result")
        XCTAssertNil(h.store.errorMessage, "cancellation is not an error")
    }
}

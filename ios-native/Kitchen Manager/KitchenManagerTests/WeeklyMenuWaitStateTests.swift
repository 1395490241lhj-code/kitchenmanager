import XCTest
@testable import KitchenManager

/// The weekly waiting state is only honest if the way out of it is real: a
/// cancelled whole-menu request must leave the form, the draft and the busy
/// flag exactly as the member left them, and its late answer must write
/// nothing. These tests drive the store directly, so the in-flight window is
/// exact rather than timed.
@MainActor
final class WeeklyMenuWaitStateTests: XCTestCase {
    /// Holds every generator call open until the test answers it.
    private final class Gate {
        private var waiters: [CheckedContinuation<AIWeeklyMenuResponse, Error>] = []
        var pendingCount: Int { waiters.count }

        func next() async throws -> AIWeeklyMenuResponse {
            try await withCheckedThrowingContinuation { waiters.append($0) }
        }

        func complete(with dish: String) throws {
            guard !waiters.isEmpty else { return XCTFail("no request is waiting") }
            waiters.removeFirst().resume(returning: try Self.response(dish: dish))
        }

        func fail(with error: Error) {
            guard !waiters.isEmpty else { return XCTFail("no request is waiting") }
            waiters.removeFirst().resume(throwing: error)
        }

        static func response(dish: String) throws -> AIWeeklyMenuResponse {
            let days: [[String: Any]] = [
                ["dayIndex": 0,
                 "meals": [["mealIndex": 0, "title": "晚餐",
                            "recipes": [["name": dish, "ingredients": ["番茄 2 个"], "steps": ["炒熟"], "source": "ai"]]]]]
            ]
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
                             tags: [], cookingTime: 10, difficulty: nil, reason: nil,
                             source: .ai, existingRecipeID: nil)
    }

    /// A on day 0, B on day 1.
    private func seededPlan() -> WeeklyMealPlan {
        WeeklyMealPlan(
            startDate: Date(),
            days: [
                WeeklyMealPlanDay(dayIndex: 0, meals: [WeeklyMealPlanMeal(mealIndex: 0, title: "晚餐", recipes: [dish("a", "菜 A")])]),
                WeeklyMealPlanDay(dayIndex: 1, meals: [WeeklyMealPlanMeal(mealIndex: 0, title: "晚餐", recipes: [dish("b", "菜 B")])])
            ],
            shoppingItems: [], servings: 2, summary: nil, createdAt: Date()
        )
    }

    private func titles(_ plan: WeeklyMealPlan?) -> [String] {
        (plan?.days ?? []).flatMap { $0.meals.flatMap { $0.recipes.map(\.title) } }
    }

    private func startGenerating(_ h: Harness) async -> Task<Bool, Never> {
        let task = Task { await h.store.generatePlan(recipeStore: h.recipes, kitchenStore: h.kitchen) }
        while h.gate.pendingCount == 0 { await Task.yield() }
        XCTAssertTrue(h.store.isGenerating)
        return task
    }

    private func startRegenerating(_ h: Harness) async -> Task<Bool, Never> {
        let task = Task { await h.store.regeneratePlan(recipeStore: h.recipes, kitchenStore: h.kitchen) }
        while h.gate.pendingCount == 0 { await Task.yield() }
        XCTAssertTrue(h.store.isGenerating)
        return task
    }

    // MARK: - Initial generation

    /// W2 — cancelling leaves the form exactly as it was and clears the busy
    /// state, with nothing to apologise for.
    func testCancellingInitialGenerationKeepsTheFormAndSaysNothing() async throws {
        let h = makeHarness()
        h.store.input.numberOfDays = 4
        h.store.input.servings = 5
        h.store.input.selectedCuisines = ["川菜"]
        h.store.input.additionalRequest = "适合带饭"
        let generation = await startGenerating(h)

        h.store.cancelGeneration()

        XCTAssertFalse(h.store.isGenerating, "the busy state clears immediately")
        XCTAssertNil(h.store.errorMessage, "cancellation is not a failure")
        XCTAssertEqual(h.store.input.numberOfDays, 4)
        XCTAssertEqual(h.store.input.servings, 5)
        XCTAssertEqual(h.store.input.selectedCuisines, ["川菜"])
        XCTAssertEqual(h.store.input.additionalRequest, "适合带饭")

        try h.gate.complete(with: "迟到的菜")
        let installed = await generation.value
        XCTAssertFalse(installed, "a cancelled run must not tell the screen to move on")
    }

    /// W3 — the late answer of a cancelled request installs nothing.
    func testLateResultAfterCancelInstallsNothing() async throws {
        let h = makeHarness()
        let generation = await startGenerating(h)

        h.store.cancelGeneration()
        try h.gate.complete(with: "迟到的菜")
        let installed = await generation.value

        XCTAssertFalse(installed)
        XCTAssertNil(h.store.generatedPlan, "a cancelled generation never publishes its result")
        XCTAssertNil(h.store.errorMessage)
        XCTAssertFalse(h.store.isGenerating)
    }

    /// W3 (navigation half) — a cancelled run on a screen that already shows a
    /// saved menu must still not report success, or the member would be carried
    /// to a result they did not ask for.
    func testCancelDoesNotReportSuccessJustBecauseASavedMenuExists() async throws {
        let h = makeHarness()
        h.store.generatedPlan = seededPlan()      // 查看上次生成的菜单 state
        let generation = await startGenerating(h)

        h.store.cancelGeneration()
        try h.gate.complete(with: "迟到的菜")

        let installed = await generation.value
        XCTAssertFalse(installed, "an existing draft is not this request's result")
        XCTAssertEqual(titles(h.store.generatedPlan), ["菜 A", "菜 B"], "the saved menu is untouched")
    }

    /// The other way a request can fail to install: it threw. An older menu is
    /// already on the store, so "a plan exists" would read as success — the
    /// invocation result must say otherwise, or the member would be shown that
    /// stale menu as though this request had produced it.
    func testFailedGenerationDoesNotReportSuccessJustBecauseASavedMenuExists() async throws {
        let h = makeHarness()
        h.store.generatedPlan = seededPlan()      // 查看上次生成的菜单 state
        let generation = await startGenerating(h)

        h.gate.fail(with: WeeklyMenuPlannerError.invalidResponse)
        let installed = await generation.value

        XCTAssertFalse(installed, "a failed request must not masquerade as a successful one")
        XCTAssertEqual(titles(h.store.generatedPlan), ["菜 A", "菜 B"], "the existing menu is left alone")
        XCTAssertEqual(h.store.errorMessage, WeeklyMenuPlannerError.invalidResponse.localizedDescription)
        XCTAssertFalse(h.store.isGenerating)
    }

    /// W4 — cancelling does not poison the next attempt.
    func testExplicitRetryAfterCancelStartsAFreshRequestAndSucceeds() async throws {
        let h = makeHarness()
        let first = await startGenerating(h)
        h.store.cancelGeneration()
        try h.gate.complete(with: "迟到的菜")
        _ = await first.value

        let retry = await startGenerating(h)
        try h.gate.complete(with: "新菜单")
        let installed = await retry.value

        XCTAssertTrue(installed, "the retry reaches the existing result flow")
        XCTAssertEqual(titles(h.store.generatedPlan), ["新菜单"])
        XCTAssertFalse(h.store.isGenerating)
        XCTAssertNil(h.store.errorMessage)
    }

    // MARK: - Regeneration

    /// R2 / R3 — cancelling a regeneration preserves the previous menu exactly,
    /// and the cancelled answer cannot replace it afterwards.
    func testCancellingRegenerationPreservesThePreviousMenu() async throws {
        let h = makeHarness()
        h.store.generatedPlan = seededPlan()
        let regeneration = await startRegenerating(h)

        h.store.cancelGeneration()
        XCTAssertFalse(h.store.isGenerating, "the waiting state is gone")
        XCTAssertEqual(titles(h.store.generatedPlan), ["菜 A", "菜 B"])

        try h.gate.complete(with: "迟到的菜单")
        let installed = await regeneration.value
        XCTAssertFalse(installed)
        XCTAssertEqual(titles(h.store.generatedPlan), ["菜 A", "菜 B"], "a cancelled result replaces nothing")
        XCTAssertNil(h.store.errorMessage, "cancellation shows nothing")
    }

    /// R4 — a successful whole-menu regeneration replaces the draft wholesale,
    /// keeping the week it was planned for. This is the sealed product rule;
    /// only cancel and failure preserve the live draft.
    func testSuccessfulRegenerationReplacesTheWholeDraft() async throws {
        let h = makeHarness()
        let previous = seededPlan()
        h.store.generatedPlan = previous
        let regeneration = await startRegenerating(h)

        try h.gate.complete(with: "全新的菜")
        let installed = await regeneration.value
        XCTAssertTrue(installed)

        XCTAssertEqual(titles(h.store.generatedPlan), ["全新的菜"], "the new menu replaces the old one")
        XCTAssertEqual(h.store.generatedPlan?.startDate, previous.startDate, "the week it covers is kept")
        XCTAssertNil(h.store.generatedPlan?.materialization, "a fresh draft carries no receipt")
        XCTAssertFalse(h.store.isGenerating)
    }

    /// R5 — a second whole-menu request cannot start while one is running.
    func testRegenerationCannotStartASecondConcurrentRequest() async throws {
        let h = makeHarness()
        h.store.generatedPlan = seededPlan()
        let regeneration = await startRegenerating(h)

        let second = await h.store.regeneratePlan(recipeStore: h.recipes, kitchenStore: h.kitchen)
        XCTAssertFalse(second, "the repeated action is refused")
        XCTAssertEqual(h.gate.pendingCount, 1, "only one request is ever in flight")

        let alsoInitial = await h.store.generatePlan(recipeStore: h.recipes, kitchenStore: h.kitchen)
        XCTAssertFalse(alsoInitial)
        XCTAssertEqual(h.gate.pendingCount, 1)

        try h.gate.complete(with: "全新的菜")
        let installed = await regeneration.value
        XCTAssertTrue(installed, "the original request is unharmed")
    }

    /// R6 — an edit made while a regeneration was waiting survives cancelling
    /// it. The draft on screen is live state, not a snapshot to roll back to.
    func testEditMadeDuringRegenerationSurvivesCancellation() async throws {
        let h = makeHarness()
        h.store.generatedPlan = seededPlan()
        let regeneration = await startRegenerating(h)

        h.store.removeRecipe("b", dayIndex: 1, mealIndex: 0)
        XCTAssertEqual(titles(h.store.generatedPlan), ["菜 A"])

        h.store.cancelGeneration()
        try h.gate.complete(with: "迟到的菜单")
        _ = await regeneration.value

        XCTAssertEqual(titles(h.store.generatedPlan), ["菜 A"], "cancellation must not resurrect 菜 B")
    }

    /// The same rule for the failure path: a request that threw wrote nothing,
    /// so it has nothing to undo. Restoring the copy taken before the await
    /// would silently drop the edit made while it ran.
    func testEditMadeDuringRegenerationSurvivesFailure() async throws {
        let h = makeHarness()
        h.store.generatedPlan = seededPlan()
        let regeneration = await startRegenerating(h)

        h.store.removeRecipe("b", dayIndex: 1, mealIndex: 0)
        h.gate.fail(with: WeeklyMenuPlannerError.invalidResponse)
        let installed = await regeneration.value
        XCTAssertFalse(installed)

        XCTAssertEqual(titles(h.store.generatedPlan), ["菜 A"], "a failed regeneration must not roll the edit back")
        XCTAssertEqual(h.store.errorMessage, WeeklyMenuPlannerError.invalidResponse.localizedDescription,
                       "the existing error wording is untouched")
        XCTAssertFalse(h.store.isGenerating)
    }
}

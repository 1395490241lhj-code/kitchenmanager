import XCTest
@testable import KitchenManager

/// The canonical ordinary-meal write path: explicit dates, an observable
/// persistence outcome, and a delete that can be undone.
@MainActor
final class PlannerMealCRUDTests: XCTestCase {
    /// Succeeds until `shouldFail` is set, so a test can build real state and
    /// then fail exactly the one write it is about.
    private final class ToggleableTodayPlanPersistence: TodayPlanPersistenceProtocol {
        struct ExpectedFailure: Error {}
        var plans: [MealPlanItem] = []
        var shouldFail = false
        var replaceCallCount = 0

        func loadPlans() throws -> [MealPlanItem] { plans }
        func replacePlans(with items: [MealPlanItem]) throws {
            replaceCallCount += 1
            if shouldFail { throw ExpectedFailure() }
            plans = items
        }
        func upsert(_ item: MealPlanItem) throws {}
        func delete(id: UUID) throws {}
        func deleteAll() throws { plans = [] }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
    }

    private func recipe(id: String = "recipe-1", title: String = "番茄炒蛋") -> Recipe {
        Recipe(
            id: id,
            title: title,
            cookingTime: 15,
            difficulty: "简单",
            tags: ["家常菜"],
            ingredients: ["番茄 2 个", "鸡蛋 3 个"],
            seasonings: ["盐 少许"],
            steps: ["炒熟"]
        )
    }

    private func makeStore(
        todayPlan: TodayPlanPersistenceProtocol? = nil
    ) -> (store: KitchenStore, bundle: KitchenPersistenceBundle) {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList,
            todayPlanPersistence: todayPlan ?? bundle.todayPlan,
            consumptionPersistence: bundle.consumption
        )
        return (store, bundle)
    }

    // MARK: - Explicit-date add

    func testExplicitAddUsesTheStatedCivilDay() {
        let calendar = self.calendar
        let (store, _) = makeStore()
        let target = day(2026, 3, 18, calendar: calendar)

        let outcome = store.addPlan(recipe: recipe(), on: target, plannedServings: 2, calendar: calendar)

        let item = try? XCTUnwrap(outcome.value)
        XCTAssertNotNil(item)
        XCTAssertTrue(calendar.isDate(store.plans[0].date, inSameDayAs: target))
        XCTAssertEqual(calendar.component(.hour, from: store.plans[0].date), 12)
    }

    func testExplicitAddCopiesRecipeIdentityAndAppends() {
        let calendar = self.calendar
        let (store, _) = makeStore()
        let target = day(2026, 3, 18, calendar: calendar)
        store.addPlan(recipe: recipe(id: "a", title: "A"), on: target, calendar: calendar)
        store.addPlan(recipe: recipe(id: "b", title: "B"), on: target, calendar: calendar)

        XCTAssertEqual(store.plans.map(\.recipeID), ["a", "b"])
        XCTAssertEqual(store.plans.map(\.recipeName), ["A", "B"])
    }

    func testExplicitAddPermitsADuplicateRecipeOnTheSameDay() {
        let calendar = self.calendar
        let (store, _) = makeStore()
        let target = day(2026, 3, 18, calendar: calendar)
        let dish = recipe()
        store.addPlan(recipe: dish, on: target, plannedServings: 2, calendar: calendar)
        store.addPlan(recipe: dish, on: target, plannedServings: 4, calendar: calendar)

        XCTAssertEqual(store.plans.count, 2, "an explicit save is deliberate, not an accidental second tap")
        XCTAssertEqual(store.plans.map(\.plannedServings), [2, 4])
        XCTAssertNotEqual(store.plans[0].id, store.plans[1].id)
    }

    func testOneTapTodayAddStillDeduplicates() {
        let (store, _) = makeStore()
        let dish = recipe()
        store.addPlan(recipe: dish, plannedServings: 2)
        store.addPlan(recipe: dish, plannedServings: 4)

        XCTAssertEqual(store.plans.count, 1, "the existing one-tap dedup must be untouched")
        XCTAssertEqual(store.plans[0].plannedServings, 2)
    }

    func testExplicitAddKeepsServingsSemantics() {
        let calendar = self.calendar
        let (store, _) = makeStore()
        let target = day(2026, 3, 18, calendar: calendar)
        store.addPlan(recipe: recipe(id: "a"), on: target, plannedServings: nil, calendar: calendar)
        store.addPlan(recipe: recipe(id: "b"), on: target, plannedServings: 12, calendar: calendar)
        store.addPlan(recipe: recipe(id: "c"), on: target, plannedServings: 13, calendar: calendar)

        XCTAssertNil(store.plans[0].plannedServings, "unstated stays unstated")
        XCTAssertEqual(store.plans[1].plannedServings, 12, "the top of 1...12 is valid")
        XCTAssertNil(store.plans[2].plannedServings, "out of range is rejected, never clamped")
    }

    // MARK: - Update

    func testUpdateChangesDateAndServingsInOneWrite() throws {
        let calendar = self.calendar
        let persistence = ToggleableTodayPlanPersistence()
        let (store, _) = makeStore(todayPlan: persistence)
        store.addPlan(recipe: recipe(), on: day(2026, 3, 18, calendar: calendar), plannedServings: 2, calendar: calendar)
        let id = try XCTUnwrap(store.plans.first?.id)
        let writesBefore = persistence.replaceCallCount

        let moved = day(2026, 3, 21, calendar: calendar)
        let outcome = store.updatePlan(id: id, on: moved, plannedServings: 6, calendar: calendar)

        XCTAssertTrue(outcome.didPersist)
        XCTAssertEqual(persistence.replaceCallCount - writesBefore, 1, "one logical mutation is one durable write")
        XCTAssertTrue(calendar.isDate(store.plans[0].date, inSameDayAs: moved))
        XCTAssertEqual(store.plans[0].plannedServings, 6)
    }

    func testUpdatePreservesIdentityAndCookedState() throws {
        let calendar = self.calendar
        let (store, _) = makeStore()
        store.addPlan(recipe: recipe(id: "a", title: "A"), on: day(2026, 3, 18, calendar: calendar), calendar: calendar)
        let id = try XCTUnwrap(store.plans.first?.id)
        store.setPlanCooked(id, isCooked: true)

        store.updatePlan(id: id, on: day(2026, 3, 20, calendar: calendar), plannedServings: 3, calendar: calendar)

        XCTAssertEqual(store.plans[0].id, id)
        XCTAssertEqual(store.plans[0].recipeID, "a")
        XCTAssertEqual(store.plans[0].recipeName, "A")
        XCTAssertTrue(store.plans[0].isCooked, "editing a completed plan does not un-cook it")
    }

    func testUpdateRejectsOutOfRangeServingsToNil() throws {
        let calendar = self.calendar
        let (store, _) = makeStore()
        store.addPlan(recipe: recipe(), on: day(2026, 3, 18, calendar: calendar), plannedServings: 4, calendar: calendar)
        let id = try XCTUnwrap(store.plans.first?.id)

        store.updatePlan(id: id, on: day(2026, 3, 18, calendar: calendar), plannedServings: 99, calendar: calendar)

        XCTAssertNil(store.plans[0].plannedServings)
    }

    func testUpdateWithAnUnknownIdIsNotFoundRatherThanFailure() {
        let calendar = self.calendar
        let (store, _) = makeStore()

        let outcome = store.updatePlan(id: UUID(), on: day(2026, 3, 18, calendar: calendar), plannedServings: 2, calendar: calendar)

        XCTAssertTrue(outcome.isNotFound)
        XCTAssertFalse(outcome.didFailToPersist, "a stale reference is not a retryable write failure")
    }

    // MARK: - Remove and restore

    func testRemoveReturnsTheExactItemAndIndex() throws {
        let calendar = self.calendar
        let (store, _) = makeStore()
        let target = day(2026, 3, 18, calendar: calendar)
        for id in ["a", "b", "c"] {
            store.addPlan(recipe: recipe(id: id, title: id), on: target, calendar: calendar)
        }
        let middle = store.plans[1]

        let removal = try XCTUnwrap(store.removePlan(id: middle.id).value)

        XCTAssertEqual(removal.item, middle)
        XCTAssertEqual(removal.index, 1)
        XCTAssertEqual(store.plans.map(\.recipeID), ["a", "c"])
    }

    func testRemoveThenRestoreReproducesTheArrayExactly() throws {
        let calendar = self.calendar
        let (store, bundle) = makeStore()
        let target = day(2026, 3, 18, calendar: calendar)
        for id in ["a", "b", "c"] {
            store.addPlan(recipe: recipe(id: id, title: id), on: target, calendar: calendar)
        }
        let before = store.plans
        let removal = try XCTUnwrap(store.removePlan(id: before[1].id).value)

        let restored = store.restorePlan(removal.item, at: removal.index)

        XCTAssertTrue(restored.didPersist)
        XCTAssertEqual(store.plans, before, "undo restores the same values in the same order")
        XCTAssertEqual(store.plans[1].id, before[1].id, "the same UUID, not a lookalike")
        XCTAssertEqual(try bundle.todayPlan.loadPlans().map(\.recipeID), ["a", "b", "c"])
    }

    func testRestoreClampsAnIndexThatNoLongerExists() throws {
        let calendar = self.calendar
        let (store, _) = makeStore()
        let target = day(2026, 3, 18, calendar: calendar)
        for id in ["a", "b", "c"] {
            store.addPlan(recipe: recipe(id: id, title: id), on: target, calendar: calendar)
        }
        let removal = try XCTUnwrap(store.removePlan(id: store.plans[2].id).value)
        store.removePlan(id: store.plans[0].id)

        XCTAssertTrue(store.restorePlan(removal.item, at: removal.index).didPersist)
        XCTAssertEqual(store.plans.map(\.recipeID), ["b", "c"])
    }

    func testRestoringAnAlreadyPresentIdDoesNotDuplicateIt() throws {
        let calendar = self.calendar
        let persistence = ToggleableTodayPlanPersistence()
        let (store, _) = makeStore(todayPlan: persistence)
        store.addPlan(recipe: recipe(), on: day(2026, 3, 18, calendar: calendar), calendar: calendar)
        let removal = try XCTUnwrap(store.removePlan(id: store.plans[0].id).value)
        store.restorePlan(removal.item, at: removal.index)
        let writesBefore = persistence.replaceCallCount

        XCTAssertTrue(store.restorePlan(removal.item, at: removal.index).didPersist)
        XCTAssertEqual(store.plans.count, 1, "a second undo tap must not create a second row")
        XCTAssertEqual(
            persistence.replaceCallCount - writesBefore, 1,
            "`.saved` off an already-present row still means a durable write actually happened"
        )
    }

    func testRestoringAnAlreadyPresentIdStillReportsAPersistenceFailure() throws {
        let calendar = self.calendar
        let persistence = ToggleableTodayPlanPersistence()
        let (store, _) = makeStore(todayPlan: persistence)
        store.addPlan(recipe: recipe(), on: day(2026, 3, 18, calendar: calendar), calendar: calendar)
        let removal = try XCTUnwrap(store.removePlan(id: store.plans[0].id).value)
        store.restorePlan(removal.item, at: removal.index)
        persistence.shouldFail = true

        XCTAssertTrue(store.restorePlan(removal.item, at: removal.index).didFailToPersist)
    }

    func testRemoveWithAnUnknownIdIsNotFound() {
        let (store, _) = makeStore()
        XCTAssertTrue(store.removePlan(id: UUID()).isNotFound)
    }

    func testCookedAndConsumedLinkageSurvivesRemoveThenRestore() throws {
        let calendar = self.calendar
        let (store, _) = makeStore()
        store.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)
        store.addPlan(recipe: recipe(), on: day(2026, 3, 18, calendar: calendar), plannedServings: 2, calendar: calendar)
        let id = try XCTUnwrap(store.plans.first?.id)
        store.setPlanCooked(id, isCooked: true)
        let drafts = InventoryConsumptionPlanner().plan(
            for: [.init(recipe: recipe(), servings: 2)],
            inventory: store.inventory
        )
        store.applyConsumption(drafts, planIDs: [id], recipeID: "recipe-1", recipeName: "番茄炒蛋")
        XCTAssertTrue(store.hasConsumedPlan(id))

        let removal = try XCTUnwrap(store.removePlan(id: id).value)
        store.restorePlan(removal.item, at: removal.index)

        XCTAssertTrue(store.plans[0].isCooked, "cooked state comes back with the plan")
        XCTAssertTrue(store.hasConsumedPlan(id), "the consumption record still resolves to the same plan id")
    }

    // MARK: - Persistence failure is observable

    func testAddReportsPersistenceFailureAndPublishesNothing() {
        let calendar = self.calendar
        let persistence = ToggleableTodayPlanPersistence()
        let (store, _) = makeStore(todayPlan: persistence)
        persistence.shouldFail = true

        let outcome = store.addPlan(recipe: recipe(), on: day(2026, 3, 18, calendar: calendar), calendar: calendar)

        XCTAssertTrue(outcome.didFailToPersist)
        XCTAssertNil(outcome.value)
        XCTAssertTrue(store.plans.isEmpty, "memory must not show a change the disk refused")
        XCTAssertNotNil(store.planNotice)
    }

    func testUpdateReportsPersistenceFailureAndLeavesTheStoreUnchanged() throws {
        let calendar = self.calendar
        let persistence = ToggleableTodayPlanPersistence()
        let (store, _) = makeStore(todayPlan: persistence)
        store.addPlan(recipe: recipe(), on: day(2026, 3, 18, calendar: calendar), plannedServings: 2, calendar: calendar)
        let before = store.plans
        persistence.shouldFail = true

        let outcome = store.updatePlan(id: before[0].id, on: day(2026, 3, 25, calendar: calendar), plannedServings: 6, calendar: calendar)

        XCTAssertTrue(outcome.didFailToPersist)
        XCTAssertEqual(store.plans, before)
        XCTAssertEqual(persistence.plans, before, "the durable copy is untouched too")
    }

    func testRemoveReportsPersistenceFailureAndKeepsTheRow() throws {
        let calendar = self.calendar
        let persistence = ToggleableTodayPlanPersistence()
        let (store, _) = makeStore(todayPlan: persistence)
        store.addPlan(recipe: recipe(), on: day(2026, 3, 18, calendar: calendar), calendar: calendar)
        let before = store.plans
        persistence.shouldFail = true

        let outcome = store.removePlan(id: before[0].id)

        XCTAssertTrue(outcome.didFailToPersist)
        XCTAssertFalse(outcome.isNotFound, "a failed write is not a missing row")
        XCTAssertEqual(store.plans, before)
    }

    func testRestoreReportsPersistenceFailureAndLeavesThePlanRemoved() throws {
        let calendar = self.calendar
        let persistence = ToggleableTodayPlanPersistence()
        let (store, _) = makeStore(todayPlan: persistence)
        store.addPlan(recipe: recipe(), on: day(2026, 3, 18, calendar: calendar), calendar: calendar)
        let removal = try XCTUnwrap(store.removePlan(id: store.plans[0].id).value)
        persistence.shouldFail = true

        let outcome = store.restorePlan(removal.item, at: removal.index)

        XCTAssertTrue(outcome.didFailToPersist)
        XCTAssertTrue(store.plans.isEmpty, "a failed undo does not half-restore the row")
    }

    func testASuccessfulCommitWritesExactlyOnce() {
        let calendar = self.calendar
        let persistence = ToggleableTodayPlanPersistence()
        let (store, _) = makeStore(todayPlan: persistence)
        let writesBefore = persistence.replaceCallCount

        store.addPlan(recipe: recipe(), on: day(2026, 3, 18, calendar: calendar), calendar: calendar)

        XCTAssertEqual(persistence.replaceCallCount - writesBefore, 1, "publishing must not repeat the write")
    }

    // MARK: - Date normalization

    // MARK: - Edit, move and plan context

    func testUpdateMovesAMealToAPastDate() throws {
        let calendar = self.calendar
        let (store, _) = makeStore()
        store.addPlan(recipe: recipe(), on: day(2026, 3, 18, calendar: calendar), plannedServings: 2, calendar: calendar)
        let id = try XCTUnwrap(store.plans.first?.id)
        let past = day(2025, 12, 24, calendar: calendar)

        XCTAssertTrue(store.updatePlan(id: id, on: past, plannedServings: 2, calendar: calendar).didPersist)
        XCTAssertTrue(calendar.isDate(store.plans[0].date, inSameDayAs: past), "a past date is a legitimate correction")
    }

    func testUpdateKeepsACookedMealsServingsWhenTheCallerPassesThemBack() throws {
        let calendar = self.calendar
        let (store, _) = makeStore()
        store.addPlan(recipe: recipe(), on: day(2026, 3, 18, calendar: calendar), plannedServings: 4, calendar: calendar)
        let id = try XCTUnwrap(store.plans.first?.id)
        store.setPlanCooked(id, isCooked: true)
        let moved = day(2026, 3, 25, calendar: calendar)

        // What the edit sheet does for a completed meal: move the date, hand the
        // existing target straight back.
        let outcome = store.updatePlan(id: id, on: moved, plannedServings: store.plans[0].plannedServings, calendar: calendar)

        XCTAssertTrue(outcome.didPersist)
        XCTAssertEqual(store.plans[0].plannedServings, 4, "a completed cook's target is not rewritten")
        XCTAssertTrue(store.plans[0].isCooked)
        XCTAssertTrue(calendar.isDate(store.plans[0].date, inSameDayAs: moved))
    }

    func testCookingContextCarriesThePlanRegardlessOfItsDate() throws {
        let calendar = self.calendar
        let (store, _) = makeStore()
        // A meal on another day: reachable from the Planner, never from Home's
        // today-scoped surfaces.
        let future = day(2026, 3, 25, calendar: calendar)
        let saved = try XCTUnwrap(store.addPlan(recipe: recipe(), on: future, plannedServings: 5, calendar: calendar).value)
        XCTAssertTrue(store.todayPlans.isEmpty, "the fixture must not be a today plan")

        let request = CookingFlowRequest(recipe: recipe(), plan: saved)

        XCTAssertEqual(request.plan?.id, saved.id, "the Planner row must hand the cooking flow this exact meal")
        XCTAssertEqual(request.initialServings, 5, "the plan's target seeds the cook, not the recipe's base")

        // What the flow does on finish.
        store.markPlanCooked(try XCTUnwrap(request.plan))
        XCTAssertTrue(store.plans[0].isCooked, "cooking a Planner meal completes that meal")
    }

    func testTodayAndNonTodayPlansProduceTheSameCookingOutcome() throws {
        let calendar = self.calendar
        let (store, _) = makeStore()
        let todayMeal = try XCTUnwrap(
            store.addPlan(recipe: recipe(id: "a", title: "A"), on: Date(), plannedServings: 3, calendar: calendar).value
        )
        let laterMeal = try XCTUnwrap(
            store.addPlan(recipe: recipe(id: "b", title: "B"), on: day(2026, 3, 25, calendar: calendar),
                          plannedServings: 3, calendar: calendar).value
        )

        for meal in [todayMeal, laterMeal] {
            let request = CookingFlowRequest(recipe: recipe(id: meal.recipeID, title: meal.recipeName), plan: meal)
            XCTAssertEqual(request.initialServings, 3)
            store.markPlanCooked(try XCTUnwrap(request.plan))
        }

        XCTAssertEqual(
            store.plans.filter(\.isCooked).map(\.id).sorted(by: { $0.uuidString < $1.uuidString }),
            [todayMeal.id, laterMeal.id].sorted(by: { $0.uuidString < $1.uuidString }),
            "navigation origin must not change which plan a cook completes"
        )
    }

    func testCookingWithoutAPlanStillMarksNothing() {
        let (store, _) = makeStore()
        let request = CookingFlowRequest(recipe: recipe(), plan: nil)
        XCTAssertNil(request.plan, "a recipe opened outside any plan carries no plan")
        XCTAssertTrue(store.plans.isEmpty)
    }

    func testNormalizedDateStaysOnTheSelectedDayAcrossADSTTransition() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08 springs forward, 2026-11-01 falls back.
        for target in [day(2026, 3, 8, calendar: calendar), day(2026, 11, 1, calendar: calendar)] {
            let normalized = MealPlanItem.normalizedPlannerDate(for: target, calendar: calendar)
            XCTAssertTrue(
                calendar.isDate(normalized, inSameDayAs: target),
                "a DST shift must not move the entry into the neighbouring day"
            )
        }
    }

    func testNormalizationIsIdempotent() {
        let calendar = self.calendar
        let target = day(2026, 3, 18, calendar: calendar)
        let once = MealPlanItem.normalizedPlannerDate(for: target, calendar: calendar)
        XCTAssertEqual(MealPlanItem.normalizedPlannerDate(for: once, calendar: calendar), once)
    }
}

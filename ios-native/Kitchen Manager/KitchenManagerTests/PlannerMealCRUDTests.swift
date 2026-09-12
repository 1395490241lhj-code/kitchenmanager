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

    // MARK: - Canonical batch append
    //
    // Weekly materialization writes a whole menu at once, with ids it allocated
    // and recorded *before* the write so an interrupted attempt can be retried
    // with the same ids. These pin that contract.

    private func plannedMeal(
        id: UUID = UUID(),
        recipeID: String = "recipe-1",
        name: String = "番茄炒蛋",
        on date: Date,
        plannedServings: Int? = nil
    ) -> MealPlanItem {
        MealPlanItem(
            id: id,
            recipeID: recipeID,
            recipeName: name,
            date: date,
            plannedServings: plannedServings
        )
    }

    func testAppendKeepsTheExactIdsTheCallerAllocated() {
        let calendar = self.calendar
        let (store, _) = makeStore()
        let ids = [UUID(), UUID(), UUID()]
        let items = ids.enumerated().map { index, id in
            plannedMeal(id: id, recipeID: "r-\(index)", on: day(2026, 3, 18 + index, calendar: calendar))
        }

        let outcome = store.appendPlans(items, calendar: calendar)

        XCTAssertEqual(outcome.items?.map(\.id), ids)
        XCTAssertEqual(store.plans.map(\.id), ids, "a retry has to be able to find these again by id")
    }

    func testAppendWritesEveryRowInTheRequestedOrderAfterWhatIsAlreadyThere() {
        let calendar = self.calendar
        let (store, _) = makeStore()
        store.addPlan(recipe: recipe(id: "existing", title: "既有"), on: day(2026, 3, 18, calendar: calendar), calendar: calendar)

        let outcome = store.appendPlans(
            [
                plannedMeal(recipeID: "b", name: "B", on: day(2026, 3, 19, calendar: calendar)),
                plannedMeal(recipeID: "a", name: "A", on: day(2026, 3, 20, calendar: calendar))
            ],
            calendar: calendar
        )

        XCTAssertTrue(outcome.didPersist)
        XCTAssertEqual(
            store.plans.map(\.recipeID), ["existing", "b", "a"],
            "existing rows keep their place and the batch keeps its own order"
        )
    }

    func testAppendNormalizesEachDateAndLeavesAnUnstatedTargetUnstated() {
        let calendar = self.calendar
        let (store, _) = makeStore()
        let target = day(2026, 3, 18, calendar: calendar)

        store.appendPlans([plannedMeal(on: target)], calendar: calendar)

        XCTAssertEqual(store.plans[0].date, MealPlanItem.normalizedPlannerDate(for: target, calendar: calendar))
        XCTAssertNil(store.plans[0].plannedServings, "nobody stated a target for this dish")
    }

    func testAppendAllowsTheSameDishTwiceOnOneDay() {
        let calendar = self.calendar
        let (store, _) = makeStore()
        let date = day(2026, 3, 18, calendar: calendar)

        let outcome = store.appendPlans(
            [plannedMeal(on: date), plannedMeal(on: date)],
            calendar: calendar
        )

        XCTAssertTrue(outcome.didPersist, "a repeated dish is a real plan, not an accident to dedup")
        XCTAssertEqual(store.plans.count, 2)
    }

    func testAppendRefusesARequestThatRepeatsOneId() {
        let calendar = self.calendar
        let persistence = ToggleableTodayPlanPersistence()
        let (store, _) = makeStore(todayPlan: persistence)
        let writesBefore = persistence.replaceCallCount
        let shared = UUID()

        let outcome = store.appendPlans(
            [
                plannedMeal(id: shared, on: day(2026, 3, 18, calendar: calendar)),
                plannedMeal(id: shared, on: day(2026, 3, 19, calendar: calendar))
            ],
            calendar: calendar
        )

        XCTAssertEqual(outcome.rejection, .duplicateIDsInBatch([shared]))
        XCTAssertTrue(store.plans.isEmpty)
        XCTAssertEqual(persistence.replaceCallCount - writesBefore, 0, "a refused batch never reaches the disk")
    }

    func testAppendRefusesAnIdThatIsAlreadyOnThePlan() {
        let calendar = self.calendar
        let persistence = ToggleableTodayPlanPersistence()
        let (store, _) = makeStore(todayPlan: persistence)
        store.addPlan(recipe: recipe(), on: day(2026, 3, 18, calendar: calendar), calendar: calendar)
        let existing = store.plans[0]
        let writesBefore = persistence.replaceCallCount

        let outcome = store.appendPlans(
            [plannedMeal(id: existing.id, on: day(2026, 3, 20, calendar: calendar))],
            calendar: calendar
        )

        XCTAssertEqual(outcome.rejection, .idsAlreadyPresent([existing.id]))
        XCTAssertEqual(store.plans, [existing], "the row that was already there is untouched")
        XCTAssertEqual(persistence.replaceCallCount - writesBefore, 0)
    }

    func testAppendRefusesAnEmptyRequest() {
        let persistence = ToggleableTodayPlanPersistence()
        let (store, _) = makeStore(todayPlan: persistence)
        let writesBefore = persistence.replaceCallCount

        XCTAssertEqual(store.appendPlans([]).rejection, .empty)
        XCTAssertEqual(persistence.replaceCallCount - writesBefore, 0)
    }

    func testAFailedBatchAppendsNothingAtAll() {
        let calendar = self.calendar
        let persistence = ToggleableTodayPlanPersistence()
        let (store, _) = makeStore(todayPlan: persistence)
        store.addPlan(recipe: recipe(id: "existing"), on: day(2026, 3, 18, calendar: calendar), calendar: calendar)
        let before = store.plans
        persistence.shouldFail = true

        let outcome = store.appendPlans(
            (0..<3).map { plannedMeal(recipeID: "r-\($0)", on: day(2026, 3, 19, calendar: calendar)) },
            calendar: calendar
        )

        XCTAssertTrue(outcome.didFailToPersist)
        XCTAssertEqual(store.plans, before, "all of the menu or none of it — never three rows out of three")
    }

    func testASuccessfulBatchIsOneDurableWrite() {
        let calendar = self.calendar
        let persistence = ToggleableTodayPlanPersistence()
        let (store, _) = makeStore(todayPlan: persistence)
        let writesBefore = persistence.replaceCallCount

        store.appendPlans(
            (0..<4).map { plannedMeal(recipeID: "r-\($0)", on: day(2026, 3, 18 + $0, calendar: calendar)) },
            calendar: calendar
        )

        XCTAssertEqual(store.plans.count, 4)
        XCTAssertEqual(persistence.plans.count, 4, "the disk holds the same four")
        XCTAssertEqual(
            persistence.replaceCallCount - writesBefore, 1,
            "a menu is one logical mutation, so it is one write"
        )
    }

    func testARetryAfterAFailedBatchReusesTheSameIds() {
        let calendar = self.calendar
        let persistence = ToggleableTodayPlanPersistence()
        let (store, _) = makeStore(todayPlan: persistence)
        // The ids a receipt would have recorded before the first attempt.
        let ids = [UUID(), UUID()]
        let items = ids.enumerated().map { index, id in
            plannedMeal(id: id, recipeID: "r-\(index)", on: day(2026, 3, 18 + index, calendar: calendar))
        }
        persistence.shouldFail = true
        XCTAssertTrue(store.appendPlans(items, calendar: calendar).didFailToPersist)

        persistence.shouldFail = false
        let retry = store.appendPlans(items, calendar: calendar)

        XCTAssertTrue(retry.didPersist)
        XCTAssertEqual(store.plans.map(\.id), ids, "the retry recreates those exact rows")
        XCTAssertEqual(store.plans.count, 2, "and does not double up")
    }
}

// Shared confirmation contract used by Planner, Today detail and cooking mode.
extension PlannerMealCRUDTests {
    private func confirmationFixture() throws -> (KitchenStore, RecipeStore, MealPlanItem, MealPlanItem) {
        let (kitchen, _) = makeStore()
        let library = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let dish = recipe()
        try library.saveUserRecipe(dish)
        kitchen.addInventory(name: "番茄", quantity: 10, unit: "个", expiryDate: nil)
        let a = try XCTUnwrap(kitchen.addPlan(recipe: dish, on: Date()).value)
        let b = try XCTUnwrap(kitchen.addPlan(recipe: dish, on: a.date).value)
        return (kitchen, library, a, b)
    }

    private func confirmation(_ ids: [UUID], kitchen: KitchenStore, library: RecipeStore) -> CookConsumptionStore {
        let confirmation = CookConsumptionStore()
        confirmation.buildDrafts(planIDs: ids, kitchenStore: kitchen, recipeStore: library)
        return confirmation
    }

    private func confirm(_ request: CookConsumptionStore, _ ids: [UUID], kitchen: KitchenStore, library: RecipeStore) -> Bool {
        request.confirm(planIDs: ids, recipeID: "recipe-1", recipeName: "番茄炒蛋",
                        kitchenStore: kitchen, recipeStore: library)
    }

    func testExactConfirmationConsumesOnceAndCompletesOnlySelectedDuplicateMeal() throws {
        let (kitchen, library, a, b) = try confirmationFixture()
        let request = confirmation([b.id], kitchen: kitchen, library: library)
        XCTAssertTrue(confirm(request, [b.id], kitchen: kitchen, library: library))
        kitchen.markPlanCooked(b)
        XCTAssertEqual(kitchen.inventory.first?.quantity, 8)
        XCTAssertEqual(kitchen.consumptionRecords.first?.planIDs, [b.id])
        XCTAssertFalse(kitchen.plans.first { $0.id == a.id }!.isCooked)
        XCTAssertTrue(kitchen.plans.first { $0.id == b.id }!.isCooked)
        XCTAssertFalse(kitchen.hasConsumedPlan(a.id))
    }

    func testAlreadyConsumedPendingPlanCanConfirmAndCompleteWithoutDeductingAgain() throws {
        let (kitchen, library, a, b) = try confirmationFixture()
        let first = confirmation([a.id], kitchen: kitchen, library: library)
        XCTAssertTrue(confirm(first, [a.id], kitchen: kitchen, library: library))
        XCTAssertFalse(kitchen.plans[0].isCooked, "consumption layer does not own cooked state")
        for _ in 0..<2 {
            let repeated = confirmation([a.id], kitchen: kitchen, library: library)
            XCTAssertEqual(repeated.alreadySatisfiedTitle([a.id], kitchenStore: kitchen), "确认完成这道菜")
            XCTAssertTrue(confirm(repeated, [a.id], kitchen: kitchen, library: library))
            kitchen.markPlanCooked(a)
        }
        XCTAssertEqual(kitchen.inventory.first?.quantity, 8)
        XCTAssertEqual(kitchen.consumptionRecords.count, 1)
        XCTAssertTrue(kitchen.plans[0].isCooked)
        XCTAssertFalse(kitchen.plans.first { $0.id == b.id }!.isCooked)
    }

    func testMixedAndPluralConfirmationCountExactPlansNotRecipes() throws {
        let (kitchen, library, a, b) = try confirmationFixture()
        XCTAssertTrue(confirm(confirmation([a.id], kitchen: kitchen, library: library), [a.id], kitchen: kitchen, library: library))
        let mixed = confirmation([a.id, b.id], kitchen: kitchen, library: library)
        XCTAssertNil(mixed.alreadySatisfiedTitle([a.id, b.id], kitchenStore: kitchen))
        XCTAssertTrue(confirm(mixed, [a.id, b.id], kitchen: kitchen, library: library))
        XCTAssertEqual(kitchen.inventory.first?.quantity, 6)
        XCTAssertEqual(kitchen.consumptionRecords.count, 2)
        let allSatisfied = confirmation([a.id, b.id], kitchen: kitchen, library: library)
        XCTAssertEqual(allSatisfied.alreadySatisfiedTitle([a.id, b.id], kitchenStore: kitchen), "确认完成这些菜")
        XCTAssertTrue(confirm(allSatisfied, [a.id, b.id], kitchen: kitchen, library: library))
        XCTAssertEqual(kitchen.inventory.first?.quantity, 6)
        XCTAssertEqual(kitchen.consumptionRecords.count, 2)
    }

    func testMissingExactTargetFailsEvenAlongsideASatisfiedTarget() throws {
        let (kitchen, library, a, _) = try confirmationFixture()
        XCTAssertTrue(confirm(confirmation([a.id], kitchen: kitchen, library: library), [a.id], kitchen: kitchen, library: library))
        let ids = [a.id, UUID()]
        let request = confirmation(ids, kitchen: kitchen, library: library)
        XCTAssertNil(request.alreadySatisfiedTitle(ids, kitchenStore: kitchen))
        var callbackCalled = false
        if confirm(request, ids, kitchen: kitchen, library: library) { callbackCalled = true }
        XCTAssertFalse(callbackCalled)
        XCTAssertFalse(request.didConfirm)
        XCTAssertEqual(kitchen.inventory.first?.quantity, 8)
        XCTAssertEqual(kitchen.consumptionRecords.count, 1)
        XCTAssertFalse(kitchen.plans[0].isCooked)
    }

    func testMissingRecipePreservesExplicitCompleteWithoutDeduction() throws {
        let (kitchen, library, _, _) = try confirmationFixture()
        let missing = MealPlanItem(recipeID: "missing", recipeName: "缺失菜谱", date: Date())
        kitchen.plans.append(missing)
        let request = confirmation([missing.id], kitchen: kitchen, library: library)
        XCTAssertEqual(request.unresolvedPlanNames, ["缺失菜谱"])
        XCTAssertTrue(confirm(request, [missing.id], kitchen: kitchen, library: library))
        kitchen.markPlanCooked(missing)
        XCTAssertTrue(kitchen.hasConsumedPlan(missing.id))
        XCTAssertEqual(kitchen.inventory.first?.quantity, 10)
        XCTAssertTrue(kitchen.plans.last!.isCooked)
    }

    func testCancelPreparedNormalAndAlreadySatisfiedRequestsDoesNotMutate() throws {
        let (kitchen, library, a, b) = try confirmationFixture()
        _ = confirmation([a.id], kitchen: kitchen, library: library)
        XCTAssertEqual(kitchen.inventory.first?.quantity, 10)
        XCTAssertTrue(kitchen.consumptionRecords.isEmpty)
        XCTAssertFalse(kitchen.plans[0].isCooked)
        XCTAssertTrue(confirm(confirmation([a.id], kitchen: kitchen, library: library), [a.id], kitchen: kitchen, library: library))
        _ = confirmation([a.id], kitchen: kitchen, library: library)
        _ = confirmation([b.id], kitchen: kitchen, library: library)
        XCTAssertEqual(kitchen.inventory.first?.quantity, 8)
        XCTAssertEqual(kitchen.consumptionRecords.count, 1)
        XCTAssertTrue(kitchen.plans.allSatisfy { !$0.isCooked })
    }

    func testEmptyRequestCannotReportSuccess() throws {
        let (kitchen, library, a, b) = try confirmationFixture()
        XCTAssertFalse(confirm(confirmation([], kitchen: kitchen, library: library), [], kitchen: kitchen, library: library))
    }

    func testStaleSheetAfterPartialExternalConsumptionConsumesOnlyRemainingPlans() throws {
        let (kitchen, library, a, b) = try confirmationFixture()
        let stale = confirmation([a.id, b.id], kitchen: kitchen, library: library)
        XCTAssertTrue(confirm(confirmation([a.id], kitchen: kitchen, library: library), [a.id], kitchen: kitchen, library: library))
        XCTAssertEqual(kitchen.inventory.first?.quantity, 8)
        XCTAssertTrue(confirm(stale, [a.id, b.id], kitchen: kitchen, library: library),
                      "the stale sheet must still succeed: A is already satisfied, B is consumed normally")
        XCTAssertEqual(kitchen.inventory.first?.quantity, 6, "B is deducted exactly once; A gets no second deduction")
        XCTAssertEqual(kitchen.consumptionRecords.count, 2)
        XCTAssertEqual(kitchen.consumptionRecords.first?.planIDs, [b.id])
        XCTAssertTrue(kitchen.hasConsumedPlan(a.id))
        XCTAssertTrue(kitchen.hasConsumedPlan(b.id))
    }

    func testPlanDeletedWhileSheetOpenFailsWithoutMutation() throws {
        let (kitchen, library, a, b) = try confirmationFixture()
        let stale = confirmation([a.id, b.id], kitchen: kitchen, library: library)
        kitchen.removePlan(id: b.id)
        XCTAssertNil(stale.alreadySatisfiedTitle([a.id, b.id], kitchenStore: kitchen))
        var callbackCalled = false
        if confirm(stale, [a.id, b.id], kitchen: kitchen, library: library) { callbackCalled = true }
        XCTAssertFalse(callbackCalled)
        XCTAssertFalse(stale.didConfirm)
        XCTAssertEqual(kitchen.inventory.first?.quantity, 10)
        XCTAssertTrue(kitchen.consumptionRecords.isEmpty)
        XCTAssertTrue(kitchen.plans.contains { $0.id == a.id })
    }
}

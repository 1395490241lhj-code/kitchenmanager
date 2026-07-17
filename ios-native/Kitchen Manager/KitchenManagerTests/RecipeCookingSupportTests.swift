import XCTest
@testable import KitchenManager

@MainActor
final class RecipeCookingSupportTests: XCTestCase {
    func testServingScalerHandlesFractionsDecimalsAndFreeText() {
        XCTAssertEqual(RecipeServingScaler.scaledText("番茄 1/2 个", multiplier: 2), "番茄 1 个")
        XCTAssertEqual(RecipeServingScaler.scaledText("油 1.5 汤匙", multiplier: 2), "油 3 汤匙")
        XCTAssertEqual(RecipeServingScaler.scaledText("盐 适量", multiplier: 4), "盐 适量")
    }

    func testCookingSessionKeepsChecklistAndStepNavigationWithinBounds() {
        let session = RecipeCookingSession(servings: 2)
        session.toggleIngredient(at: 1)
        XCTAssertEqual(session.checkedIngredientIndexes, [1])
        session.toggleIngredient(at: 1)
        XCTAssertTrue(session.checkedIngredientIndexes.isEmpty)
        session.previous(stepCount: 3)
        XCTAssertEqual(session.currentStepIndex, 0)
        session.next(stepCount: 3); session.next(stepCount: 3); session.next(stepCount: 3)
        XCTAssertEqual(session.currentStepIndex, 2)
        session.moveToStep(8, stepCount: 0)
        XCTAssertEqual(session.currentStepIndex, 0)
    }

    func testTimerPauseResumeCancelAndFinish() {
        var state = CookingTimerState()
        state.start(seconds: 2)
        state.pause(); XCTAssertFalse(state.advance())
        state.resume(); XCTAssertFalse(state.advance())
        XCTAssertEqual(state.remainingSeconds, 1)
        XCTAssertTrue(state.advance()); XCTAssertEqual(state.status, .finished)
        state.cancel(); XCTAssertEqual(state.status, .idle); XCTAssertEqual(state.remainingSeconds, 0)
    }

    func testStepTimerSuggestionAcceptsBoundedMinuteTextOnly() {
        XCTAssertEqual(RecipeStepTimerSuggestion.seconds(in: "小火焖 10 分钟"), 600)
        XCTAssertNil(RecipeStepTimerSuggestion.seconds(in: "适量煮熟"))
        XCTAssertNil(RecipeStepTimerSuggestion.seconds(in: "焖 999 分钟"))
    }

    func testScreenAwakeRestoresPriorState() {
        var value = false
        let controller = ScreenAwakeController(read: { value }, write: { value = $0 })
        controller.activate(); XCTAssertTrue(value)
        controller.deactivate(); XCTAssertFalse(value)
        value = true
        controller.activate(); controller.deactivate(); XCTAssertTrue(value)
    }

    func testCookingFinishOnlyMarksPlanWhenContextExists() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = KitchenStore(userDefaults: defaults, inventoryPersistence: bundle.inventory, shoppingListPersistence: bundle.shoppingList, todayPlanPersistence: bundle.todayPlan, consumptionPersistence: bundle.consumption, weeklyPlanPersistence: bundle.weeklyPlan)
        let recipe = Recipe.samples[0]
        store.addPlan(recipe: recipe, servings: 2)
        let plan = try! XCTUnwrap(store.todayPlans.first)
        XCTAssertFalse(plan.isCooked)
        store.markPlanCooked(plan)
        XCTAssertTrue(store.todayPlans.first?.isCooked == true)
    }
}

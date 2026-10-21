import XCTest
@testable import KitchenManager

/// PLANNING-1: cooking today's planned dish from the library deducted it as a
/// direct recipe, and ticking the meal afterwards deducted it again. The
/// library cook now offers the matching meal; these pin which meal that is.
final class CookingTodayPlanCandidateTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 18))! }

    private func plan(_ recipeID: String, name: String = "番茄炒蛋", dayOffset: Int = 0, hour: Int = 12, cooked: Bool = false) -> MealPlanItem {
        let day = calendar.date(byAdding: .day, value: dayOffset, to: now)!
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        return MealPlanItem(recipeID: recipeID, recipeName: name, date: date, isCooked: cooked)
    }

    func testFindsTodaysUncookedMealOfTheSameRecipe() {
        let meal = plan("recipe-a")
        let found = CookingFlowRequest.todayPlanCandidate(recipeID: "recipe-a", plans: [meal], now: now, calendar: calendar)
        XCTAssertEqual(found?.id, meal.id)
    }

    func testIgnoresCookedMealsOtherDaysAndOtherRecipes() {
        let plans = [
            plan("recipe-a", cooked: true),
            plan("recipe-a", dayOffset: -1),
            plan("recipe-a", dayOffset: 1),
            plan("recipe-b"),
        ]
        XCTAssertNil(CookingFlowRequest.todayPlanCandidate(recipeID: "recipe-a", plans: plans, now: now, calendar: calendar))
    }

    func testNeverMatchesByName() {
        let sameNameOtherRecipe = plan("recipe-b", name: "番茄炒蛋")
        XCTAssertNil(CookingFlowRequest.todayPlanCandidate(recipeID: "recipe-a", plans: [sameNameOtherRecipe], now: now, calendar: calendar))
    }

    func testPicksTheEarliestOfTwoUncookedMealsToday() {
        let dinner = plan("recipe-a", hour: 18)
        let lunch = plan("recipe-a", hour: 11)
        let found = CookingFlowRequest.todayPlanCandidate(recipeID: "recipe-a", plans: [dinner, lunch], now: now, calendar: calendar)
        XCTAssertEqual(found?.id, lunch.id)
    }

    /// Linking to the meal makes the cook that meal's: its receipt carries the
    /// plan id, so ticking the meal later finds it instead of deducting again.
    @MainActor
    func testLinkedCookMarksTheMealConsumedSoTickingItDoesNotDeductAgain() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let kitchen = KitchenStore(
            userDefaults: defaults,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList,
            todayPlanPersistence: bundle.todayPlan,
            consumptionPersistence: bundle.consumption,
            weeklyPlanPersistence: bundle.weeklyPlan,
            preparedComponentPersistence: bundle.preparedComponents
        )
        let recipeStore = RecipeStore(userDefaults: defaults, userRecipePersistence: bundle.userRecipes, recipePreferencePersistence: bundle.recipePreferences)
        let recipe = Recipe(id: "user-eggs", title: "番茄炒蛋", cookingTime: nil, difficulty: nil, tags: [], ingredients: ["鸡蛋 4 个"], steps: ["炒"])
        try recipeStore.saveUserRecipe(recipe)
        kitchen.addInventory(name: "鸡蛋", quantity: 6, unit: "个", expiryDate: nil)
        kitchen.addPlan(recipe: recipe)
        let meal = try XCTUnwrap(CookingFlowRequest.todayPlanCandidate(recipeID: recipe.id, plans: kitchen.plans))

        let consumption = CookConsumptionStore()
        let target = CookConsumptionTarget.plannedMeals(planIDs: [meal.id], recipe: nil, servings: 1)
        consumption.buildDrafts(target: target, kitchenStore: kitchen, recipeStore: recipeStore)
        XCTAssertTrue(consumption.confirm(target: target, recipeID: recipe.id, recipeName: recipe.title, kitchenStore: kitchen, recipeStore: recipeStore))
        XCTAssertEqual(kitchen.inventory.first?.quantity, 2)

        let second = CookConsumptionStore()
        XCTAssertTrue(second.isTargetAlreadySatisfied(target: target, kitchenStore: kitchen),
                      "ticking the same meal afterwards must not deduct a second time")
    }
}

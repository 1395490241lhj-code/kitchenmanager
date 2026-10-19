import XCTest
@testable import KitchenManager

/// A second 生成菜单 used to reuse the previous menu's start date even after
/// that menu was added to the Planner or its days had passed, so the new menu
/// could land on yesterday.
@MainActor
final class WeeklyMenuStartDateTests: XCTestCase {
    private let calendar = Calendar.current
    private lazy var today = calendar.startOfDay(for: Date())

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: today)!
    }

    private func plan(startingIn offset: Int, materialized: Bool = false) -> WeeklyMealPlan {
        WeeklyMealPlan(
            startDate: day(offset),
            days: [WeeklyMealPlanDay(dayIndex: 0, meals: [WeeklyMealPlanMeal(mealIndex: 0, title: "晚餐", recipes: [
                WeeklyMealPlanRecipe(id: "d", title: "菜", ingredients: ["番茄 2 个"], steps: ["炒熟"], tags: [],
                                     cookingTime: 10, difficulty: nil, reason: nil, source: .ai, existingRecipeID: nil)
            ])])],
            shoppingItems: [], servings: 2, summary: nil, createdAt: Date(),
            materialization: materialized
                ? WeeklyMaterializationReceipt(state: .materialized, planIDs: [UUID()], recipeIDs: ["r"],
                                               planDates: [day(offset)], startedAt: Date(), completedAt: Date())
                : nil
        )
    }

    private func start(previous: WeeklyMealPlan?, preferred: Date? = nil) -> Date {
        WeeklyMenuPlannerStore.generationStartDate(previous: previous, preferredStart: preferred, now: Date(), calendar: calendar)
    }

    func testFirstGenerationStartsToday() {
        XCTAssertEqual(start(previous: nil), today)
    }

    func testAnUnaddedDraftStillAheadKeepsItsDays() {
        XCTAssertEqual(start(previous: plan(startingIn: 2)), day(2))
        XCTAssertEqual(start(previous: plan(startingIn: 0)), today)
    }

    func testADraftWhoseStartHasPassedStartsFromToday() {
        XCTAssertEqual(start(previous: plan(startingIn: -3)), today)
    }

    func testAMenuAlreadyAddedToThePlannerStartsAgainFromToday() {
        XCTAssertEqual(start(previous: plan(startingIn: 1, materialized: true)), today)
    }

    func testTheWeekOnScreenIsUsedWhenItIsStillAhead() {
        XCTAssertEqual(start(previous: plan(startingIn: -3), preferred: day(5)), day(5))
        XCTAssertEqual(start(previous: nil, preferred: day(-4)), today, "never a past week")
    }

    func testGenerateFromTheFormLandsOnTodayAndRegenerateKeepsThoseDays() async throws {
        let store = WeeklyMenuPlannerStore(generate: { _ in try Self.response() })
        let kitchen = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let recipes = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.generatedPlan = plan(startingIn: -2, materialized: true)
        store.input.numberOfDays = 3
        store.input.allowNewAIRecipes = true
        XCTAssertEqual(store.nextGenerationDateRange(preferredStart: nil).start, today)
        XCTAssertEqual(store.nextGenerationDateRange(preferredStart: nil).end, day(2))

        let generated = await store.generatePlan(recipeStore: recipes, kitchenStore: kitchen)
        XCTAssertTrue(generated)
        XCTAssertEqual(store.generatedPlan?.startDate, today)

        let regenerated = await store.regeneratePlan(recipeStore: recipes, kitchenStore: kitchen)
        XCTAssertTrue(regenerated)
        XCTAssertEqual(store.generatedPlan?.startDate, today, "重新生成 keeps the menu's own days")
    }

    private static func response() throws -> AIWeeklyMenuResponse {
        let days: [[String: Any]] = [
            ["dayIndex": 0,
             "meals": [["mealIndex": 0, "title": "晚餐",
                        "recipes": [["name": "番茄炒蛋", "ingredients": ["番茄 2 个"], "steps": ["炒熟"], "source": "ai"]]]]]
        ]
        return try JSONDecoder().decode(
            AIWeeklyMenuResponse.self,
            from: JSONSerialization.data(withJSONObject: ["days": days])
        )
    }
}

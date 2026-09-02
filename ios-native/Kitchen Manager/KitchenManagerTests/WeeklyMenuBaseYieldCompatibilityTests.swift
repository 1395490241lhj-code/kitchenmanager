import XCTest
@testable import KitchenManager

/// The base-yield contract belongs to Special Plan alone. `AIWeeklyMenuRecipeDTO`
/// is shared, so these guard the weekly planner against inheriting it: a weekly
/// response never carries the field, and a weekly recipe saved to the library
/// must not acquire a yield nobody stated.
@MainActor
final class WeeklyMenuBaseYieldCompatibilityTests: XCTestCase {
    private func response(_ dish: [String: Any]) throws -> AIWeeklyMenuResponse {
        let payload: [String: Any] = [
            "days": [[
                "dayIndex": 0,
                "meals": [["mealIndex": 0, "title": "晚餐", "recipes": [dish]]]
            ]],
            "shoppingItems": [],
            "warnings": []
        ]
        return try JSONDecoder().decode(
            AIWeeklyMenuResponse.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }

    func testWeeklyResponseWithoutTheYieldFieldStillDecodes() throws {
        let decoded = try response([
            "name": "番茄炒蛋",
            "ingredients": ["鸡蛋 2 个"],
            "steps": ["炒"],
            "source": "ai"
        ])

        let dto = try XCTUnwrap(decoded.days.first?.meals.first?.recipes.first)
        XCTAssertEqual(dto.name, "番茄炒蛋")
        XCTAssertNil(dto.baseServings, "weekly responses do not state a yield")
    }

    func testWeeklyRecipeSavedToLibraryHasNoBaseYield() throws {
        let recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let planned = WeeklyMealPlanRecipe(
            id: "weekly-ai-1",
            title: "番茄炒蛋",
            ingredients: ["鸡蛋 2 个"],
            steps: ["炒"],
            tags: [],
            cookingTime: nil,
            difficulty: nil,
            reason: nil,
            source: .ai,
            existingRecipeID: nil
        )

        try WeeklyMenuPlannerStore().saveRecipeToLibrary(planned, recipeStore: recipeStore)

        XCTAssertEqual(recipeStore.userRecipes.count, 1)
        XCTAssertNil(
            recipeStore.userRecipes.first?.baseServings,
            "an unstated yield stays nil; weekly must not stamp one"
        )
    }
}

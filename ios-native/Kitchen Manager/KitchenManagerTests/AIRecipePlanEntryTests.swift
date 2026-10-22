import XCTest
@testable import KitchenManager

/// AI 做菜 used to offer 仅加入今日计划, which planned a draft that was never
/// saved: the meal named a recipe id the library did not have. The only way
/// onto the plan is now 保存并加入计划, and `addToPlan` takes the saved recipe.
@MainActor
final class AIRecipePlanEntryTests: XCTestCase {
    func testSaveAndAddToPlanLeavesAMealWhoseRecipeResolves() throws {
        let generator = AIRecipeGeneratorStore(generateDraft: { _ in throw CancellationError() })
        generator.generatedDraft = EditableRecipeDraft(
            title: "番茄炒蛋", ingredientsText: "鸡蛋\n番茄", stepsText: "鸡蛋打散备用\n同炒"
        )
        let recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let kitchen = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)

        let saved = try generator.save(into: recipeStore)
        _ = try generator.addToPlan(kitchen, recipe: saved)

        let meal = try XCTUnwrap(kitchen.plans.last)
        XCTAssertEqual(meal.recipeID, saved.id)
        XCTAssertNotNil(recipeStore.recipe(id: meal.recipeID), "计划里的菜必须能在菜谱库找到")
        XCTAssertTrue(generator.hasSavedCurrentDraft)
        XCTAssertTrue(generator.hasAddedCurrentDraftToPlan)
    }
}

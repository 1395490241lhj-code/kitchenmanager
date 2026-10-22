import XCTest
@testable import KitchenManager

/// RECIPES_LOGIC-12: every built-in recipe has no 难度 or 烹饪时间, so filtering
/// the library by either removed all of them. Unlabelled recipes are now kept
/// (listed after the matches) and the filter chip says 含未标注.
final class RecipeLibraryFilterTests: XCTestCase {
    private func recipe(_ id: String, difficulty: String? = nil, time: Int? = nil) -> Recipe {
        Recipe(id: id, title: id, cookingTime: time, difficulty: difficulty, tags: [], ingredients: ["蛋 1 个"], steps: ["做"])
    }

    func testAnUnlabelledRecipeIsKeptByBothFilters() {
        XCTAssertTrue(RecipeLibraryFilter.matches(difficulty: nil, selected: "简单"))
        XCTAssertTrue(RecipeLibraryFilter.matches(cookingTime: nil, maximum: 30))
    }

    func testALabelledRecipeStillHasToMatch() {
        XCTAssertTrue(RecipeLibraryFilter.matches(difficulty: "简单", selected: "简单"))
        XCTAssertFalse(RecipeLibraryFilter.matches(difficulty: "较难", selected: "简单"))
        XCTAssertTrue(RecipeLibraryFilter.matches(cookingTime: 20, maximum: 30))
        XCTAssertFalse(RecipeLibraryFilter.matches(cookingTime: 45, maximum: 30))
    }

    func testNoFilterMatchesEverything() {
        XCTAssertTrue(RecipeLibraryFilter.matches(difficulty: "较难", selected: nil))
        XCTAssertTrue(RecipeLibraryFilter.matches(cookingTime: 120, maximum: nil))
    }

    func testMatchesAreListedBeforeUnlabelledRecipes() {
        let builtIn = recipe("built-in")
        let quick = recipe("quick", time: 15)
        let ordered = RecipeLibraryFilter.labelledFirst([builtIn, quick], difficulty: nil, maximumTime: 30)
        XCTAssertEqual(ordered.map(\.id), ["quick", "built-in"])
        XCTAssertEqual(RecipeLibraryFilter.labelledFirst([builtIn, quick], difficulty: nil, maximumTime: nil).map(\.id),
                       ["built-in", "quick"], "without these filters the order is untouched")
    }
}

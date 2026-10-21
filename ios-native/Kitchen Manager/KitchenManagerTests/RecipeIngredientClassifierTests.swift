import XCTest
@testable import KitchenManager

/// The curated Sichuan library writes every amount in grams ("盐 2 g"). The
/// classifier's own pattern did not know "g", looked up "盐 2 g" as a name,
/// and so filed salt, MSG and oil as core ingredients — every such recipe then
/// read 还缺 盐、味精、菜油 no matter what the kitchen held.
@MainActor
final class RecipeIngredientClassifierTests: XCTestCase {
    func testCuratedGramLinesFileSeasoningsAsSeasonings() {
        let lines = [
            "猪肉 200 g", "盐 2 g", "味精 1 g", "菜油 50 g", "酱油 10 g", "汤 100 g",
            "高汤 200 毫升", "水豆粉 15 g", "郫县豆瓣 25 g", "甜酱 10 g", "化猪油 30 g",
            "姜米 5 g", "蒜米 5 g"
        ]
        let classified = RecipeIngredientClassifier.classify(lines, recipeTitle: "回锅肉")
        XCTAssertEqual(classified.ingredients, ["猪肉 200 g"])
        XCTAssertEqual(classified.seasonings.count, lines.count - 1)
    }

    func testFractionsAndUnitlessAmountsAreStrippedBeforeTheLookup() {
        let classified = RecipeIngredientClassifier.classify(
            ["味精 1/2 茶匙", "醋 1 ml", "鸡蛋 2"], recipeTitle: "蛋汤"
        )
        XCTAssertEqual(classified.ingredients, ["鸡蛋 2"])
        XCTAssertEqual(classified.seasonings, ["味精 1/2 茶匙", "醋 1 ml"])
    }

    /// Unchanged by the gram fix: a weighed single-character aromatic or a
    /// weighed flour line is still read as a core ingredient.
    func testWeighedFlourAndScallionStayIngredients() {
        let classified = RecipeIngredientClassifier.classify(["面粉 500g", "葱 10 g"], recipeTitle: "菜")
        XCTAssertEqual(classified.ingredients, ["面粉 500g", "葱 10 g"])
    }

    func testCoreAromaticsAndFlourStayIngredientsWhereTheDishIsAboutThem() {
        XCTAssertEqual(
            RecipeIngredientClassifier.classify(["葱 50 g", "海参 2 只"], recipeTitle: "葱烧海参").ingredients,
            ["葱 50 g", "海参 2 只"]
        )
        XCTAssertEqual(
            RecipeIngredientClassifier.classify(["面粉 200 g"], recipeTitle: "葱油饼").ingredients,
            ["面粉 200 g"]
        )
    }

    /// The symptom: with only the pork at home the recipe must not ask for salt.
    func testACuratedRecipeIsNotMissingItsSeasonings() {
        let recipe = Recipe(
            id: "curated", title: "回锅肉", cookingTime: nil, difficulty: nil, tags: [],
            ingredients: ["猪肉 200 g", "盐 2 g", "味精 1 g", "菜油 50 g", "酱油 10 g"],
            steps: ["炒"]
        )
        let inventory = [InventoryItem(name: "猪肉", quantity: 300, unit: "克", expiryDate: nil)]
        XCTAssertEqual(RecipeStockMatch.missingIngredients(in: recipe, inventory: inventory), [])
    }
}

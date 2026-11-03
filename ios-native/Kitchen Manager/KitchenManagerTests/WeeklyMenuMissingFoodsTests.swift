import XCTest
@testable import KitchenManager

/// PLAN-3: the result page's 预计新增采购 counted the AI's own list while each
/// dish row judged stock locally, so a menu could read 0 项 next to a dish
/// showing 缺 2 样, and the 需要购买 section with its button disappeared.
/// The page's number now comes from the same local check as the dish rows.
final class WeeklyMenuMissingFoodsTests: XCTestCase {
    private func dish(_ title: String, _ ingredients: [String]) -> WeeklyMealPlanRecipe {
        WeeklyMealPlanRecipe(
            id: title, title: title, ingredients: ingredients, steps: [], tags: [],
            cookingTime: nil, difficulty: nil, reason: nil, source: .ai
        )
    }

    private func menu(_ dishes: [WeeklyMealPlanRecipe], aiList: [WeeklyMealPlanShoppingItem] = []) -> WeeklyMealPlan {
        WeeklyMealPlan(
            startDate: Date(timeIntervalSince1970: 0),
            days: dishes.enumerated().map { index, dish in
                WeeklyMealPlanDay(dayIndex: index, meals: [WeeklyMealPlanMeal(mealIndex: 0, title: nil, recipes: [dish])])
            },
            shoppingItems: aiList,
            servings: 2, summary: nil, createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    func test_twoDishesSharingAMissingFood_countItOnce() {
        let plan = menu([
            dish("番茄炒蛋", ["番茄 2 个", "鸡蛋 3 个"]),
            dish("葱花蛋饼", ["鸡蛋 2 个", "葱 1 根", "面粉 100 克"])
        ])

        let missing = WeeklyMenuInventoryCoverage.missingFoods(in: plan, inventoryNames: ["番茄", "面粉"])

        XCTAssertEqual(missing, ["鸡蛋", "葱"])
    }

    func test_everythingInStock_countsZero_whateverTheAIListed() {
        let plan = menu(
            [dish("番茄炒蛋", ["番茄 2 个", "鸡蛋 3 个"])],
            aiList: [WeeklyMealPlanShoppingItem(name: "番茄", quantityText: "2", unit: "个", reason: nil)]
        )

        let missing = WeeklyMenuInventoryCoverage.missingFoods(in: plan, inventoryNames: ["番茄", "鸡蛋"])

        XCTAssertEqual(missing, [])
    }

    /// UX-1: the check is by presence, not amount. 鸡蛋 2 个 at home covers
    /// three dishes that need 鸡蛋 3 个 each, so the page counts 还缺食材 0 样
    /// rather than promising nothing to buy, and keeps 核对后加入买菜清单 for
    /// the review page, which compares amounts.
    func test_theCheckIsByPresence_soStockTooSmallForTheMenuStillCountsAsHad() {
        let plan = menu([
            dish("番茄炒蛋", ["鸡蛋 3 个"]),
            dish("蒸蛋", ["鸡蛋 3 个"]),
            dish("蛋饼", ["鸡蛋 3 个"])
        ])

        XCTAssertEqual(WeeklyMenuInventoryCoverage.missingFoods(in: plan, inventoryNames: ["鸡蛋"]), [])
    }

    func test_aDishShowingMissing_neverLeavesTheMenuAtZero() {
        let plan = menu([dish("葱油拌面", ["面条 200 克", "葱 3 根"])])
        let names = ["面条"]

        let row = WeeklyMenuInventoryCoverage.coverage(of: plan.days[0].meals[0].recipes[0].ingredients, inventoryNames: names)
        let missing = WeeklyMenuInventoryCoverage.missingFoods(in: plan, inventoryNames: names)

        XCTAssertEqual(row.uses, 1)
        XCTAssertEqual(row.missing, 1)
        XCTAssertEqual(missing, ["葱"])
    }
}

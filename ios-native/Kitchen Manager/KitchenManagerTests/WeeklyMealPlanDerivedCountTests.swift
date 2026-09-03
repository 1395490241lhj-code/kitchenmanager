import XCTest
@testable import KitchenManager

/// Displayed plan totals must always be counted from the plan's own contents.
///
/// A design exploration surfaced a screen that stated "2 道菜" while holding one
/// dish, because the count lived beside the recipes instead of being derived
/// from them. Production already derives it; these tests keep that true by
/// construction, so no future edit can reintroduce a second source of truth.
final class WeeklyMealPlanDerivedCountTests: XCTestCase {

    private func recipe(_ title: String) -> WeeklyMealPlanRecipe {
        WeeklyMealPlanRecipe(
            id: title,
            title: title,
            ingredients: [],
            steps: [],
            tags: [],
            cookingTime: nil,
            difficulty: nil,
            reason: nil,
            source: .ai
        )
    }

    private func plan(_ days: [[[String]]]) -> WeeklyMealPlan {
        WeeklyMealPlan(
            startDate: Date(timeIntervalSince1970: 0),
            days: days.enumerated().map { dayIndex, meals in
                WeeklyMealPlanDay(
                    dayIndex: dayIndex,
                    meals: meals.enumerated().map { mealIndex, titles in
                        WeeklyMealPlanMeal(
                            mealIndex: mealIndex,
                            title: nil,
                            recipes: titles.map(recipe)
                        )
                    }
                )
            },
            shoppingItems: [],
            servings: 2,
            summary: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testDishCountSumsEveryRecipeAcrossDaysAndMeals() {
        let subject = plan([
            [["番茄牛腩", "蒜蓉上海青"], ["紫菜蛋花汤"]],
            [["麻婆豆腐"]]
        ])

        XCTAssertEqual(subject.dishCount, 4)
        XCTAssertEqual(subject.dayCount, 2)
    }

    func testEmptyPlanCountsZeroRatherThanAssumingAMeal() {
        XCTAssertEqual(plan([]).dishCount, 0)
        XCTAssertEqual(plan([]).dayCount, 0)
        // A day scheduled with no dishes is still a day, and still zero dishes.
        XCTAssertEqual(plan([[[]]]).dishCount, 0)
        XCTAssertEqual(plan([[[]]]).dayCount, 1)
    }

    func testDishCountFollowsTheMenuAfterItIsEdited() {
        var subject = plan([[["番茄牛腩", "蒜蓉上海青"]]])
        XCTAssertEqual(subject.dishCount, 2)

        // The exact drift the exploration hit: the menu changes, and the
        // displayed total has to change with it because there is nowhere else
        // for it to be stored.
        subject.days[0].meals[0].recipes.removeLast()
        XCTAssertEqual(subject.dishCount, 1)

        subject.days[0].meals[0].recipes.append(recipe("凉拌黄瓜"))
        subject.days[0].meals[0].recipes.append(recipe("香菇滑鸡"))
        XCTAssertEqual(subject.dishCount, 3)
    }

    func testDishCountSurvivesEncodingRoundTripWithoutBeingStored() throws {
        let subject = plan([[["番茄牛腩", "蒜蓉上海青"]]])
        let data = try JSONEncoder().encode(subject)

        // The count must not be persisted; it is derived on read.
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(raw.contains("dishCount"))

        let decoded = try JSONDecoder().decode(WeeklyMealPlan.self, from: data)
        XCTAssertEqual(decoded.dishCount, subject.dishCount)
    }
}

import XCTest
@testable import KitchenManager

/// The hero states tonight's menu, so its dish count must describe the whole
/// evening rather than the part Home happens to list.
final class HomeMealHeroModelTests: XCTestCase {

    private func plan(_ name: String) -> MealPlanItem {
        MealPlanItem(recipeID: name, recipeName: name, plannedServings: 2)
    }

    func testDishCountDescribesTheWholeMenuNotTheVisiblePreview() throws {
        // Home caps its dish list; a four-dish evening shows three rows plus
        // 另有 1 道. The hero must still say four.
        let visible = [plan("麻婆豆腐"), plan("番茄炒鸡蛋"), plan("蒜蓉上海青")]
        let model = try XCTUnwrap(
            HomeMealHeroModel.make(plans: visible, totalDishCount: 4, cookingMinutes: 40, readiness: nil)
        )

        XCTAssertEqual(model.dishCount, 4)
        XCTAssertEqual(model.title, "麻婆豆腐")
        XCTAssertEqual(model.sideDishes, ["番茄炒鸡蛋", "蒜蓉上海青"])
    }

    func testLeadDishIsNeverRepeatedAmongTheSides() throws {
        let model = try XCTUnwrap(
            HomeMealHeroModel.make(plans: [plan("麻婆豆腐")], totalDishCount: 1, cookingMinutes: 25, readiness: nil)
        )

        XCTAssertEqual(model.title, "麻婆豆腐")
        XCTAssertTrue(model.sideDishes.isEmpty)
        XCTAssertEqual(model.dishCount, 1)
    }

    func testNoPlansProducesNoHero() {
        XCTAssertNil(
            HomeMealHeroModel.make(plans: [], totalDishCount: 0, cookingMinutes: nil, readiness: nil)
        )
    }

    func testReadinessWordsMatchTheCountsTheyDescribe() {
        XCTAssertEqual(HomeMealReadiness(ready: 0, total: 5).summary, "0/5 食材就绪")
        XCTAssertEqual(HomeMealReadiness(ready: 3, total: 5).summary, "3/5 食材就绪")
        XCTAssertEqual(HomeMealReadiness(ready: 5, total: 5).summary, "食材齐全")
        XCTAssertEqual(HomeMealReadiness(ready: 0, total: 0).summary, "无需备料")
    }
}

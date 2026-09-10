import XCTest
@testable import KitchenManager

/// The hero states tonight's menu, so its dish count must describe the whole
/// evening rather than the part Home happens to list.
final class HomeMealHeroModelTests: XCTestCase {

    private func plan(_ name: String) -> MealPlanItem {
        MealPlanItem(recipeID: name, recipeName: name, plannedServings: 2)
    }

    /// Old contract: the hero named every other dish on a 配 line, however many
    /// there were, while Home listed a capped preview beneath it.
    /// New contract: only a two-dish menu names its other dish inline. At three
    /// or more, the remaining dishes belong to the 另有 N 道 disclosure, and a
    /// 配 line repeating them would state the same menu twice.
    ///
    /// Not weaker: the property this test was written to protect — the count
    /// describes the whole evening rather than what Home happens to show — is
    /// still asserted exactly, and the branch that replaced the 配 line is now
    /// asserted too rather than left uncovered.
    func testThreeOrMoreDishesLeaveTheOtherDishesToTheDisclosure() throws {
        let plans = [plan("麻婆豆腐"), plan("番茄炒鸡蛋"), plan("蒜蓉上海青"), plan("紫菜蛋花汤")]
        let model = try XCTUnwrap(
            HomeMealHeroModel.make(plans: plans, totalDishCount: 4, cookingMinutes: 40, readiness: nil)
        )

        XCTAssertEqual(model.dishCount, 4)
        XCTAssertEqual(model.title, "麻婆豆腐")
        XCTAssertEqual(model.sideDishes, [], "三道以上不再用 配 行重复披露里的菜。")
    }

    /// The branch the multi-dish contract introduced: exactly two dishes name
    /// the second one inline, because a disclosure holding a single row is more
    /// chrome than content.
    func testTwoDishesNameTheSecondDishInline() throws {
        let model = try XCTUnwrap(
            HomeMealHeroModel.make(
                plans: [plan("麻婆豆腐"), plan("番茄炒鸡蛋")],
                totalDishCount: 2,
                cookingMinutes: 40,
                readiness: nil
            )
        )

        XCTAssertEqual(model.title, "麻婆豆腐")
        XCTAssertEqual(model.sideDishes, ["番茄炒鸡蛋"])
        XCTAssertEqual(model.dishCount, 2)
    }

    /// One dish may state its own cooking time. Several dishes have no honest
    /// total — they are cooked in an overlapping order the product does not
    /// model — so the hero states none.
    func testOnlyASingleDishStatesACookingTime() throws {
        let single = try XCTUnwrap(
            HomeMealHeroModel.make(plans: [plan("麻婆豆腐")], totalDishCount: 1, cookingMinutes: 25, readiness: nil)
        )
        XCTAssertEqual(single.duration, "25 分钟")

        let several = try XCTUnwrap(
            HomeMealHeroModel.make(
                plans: [plan("麻婆豆腐"), plan("番茄炒鸡蛋")],
                totalDishCount: 2,
                cookingMinutes: 40,
                readiness: nil
            )
        )
        XCTAssertNil(several.duration, "多道菜没有可诚实陈述的总时长。")
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

    /// Old contract: 食材就绪 / 食材齐全.
    /// New contract: 已在库. The matcher behind these numbers only asks whether
    /// an ingredient *name* resolved to something in stock — it compares no
    /// quantities, reads no expiry and applies no serving scaling. 就绪 and
    /// 齐全 both claimed a readiness verdict the projection cannot support.
    ///
    /// Not weaker: the same four cases are asserted with the same exact
    /// equality; only the claim the words make is now one the data supports.
    func testReadinessWordsClaimPresenceRatherThanSufficiency() {
        XCTAssertEqual(HomeMealReadiness(ready: 0, total: 5).summary, "0/5 食材已在库")
        XCTAssertEqual(HomeMealReadiness(ready: 3, total: 5).summary, "3/5 食材已在库")
        XCTAssertEqual(HomeMealReadiness(ready: 5, total: 5).summary, "所需食材已在库")
        XCTAssertEqual(HomeMealReadiness(ready: 0, total: 0).summary, "无需备料")
    }
}

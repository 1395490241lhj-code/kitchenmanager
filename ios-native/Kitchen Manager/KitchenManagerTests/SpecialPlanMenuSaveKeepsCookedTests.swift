import XCTest
@testable import KitchenManager

/// PLANNING-8: saving an AI 重新设计菜单 draft replaced the whole menu, so a
/// dish already cooked (with its consumption receipt) and the dishes the member
/// added from the library vanished without a word. Cooked dishes now stay, and
/// the screen lists what will be replaced before it saves.
@MainActor
final class SpecialPlanMenuSaveKeepsCookedTests: XCTestCase {
    private func makeStores() -> (KitchenStore, RecipeStore) {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return (
            KitchenStore(userDefaults: defaults, persistence: bundle),
            RecipeStore(userDefaults: defaults, userRecipePersistence: bundle.userRecipes,
                        recipePreferencePersistence: bundle.recipePreferences)
        )
    }

    private func draftDish(_ title: String) -> SpecialPlanMenuDraftDish {
        SpecialPlanMenuDraftDish(
            title: title, ingredients: ["鱼 1 条"], seasonings: [], steps: ["蒸熟"], tags: [],
            cookingTime: nil, difficulty: nil, reason: nil, existingRecipeID: nil,
            baseServings: SpecialPlanMenuBounds.aiRecipeBaseServings
        )
    }

    private func planWithMenu(_ kitchen: KitchenStore) -> (plan: SpecialPlan, cooked: SpecialPlanDish, added: SpecialPlanDish, aiDish: SpecialPlanDish) {
        let cooked = SpecialPlanDish(recipeID: "r-cucumber", recipeName: "凉拌黄瓜")
        let added = SpecialPlanDish(recipeID: "user-pork", recipeName: "妈妈的红烧肉")
        let aiDish = SpecialPlanDish(recipeID: "r-chicken", recipeName: "宫保鸡丁")
        let plan = SpecialPlan(
            title: "周六聚餐", scheduledAt: Date(timeIntervalSince1970: 1_750_000_000), peopleCount: 7,
            constraintNotes: [], notes: "", requestText: "周六 7 个人", usesHomeInventory: true,
            dishes: [aiDish, added, cooked]
        )
        kitchen.addSpecialPlan(plan)
        _ = kitchen.setDishCooked(cooked.id, inSpecialPlan: plan.id, isCooked: true)
        return (plan, cooked, added, aiDish)
    }

    func testSavingANewMenuKeepsCookedDishesWithTheirIds() throws {
        let (kitchen, recipes) = makeStores()
        let fixture = planWithMenu(kitchen)

        try SpecialPlanMenuAcceptance.acceptMenu(
            dishes: [draftDish("清蒸鲈鱼"), draftDish("白灼虾")],
            planID: fixture.plan.id, kitchenStore: kitchen, recipeStore: recipes
        )

        let saved = try XCTUnwrap(kitchen.specialPlans.first { $0.id == fixture.plan.id })
        XCTAssertEqual(saved.dishes.map(\.recipeName), ["凉拌黄瓜", "清蒸鲈鱼", "白灼虾"])
        let keptCooked = try XCTUnwrap(saved.dishes.first)
        XCTAssertEqual(keptCooked.id, fixture.cooked.id, "the cooked dish keeps the id its receipt points to")
        XCTAssertTrue(keptCooked.isCooked)
    }

    func testTheReplacedListIsEveryUncookedDishIncludingOnesAddedFromTheLibrary() {
        let (kitchen, _) = makeStores()
        let fixture = planWithMenu(kitchen)

        let replaced = SpecialPlanMenuAcceptance.dishesReplacedBySaving(planID: fixture.plan.id, kitchenStore: kitchen)
        XCTAssertEqual(replaced.map(\.id), [fixture.aiDish.id, fixture.added.id])
    }

    func testAPlanWithoutDishesHasNothingToConfirm() {
        let (kitchen, _) = makeStores()
        let plan = SpecialPlan(
            title: "聚餐", scheduledAt: Date(), peopleCount: 2, constraintNotes: [], notes: "",
            requestText: "", usesHomeInventory: true, dishes: []
        )
        kitchen.addSpecialPlan(plan)
        XCTAssertTrue(SpecialPlanMenuAcceptance.dishesReplacedBySaving(planID: plan.id, kitchenStore: kitchen).isEmpty)
    }
}

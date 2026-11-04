import XCTest
@testable import KitchenManager

/// The cook confirmation said 已记录消耗，库存已更新 whatever it deducted. Found
/// on the simulator: 白菜丸子 from the curated library has no quantities, every
/// row read 这一行不扣减, and the sheet still claimed stock was updated while
/// inventory was unchanged. The result now comes from the receipt.
@MainActor
final class CookConsumptionStockResultTests: XCTestCase {
    private var kitchenStore: KitchenStore!
    private var recipeStore: RecipeStore!

    override func setUp() {
        super.setUp()
        kitchenStore = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func recipe(_ title: String, _ ingredients: [String]) -> Recipe {
        Recipe(id: UUID().uuidString, title: title, cookingTime: nil, difficulty: nil,
               tags: [], ingredients: ingredients, steps: ["步骤"])
    }

    private func cookDirectly(_ dish: Recipe) -> CookConsumptionStore {
        let store = CookConsumptionStore()
        store.buildDrafts(planIDs: [], recipe: dish, kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertTrue(store.confirm(planIDs: [], recipeID: dish.id, recipeName: dish.title,
                                    kitchenStore: kitchenStore, recipeStore: recipeStore))
        return store
    }

    private func quantity(of name: String) -> Double? {
        kitchenStore.inventory.first { $0.name == name }?.quantity
    }

    func testRecipeWithoutQuantitiesSaysStockDidNotChange() throws {
        kitchenStore.addInventory(name: "白菜", quantity: 1, unit: "颗", expiryDate: nil)
        kitchenStore.addInventory(name: "猪肉", quantity: 300, unit: "克", expiryDate: nil)

        let store = cookDirectly(recipe("白菜丸子", ["猪肉", "白菜", "鸡蛋"]))

        XCTAssertEqual(quantity(of: "白菜"), 1)
        XCTAssertEqual(quantity(of: "猪肉"), 300)
        // The empty receipt is still written: it stops a second deduction.
        XCTAssertEqual(try XCTUnwrap(kitchenStore.consumptionRecords.first).items, [])
        XCTAssertEqual(store.stockResult, .recorded(deducted: 0, notDeducted: 3))
        XCTAssertEqual(store.stockResult?.headline, "已记录这次做饭，库存没有变化")
        XCTAssertEqual(store.stockResult?.headlineStyle, .informational)
        XCTAssertTrue(store.didConfirm)
    }

    func testPartialDeductionNamesHowManyRowsWereDeducted() {
        kitchenStore.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)
        kitchenStore.addInventory(name: "鸡蛋", quantity: 6, unit: "个", expiryDate: nil)

        // 土豆 is not in stock. (Not 盐: Recipe files salt under seasonings,
        // which the sheet does not list.)
        let store = cookDirectly(recipe("番茄炒蛋", ["番茄 2个", "鸡蛋", "土豆 1个"]))

        XCTAssertEqual(quantity(of: "番茄"), 3)
        XCTAssertEqual(quantity(of: "鸡蛋"), 6, "no amount, so 鸡蛋 is left alone")
        XCTAssertEqual(store.drafts.count, 3)
        XCTAssertEqual(store.stockResult, .recorded(deducted: 1, notDeducted: 2))
        XCTAssertEqual(store.stockResult?.headline, "已扣减 1 样食材，2 样未扣减")
        XCTAssertEqual(store.stockResult?.headlineStyle, .success)
    }

    func testFullDeductionKeepsTheUpdatedCopy() {
        kitchenStore.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)

        let store = cookDirectly(recipe("糖拌番茄", ["番茄 2个"]))

        XCTAssertEqual(store.stockResult, .recorded(deducted: 1, notDeducted: 0))
        XCTAssertEqual(store.stockResult?.headline, "已记录消耗，库存已更新")
        XCTAssertEqual(store.stockResult?.headlineStyle, .success)
    }

    /// Two batches of one food are one row the member saw, not two.
    func testOneRowSpreadOverTwoBatchesCountsOnce() {
        let soon = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let later = Calendar.current.date(byAdding: .day, value: 10, to: Date())!
        kitchenStore.addInventory(name: "鸡蛋", quantity: 6, unit: "个", expiryDate: soon)
        kitchenStore.addInventory(name: "鸡蛋", quantity: 6, unit: "个", expiryDate: later)

        let store = cookDirectly(recipe("蛋饼", ["鸡蛋 8个"]))

        XCTAssertEqual(kitchenStore.consumptionRecords.first?.items.count, 2)
        XCTAssertEqual(store.stockResult, .recorded(deducted: 1, notDeducted: 0))
    }

    /// Two rows can share a food (猪肉 100克 and a bare 猪肉). Only the one with
    /// an amount deducts, so the result must not read as a full deduction.
    func testARowWithoutAnAmountIsNotCreditedWithAnotherRowsDeduction() {
        kitchenStore.addInventory(name: "猪肉", quantity: 300, unit: "克", expiryDate: nil)

        let store = cookDirectly(recipe("回锅肉", ["猪肉 100克", "猪肉"]))

        XCTAssertEqual(store.drafts.count, 2)
        XCTAssertEqual(store.stockResult, .recorded(deducted: 1, notDeducted: 1))
    }

    func testConfirmingAPlanAgainSaysNothingWasDeductedTwice() throws {
        kitchenStore.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)
        let dish = try XCTUnwrap(Recipe.samples.first { $0.id == "sample-tomato-eggs" })
        kitchenStore.addPlan(recipe: dish)
        let planID = try XCTUnwrap(kitchenStore.plans.first?.id)

        let first = CookConsumptionStore()
        first.buildDrafts(planIDs: [planID], kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertTrue(first.confirm(planIDs: [planID], recipeID: dish.id, recipeName: dish.title,
                                    kitchenStore: kitchenStore, recipeStore: recipeStore))
        XCTAssertEqual(quantity(of: "番茄"), 3)

        let again = CookConsumptionStore()
        again.buildDrafts(planIDs: [planID], kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertTrue(again.confirm(planIDs: [planID], recipeID: dish.id, recipeName: dish.title,
                                    kitchenStore: kitchenStore, recipeStore: recipeStore))

        XCTAssertEqual(quantity(of: "番茄"), 3)
        XCTAssertEqual(kitchenStore.consumptionRecords.count, 1)
        XCTAssertEqual(again.stockResult, .alreadyRecorded(stockChanged: true))
        XCTAssertEqual(again.stockResult?.headline, "食材消耗之前已记录，库存没有再次扣减")
        XCTAssertEqual(again.stockResult?.headlineStyle, .informational)
        // D-047 §5: the earlier confirmation did deduct, so its pair still reads 库存已更新.
        XCTAssertEqual(again.stockResult?.savedStockLine, "库存已更新")
    }

    func testAFailedConfirmationLeavesNoResult() {
        let store = CookConsumptionStore()
        store.buildDrafts(planIDs: [], recipe: recipe("菜", ["番茄 2个"]), kitchenStore: kitchenStore, recipeStore: recipeStore)
        // A plan the store was not prepared for is rejected.
        XCTAssertFalse(store.confirm(planIDs: [UUID()], recipeID: nil, recipeName: "菜",
                                     kitchenStore: kitchenStore, recipeStore: recipeStore))
        XCTAssertNil(store.stockResult)
        XCTAssertFalse(store.didConfirm)
    }

    /// D-047 §5's stock line when the dish state failed to save keeps 库存已更新
    /// only for stock that really changed.
    func testSavedStockLineFollowsWhetherStockChanged() {
        XCTAssertEqual(CookConsumptionStockResult.recorded(deducted: 2, notDeducted: 1).savedStockLine, "库存已更新")
        XCTAssertEqual(CookConsumptionStockResult.recorded(deducted: 2, notDeducted: 1).savedStockStyle, .success)
        XCTAssertEqual(CookConsumptionStockResult.recorded(deducted: 0, notDeducted: 3).savedStockLine, "库存没有变化")
        XCTAssertEqual(CookConsumptionStockResult.recorded(deducted: 0, notDeducted: 3).savedStockStyle, .informational)
        XCTAssertEqual(CookConsumptionStockResult.alreadyRecorded(stockChanged: false).savedStockLine, "库存没有变化")
        // A retry after an empty first receipt must not imply an earlier deduction.
        XCTAssertEqual(CookConsumptionStockResult.alreadyRecorded(stockChanged: false).headline, "已记录过这次做饭，库存没有变化")
        XCTAssertEqual(CookConsumptionStockResult.recorded(deducted: 0, notDeducted: 0).headline, "已记录这次做饭，库存没有变化")
    }
}

import XCTest
@testable import KitchenManager

/// CONSISTENCY_SWEEP-7 / INVENTORY_MODEL-9 / SHOPPING_LOGIC-10: a cooked-down
/// batch stays as a 0 row beside a newer batch, and that row alone made Home
/// say "鸡蛋 · 已用完" and the post-cook sheet offer 加入清单 while eggs were
/// still in the fridge. Used-up is now judged per food across its batches.
@MainActor
final class UsedUpPerFoodTests: XCTestCase {
    private func batch(_ name: String, _ quantity: Double, unit: String = "个", expiresIn days: Int) -> InventoryItem {
        InventoryItem(name: name, quantity: quantity, unit: unit,
                      expiryDate: Calendar.current.date(byAdding: .day, value: days, to: Date()), createdAt: Date())
    }

    private func summary(_ inventory: [InventoryItem]) -> HomeDashboardSummary {
        HomeDashboardSummary(inventory: inventory, todayPlans: [], shoppingItems: [])
    }

    func testAnEmptiedBatchBesideAStockedOneIsNotUsedUp() {
        let home = summary([batch("鸡蛋", 0, expiresIn: 3), batch("鸡蛋", 6, expiresIn: 20)])
        XCTAssertEqual(home.lowStockCount, 0)
        XCTAssertFalse(home.attentionItems.contains { $0.kind == .lowStock })
    }

    func testAFoodWithEveryBatchEmptyIsOneUsedUpRow() {
        let home = summary([batch("鸡蛋", 0, expiresIn: 3), batch("鸡蛋", 0, expiresIn: 20), batch("番茄", 3, expiresIn: 5)])
        let rows = home.attentionItems.filter { $0.kind == .lowStock }
        XCTAssertEqual(rows.map(\.name), ["鸡蛋"])
        XCTAssertEqual(rows.first?.detail, "已用完")
        XCTAssertEqual(home.lowStockCount, 1)
    }

    func testRestockSkipsAFoodAnotherBatchStillHolds() {
        let kitchen = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
                                   persistence: KitchenPersistenceFactory.isolatedInMemory())
        let old = batch("鸡蛋", 0, expiresIn: 1)
        let fresh = batch("鸡蛋", 9, expiresIn: 20)
        kitchen.inventory = [old, fresh]
        let emptiedOldBatch = InventoryConsumptionRecordItem(
            inventoryItemID: old.id, ingredientName: "鸡蛋", consumedQuantity: 2, unit: "个",
            previousQuantity: 2, resultingQuantity: 0
        )

        let suggestions = RestockSuggestionEngine().generate(
            kitchenStore: kitchen,
            recipeStore: RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!),
            justConsumed: [emptiedOldBatch]
        )
        XCTAssertFalse(suggestions.contains { $0.source == .consumed && $0.name == "鸡蛋" })
    }

    func testRestockStillSuggestsAFoodThatIsReallyGone() {
        let kitchen = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
                                   persistence: KitchenPersistenceFactory.isolatedInMemory())
        let only = batch("鸡蛋", 0, expiresIn: 1)
        kitchen.inventory = [only]
        let emptied = InventoryConsumptionRecordItem(
            inventoryItemID: only.id, ingredientName: "鸡蛋", consumedQuantity: 4, unit: "个",
            previousQuantity: 4, resultingQuantity: 0
        )

        let suggestions = RestockSuggestionEngine().generate(
            kitchenStore: kitchen,
            recipeStore: RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!),
            justConsumed: [emptied]
        )
        XCTAssertTrue(suggestions.contains { $0.source == .consumed && $0.name == "鸡蛋" })
    }
}

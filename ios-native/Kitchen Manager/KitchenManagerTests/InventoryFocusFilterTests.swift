import XCTest
@testable import KitchenManager

/// INV-1: a used-up (0) batch kept showing under 已过期 and 临期 and sat at
/// the top of 全部 because only its date was sorted on. Home already left
/// used-up rows out of its expiry counts, so the two screens disagreed. 缺货
/// keeps every emptied row (KITCHEN_DESIGN_LANGUAGE.md, Phase A: an empty
/// ordinary row still counts under the 缺货 filter).
@MainActor
final class InventoryFocusFilterTests: XCTestCase {
    private func item(_ name: String, quantity: Double, expiryDays: Int?, staple: Bool = false) -> InventoryItem {
        InventoryItem(
            name: name, quantity: quantity, unit: "个",
            expiryDate: expiryDays.map { Calendar.current.date(byAdding: .day, value: $0, to: Date())! },
            isStaple: staple
        )
    }

    private var mixedInventory: [InventoryItem] {
        [
            item("牛奶", quantity: 0, expiryDays: -2),
            item("酸奶", quantity: 1, expiryDays: -1),
            item("豆腐", quantity: 0, expiryDays: 1),
            item("番茄", quantity: 3, expiryDays: 2),
            item("鸡蛋", quantity: 0, expiryDays: 3),
            item("鸡蛋", quantity: 6, expiryDays: 20),
            item("面包", quantity: 0, expiryDays: nil),
            item("大米", quantity: 0, expiryDays: nil, staple: true)
        ]
    }

    func testAUsedUpBatchIsNeitherExpiredNorExpiringSoon() {
        let inventory = mixedInventory
        let fresh = inventory.filter { !$0.isStaple }
        XCTAssertEqual(InventoryFocus.expired.rows(of: fresh).map(\.name), ["酸奶"])
        XCTAssertEqual(InventoryFocus.expiringSoon.rows(of: fresh).map(\.name), ["番茄"])
        XCTAssertEqual(InventoryFocus.all.rows(of: fresh).count, fresh.count,
                       "全部 still lists the used-up batches")
    }

    /// The 2026-10-08 screenshot review: an emptied row reads 已用完 and still
    /// counts under 缺货, even next to a newer stocked batch of the same food.
    func testEveryEmptiedRowStillCountsUnderLowStock() {
        let inventory = mixedInventory
        let fresh = inventory.filter { !$0.isStaple }
        let staples = inventory.filter(\.isStaple)
        XCTAssertEqual(InventoryFocus.lowStock.rows(of: fresh).map(\.name), ["牛奶", "豆腐", "鸡蛋", "面包"])
        XCTAssertEqual(InventoryFocus.lowStock.rows(of: staples).map(\.name), ["大米"])
    }

    /// The date filters count fresh rows; each must equal the number Home
    /// prints. 缺货 counts rows here and foods on Home, by design (above).
    func testDateFilterCountsMatchHome() {
        let inventory = mixedInventory
        let fresh = inventory.filter { !$0.isStaple }
        let home = HomeDashboardSummary(inventory: inventory, todayPlans: [], shoppingItems: [])

        XCTAssertEqual(InventoryFocus.expired.rows(of: fresh).count, home.expiredCount)
        XCTAssertEqual(InventoryFocus.expiringSoon.rows(of: fresh).count, home.expiringSoonCount)
    }

    func testAllListsUsedUpBatchesAfterStockedOnesKeepingEachGroupsOrder() {
        let store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
                                 persistence: KitchenPersistenceFactory.isolatedInMemory())
        store.inventory = [
            item("牛奶", quantity: 0, expiryDays: -2),
            item("番茄", quantity: 3, expiryDays: 5),
            item("酸奶", quantity: 1, expiryDays: -1),
            item("豆腐", quantity: 0, expiryDays: 1),
            item("面包", quantity: 2, expiryDays: nil),
            item("大米", quantity: 1, expiryDays: nil, staple: true)
        ]

        XCTAssertEqual(store.sortedFreshInventory.map(\.name), ["酸奶", "番茄", "面包", "牛奶", "豆腐"])
    }
}

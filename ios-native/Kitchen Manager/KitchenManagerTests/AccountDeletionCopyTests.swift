import XCTest
@testable import KitchenManager

/// The deletion page promised 本机可继续以游客模式使用 while a completed
/// deletion runs `KitchenStore.clearAllLocalData()` on this device.
@MainActor
final class AccountDeletionCopyTests: XCTestCase {
    func testDeletionPageSaysWhatIsClearedAndSuggestsABackup() {
        let notice = AccountDeletionView.localDataNotice
        for domain in ["库存", "买菜清单", "用餐计划", "每周菜单", "聚餐计划", "备餐组件", "消耗记录"] {
            XCTAssertTrue(notice.contains(domain), "缺少「\(domain)」")
        }
        XCTAssertTrue(notice.contains("菜谱库保留"))
        XCTAssertTrue(notice.contains("备份与恢复"))
    }

    /// The list above is the truth: the clear the deletion runs empties them.
    func testTheClearTheDeletionRunsEmptiesTheNamedKitchenData() {
        let kitchen = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        kitchen.addInventory(name: "鸡蛋", quantity: 2, unit: "个", expiryDate: nil)
        kitchen.addShopping(name: "番茄")
        kitchen.addSpecialPlan(SpecialPlan(title: "周末聚会", scheduledAt: Date()))

        kitchen.clearAllLocalData()

        XCTAssertTrue(kitchen.inventory.isEmpty)
        XCTAssertTrue(kitchen.shoppingItems.isEmpty)
        XCTAssertTrue(kitchen.plans.isEmpty)
        XCTAssertTrue(kitchen.specialPlans.isEmpty)
        XCTAssertNil(kitchen.weeklyPlan)
        XCTAssertTrue(kitchen.consumptionRecords.isEmpty)
        XCTAssertTrue(kitchen.preparedComponents.isEmpty)
    }
}

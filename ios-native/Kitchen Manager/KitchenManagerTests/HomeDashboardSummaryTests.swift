import XCTest
@testable import KitchenManager

final class HomeDashboardSummaryTests: XCTestCase {
    private let calendar = Calendar.current

    private func item(
        name: String,
        quantity: Double = 1,
        expiryDays: Int? = nil,
        staple: Bool = false,
        threshold: Double? = nil
    ) -> InventoryItem {
        InventoryItem(
            name: name,
            quantity: quantity,
            unit: "份",
            expiryDate: expiryDays.map { calendar.date(byAdding: .day, value: $0, to: Date())! },
            isStaple: staple,
            lowStockThreshold: threshold
        )
    }

    private func plan(_ name: String, cooked: Bool = false) -> MealPlanItem {
        MealPlanItem(recipeID: name, recipeName: name, isCooked: cooked)
    }

    func testTodayPlanDisplaysAtMostThreePendingPlansBeforeCompletedPlans() {
        let summary = HomeDashboardSummary(
            inventory: [],
            todayPlans: [plan("已完成", cooked: true), plan("未完成一"), plan("未完成二"), plan("未完成三"), plan("未完成四")],
            shoppingItems: []
        )

        XCTAssertEqual(summary.displayedPlans.map(\.recipeName), ["未完成一", "未完成二", "未完成三"])
        XCTAssertEqual(summary.additionalPlanCount, 2)
        XCTAssertEqual(summary.completedPlanCount, 1)
        XCTAssertEqual(summary.todayPlanState, .partial)
    }

    func testInventorySummarySeparatesExpiredExpiringAndLowStock() {
        let summary = HomeDashboardSummary(
            inventory: [
                item(name: "过期", expiryDays: -1),
                item(name: "明天到期", expiryDays: 1),
                item(name: "米", quantity: 1, staple: true, threshold: 2),
                item(name: "充足", quantity: 5, staple: true, threshold: 2)
            ],
            todayPlans: [],
            shoppingItems: []
        )

        XCTAssertEqual(summary.expiredCount, 1)
        XCTAssertEqual(summary.expiringSoonCount, 1)
        XCTAssertEqual(summary.lowStockCount, 1)
        XCTAssertTrue(summary.hasInventoryAlerts)
    }

    func testEmptyDashboardOffersEmptyTodayPlanAndCompactShoppingState() {
        let summary = HomeDashboardSummary(inventory: [], todayPlans: [], shoppingItems: [])

        XCTAssertEqual(summary.todayPlanState, .empty)
        XCTAssertEqual(summary.totalPlanCount, 0)
        XCTAssertEqual(summary.pendingShoppingCount, 0)
        XCTAssertTrue(summary.shoppingPreview.isEmpty)
        XCTAssertFalse(summary.hasInventoryAlerts)
    }

    func testShoppingPreviewIsBoundedAndPreservesExistingOrder() {
        let items = ["鸡蛋", "牛奶", "青菜", "面包"].map { KitchenShoppingItem(name: $0) }
        let summary = HomeDashboardSummary(inventory: [], todayPlans: [], shoppingItems: items)

        XCTAssertEqual(summary.pendingShoppingCount, 4)
        XCTAssertEqual(summary.shoppingPreview.map(\.name), ["鸡蛋", "牛奶", "青菜"])
    }

    func testHeaderHandlesGuestAndSignedInWithoutHousehold() {
        XCTAssertEqual(HomeDashboardHeaderModel(displayName: nil, householdName: nil).title, "今天吃什么？")
        XCTAssertFalse(HomeDashboardHeaderModel(displayName: nil, householdName: nil).shouldShowHousehold)
        XCTAssertEqual(HomeDashboardHeaderModel(displayName: "泓靖", householdName: nil).title, "你好，泓靖")
        XCTAssertFalse(HomeDashboardHeaderModel(displayName: "泓靖", householdName: " ").shouldShowHousehold)
    }

    func testModuleIssuesRemainIndependent() {
        XCTAssertEqual(HomeDashboardModuleIssue.issues(inventoryNotice: "库存保存失败，请稍后重试。", shoppingNotice: nil), [.inventory])
        XCTAssertEqual(HomeDashboardModuleIssue.issues(inventoryNotice: nil, shoppingNotice: "购物清单保存失败，请稍后重试。"), [.shopping])
        XCTAssertEqual(HomeDashboardModuleIssue.issues(inventoryNotice: "已添加 1 项食材", shoppingNotice: ""), [])
    }

    func testPrimaryActionAddsPlanWhenTodayIsEmpty() {
        let summary = HomeDashboardSummary(inventory: [], todayPlans: [], shoppingItems: [])

        XCTAssertEqual(summary.primaryAction, .addTodayPlan)
    }

    func testPrimaryActionViewsPlanWhenTodayHasUnfinishedWork() {
        let summary = HomeDashboardSummary(
            inventory: [],
            todayPlans: [plan("已完成", cooked: true), plan("待完成")],
            shoppingItems: []
        )

        XCTAssertEqual(summary.todayPlanState, .partial)
        XCTAssertEqual(summary.primaryAction, .viewTodayPlan)
    }

    func testPrimaryActionBrowsesRecipesWhenTodayIsComplete() {
        let summary = HomeDashboardSummary(
            inventory: [],
            todayPlans: [plan("已完成", cooked: true)],
            shoppingItems: []
        )

        XCTAssertEqual(summary.primaryAction, .browseRecipes)
    }

    func testPurchasedItemsOverrideAllOtherRemindersAndPrimaryActions() {
        let purchased = KitchenShoppingItem(name: "牛奶", isDone: true)
        let summary = HomeDashboardSummary(
            inventory: [
                item(name: "过期", expiryDays: -1),
                item(name: "临期", expiryDays: 1),
                item(name: "米", quantity: 1, staple: true, threshold: 2)
            ],
            todayPlans: [],
            shoppingItems: [purchased, KitchenShoppingItem(name: "鸡蛋")]
        )

        XCTAssertEqual(summary.primaryAction, .stockInPurchased)
        XCTAssertEqual(summary.highestPriorityReminder, .purchasedAwaitingStockIn(count: 1))
    }

    func testExpiredReminderPrecedesExpiringShoppingAndLowStock() {
        let summary = HomeDashboardSummary(
            inventory: [
                item(name: "过期", expiryDays: -1),
                item(name: "临期", expiryDays: 1),
                item(name: "米", quantity: 1, staple: true, threshold: 2)
            ],
            todayPlans: [],
            shoppingItems: [KitchenShoppingItem(name: "鸡蛋")]
        )

        XCTAssertEqual(summary.highestPriorityReminder, .expiredInventory(count: 1))
    }

    func testExpiringReminderPrecedesPendingShoppingAndLowStock() {
        let summary = HomeDashboardSummary(
            inventory: [
                item(name: "临期一", expiryDays: 1),
                item(name: "临期二", expiryDays: 2),
                item(name: "米", quantity: 1, staple: true, threshold: 2)
            ],
            todayPlans: [],
            shoppingItems: [KitchenShoppingItem(name: "鸡蛋")]
        )

        XCTAssertEqual(summary.highestPriorityReminder, .expiringInventory(count: 2))
    }

    func testPendingShoppingReminderPrecedesLowStock() {
        let summary = HomeDashboardSummary(
            inventory: [item(name: "米", quantity: 1, staple: true, threshold: 2)],
            todayPlans: [],
            shoppingItems: [KitchenShoppingItem(name: "鸡蛋"), KitchenShoppingItem(name: "青菜")]
        )

        XCTAssertEqual(summary.highestPriorityReminder, .pendingShopping(count: 2))
    }

    func testLowStockIsUsedWhenNoHigherPriorityReminderExists() {
        let summary = HomeDashboardSummary(
            inventory: [item(name: "米", quantity: 1, staple: true, threshold: 2)],
            todayPlans: [],
            shoppingItems: []
        )

        XCTAssertEqual(summary.highestPriorityReminder, .lowStock(count: 1))
    }

    func testNoReminderReturnsNil() {
        let summary = HomeDashboardSummary(inventory: [], todayPlans: [], shoppingItems: [])

        XCTAssertNil(summary.highestPriorityReminder)
    }

    func testPurchasedItemsAreAggregatedWithoutChangingPendingPreview() {
        let summary = HomeDashboardSummary(
            inventory: [],
            todayPlans: [],
            shoppingItems: [
                KitchenShoppingItem(name: "牛奶", isDone: true),
                KitchenShoppingItem(name: "面包", isDone: true),
                KitchenShoppingItem(name: "鸡蛋")
            ]
        )

        XCTAssertEqual(summary.purchasedShoppingCount, 2)
        XCTAssertEqual(summary.pendingShoppingCount, 1)
        XCTAssertEqual(summary.shoppingPreview.map(\.name), ["鸡蛋"])
        XCTAssertEqual(summary.highestPriorityReminder, .purchasedAwaitingStockIn(count: 2))
    }
}

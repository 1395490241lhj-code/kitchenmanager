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

    // MARK: - Needs attention (Home V2)
    //
    // The chips said 即将到期 2. They could not be acted on from Home and did not
    // say which food was at risk. These tests pin the replacement: named rows,
    // one deterministic order, and every fact appearing exactly once.

    private func batch(_ name: String, inDays days: Int, portions: Int = 2) -> PreparedComponent {
        PreparedComponent(
            name: name,
            portionsRemaining: portions,
            state: .cooked,
            storage: .refrigerated,
            preparedAt: Date(),
            expiryDate: calendar.date(byAdding: .day, value: days, to: Date())!
        )
    }

    func testAttentionRowsNameTheFoodInsteadOfCountingIt() {
        let summary = HomeDashboardSummary(
            inventory: [item(name: "上海青", expiryDays: 1)],
            todayPlans: [],
            shoppingItems: []
        )

        XCTAssertEqual(summary.attentionItems.map(\.name), ["上海青"])
        XCTAssertEqual(summary.attentionItems.map(\.detail), ["明天到期"])
        // The count projection still exists — it is simply no longer what Home
        // shows.
        XCTAssertEqual(summary.expiringSoonCount, 1)
    }

    func testAttentionPriorityPutsSpoilageBeforeTidyingUp() {
        let summary = HomeDashboardSummary(
            inventory: [
                item(name: "过期生菜", expiryDays: -1),
                item(name: "上海青", expiryDays: 1),
                item(name: "鸡蛋", quantity: 1, staple: true, threshold: 2)
            ],
            todayPlans: [],
            shoppingItems: [
                KitchenShoppingItem(name: "牛奶", isDone: true),
                KitchenShoppingItem(name: "面包")
            ],
            preparedComponents: [batch("卤鸡腿", inDays: 1)]
        )

        XCTAssertEqual(
            summary.attentionItems.map(\.kind),
            [
                .expiredInventory,
                .preparedExpiring,
                .expiringInventory,
                .purchasedAwaitingStockIn,
                .pendingShopping,
                .lowStock
            ],
            "Food already going bad cannot wait; groceries waiting to be put away can. Low stock is about shopping later, so it comes last."
        )
    }

    func testPreparedBatchesAppearOnAnyDayButOnlyWhileTimeSensitive() {
        let summary = HomeDashboardSummary(
            inventory: [],
            todayPlans: [],
            shoppingItems: [],
            preparedComponents: [
                batch("卤鸡腿", inDays: 1),
                batch("已经过期的卤味", inDays: -2),
                batch("腌鸡肉", inDays: 4)
            ]
        )

        // Nothing here depends on the day type: the projection has no idea one
        // exists. 腌鸡肉 is four days out and belongs on the board, not here.
        XCTAssertEqual(summary.attentionItems.map(\.name), ["已经过期的卤味", "卤鸡腿"])
        XCTAssertEqual(summary.attentionItems.map(\.detail), ["建议尽快吃完", "建议明天前吃完"])
        XCTAssertTrue(summary.attentionItems.allSatisfy { $0.kind == .preparedExpiring })
    }

    /// Determinism, not a particular alphabet. The tie-break chain ends in
    /// `localizedCompare` and then the record id, which is stable on any one
    /// device — the same chain `MealPrepBoard` already uses — so the assertion
    /// is that input order cannot change output order, not that a specific
    /// collation wins.
    func testAttentionOrderDoesNotDependOnInputOrderWhenItemsShareADate() {
        let items = [item(name: "菠菜", expiryDays: 1), item(name: "白菜", expiryDays: 1)]
        let forward = HomeDashboardSummary(inventory: items, todayPlans: [], shoppingItems: [])
        let reversed = HomeDashboardSummary(inventory: items.reversed(), todayPlans: [], shoppingItems: [])

        XCTAssertEqual(forward.attentionItems.count, 2)
        XCTAssertEqual(forward.attentionItems.map(\.name), reversed.attentionItems.map(\.name))
    }

    /// Dates still win over names, whatever the collation does.
    func testSoonerExpiryAlwaysOutranksLaterExpiry() {
        let summary = HomeDashboardSummary(
            inventory: [item(name: "后天", expiryDays: 2), item(name: "明天", expiryDays: 1)],
            todayPlans: [],
            shoppingItems: []
        )

        XCTAssertEqual(summary.attentionItems.map(\.name), ["明天", "后天"])
    }

    func testAttentionListIsBoundedAndSaysWhatItLeftOut() {
        let inventory = (1...7).map { item(name: "临期\($0)", expiryDays: $0 % 3) }
        let summary = HomeDashboardSummary(inventory: inventory, todayPlans: [], shoppingItems: [])

        let task = HomePrimaryTask.resolve(
            dayType: .cooking, dinnerIntent: .household,
            planState: .empty, totalPlanCount: 0, completedPlanCount: 0
        )
        let shown = task.needsAttention(from: summary.attentionItems)

        XCTAssertEqual(summary.attentionItems.count, 7)
        XCTAssertEqual(shown.visible.count, HomeDashboardSummary.maximumVisibleAttentionItems)
        XCTAssertEqual(shown.additional, 3, "A cap that is not reported reads as “that is everything”.")
    }

    func testHealthyKitchenProducesNoAttentionItems() {
        let summary = HomeDashboardSummary(inventory: [], todayPlans: [], shoppingItems: [])

        XCTAssertTrue(summary.attentionItems.isEmpty)
        XCTAssertFalse(summary.hasInventoryAlerts)
    }

    func testEachInventoryFactProducesExactlyOneRow() {
        let summary = HomeDashboardSummary(
            inventory: [item(name: "过期生菜", expiryDays: -1)],
            todayPlans: [],
            shoppingItems: []
        )

        XCTAssertEqual(summary.attentionItems.count, 1)
        XCTAssertEqual(Set(summary.attentionItems.map(\.id)).count, summary.attentionItems.count)
    }

    func testShoppingAlertsBecomeOneNamedRowEach() {
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
        XCTAssertEqual(
            summary.attentionItems.map { "\($0.name)·\($0.detail)" },
            ["已买的 2 项·等待入库", "买菜清单·还有 1 项没买"]
        )
    }

    func testInventoryDetailUsesRelativeWordingWhereAPersonWould() {
        XCTAssertEqual(HomeAttentionCopy.inventoryDetail(for: item(name: "a", expiryDays: -2)), "已过期 2 天")
        XCTAssertEqual(HomeAttentionCopy.inventoryDetail(for: item(name: "b", expiryDays: 0)), "今天到期")
        XCTAssertEqual(HomeAttentionCopy.inventoryDetail(for: item(name: "c", expiryDays: 1)), "明天到期")
        XCTAssertEqual(HomeAttentionCopy.inventoryDetail(for: item(name: "d", expiryDays: 3)), "3 天后到期")
        XCTAssertEqual(HomeAttentionCopy.inventoryDetail(for: item(name: "e")), "未设置保质期")
    }

    func testOutOfStockAndLowStockReadDifferently() {
        let summary = HomeDashboardSummary(
            inventory: [
                item(name: "橄榄油", quantity: 0, staple: true, threshold: 2),
                item(name: "鸡蛋", quantity: 1, staple: true, threshold: 2)
            ],
            todayPlans: [],
            shoppingItems: []
        )

        XCTAssertEqual(
            summary.attentionItems.map { "\($0.name)·\($0.detail)" },
            ["橄榄油·已用完", "鸡蛋·库存偏低"]
        )
    }
}

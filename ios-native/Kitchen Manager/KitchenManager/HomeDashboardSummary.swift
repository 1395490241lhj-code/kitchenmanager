import Foundation

/// A read-only projection of the existing local stores for the home screen.
/// It owns no persistence and deliberately does not infer ingredient
/// availability for a recipe: the dashboard only reports facts already held
/// by `KitchenStore`.
struct HomeDashboardSummary: Equatable {
    static let maximumVisiblePlans = 3
    static let maximumVisibleShoppingItems = 3

    let displayedPlans: [MealPlanItem]
    let totalPlanCount: Int
    let completedPlanCount: Int
    let expiredCount: Int
    let expiringSoonCount: Int
    let lowStockCount: Int
    let pendingShoppingCount: Int
    let purchasedShoppingCount: Int
    let shoppingPreview: [KitchenShoppingItem]

    init(
        inventory: [InventoryItem],
        todayPlans: [MealPlanItem],
        shoppingItems: [KitchenShoppingItem]
    ) {
        let pendingPlans = todayPlans.filter { !$0.isCooked }
        let completedPlans = todayPlans.filter(\.isCooked)
        displayedPlans = Array((pendingPlans + completedPlans).prefix(Self.maximumVisiblePlans))
        totalPlanCount = todayPlans.count
        completedPlanCount = completedPlans.count

        expiredCount = inventory.filter { $0.isAvailable && $0.expiryStatus == .expired }.count
        expiringSoonCount = inventory.filter {
            $0.isAvailable && ($0.expiryStatus == .today || $0.expiryStatus == .soon)
        }.count
        lowStockCount = inventory.filter {
            $0.stapleStatus == .low || $0.stapleStatus == .outOfStock
        }.count

        let pendingShoppingItems = shoppingItems.filter { !$0.isDone }
        pendingShoppingCount = pendingShoppingItems.count
        purchasedShoppingCount = shoppingItems.count - pendingShoppingItems.count
        shoppingPreview = Array(pendingShoppingItems.prefix(Self.maximumVisibleShoppingItems))
    }

    var hasInventoryAlerts: Bool {
        expiredCount > 0 || expiringSoonCount > 0 || lowStockCount > 0
    }

    var additionalPlanCount: Int {
        max(0, totalPlanCount - displayedPlans.count)
    }

    var todayPlanState: HomeTodayPlanState {
        guard totalPlanCount > 0 else { return .empty }
        if completedPlanCount == totalPlanCount { return .completed }
        return completedPlanCount > 0 ? .partial : .active
    }

    var primaryAction: HomePrimaryAction {
        if purchasedShoppingCount > 0 { return .stockInPurchased }
        switch todayPlanState {
        case .empty: return .addTodayPlan
        case .active, .partial: return .viewTodayPlan
        case .completed: return .browseRecipes
        }
    }

    var highestPriorityReminder: HomeAttentionReminder? {
        if purchasedShoppingCount > 0 { return .purchasedAwaitingStockIn(count: purchasedShoppingCount) }
        if expiredCount > 0 { return .expiredInventory(count: expiredCount) }
        if expiringSoonCount > 0 { return .expiringInventory(count: expiringSoonCount) }
        if pendingShoppingCount > 0 { return .pendingShopping(count: pendingShoppingCount) }
        if lowStockCount > 0 { return .lowStock(count: lowStockCount) }
        return nil
    }
}

enum HomeTodayPlanState: Equatable {
    case empty
    case active
    case partial
    case completed
}

enum HomePrimaryAction: Equatable {
    case stockInPurchased
    case addTodayPlan
    case viewTodayPlan
    case browseRecipes
}

enum HomeAttentionReminder: Equatable {
    case purchasedAwaitingStockIn(count: Int)
    case expiredInventory(count: Int)
    case expiringInventory(count: Int)
    case pendingShopping(count: Int)
    case lowStock(count: Int)

    var count: Int {
        switch self {
        case .purchasedAwaitingStockIn(let count),
             .expiredInventory(let count),
             .expiringInventory(let count),
             .pendingShopping(let count),
             .lowStock(let count):
            count
        }
    }
}

struct HomeDashboardHeaderModel: Equatable {
    let displayName: String?
    let householdName: String?

    var title: String {
        displayName.map { "你好，\($0)" } ?? "今天吃什么？"
    }

    var shouldShowHousehold: Bool {
        householdName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

enum HomeDashboardModuleIssue: Equatable {
    case inventory
    case shopping

    static func issues(inventoryNotice: String?, shoppingNotice: String?) -> [Self] {
        var issues: [Self] = []
        if inventoryNotice?.contains("失败") == true { issues.append(.inventory) }
        if shoppingNotice?.contains("失败") == true { issues.append(.shopping) }
        return issues
    }

    var title: String {
        switch self {
        case .inventory: "库存暂未完全保存"
        case .shopping: "购物清单暂未完全保存"
        }
    }

    var actionTitle: String {
        switch self {
        case .inventory: "查看食材"
        case .shopping: "查看清单"
        }
    }
}

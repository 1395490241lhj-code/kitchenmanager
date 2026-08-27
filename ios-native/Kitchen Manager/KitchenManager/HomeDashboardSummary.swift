import Foundation

/// A read-only projection of the existing local stores for the home screen.
/// It owns no persistence and deliberately does not infer ingredient
/// availability for a recipe: the dashboard only reports facts already held
/// by `KitchenStore`.
///
/// Home V2 added `preparedComponents`. It is read strictly the same way as
/// everything else here — counted and described, never mutated — and it exists
/// because a batch going off was previously invisible on Home unless the day
/// happened to be a 备餐日. Nothing about `PreparedComponent`'s schema, its
/// consumption path or its expiry seeding is touched by reading it.
struct HomeDashboardSummary: Equatable {
    static let maximumVisiblePlans = 3
    static let maximumVisibleShoppingItems = 3
    /// Home lists this many things to handle and then says how many are left.
    /// A bounded list keeps 需要处理 secondary; the overflow row keeps the cap
    /// from reading as "that is everything".
    static let maximumVisibleAttentionItems = 4

    let displayedPlans: [MealPlanItem]
    let totalPlanCount: Int
    let completedPlanCount: Int
    let expiredCount: Int
    let expiringSoonCount: Int
    let lowStockCount: Int
    let pendingShoppingCount: Int
    let purchasedShoppingCount: Int
    let shoppingPreview: [KitchenShoppingItem]
    /// Every named thing worth handling today, already in priority order.
    /// Unbounded on purpose: `HomePrimaryTask.needsAttention(from:)` decides
    /// what is redundant with the primary region and applies the cap, so this
    /// projection stays a plain statement of the facts.
    let attentionItems: [HomeAttentionItem]

    init(
        inventory: [InventoryItem],
        todayPlans: [MealPlanItem],
        shoppingItems: [KitchenShoppingItem],
        preparedComponents: [PreparedComponent] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let pendingPlans = todayPlans.filter { !$0.isCooked }
        let completedPlans = todayPlans.filter(\.isCooked)
        displayedPlans = Array((pendingPlans + completedPlans).prefix(Self.maximumVisiblePlans))
        totalPlanCount = todayPlans.count
        completedPlanCount = completedPlans.count

        let expiredItems = inventory.filter { $0.isAvailable && $0.expiryStatus == .expired }
        let expiringItems = inventory.filter {
            $0.isAvailable && ($0.expiryStatus == .today || $0.expiryStatus == .soon)
        }
        let lowStockItems = inventory.filter {
            $0.stapleStatus == .low || $0.stapleStatus == .outOfStock
        }
        expiredCount = expiredItems.count
        expiringSoonCount = expiringItems.count
        lowStockCount = lowStockItems.count

        let pendingShoppingItems = shoppingItems.filter { !$0.isDone }
        pendingShoppingCount = pendingShoppingItems.count
        purchasedShoppingCount = shoppingItems.count - pendingShoppingItems.count
        shoppingPreview = Array(pendingShoppingItems.prefix(Self.maximumVisibleShoppingItems))

        attentionItems = HomeAttentionItem.projection(
            expiredInventory: expiredItems,
            expiringInventory: expiringItems,
            lowStockInventory: lowStockItems,
            preparedComponents: preparedComponents,
            purchasedShoppingCount: purchasedShoppingCount,
            pendingShoppingCount: pendingShoppingCount,
            now: now,
            calendar: calendar
        )
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
}

enum HomeTodayPlanState: Equatable {
    case empty
    case active
    case partial
    case completed
}

// MARK: - Needs attention
//
// Home V2 replaced the count chips (即将到期 2) with named rows (上海青 ·
// 明天到期). A count cannot be acted on from Home and does not say which food is
// at risk, so it forced a navigation just to find out what it meant.
//
// The list is one place, in one order, so the same fact can never appear twice
// in two shapes. `HomeDashboardSummary.highestPriorityReminder` used to compute
// a competing priority order; it was never read by `HomeView` and is gone.

/// One named thing worth handling today.
struct HomeAttentionItem: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case expiredInventory
        case preparedExpiring
        case expiringInventory
        case purchasedAwaitingStockIn
        case pendingShopping
        case lowStock
    }

    let id: String
    let kind: Kind
    /// The food, or — for the two batch operations that have no single subject —
    /// what the batch is.
    let name: String
    /// Why it is here. Never a food-safety claim.
    let detail: String
}

extension HomeAttentionItem {
    /// Priority order, and the reasoning behind it:
    ///
    /// Spoilage outranks tidying up. Food already going bad cannot wait;
    /// groceries waiting to be put away can. Within spoilage, food that is
    /// already made outranks raw ingredients that are merely close, because a
    /// cooked batch has a shorter honest life and more work already invested.
    /// Low stock comes last: it is the only entry that is about shopping later
    /// rather than about food that exists now.
    ///
    /// Every tier sorts deterministically all the way down to a stable key, so
    /// the same kitchen always produces the same list.
    static func projection(
        expiredInventory: [InventoryItem],
        expiringInventory: [InventoryItem],
        lowStockInventory: [InventoryItem],
        preparedComponents: [PreparedComponent],
        purchasedShoppingCount: Int,
        pendingShoppingCount: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [HomeAttentionItem] {
        var items: [HomeAttentionItem] = []

        items += expiredInventory
            .sorted(by: inventoryOrder)
            .map { item in
                HomeAttentionItem(
                    id: "expired.\(item.id.uuidString)",
                    kind: .expiredInventory,
                    name: item.name,
                    detail: HomeAttentionCopy.inventoryDetail(for: item)
                )
            }

        items += preparedComponents
            .filter {
                PreparedComponentExpiryPolicy.isUrgentForHomeAttention(
                    expiryDate: $0.expiryDate, now: now, calendar: calendar
                )
            }
            .sorted(by: preparedOrder)
            .map { component in
                HomeAttentionItem(
                    id: "prepared.\(component.id.uuidString)",
                    kind: .preparedExpiring,
                    name: component.name,
                    // Reuses the board's wording rather than inventing a second
                    // phrasing for the same fact. It stays 建议…吃完: the user's
                    // own note about when to finish a batch, never a guarantee.
                    detail: MealPrepBoard.expiryText(for: component.expiryDate, now: now, calendar: calendar)
                )
            }

        items += expiringInventory
            .sorted(by: inventoryOrder)
            .map { item in
                HomeAttentionItem(
                    id: "expiring.\(item.id.uuidString)",
                    kind: .expiringInventory,
                    name: item.name,
                    detail: HomeAttentionCopy.inventoryDetail(for: item)
                )
            }

        if purchasedShoppingCount > 0 {
            items.append(
                HomeAttentionItem(
                    id: "shopping.stockIn",
                    kind: .purchasedAwaitingStockIn,
                    name: "已买的 \(purchasedShoppingCount) 项",
                    detail: "等待入库"
                )
            )
        }

        if pendingShoppingCount > 0 {
            items.append(
                HomeAttentionItem(
                    id: "shopping.pending",
                    kind: .pendingShopping,
                    name: "买菜清单",
                    detail: "还有 \(pendingShoppingCount) 项没买"
                )
            )
        }

        items += lowStockInventory
            .sorted { lhs, rhs in
                if lhs.name != rhs.name {
                    return lhs.name.localizedCompare(rhs.name) == .orderedAscending
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map { item in
                HomeAttentionItem(
                    id: "lowStock.\(item.id.uuidString)",
                    kind: .lowStock,
                    name: item.name,
                    detail: item.stapleStatus == .outOfStock ? "已用完" : "库存偏低"
                )
            }

        return items
    }

    /// Soonest first, then a stable key. Items without a date sort last so a
    /// missing expiry never jumps the queue.
    private static func inventoryOrder(_ lhs: InventoryItem, _ rhs: InventoryItem) -> Bool {
        switch (lhs.expiryDate, rhs.expiryDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            break
        }
        if lhs.name != rhs.name {
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Same tie-breaking chain `MealPrepBoard` uses, so a batch never appears in
    /// one order on the board and another in 需要处理.
    private static func preparedOrder(_ lhs: PreparedComponent, _ rhs: PreparedComponent) -> Bool {
        if lhs.expiryDate != rhs.expiryDate { return lhs.expiryDate < rhs.expiryDate }
        if lhs.preparedAt != rhs.preparedAt { return lhs.preparedAt < rhs.preparedAt }
        if lhs.name != rhs.name {
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum HomeAttentionCopy {
    /// Relative wording where a person would use it, a plain count otherwise.
    /// `InventoryItem.expiryStatusText` says 剩余 1 天, which is a shelf-life
    /// reading; a list of things to handle wants 明天到期.
    static func inventoryDetail(for item: InventoryItem) -> String {
        guard let days = item.remainingDays else { return "未设置保质期" }
        switch days {
        case ..<0: return "已过期 \(-days) 天"
        case 0: return "今天到期"
        case 1: return "明天到期"
        default: return "\(days) 天后到期"
        }
    }
}

struct HomeDashboardHeaderModel: Equatable {
    let displayName: String?
    let householdName: String?

    /// Unused by `HomeView` since Home V2: the navigation title is a fixed 今天
    /// and the page's state lives in the primary task's own heading, which is
    /// what lets the navigation layer stay still while the content changes.
    /// Restoring a greeting there was considered and decided against.
    ///
    /// Deliberately not deleted in that change — removing it is unrelated
    /// cleanup and belongs in its own pass, not folded into an IA revision.
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

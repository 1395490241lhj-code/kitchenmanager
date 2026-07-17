import Foundation

enum ShoppingCategory: String, CaseIterable, Identifiable {
    case produce = "蔬果", meat = "肉类", seafood = "海鲜", dairy = "乳制品", bakery = "烘焙", frozen = "冷冻", pantry = "粮油干货", spices = "调味香料", beverages = "饮品", other = "其他"
    var id: String { rawValue }

    static func category(for name: String) -> ShoppingCategory {
        let value = IngredientNormalizer.normalizedName(name).lowercased()
        let mapping: [(ShoppingCategory, [String])] = [
            (.produce, ["番茄", "土豆", "生菜", "青菜", "洋葱", "胡萝卜", "苹果", "香蕉", "蔬", "菜"]),
            (.meat, ["鸡", "猪", "牛肉", "羊肉", "肉"]),
            (.seafood, ["鱼", "虾", "蟹", "贝"]),
            (.dairy, ["牛奶", "酸奶", "奶酪", "黄油", "鸡蛋"]),
            (.bakery, ["面包", "吐司", "蛋糕"]),
            (.frozen, ["冷冻", "速冻", "冰淇淋"]),
            (.spices, ["盐", "糖", "胡椒", "花椒", "香料", "酱", "醋"]),
            (.beverages, ["咖啡", "茶", "饮料", "果汁", "汽水"]),
            (.pantry, ["米", "面", "油", "粉", "豆", "罐头", "燕麦"])
        ]
        return mapping.first(where: { _, keywords in keywords.contains { value.contains($0) } })?.0 ?? .other
    }
}

struct ShoppingListSummary {
    let pendingCount: Int
    let purchasedCount: Int
    let categoryCount: Int

    init(items: [KitchenShoppingItem]) {
        let pending = items.filter { !$0.isDone }
        pendingCount = pending.count
        purchasedCount = items.count - pending.count
        categoryCount = Set(pending.map { ShoppingCategory.category(for: $0.name) }).count
    }
}

struct ShoppingBulkActionAvailability: Equatable {
    let pendingCount: Int
    let purchasedCount: Int

    init(summary: ShoppingListSummary) {
        pendingCount = summary.pendingCount
        purchasedCount = summary.purchasedCount
    }

    var canMarkAllPurchased: Bool { pendingCount > 0 }
    var canClearPurchased: Bool { purchasedCount > 0 }
    var canStockInPurchased: Bool { purchasedCount > 0 }
    var canChangePurchasedExpansion: Bool { purchasedCount > 0 }
}

struct ShoppingModePresentation: Equatable {
    let remainingCount: Int
    let totalCount: Int

    init(items: [KitchenShoppingItem]) {
        remainingCount = items.filter { !$0.isDone }.count
        totalCount = items.count
    }

    var isCompleted: Bool { totalCount > 0 && remainingCount == 0 }
    var isEmpty: Bool { totalCount == 0 }
}

enum ShoppingListPresentation {
    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ item: KitchenShoppingItem, query: String) -> Bool {
        let query = normalizedQuery(query)
        return query.isEmpty || item.name.localizedCaseInsensitiveContains(query)
    }

    static func sections(items: [KitchenShoppingItem], query: String) -> [(ShoppingCategory, [KitchenShoppingItem])] {
        let pending = items.filter { !$0.isDone && matches($0, query: query) }
        return ShoppingCategory.allCases.compactMap { category in
            let values = pending.filter { ShoppingCategory.category(for: $0.name) == category }
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            return values.isEmpty ? nil : (category, values)
        }
    }

    static func purchasedItems(items: [KitchenShoppingItem], query: String) -> [KitchenShoppingItem] {
        items
            .filter { $0.isDone && matches($0, query: query) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    static func shouldShowPurchased(
        isExpanded: Bool,
        query: String,
        matchingPurchasedCount: Int
    ) -> Bool {
        isExpanded || (!normalizedQuery(query).isEmpty && matchingPurchasedCount > 0)
    }
}

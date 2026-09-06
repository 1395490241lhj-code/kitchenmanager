import Foundation

#if DEBUG
/// Deterministic data only. Tests render the normal Shopping implementation.
enum ShoppingRegressionFixture {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_SEED_SHOPPING_REGRESSION")
    }

    static var items: [KitchenShoppingItem] {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("SHOPPING_DATA_EMPTY") { return [] }
        let mixed = arguments.contains("SHOPPING_DATA_MIXED")
        let dense = arguments.contains("SHOPPING_DATA_DENSE")
        let sources = arguments.contains("SHOPPING_DATA_SOURCES")
        var items = [
            KitchenShoppingItem(name: "上海青", quantity: 2, unit: "把", source: sources ? "今日计划" : "手动添加"),
            KitchenShoppingItem(name: "小葱", quantity: 1, unit: "把"),
            KitchenShoppingItem(name: "番茄", quantity: 4, unit: "个", source: sources ? "菜谱" : "手动添加"),
            KitchenShoppingItem(name: "牛奶", quantity: 2, unit: "L", source: sources ? "日常补给" : "手动添加", isDone: mixed),
            KitchenShoppingItem(name: "无糖希腊酸奶", quantity: 12, unit: "杯", isDone: mixed),
            KitchenShoppingItem(name: "嫩豆腐", quantity: 400, unit: "克", source: sources ? "本周菜单" : "手动添加")
        ]
        if dense {
            items += [
                KitchenShoppingItem(name: "意大利整颗去皮番茄罐头（无添加盐）", quantity: 3, unit: "罐"),
                KitchenShoppingItem(name: "胡萝卜", quantity: 6, unit: "根"),
                KitchenShoppingItem(name: "五花肉", quantity: 0.75, unit: "千克"),
                KitchenShoppingItem(name: "鸡蛋", quantity: 12, unit: "个"),
                KitchenShoppingItem(name: "冷冻去壳去虾线大虾仁（家庭装）", quantity: 750, unit: "克"),
                KitchenShoppingItem(name: "低钠生抽", quantity: 1, unit: "瓶"),
                KitchenShoppingItem(name: "全麦燕麦片", quantity: 2, unit: "袋"),
                KitchenShoppingItem(name: "厨房纸", quantity: 12, unit: "卷")
            ]
        }
        // Stable IDs across captures; names/amounts use the real model without a new schema.
        for index in items.indices {
            items[index].id = UUID(uuidString: String(format: "51000000-0000-0000-0000-%012d", index + 1))!
        }
        return items
    }
}
#endif

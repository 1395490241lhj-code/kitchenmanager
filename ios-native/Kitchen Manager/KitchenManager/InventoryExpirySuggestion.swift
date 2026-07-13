import Foundation

/// Conservative expiry defaults used by every normal inventory creation path.
///
/// Every ordinary grocery item — including dry goods, condiments, and other
/// long-life foods — now gets a real, finite suggested date; nothing falls
/// through to "no date" anymore except items explicitly on the pantry/staple
/// shelf (`category` containing "常备"), which genuinely don't expire on a
/// schedule worth tracking. An unrecognized name still gets a conservative
/// 7-day default rather than being left undated.
enum InventoryExpirySuggestion {
    static func suggestedExpiryDate(
        for ingredientName: String,
        category: String? = nil,
        from creationDate: Date = Date()
    ) -> Date? {
        let name = IngredientNormalizer.normalizedName(ingredientName).lowercased()
        let category = category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !name.isEmpty, !category.contains("常备") else { return nil }

        let days = suggestedDays(for: name, category: category)
        return Calendar.current.date(byAdding: .day, value: days, to: creationDate)
    }

    private static func suggestedDays(for name: String, category: String) -> Int {
        if category.contains("冷冻") || containsAny(name, frozenTerms) {
            return 90
        }
        // Processed condiments/sauces and shelf-stable staples are checked
        // FIRST, before any meat/seafood keyword match — otherwise
        // "牛肉酱"/"鱼露"/"虾酱" would false-positive as fresh meat/seafood
        // purely because they contain "牛肉"/"鱼"/"虾" as a substring.
        if containsAny(name, openedSauceTerms) {
            return 90
        }
        if containsAny(name, longLifeSeasoningTerms) {
            return 365
        }
        if containsAny(name, pantryStapleTerms) {
            return 180
        }
        if containsAny(name, curedMeatTerms) {
            return 7
        }
        if containsAny(name, breadTerms) {
            return 5
        }
        if containsAny(name, deliTerms) {
            return 3
        }
        if containsAny(name, seafoodTerms) {
            return 2
        }
        if containsAny(name, meatTerms) {
            return 3
        }
        if containsAny(name, leafyVegetableTerms) {
            return 5
        }
        if containsAny(name, dairyTerms) {
            return 7
        }
        if containsAny(name, eggTerms) {
            return 21
        }
        if containsAny(name, tofuTerms) {
            return 5
        }
        if containsAny(name, freshVegetableTerms) || containsAny(name, fruitTerms) {
            return 7
        }
        // Unrecognized ordinary ingredient: conservative default, never nil.
        return 7
    }

    private static func containsAny(_ name: String, _ terms: [String]) -> Bool {
        terms.contains { name.contains($0) }
    }

    private static let leafyVegetableTerms = [
        "韭菜花", "韭菜", "菠菜", "生菜", "香菜", "小葱", "葱", "油麦菜", "空心菜", "茼蒿"
    ]
    private static let freshVegetableTerms = [
        "番茄", "黄瓜", "青椒", "彩椒", "蘑菇", "西兰花", "茄子", "西葫芦", "胡萝卜"
    ]
    private static let meatTerms = [
        "猪肉", "牛肉", "羊肉", "鸡肉", "鸡胸肉", "鸡腿肉", "肉末", "排骨"
    ]
    private static let seafoodTerms = ["鱼", "鱼片", "三文鱼", "虾", "螃蟹", "贝类", "海鲜"]
    private static let dairyTerms = ["牛奶", "鲜奶", "奶油", "酸奶"]
    private static let eggTerms = ["鸡蛋", "鸭蛋", "鹌鹑蛋"]
    private static let tofuTerms = ["豆腐", "嫩豆腐", "老豆腐", "豆干", "豆皮"]
    private static let fruitTerms = ["苹果", "香蕉", "橙子", "草莓", "葡萄", "蓝莓", "梨", "桃", "猕猴桃"]
    private static let frozenTerms = ["冷冻鱼", "冷冻肉", "冷冻蔬菜", "速冻", "冰冻"]
    /// 面包/烘焙食品 — 5 天。
    private static let breadTerms = ["面包", "吐司", "蛋糕", "馒头", "包子", "烘焙"]
    /// 熟食和剩菜 — 3 天。
    private static let deliTerms = ["熟食", "剩菜", "卤味", "烧腊"]
    /// 火腿、香肠等冷藏加工肉 — 7 天。
    private static let curedMeatTerms = ["火腿", "香肠", "培根", "腊肉", "午餐肉"]
    /// 已开封酱料类调味品（酱/膏状）— 90 天。检查顺序在肉类/海鲜关键词之前，
    /// 避免"牛肉酱""虾酱"等被误判为鲜肉或海鲜。
    private static let openedSauceTerms = [
        "牛肉酱", "虾酱", "辣椒酱", "甜面酱", "豆瓣酱", "郫县豆瓣", "沙茶酱", "芝麻酱", "番茄酱",
        "味精", "鸡精", "火锅底料", "高汤宝"
    ]
    /// 未开封调味料/液态调味品 — 365 天。同样在肉类/海鲜关键词之前检查，
    /// 避免"鱼露""蚝油"被误判为鲜鱼或海鲜。
    private static let longLifeSeasoningTerms = [
        "盐", "糖", "生抽", "老抽", "酱油", "醋", "蚝油", "鱼露", "调味料", "罐头"
    ]
    /// 主食/干货/油类 — 180 天。
    private static let pantryStapleTerms = [
        "大米", "面粉", "意面", "干货", "食用油", "咖啡豆", "茶叶", "谷物", "面条", "米粉"
    ]
}

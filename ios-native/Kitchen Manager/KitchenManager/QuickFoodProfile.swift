import Foundation

// MARK: - Quick meal food profile (P0-3C)
//
// Three *independent* axes, deliberately not collapsed into one mutually
// exclusive enum. Real foods sit on several at once and the combinations are
// what Quick Meal assembly reasons about:
//
//   卤牛肉   → protein,           cooked        (eat as is)
//   腌鸡肉   → protein,           prepped       (still needs cooking)
//   米饭     → carb + rice,       cooked
//   大米     → carb + rice,       raw           (30+ minutes away from a meal)
//   冷冻饺子 → carb + protein,    dumpling, convenience
//
// A single `FoodRole` enum would have to pick one of those facts and throw the
// rest away, which is exactly what makes 大米 and 米饭 indistinguishable.
//
// Nothing here is persisted. Profiles are derived on demand from the inventory
// item's name, so `InventoryItem`, the SwiftData schema, sync and backup are
// all untouched.

/// What part of a meal an item can play. An item may play several.
enum MealComponentRole: String, CaseIterable {
    case carb
    case protein
    case vegetable
    case seasoning
}

/// The physical form, but only the distinctions first-version assembly actually
/// needs to tell apart. Not a food taxonomy — 牛肉 and 鸡蛋 share no form because
/// assembly never needs to distinguish them by shape.
enum QuickFoodForm: String, CaseIterable {
    case noodle
    case riceNoodle
    case rice
    case dumpling
    case wonton
    case bread
    case tuber
    /// 玉米. Its own form rather than a tuber: it carries both a staple and a
    /// vegetable role like a tuber does, but it is neither stored nor cooked
    /// like one, and Component Meal orders staples by form.
    case corn
    /// A finished dish rather than an ingredient: 剩菜, 熟食, 卤味, 盒饭.
    case preparedDish
}

/// How much work stands between this item and being edible.
enum PreparationState: String, CaseIterable {
    /// Needs full cooking from scratch.
    case raw
    /// Marinated / cut / part-processed, still needs cooking. 腌鸡肉, 半成品.
    case prepped
    /// Already cooked. Eat as is or just reheat. 卤牛肉, 米饭, 剩菜.
    case cooked
    /// Packaged cook-and-eat product: 饺子, 馄饨, 方便面. Not "ready to eat" —
    /// it still needs a pot of water, but it needs no preparation.
    case convenience
    /// Not determinable from the name.
    case unknown
}

/// One item's position on all three axes.
nonisolated struct QuickFoodProfile: Equatable {
    var roles: Set<MealComponentRole>
    var form: QuickFoodForm?
    var preparationState: PreparationState

    static let unknown = QuickFoodProfile(roles: [], form: nil, preparationState: .unknown)

    func has(_ role: MealComponentRole) -> Bool { roles.contains(role) }

    /// Nothing about this item could be determined; assembly must skip it rather
    /// than guess.
    var isUnclassified: Bool {
        roles.isEmpty && form == nil && preparationState == .unknown
    }

    /// Seasonings are tracked so they can be *excluded*: a shelf of 生抽 and 盐
    /// is not a meal.
    var isSeasoningOnly: Bool { roles == [.seasoning] }

    /// Ranks how close this item already is to being eaten. Used for ordering
    /// only — never converted into minutes, which the app has no data for.
    var readinessScore: Int {
        switch preparationState {
        case .cooked: return 3
        case .convenience: return 2
        case .prepped: return 1
        case .raw, .unknown: return 0
        }
    }
}

// MARK: - Classifier
//
// Keyword matching over the item name, in the same spirit as
// `InventoryExpirySuggestion` — which already ships this approach for shelf
// life. Two deliberate differences from that type: this one returns a
// classification rather than a number of days, and the ordering below is
// arranged for classification correctness rather than for expiry safety.
//
// Order matters throughout. Seasonings are checked before everything (番茄酱 is
// not 番茄), pickles before the generic 腌 marker (腌黄瓜 is ready to eat,
// 腌鸡肉 is not), and 米粉 before 大米 (a rice noodle is not rice).

nonisolated enum QuickFoodProfileClassifier {
    /// The single entry point. Callers with a structured preparation state pass
    /// it in and it wins; callers without one get the name inference unchanged.
    ///
    /// One function rather than a second "prepared" classifier on purpose: two
    /// entry points would drift, and the roles/form half of the answer is
    /// identical either way — only the preparation axis is ever known better
    /// from elsewhere.
    static func profile(
        for name: String,
        preparationState: PreparationState? = nil
    ) -> QuickFoodProfile {
        var profile = inferredProfile(for: name)
        if let preparationState {
            profile.preparationState = preparationState
        }
        return profile
    }

    /// Everything derived from the name alone. Byte-for-byte the behaviour that
    /// shipped in P0-3C, so an inventory item classifies exactly as before.
    private static func inferredProfile(for name: String) -> QuickFoodProfile {
        let name = IngredientNormalizer.normalizedName(name)
            .lowercased()
            .filter { !$0.isWhitespace }
        guard !name.isEmpty else { return .unknown }

        if contains(name, seasoningTerms) {
            // The preparation axis does not apply to a seasoning.
            return QuickFoodProfile(roles: [.seasoning], form: nil, preparationState: .unknown)
        }

        if contains(name, pickledVegetableTerms) {
            return QuickFoodProfile(roles: [.vegetable], form: nil, preparationState: .cooked)
        }

        if contains(name, halfPreparedDishTerms) {
            return QuickFoodProfile(roles: [], form: .preparedDish, preparationState: .prepped)
        }
        if contains(name, preparedDishTerms) {
            // Composition unknown on purpose: "剩菜" says nothing about whether
            // there is protein in it. Assembly keys off the form and state.
            return QuickFoodProfile(roles: [], form: .preparedDish, preparationState: .cooked)
        }

        let form = self.form(for: name)
        var roles = self.roles(for: name, form: form)
        if roles.isEmpty, form != nil { roles.insert(.carb) }

        let state = preparationState(for: name, form: form, roles: roles)
        guard !roles.isEmpty || form != nil else { return .unknown }
        return QuickFoodProfile(roles: roles, form: form, preparationState: state)
    }

    // MARK: Form

    private static func form(for name: String) -> QuickFoodForm? {
        if contains(name, dumplingTerms) { return .dumpling }
        if contains(name, wontonTerms) { return .wonton }
        if contains(name, breadTerms) { return .bread }
        // 面粉 is flour: a carb, but no assembly starts from it, so it gets no
        // form and can never satisfy a "主食" slot.
        if contains(name, flourTerms) { return nil }
        if contains(name, riceNoodleTerms) { return .riceNoodle }
        if contains(name, noodleTerms) { return .noodle }
        // Before the rice terms for the same reason those terms spell every
        // grain out instead of matching a bare 米: 玉米 is not rice.
        if contains(name, cornTerms) { return .corn }
        if contains(name, riceTerms) { return .rice }
        if contains(name, tuberTerms) { return .tuber }
        return nil
    }

    // MARK: Roles

    private static func roles(for name: String, form: QuickFoodForm?) -> Set<MealComponentRole> {
        var roles: Set<MealComponentRole> = []
        if contains(name, proteinTerms) { roles.insert(.protein) }
        if contains(name, vegetableTerms) { roles.insert(.vegetable) }

        switch form {
        case .noodle, .riceNoodle, .rice, .bread:
            roles.insert(.carb)
        case .dumpling, .wonton:
            // A dumpling is wrapper plus filling — both facts are true and both
            // matter, which is the whole reason roles is a Set.
            roles.insert(.carb)
            roles.insert(.protein)
        case .tuber:
            // 土豆 is genuinely both in home cooking; recording only one would
            // force a false choice.
            roles.insert(.carb)
            roles.insert(.vegetable)
        case .corn:
            // Same double role, and for the same reason: a cob can be the staple
            // of a plate or the vegetable on it. Which one it is on any given
            // plate is the assembling layer's decision, not the classifier's —
            // and no layer may let one cob be both at once.
            roles.insert(.carb)
            roles.insert(.vegetable)
        case .preparedDish, .none:
            break
        }
        if contains(name, flourTerms) { roles.insert(.carb) }
        return roles
    }

    // MARK: Preparation state

    private static func preparationState(
        for name: String,
        form: QuickFoodForm?,
        roles: Set<MealComponentRole>
    ) -> PreparationState {
        if contains(name, convenienceTerms) { return .convenience }
        if form == .dumpling || form == .wonton { return .convenience }
        if contains(name, cookedTerms) { return .cooked }
        if form == .rice, contains(name, cookedRiceTerms) { return .cooked }
        if form == .bread { return .cooked }
        if contains(name, preppedTerms) { return .prepped }
        return roles.isEmpty && form == nil ? .unknown : .raw
    }

    private static func contains(_ name: String, _ terms: [String]) -> Bool {
        terms.contains { name.contains($0) }
    }

    // MARK: Term tables

    private static let seasoningTerms = [
        "盐", "糖", "生抽", "老抽", "酱油", "醋", "料酒", "黄酒", "蚝油", "鱼露",
        "香油", "芝麻油", "食用油", "菜籽油", "花生油", "橄榄油", "植物油", "调和油", "猪油", "玉米油",
        "豆瓣酱", "郫县豆瓣", "甜面酱", "黄豆酱", "芝麻酱", "辣椒酱", "番茄酱", "沙茶酱",
        "牛肉酱", "虾酱", "火锅底料", "高汤", "味精", "鸡精",
        "胡椒", "花椒", "辣椒粉", "干辣椒", "八角", "桂皮", "香叶", "孜然", "五香粉", "十三香",
        "淀粉", "生粉", "豆粉", "调味料"
    ]

    /// Pickled/fermented vegetables are eaten as they are, so they must be caught
    /// before the generic 腌 prefix marks them as needing cooking.
    private static let pickledVegetableTerms = ["泡菜", "酸菜", "榨菜", "咸菜", "腌菜", "梅干菜"]

    private static let preparedDishTerms = ["剩菜", "剩饭菜", "熟食", "卤味", "烧腊", "盒饭", "便当", "预制菜"]
    private static let halfPreparedDishTerms = ["半成品"]

    private static let dumplingTerms = ["饺子", "水饺", "蒸饺", "锅贴"]
    private static let wontonTerms = ["馄饨", "云吞", "抄手"]
    private static let breadTerms = ["面包", "吐司", "馒头", "包子", "花卷", "烧饼", "大饼"]
    private static let flourTerms = ["面粉"]
    private static let riceNoodleTerms = ["米粉", "米线", "河粉", "粉丝", "粉条", "红薯粉", "螺蛳粉", "酸辣粉", "凉皮"]
    private static let noodleTerms = [
        "挂面", "面条", "拉面", "龙须面", "阳春面", "手擀面", "鸡蛋面", "意面", "意大利面",
        "乌冬", "荞麦面", "方便面", "泡面"
    ]
    /// Deliberately no bare "米": it would swallow 玉米. Every rice term is spelled out.
    private static let riceTerms = ["米饭", "大米", "糙米", "白米", "小米", "糯米", "饭"]
    private static let cookedRiceTerms = ["米饭", "白饭", "剩饭", "熟饭", "炒饭", "盖饭"]
    private static let tuberTerms = ["土豆", "红薯", "紫薯", "山药", "芋头"]
    /// Only the cob itself. 玉米淀粉 is caught by the seasoning table above and
    /// 玉米油 was added to it, so neither reaches here.
    private static let cornTerms = ["玉米"]

    private static let proteinTerms = [
        "猪肉", "牛肉", "羊肉", "鸡肉", "鸡胸", "鸡腿", "鸡翅", "鸭肉", "排骨", "肉末", "绞肉", "肉片", "肉丝",
        "培根", "火腿", "香肠", "腊肉", "午餐肉", "肉丸", "丸子",
        "鸡蛋", "鸭蛋", "鹌鹑蛋", "皮蛋", "咸蛋",
        "鱼", "虾", "蟹", "鱿鱼", "贝", "三文鱼", "海鲜",
        "豆腐", "豆干", "豆皮", "腐竹", "千张"
    ]

    private static let vegetableTerms = [
        "青菜", "上海青", "小白菜", "大白菜", "白菜", "菠菜", "生菜", "油麦菜", "空心菜", "茼蒿", "芥兰",
        "豌豆尖", "韭菜", "包菜", "卷心菜", "芹菜", "西兰花", "西蓝花", "花菜", "菜花",
        "黄瓜", "番茄", "西红柿", "青椒", "彩椒", "茄子", "西葫芦", "胡萝卜", "萝卜", "洋葱",
        "豆芽", "蘑菇", "香菇", "金针菇", "杏鲍菇", "口蘑", "木耳", "海带", "莴笋",
        "苦瓜", "冬瓜", "南瓜", "玉米", "豆角", "四季豆", "青豆", "毛豆"
    ]

    private static let cookedTerms = [
        "卤", "熟", "烧腊", "白切", "烤鸡", "烤鸭", "酱牛肉", "红烧", "回锅", "凉拌", "剩"
    ]
    private static let preppedTerms = ["腌", "调味", "半成品", "切好"]
    private static let convenienceTerms = ["速冻", "速食", "即食", "方便面", "泡面"]
}

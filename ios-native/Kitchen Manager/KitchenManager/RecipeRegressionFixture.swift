import Foundation

#if DEBUG
/// Deterministic UI regression data; never compiled into Release.
enum RecipeRegressionFixture {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_SEED_RECIPE_REGRESSION")
    }

    static let recipes = [
        Recipe(id: "regression-mapo", title: "麻婆豆腐", cookingTime: 25, difficulty: "简单",
               tags: ["川菜", "下饭菜"], ingredients: ["嫩豆腐 400 克", "猪肉末 100 克"],
               seasonings: ["豆瓣酱 1 汤匙", "花椒粉 少许", "蒜末 10 克", "生抽 1 茶匙", "水淀粉 2 汤匙"],
               steps: ["豆腐切成小块，放入淡盐水中焯 2 分钟后沥干。", "小火炒香肉末，加入豆瓣酱和蒜末，慢慢炒出红油。", "加入清水，轻轻推入豆腐。保持微沸 5 分钟，用锅铲背面推动，避免把豆腐搅碎。分两次淋入水淀粉，每次都等汤汁重新沸腾，让芡汁均匀包住豆腐。", "撒上花椒粉，趁热盛出。", "小贴士：豆瓣酱已有咸味，出锅前尝味再决定是否加盐。"], baseServings: 2),
        Recipe(id: "regression-beef", title: "茄汁土豆胡萝卜炖牛腩", cookingTime: 90, difficulty: "中等",
               tags: ["家常菜", "炖菜"],
               ingredients: ["牛腩 600 克", "土豆 2 个", "胡萝卜 1 根", "番茄 3 个", "洋葱 1 个", "鲜香菇 4 个", "西芹 2 根", "甜椒 1 个", "白萝卜 200 克", "玉米 1 根"],
               seasonings: ["姜片 15 克", "八角 2 个", "番茄酱 2 汤匙", "生抽 2 汤匙", "盐 适量"],
               steps: ["牛腩切块，冷水下锅煮出浮沫，捞出后用温水洗净。", "番茄切块，其余蔬菜切成大小接近的块。", "锅中炒香洋葱和姜片，加入番茄与番茄酱，用中小火慢慢炒至番茄出汁。放入牛腩翻匀，注入没过食材的热水，煮开后转小火，盖上锅盖炖 60 分钟。期间留意水量，必要时补充热水，避免糊底。", "加入土豆、胡萝卜、白萝卜和玉米，再炖 20 分钟。", "加入其余蔬菜，煮至软熟后尝味调盐。"], baseServings: 4),
        Recipe(id: "regression-prawn", title: "蒜蓉粉丝蒸大虾", cookingTime: 30, difficulty: "中等", tags: ["蒸菜"], ingredients: ["大虾 12 只", "粉丝 50 克"], seasonings: ["蒜末 30 克", "生抽 1 汤匙"], steps: ["粉丝泡软铺盘，大虾开背去虾线。", "铺上蒜蓉，水开后蒸 8 分钟。"], baseServings: 3),
        Recipe(id: "regression-eggs", title: "番茄炒鸡蛋", cookingTime: 15, difficulty: "简单", tags: ["快手菜"], ingredients: ["番茄 2 个", "鸡蛋 3 个"], steps: ["番茄切块，鸡蛋打散。", "分别炒熟后合炒调味。"], baseServings: 2),
        Recipe(id: "regression-soup", title: "冬瓜鲜菇汤", cookingTime: 20, difficulty: "简单", tags: ["汤羹"], ingredients: ["冬瓜 300 克", "鲜香菇 4 个"], steps: ["冬瓜去皮切片，鲜菇洗净。", "加水煮 15 分钟，调味出锅。"]),
        Recipe(id: "regression-fish", title: "清蒸鲈鱼", cookingTime: 20, difficulty: "较难", tags: ["蒸菜"], ingredients: ["鲈鱼 1 条"], steps: ["清理鲈鱼并擦干。", "水开后蒸至熟透，再淋上调味汁。"], baseServings: 2)
    ]
}
#endif

import Foundation
import Combine

struct Recipe: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let cookingTime: Int?
    let difficulty: String?
    let tags: [String]
    let ingredients: [String]
    let seasonings: [String]
    let steps: [String]
    var source: RecipeSourceMetadata? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, cookingTime, difficulty, tags, ingredients, seasonings, steps, source
    }

    init(
        id: String,
        title: String,
        cookingTime: Int?,
        difficulty: String?,
        tags: [String],
        ingredients: [String],
        seasonings: [String] = [],
        steps: [String],
        source: RecipeSourceMetadata? = nil
    ) {
        self.id = id
        self.title = title
        self.cookingTime = cookingTime
        self.difficulty = difficulty
        self.tags = tags
        let classified = RecipeIngredientClassifier.classify(ingredients, recipeTitle: title)
        self.ingredients = seasonings.isEmpty ? classified.ingredients : RecipeIngredientClassifier.unique(ingredients)
        self.seasonings = RecipeIngredientClassifier.unique(seasonings.isEmpty ? classified.seasonings : seasonings)
        self.steps = steps.map(EditableRecipeDraft.cleanStep).filter { !$0.isEmpty }
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        cookingTime = try container.decodeIfPresent(Int.self, forKey: .cookingTime)
        difficulty = try container.decodeIfPresent(String.self, forKey: .difficulty)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        let legacyIngredients = try container.decodeIfPresent([String].self, forKey: .ingredients) ?? []
        let explicitSeasonings = try container.decodeIfPresent([String].self, forKey: .seasonings)
        let classified = RecipeIngredientClassifier.classify(legacyIngredients, recipeTitle: title)
        // A stored seasonings array is an explicit user/AI/import decision. Preserve it
        // verbatim instead of reclassifying its companion ingredients on every launch.
        ingredients = explicitSeasonings == nil ? classified.ingredients : RecipeIngredientClassifier.unique(legacyIngredients)
        seasonings = RecipeIngredientClassifier.unique(explicitSeasonings ?? classified.seasonings)
        steps = (try container.decodeIfPresent([String].self, forKey: .steps) ?? [])
            .map(EditableRecipeDraft.cleanStep).filter { !$0.isEmpty }
        source = try container.decodeIfPresent(RecipeSourceMetadata.self, forKey: .source)
    }

    var summaryText: String {
        var values: [String] = []

        if let cookingTime {
            values.append("\(cookingTime) 分钟")
        }

        if let difficulty, !difficulty.isEmpty {
            values.append(difficulty)
        }

        if values.isEmpty {
            if !ingredients.isEmpty {
                values.append("\(ingredients.count) 种食材")
            }

            if !steps.isEmpty {
                values.append("\(steps.count) 个步骤")
            }
        }

        return values.isEmpty
            ? "暂无详细信息"
            : values.joined(separator: " · ")
    }

    static let samples: [Recipe] = [
        Recipe(
            id: "sample-mapotofu",
            title: "麻婆豆腐",
            cookingTime: 25,
            difficulty: "简单",
            tags: ["川菜", "下饭菜"],
            ingredients: [
                "嫩豆腐 1 块",
                "猪肉末 100 克",
                "豆瓣酱 1 汤匙"
            ],
            steps: [
                "豆腐切块并焯水。",
                "炒熟肉末。",
                "加入豆瓣酱炒出红油。",
                "加入豆腐烧至入味。"
            ]
        ),
        Recipe(
            id: "sample-tomato-eggs",
            title: "番茄炒鸡蛋",
            cookingTime: 15,
            difficulty: "简单",
            tags: ["家常菜", "快手菜"],
            ingredients: [
                "番茄 2 个",
                "鸡蛋 3 个",
                "盐 适量"
            ],
            steps: [
                "番茄切块，鸡蛋打散。",
                "炒熟鸡蛋并盛出。",
                "炒软番茄后倒回鸡蛋。",
                "调味后出锅。"
            ]
        )
    ]
}

enum RecipeIngredientClassifier {
    private static let directSeasoningNames: Set<String> = [
        "盐", "糖", "白糖", "冰糖", "味精", "鸡精", "胡椒粉", "白胡椒", "白胡椒粉", "黑胡椒", "黑胡椒粉",
        "生抽", "老抽", "酱油", "醋", "米醋", "陈醋", "香醋", "料酒", "黄酒", "蚝油", "鱼露", "香油", "芝麻油",
        "豆瓣酱", "郫县豆瓣", "甜面酱", "黄豆酱", "芝麻酱", "辣椒酱", "番茄酱", "沙茶酱",
        "豆粉", "淀粉", "生粉", "红薯淀粉", "玉米淀粉", "木薯粉", "水淀粉", "淀粉水", "炸粉", "腌肉粉",
        "食用油", "菜籽油", "菜油", "花生油", "猪油", "黄油", "橄榄油", "植物油", "调和油",
        "花椒", "花椒粉", "辣椒粉", "干辣椒", "八角", "桂皮", "香叶", "孜然", "五香粉", "十三香",
        "清水", "水", "高汤", "骨汤", "鸡汤", "泡椒水"
    ]
    private static let aromaticNames: Set<String> = ["葱", "葱花", "姜", "姜末", "姜片", "蒜", "蒜末", "蒜片", "香菜"]
    private static let quantityHintPattern = #"(?:少许|适量|[一二两半]?[勺匙]|汤匙|茶匙|克|毫升|杯|用于(?:腌制|勾芡|炸制|调味)|腌制|勾芡|炝锅|调味)"#

    static func classify(
        _ lines: [String],
        recipeTitle: String = ""
    ) -> (ingredients: [String], seasonings: [String]) {
        var ingredients: [String] = []
        var seasonings: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("调料：") || line.hasPrefix("辅料：") {
                seasonings.append(String(line.dropFirst("调料：".count)))
            } else if shouldBeSeasoning(line, recipeTitle: recipeTitle) {
                seasonings.append(line)
            } else {
                ingredients.append(line)
            }
        }
        return (unique(ingredients), unique(seasonings))
    }

    private static func shouldBeSeasoning(_ line: String, recipeTitle: String) -> Bool {
        let name = ingredientName(from: line)
        guard !name.isEmpty else { return false }
        if directSeasoningNames.contains(name) { return true }
        if name.contains("淀粉") || name.contains("豆粉") || name == "生粉" || name.contains("腌肉粉") || name.contains("炸粉") {
            // 豌豆粉制作凉粉、面粉制作面食时可能是主体，保留给用户确认。
            if (name.contains("豌豆粉") && recipeTitle.contains("凉粉")) || (name.contains("面粉") && isFlourBasedDish(recipeTitle)) {
                return false
            }
            return true
        }
        if name == "面粉" {
            return line.range(of: quantityHintPattern, options: .regularExpression) != nil && !isFlourBasedDish(recipeTitle)
        }
        if aromaticNames.contains(name) {
            // 葱烧海参、姜爆鸭等菜名明确把该香料作为核心时不擅自移动。
            return !recipeTitle.contains(name)
                && (name.count > 1 || line.range(of: quantityHintPattern, options: .regularExpression) != nil)
        }
        return false
    }

    private static func ingredientName(from line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s*(?:\d+(?:\.\d+)?|[一二两半]+)?\s*(?:个|根|把|棵|块|袋|盒|片|只|条|份|勺|匙|汤匙|茶匙|克|毫升|杯|适量|少许).*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isFlourBasedDish(_ title: String) -> Bool {
        ["面", "饼", "馒头", "包子", "饺子", "凉粉"].contains { title.contains($0) }
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

struct RecipeSourceMetadata: Hashable, Codable {
    let platform: String
    let originalURL: String
    let canonicalURL: String
    let importedAt: Date
    let title: String?
    let author: String?
}

@MainActor
final class RecipeStore: ObservableObject {
    @Published private(set) var remoteRecipes: [Recipe] = []
    @Published private(set) var userRecipes: [Recipe] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var favoriteRecipeIDs: Set<String> = []
    @Published private(set) var frequentRecipeIDs: Set<String> = []

    private let service = RecipeService()
    private let userRecipePersistence: UserRecipePersistenceProtocol
    private let recipePreferencePersistence: RecipePreferencePersistenceProtocol
    /// Existing `RecipeStore()` call sites use the application store. Tests that
    /// inject an isolated defaults suite receive an isolated in-memory container.
    private let userDefaults: UserDefaults
    var libraryMode: RecipeLibraryMode {
        get { RecipeLibraryMode(rawValue: userDefaults.string(forKey: "recipeLibraryMode") ?? "") ?? .curated }
        set { userDefaults.set(newValue.rawValue, forKey: "recipeLibraryMode") }
    }

    var recipes: [Recipe] {
        let userIDs = Set(userRecipes.map(\.id))
        return userRecipes + remoteRecipes.filter { !userIDs.contains($0.id) }
    }

    init(
        userDefaults: UserDefaults = .standard,
        userRecipePersistence: UserRecipePersistenceProtocol? = nil,
        recipePreferencePersistence: RecipePreferencePersistenceProtocol? = nil
    ) {
        self.userDefaults = userDefaults
        if let userRecipePersistence, let recipePreferencePersistence {
            self.userRecipePersistence = userRecipePersistence
            self.recipePreferencePersistence = recipePreferencePersistence
        } else {
            let persistence = userDefaults === UserDefaults.standard
                ? KitchenPersistenceFactory.application()
                : KitchenPersistenceFactory.isolatedInMemory()
            self.userRecipePersistence = persistence.userRecipes
            self.recipePreferencePersistence = persistence.recipePreferences
        }
        do {
            let state = try RecipeStoreMigration.migrateIfNeeded(
                userDefaults: userDefaults,
                recipes: self.userRecipePersistence,
                preferences: self.recipePreferencePersistence
            )
            userRecipes = state.userRecipes
            favoriteRecipeIDs = state.favoriteRecipeIDs
            frequentRecipeIDs = state.frequentRecipeIDs
        } catch {
            errorMessage = "本地菜谱暂时无法读取，旧数据仍保留在设备上。"
            #if DEBUG
            print("[RecipePersistence] migration/load failed: \(error)")
            #endif
        }
    }

    func toggleFavorite(_ id: String) {
        var updated = favoriteRecipeIDs
        if !updated.insert(id).inserted { updated.remove(id) }
        persistPreferences(favorites: updated, frequent: frequentRecipeIDs)
    }

    func toggleFrequent(_ id: String) {
        var updated = frequentRecipeIDs
        if !updated.insert(id).inserted { updated.remove(id) }
        persistPreferences(favorites: favoriteRecipeIDs, frequent: updated)
    }

    func loadRecipes() async {
        guard !isLoading else {
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            remoteRecipes = try await service.fetchRecipes(mode: libraryMode)
        } catch is CancellationError {
            return
        } catch {
            if libraryMode == .full,
               let fallback = try? await service.fetchRecipes(mode: .curated) {
                remoteRecipes = fallback
                errorMessage = "完整菜谱库暂时无法加载，已回退到精简日常菜谱库。"
                return
            }
            if remoteRecipes.isEmpty {
                remoteRecipes = Recipe.samples
            }

            errorMessage = """
            暂时无法加载线上菜谱，当前显示示例数据。
            \(error.localizedDescription)
            """
        }
    }

    func add(_ recipe: Recipe) {
        try? saveUserRecipe(recipe)
    }

    func reload(mode: RecipeLibraryMode) async {
        libraryMode = mode
        remoteRecipes = []
        await loadRecipes()
    }

    func replaceUserRecipe(_ recipe: Recipe) throws {
        var updated = userRecipes
        if let index = updated.firstIndex(where: { $0.id == recipe.id }) {
            updated[index] = recipe
        } else {
            updated.insert(recipe, at: 0)
        }
        do { try userRecipePersistence.replaceRecipes(with: updated); userRecipes = updated }
        catch { throw UserRecipeSaveError.persistenceFailed }
    }

    func deleteUserRecipe(id: String) throws {
        let updated = userRecipes.filter { $0.id != id }
        do { try userRecipePersistence.replaceRecipes(with: updated); userRecipes = updated }
        catch { throw UserRecipeSaveError.persistenceFailed }
    }

    func clearLocalData() {
        let previousRecipes = userRecipes
        let previousFavorites = favoriteRecipeIDs
        let previousFrequent = frequentRecipeIDs
        do {
            try userRecipePersistence.deleteAll()
            try recipePreferencePersistence.deleteAll()
        } catch {
            try? userRecipePersistence.replaceRecipes(with: previousRecipes)
            try? recipePreferencePersistence.replacePreferences(with: previousFavorites.union(previousFrequent).map {
                RecipePreference(
                    recipeID: $0,
                    isFavorite: previousFavorites.contains($0),
                    isFrequent: previousFrequent.contains($0)
                )
            })
            errorMessage = "本地菜谱暂时无法清除，请稍后重试。"
            return
        }
        userDefaults.removeObject(forKey: RecipeStoreMigration.legacyRecipesKey)
        userDefaults.removeObject(forKey: RecipeStoreMigration.legacyFavoritesKey)
        userDefaults.removeObject(forKey: RecipeStoreMigration.legacyFrequentKey)
        userRecipes = []
        favoriteRecipeIDs = []
        frequentRecipeIDs = []
    }

    func saveUserRecipe(_ recipe: Recipe) throws {
        guard !userRecipes.contains(where: { $0.id == recipe.id }) else {
            throw UserRecipeSaveError.alreadySaved
        }

        if let source = recipe.source,
           userRecipes.contains(where: { Self.sourcesMatch($0.source, source) }) {
            throw UserRecipeSaveError.sourceAlreadyImported
        }

        let fingerprint = Self.fingerprint(for: recipe)
        guard !userRecipes.contains(where: { Self.fingerprint(for: $0) == fingerprint }) else {
            throw UserRecipeSaveError.alreadySaved
        }

        let updatedRecipes = [recipe] + userRecipes

        do {
            try userRecipePersistence.replaceRecipes(with: updatedRecipes)
            userRecipes = updatedRecipes
        } catch {
            throw UserRecipeSaveError.persistenceFailed
        }
    }

    func containsImportedSource(_ url: String) -> Bool {
        let normalized = Self.normalizedSourceURL(url)
        guard !normalized.isEmpty else { return false }
        return userRecipes.contains { recipe in
            guard let source = recipe.source else { return false }
            return [source.originalURL, source.canonicalURL]
                .map(Self.normalizedSourceURL)
                .contains(normalized)
        }
    }

    static func fingerprint(for recipe: Recipe) -> String {
        ([recipe.title] + recipe.ingredients + recipe.seasonings + recipe.steps)
            .joined(separator: "|")
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private static func sourcesMatch(
        _ lhs: RecipeSourceMetadata?,
        _ rhs: RecipeSourceMetadata
    ) -> Bool {
        guard let lhs else { return false }
        let left = Set([lhs.originalURL, lhs.canonicalURL].map(normalizedSourceURL).filter { !$0.isEmpty })
        let right = Set([rhs.originalURL, rhs.canonicalURL].map(normalizedSourceURL).filter { !$0.isEmpty })
        return !left.isDisjoint(with: right)
    }

    nonisolated static func normalizedSourceURL(_ value: String) -> String {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ""
        }
        components.fragment = nil
        components.host = components.host?.lowercased()
        let filteredQueryItems = components.queryItems?.filter { item in
            let key = item.name.lowercased()
            return !key.hasPrefix("utm_")
                && !key.hasPrefix("xsec_")
                && !["sharefrom", "share_from", "appuid", "xhsshare"].contains(key)
        }
        // Assigning an empty array (as opposed to nil) makes URLComponents
        // render a stray trailing "?" with no query — e.g. a URL whose only
        // parameter was "utm_source" would then never equal the same URL
        // with no query string at all, breaking the exact dedup case this
        // is meant to handle.
        components.queryItems = (filteredQueryItems?.isEmpty ?? true) ? nil : filteredQueryItems
        return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
    }

    private func persistPreferences(favorites: Set<String>, frequent: Set<String>) {
        let preferences = favorites.union(frequent).map {
            RecipePreference(recipeID: $0, isFavorite: favorites.contains($0), isFrequent: frequent.contains($0))
        }
        do {
            try recipePreferencePersistence.replacePreferences(with: preferences)
            favoriteRecipeIDs = favorites
            frequentRecipeIDs = frequent
        } catch {
            errorMessage = "菜谱偏好暂时无法保存，请稍后重试。"
            #if DEBUG
            print("[RecipePersistence] preference save failed: \(error)")
            #endif
        }
    }
}

enum UserRecipeSaveError: LocalizedError {
    case alreadySaved
    case sourceAlreadyImported
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .alreadySaved:
            return "这份菜谱已经保存过了。"
        case .sourceAlreadyImported:
            return "这个来源链接已经导入过了。"
        case .persistenceFailed:
            return "无法将菜谱保存到设备，请稍后重试。"
        }
    }
}

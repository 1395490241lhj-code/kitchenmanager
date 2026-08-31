import Foundation
import Combine

enum RecommendationSource: String, Codable {
    case local
    case ai
}

struct RecipeRecommendation: Identifiable, Hashable {
    let recipe: Recipe
    let reason: String?
    let source: RecommendationSource

    var id: String { recipe.id }
}

private struct AIRecommendationEnvelope: Decodable {
    let recommendations: [AIRecommendedRecipeDTO]
}

private struct AIRecommendedRecipeDTO: Decodable {
    let name: String
    let ingredients: [String]
    let seasonings: [String]?
    let steps: [String]
    let tags: [String]?
    let difficulty: String?
    let cookingTime: Int?
    let reason: String?
}

protocol AIRecommendationProviding {
    func generateRecommendations(
        query: String,
        inventory: [String],
        expiringIngredients: [String],
        preferences: [String],
        excludedRecipeNames: [String],
        count: Int
    ) async throws -> [RecipeRecommendation]

    /// Whatever actually served the most recent request. Lets the store tell an
    /// explicit Apple choice apart from an offline reroute without re-deciding.
    var lastExecutionProvider: RecommendationExecutionProvider? { get }
}

extension AIRecommendationProviding {
    var lastExecutionProvider: RecommendationExecutionProvider? { nil }
}

struct AIRecommendationService: AIRecommendationProviding {
    private let chatService: AIChatService
    private let userDefaults: UserDefaults
    private let appleGenerator: any AppleRecipeCandidateGenerating
    private let network: any NetworkAvailabilityProviding
    private let appleEligibility: (AppleEligibilityRequest) -> AppleEligibility
    private let executionRecorder = ExecutionRecorder()

    init(
        chatService: AIChatService = AIChatService(),
        userDefaults: UserDefaults = .standard,
        appleGenerator: any AppleRecipeCandidateGenerating = AppleFoundationModelCandidateGenerator(),
        network: any NetworkAvailabilityProviding = PathMonitorNetworkAvailabilityProvider.shared,
        appleEligibility: @escaping (AppleEligibilityRequest) -> AppleEligibility = {
            AppleRecommendationPolicy.evaluate($0)
        }
    ) {
        self.chatService = chatService
        self.userDefaults = userDefaults
        self.appleGenerator = appleGenerator
        self.network = network
        self.appleEligibility = appleEligibility
    }

    var lastExecutionProvider: RecommendationExecutionProvider? {
        executionRecorder.value
    }

    /// Reference box so the executed provider survives the `struct`'s value
    /// semantics without turning the whole service into a class.
    private final class ExecutionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: RecommendationExecutionProvider?

        var value: RecommendationExecutionProvider? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func record(_ provider: RecommendationExecutionProvider?) {
            lock.lock()
            stored = provider
            lock.unlock()
        }
    }

    func generateRecommendations(
        query: String,
        inventory: [String],
        expiringIngredients: [String],
        preferences: [String],
        excludedRecipeNames: [String],
        count: Int
    ) async throws -> [RecipeRecommendation] {
        let requestedCount = min(max(count, 1), 8)
        executionRecorder.record(nil)
        let provider = AIRecommendationProvider.selected(in: userDefaults)
        let eligibilityRequest = AppleEligibilityRequest(query: query, preferences: preferences)

        // Routing decision. Only an explicitly unavailable network path may
        // reroute a cloud choice; a cloud *failure* never does.
        let route: RecommendationExecutionProvider
        if provider == .apple {
            route = .appleExplicit
        } else if network.currentAvailability.isExplicitlyOffline {
            switch appleEligibility(eligibilityRequest) {
            case .eligible:
                route = .appleOfflineFallback
            case .ineligible(let error):
                // Offline and the device model cannot serve this request:
                // fail fast instead of firing a doomed cloud request.
                throw AppleRecommendationError.offlineWithoutUsableLocalModel(error.localizedDescription)
            }
        } else {
            route = provider == .groq ? .groq : .gemini
        }

        if route == .appleExplicit || route == .appleOfflineFallback {
            let started = Date()
            let candidates = try await appleGenerator.generateCandidates(
                query: query,
                inventory: inventory,
                expiringIngredients: expiringIngredients,
                preferences: preferences,
                excludedRecipeNames: excludedRecipeNames,
                count: requestedCount
            )
            let recommendations = AppleRecommendationBuilder.makeRecommendations(
                candidates: candidates,
                inventory: inventory,
                expiringIngredients: expiringIngredients,
                excludedRecipeNames: excludedRecipeNames,
                count: requestedCount
            )
            executionRecorder.record(route)
            #if DEBUG
            print("[AIRecommendationProvider] provider=\(route.rawValue) latencyMs=\(Int(Date().timeIntervalSince(started) * 1_000)) count=\(recommendations.count)")
            #endif
            return recommendations
        }

        let prompt = """
        你是 Kitchen Manager 的家庭菜谱推荐助手。请推荐 \(requestedCount) 道真实、合理、适合家庭烹饪的菜。

        用户当前输入：\(query.isEmpty ? "没有指定" : query)
        当前库存食材：\(inventory.isEmpty ? "暂无" : inventory.joined(separator: "、"))
        临期食材：\(expiringIngredients.isEmpty ? "暂无" : expiringIngredients.joined(separator: "、"))
        用户偏好：\(preferences.isEmpty ? "暂无" : preferences.joined(separator: "、"))
        本批需要避开的菜名：\(excludedRecipeNames.isEmpty ? "暂无" : excludedRecipeNames.joined(separator: "、"))

        要求：
        - 优先使用库存食材和临期食材。
        - 不要重复“需要避开的菜名”，也不要返回高度相似的菜。
        - 每道菜给出核心食材、调料与辅料、清晰步骤、标签、难度、预计分钟数和一句简短推荐理由。豆粉、淀粉、生粉、水淀粉、盐、油、生抽、料酒和清水必须放在 seasonings，不要混进 ingredients。
        - 只返回 JSON，不要 markdown，不要解释。

        JSON 格式：
        {
          "recommendations": [
            {
              "name": "菜名",
              "ingredients": ["食材 1", "食材 2"],
              "seasonings": ["生抽 1 勺", "淀粉 少许"],
              "steps": ["步骤 1", "步骤 2"],
              "tags": ["家常菜"],
              "difficulty": "简单",
              "cookingTime": 30,
              "reason": "推荐理由"
            }
          ]
        }
        """

        let started = Date()
        let cleaned = try await chatService.request(
            prompt: prompt,
            taskType: "recommendation",
            provider: provider.rawValue
        )
        executionRecorder.record(route)
        #if DEBUG
        print("[AIRecommendationProvider] provider=\(provider.rawValue) latencyMs=\(Int(Date().timeIntervalSince(started) * 1_000))")
        #endif
        guard let contentData = cleaned.data(using: .utf8) else {
            throw AIRecommendationServiceError.invalidResponse
        }

        let decoder = JSONDecoder()
        let dtos: [AIRecommendedRecipeDTO]
        if let envelope = try? decoder.decode(AIRecommendationEnvelope.self, from: contentData) {
            dtos = envelope.recommendations
        } else if let direct = try? decoder.decode([AIRecommendedRecipeDTO].self, from: contentData) {
            dtos = direct
        } else {
            throw AIRecommendationServiceError.invalidResponse
        }

        let excluded = Set(excludedRecipeNames.map(Self.normalizedName))
        var usedNames = Set<String>()
        return dtos.compactMap { dto in
            let name = dto.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = Self.normalizedName(name)
            guard !name.isEmpty,
                  !excluded.contains(normalized),
                  usedNames.insert(normalized).inserted else {
                return nil
            }

            let recipe = Recipe(
                id: "ai-\(normalized)",
                title: name,
                cookingTime: dto.cookingTime,
                difficulty: dto.difficulty,
                tags: dto.tags ?? [],
                ingredients: dto.ingredients,
                seasonings: dto.seasonings ?? [],
                steps: dto.steps.isEmpty ? ["暂未提供详细步骤。"] : dto.steps
            )
            return RecipeRecommendation(
                recipe: recipe,
                reason: dto.reason,
                source: .ai
            )
        }
        .prefix(requestedCount)
        .map { $0 }
    }

    private static func normalizedName(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}

private enum AIRecommendationServiceError: Error {
    case invalidResponse
}

@MainActor
final class HomeRecommendationStore: ObservableObject {
    @Published var searchQuery = ""
    @Published private(set) var recommendedRecipes: [RecipeRecommendation] = []
    @Published var currentRecommendationIndex = 0
    @Published private(set) var isSearchingRecommendations = false
    @Published private(set) var isGeneratingRecommendations = false
    @Published private(set) var recommendationError: String?
    /// Lightweight, non-blocking notice for the automatic offline reroute.
    /// Cleared on every new request so it never outlives the result it describes.
    @Published private(set) var recommendationNotice: String?
    @Published private(set) var lastExecutionProvider: RecommendationExecutionProvider?

    private let aiService: any AIRecommendationProviding
    private var requestTask: Task<[RecipeRecommendation], Error>?
    private var activeRequestID: UUID?
    private var lastCompletedSearchQuery = ""
    private var recommendationSessionDay: Date?
    private var hasLoadedRecommendationsForSession = false
    private let currentDate: () -> Date

    init(currentDate: @escaping () -> Date = { Date() }) {
        self.aiService = AIRecommendationService()
        self.currentDate = currentDate
    }

    init(
        aiService: any AIRecommendationProviding,
        currentDate: @escaping () -> Date = { Date() }
    ) {
        self.aiService = aiService
        self.currentDate = currentDate
    }

    var currentRecommendation: RecipeRecommendation? {
        guard recommendedRecipes.indices.contains(currentRecommendationIndex) else {
            return nil
        }
        return recommendedRecipes[currentRecommendationIndex]
    }

    /// Reads whatever actually served the request and turns an offline reroute
    /// into the user-facing notice. The persisted provider setting is never
    /// touched here — only this transient per-request state.
    private func recordExecutionOutcome() {
        let executed = aiService.lastExecutionProvider
        lastExecutionProvider = executed
        recommendationNotice = executed == .appleOfflineFallback
            ? "离线，使用设备端 Apple Intelligence"
            : nil
    }

    func loadDefaultRecommendations(
        recipes: [Recipe],
        inventory: [String],
        expiringIngredients: [String]
    ) {
        refreshRecommendationSessionIfNeeded()
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isSearchingRecommendations,
              !isGeneratingRecommendations,
              !hasLoadedRecommendationsForSession else {
            return
        }
        apply(
            localRecommendations(
                recipes: recipes,
                inventory: inventory,
                expiringIngredients: expiringIngredients,
                limit: 8
            )
        )
        recommendationError = nil
        recommendationNotice = nil
        hasLoadedRecommendationsForSession = true
    }

    func searchRecommendations(
        recipes: [Recipe],
        inventory: [String],
        expiringIngredients: [String]
    ) async {
        refreshRecommendationSessionIfNeeded()
        let query = Self.normalizedQuery(searchQuery)
        searchQuery = query
        recommendationError = nil
        recommendationNotice = nil

        guard !query.isEmpty else {
            lastCompletedSearchQuery = ""
            loadDefaultRecommendations(
                recipes: recipes,
                inventory: inventory,
                expiringIngredients: expiringIngredients
            )
            return
        }
        guard query != lastCompletedSearchQuery || recommendedRecipes.isEmpty else { return }

        cancelCurrentRequest()
        let requestID = UUID()
        activeRequestID = requestID
        isSearchingRecommendations = true
        let previous = recommendedRecipes
        let local = searchLocalRecipes(query: query, recipes: recipes, limit: 8)

        if local.count >= 3 {
            guard activeRequestID == requestID else { return }
            apply(local)
            lastCompletedSearchQuery = query
            hasLoadedRecommendationsForSession = true
            finishSearch(requestID)
            return
        }

        let aiCount = max(5 - local.count, 3)
        let task = Task {
            try await aiService.generateRecommendations(
                query: query,
                inventory: inventory,
                expiringIngredients: expiringIngredients,
                preferences: preferenceKeywords(in: query),
                excludedRecipeNames: local.map { $0.recipe.title },
                count: aiCount
            )
        }
        requestTask = task

        do {
            let ai = try await task.value
            guard activeRequestID == requestID, !Task.isCancelled else { return }
            let merged = deduplicated(local + ai, limit: 8)
            apply(merged)
            recordExecutionOutcome()
            lastCompletedSearchQuery = query
            hasLoadedRecommendationsForSession = true
        } catch is CancellationError {
            return
        } catch {
            guard activeRequestID == requestID else { return }
            if !local.isEmpty {
                apply(local)
                lastCompletedSearchQuery = query
            } else {
                recommendedRecipes = previous
                repairIndex()
            }
            recommendationError = recommendationErrorMessage(for: error)
        }
        finishSearch(requestID)
    }

    func generateNewRecommendations(
        inventory: [String],
        expiringIngredients: [String]
    ) async {
        refreshRecommendationSessionIfNeeded()
        guard !isGeneratingRecommendations else { return }
        cancelCurrentRequest()
        let requestID = UUID()
        activeRequestID = requestID
        isGeneratingRecommendations = true
        recommendationError = nil
        recommendationNotice = nil
        let previous = recommendedRecipes
        let excluded = previous.map { $0.recipe.title }
        let query = Self.normalizedQuery(searchQuery)

        let task = Task {
            try await aiService.generateRecommendations(
                query: query,
                inventory: inventory,
                expiringIngredients: expiringIngredients,
                preferences: preferenceKeywords(in: query),
                excludedRecipeNames: excluded,
                count: 5
            )
        }
        requestTask = task

        do {
            let ai = try await task.value
            guard activeRequestID == requestID, !Task.isCancelled else { return }
            if ai.isEmpty {
                recommendedRecipes = previous
                recommendationError = "AI 推荐暂时不可用，仍可以继续浏览本地推荐。"
            } else {
                apply(ai)
                recordExecutionOutcome()
                hasLoadedRecommendationsForSession = true
            }
        } catch is CancellationError {
            return
        } catch {
            guard activeRequestID == requestID else { return }
            recommendedRecipes = previous
            repairIndex()
            recommendationError = recommendationErrorMessage(for: error)
        }
        finishGeneration(requestID)
    }

    func clearSearch(
        recipes: [Recipe],
        inventory: [String],
        expiringIngredients: [String]
    ) {
        refreshRecommendationSessionIfNeeded()
        cancelCurrentRequest()
        searchQuery = ""
        lastCompletedSearchQuery = ""
        recommendationError = nil
        recommendationNotice = nil
        apply(
            localRecommendations(
                recipes: recipes,
                inventory: inventory,
                expiringIngredients: expiringIngredients,
                limit: 8
            )
        )
        hasLoadedRecommendationsForSession = true
    }

    func removeRecommendation(id: String) {
        recommendedRecipes.removeAll { $0.id == id }
        repairIndex()
    }

    func cancelRequests() {
        cancelCurrentRequest()
        isSearchingRecommendations = false
        isGeneratingRecommendations = false
    }

#if DEBUG
    func applyHomeUITestStateIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("UITEST_HOME_RECOMMENDATION_LOADING") {
            recommendedRecipes = []
            isGeneratingRecommendations = true
        } else if arguments.contains("UITEST_HOME_RECOMMENDATION_EMPTY") {
            recommendedRecipes = []
        } else if arguments.contains("UITEST_HOME_RECOMMENDATION_ERROR") {
            recommendationError = "AI 推荐暂时不可用，仍可以继续浏览本地推荐。"
        }
        repairIndex()
    }
#endif

    private func localRecommendations(
        recipes: [Recipe],
        inventory: [String],
        expiringIngredients: [String],
        limit: Int
    ) -> [RecipeRecommendation] {
        let inventoryTerms = inventory.map(Self.normalizedText)
        let expiringTerms = expiringIngredients.map(Self.normalizedText)
        let scored = recipes.enumerated().map { index, recipe -> (Recipe, Int, Int) in
            let ingredients = recipe.ingredients.map(Self.normalizedText)
            let inventoryMatches = inventoryTerms.filter { term in
                ingredients.contains { $0.contains(term) || term.contains($0) }
            }.count
            let expiringMatches = expiringTerms.filter { term in
                ingredients.contains { $0.contains(term) || term.contains($0) }
            }.count
            return (recipe, inventoryMatches * 20 + expiringMatches * 35, index)
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.2 < rhs.2 }
                return lhs.1 > rhs.1
            }
            .prefix(limit)
            .map { row in
                RecipeRecommendation(
                    recipe: row.0,
                    reason: row.1 > 0 ? "优先匹配现有库存食材。" : nil,
                    source: .local
                )
            }
    }

    private func searchLocalRecipes(
        query: String,
        recipes: [Recipe],
        limit: Int
    ) -> [RecipeRecommendation] {
        let terms = searchTerms(query: query, recipes: recipes)
        let cookingUnder30 = query.contains("30分钟以内")
            || query.contains("30 分钟以内")
            || query.contains("半小时以内")

        let scored = recipes.enumerated().compactMap { index, recipe -> (Recipe, Int, Int)? in
            let title = Self.normalizedText(recipe.title)
            let tags = recipe.tags.map(Self.normalizedText)
            let ingredients = recipe.ingredients.map(Self.normalizedText)
            let difficulty = Self.normalizedText(recipe.difficulty ?? "")
            var score = 0

            if title == Self.normalizedText(query) { score += 140 }
            if title.contains(Self.normalizedText(query)) { score += 65 }

            for term in terms {
                if title == term { score += 70 }
                else if title.contains(term) || term.contains(title) { score += 45 }
                if tags.contains(where: { $0 == term }) { score += 32 }
                else if tags.contains(where: { $0.contains(term) || term.contains($0) }) { score += 24 }
                if ingredients.contains(where: { $0.contains(term) || term.contains($0) }) { score += 18 }
                if !difficulty.isEmpty && (difficulty.contains(term) || term.contains(difficulty)) { score += 12 }
            }

            if cookingUnder30, let time = recipe.cookingTime, time <= 30 { score += 24 }
            if query.contains("简单"), recipe.difficulty == "简单" || recipe.tags.contains(where: { $0.contains("快手") }) {
                score += 20
            }
            guard score > 0 else { return nil }
            return (recipe, score, index)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.2 < rhs.2 }
                return lhs.1 > rhs.1
            }
            .prefix(limit)
            .map { row in
                RecipeRecommendation(
                    recipe: row.0,
                    reason: "与“\(query)”相关。",
                    source: .local
                )
            }
    }

    private func searchTerms(query: String, recipes: [Recipe]) -> [String] {
        let separators = CharacterSet(charactersIn: " ,，、;；/|")
        var terms = query
            .components(separatedBy: separators)
            .map(Self.normalizedText)
            .filter { !$0.isEmpty }

        let corpus = Set(recipes.flatMap { recipe in
            [recipe.title, recipe.difficulty ?? ""]
                + recipe.tags
                + recipe.ingredients.map { ingredient in
                    ingredient.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ingredient
                }
        }.map(Self.normalizedText).filter { !$0.isEmpty })

        let normalizedQuery = Self.normalizedText(query)
        terms.append(contentsOf: corpus.filter { token in
            token.count >= 2 && normalizedQuery.contains(token)
        })

        let preferenceAliases: [String: [String]] = [
            "简单": ["简单", "快手"],
            "清淡": ["清淡"],
            "下饭": ["下饭", "下饭菜"],
            "酸辣": ["酸辣"],
            "川菜": ["川菜"],
            "鸡肉": ["鸡肉", "鸡胸肉", "鸡腿"]
        ]
        for (needle, aliases) in preferenceAliases where normalizedQuery.contains(needle) {
            terms.append(contentsOf: aliases.map(Self.normalizedText))
        }
        return Array(Set(terms)).filter { $0.count >= 2 }
    }

    private func preferenceKeywords(in query: String) -> [String] {
        ["清淡", "川菜", "下饭菜", "酸辣", "简单", "快手", "30分钟以内", "两个人"]
            .filter { query.contains($0) }
    }

    private func recommendationErrorMessage(for error: Error) -> String {
        if let appleError = error as? AppleRecommendationError {
            return appleError.localizedDescription
        }
        return "AI 推荐暂时不可用，仍可以继续浏览本地推荐。"
    }

    private func deduplicated(
        _ recommendations: [RecipeRecommendation],
        limit: Int
    ) -> [RecipeRecommendation] {
        var names = Set<String>()
        return recommendations.filter { recommendation in
            names.insert(Self.normalizedText(recommendation.recipe.title)).inserted
        }
        .prefix(limit)
        .map { $0 }
    }

    private func apply(_ recommendations: [RecipeRecommendation]) {
        recommendedRecipes = recommendations
        currentRecommendationIndex = 0
    }

    private func repairIndex() {
        if recommendedRecipes.isEmpty {
            currentRecommendationIndex = 0
        } else {
            currentRecommendationIndex = min(
                currentRecommendationIndex,
                recommendedRecipes.count - 1
            )
        }
    }

    private func cancelCurrentRequest() {
        requestTask?.cancel()
        requestTask = nil
        activeRequestID = nil
        isSearchingRecommendations = false
        isGeneratingRecommendations = false
    }

    private func refreshRecommendationSessionIfNeeded() {
        let today = Calendar.current.startOfDay(for: currentDate())
        guard recommendationSessionDay != today else { return }

        recommendationSessionDay = today
        hasLoadedRecommendationsForSession = false
        recommendedRecipes = []
        currentRecommendationIndex = 0
    }

    private func finishSearch(_ requestID: UUID) {
        guard activeRequestID == requestID else { return }
        isSearchingRecommendations = false
        requestTask = nil
        activeRequestID = nil
    }

    private func finishGeneration(_ requestID: UUID) {
        guard activeRequestID == requestID else { return }
        isGeneratingRecommendations = false
        requestTask = nil
        activeRequestID = nil
    }

    private static func normalizedQuery(_ query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func normalizedText(_ text: String) -> String {
        text.lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}

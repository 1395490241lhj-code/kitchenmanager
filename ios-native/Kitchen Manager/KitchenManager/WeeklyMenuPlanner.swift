import Combine
import SwiftUI
import UIKit

// MARK: - Persisted plan models
//
// These live alongside `MealPlanItem` (today's plan) rather than replacing it —
// the weekly plan is a separate, higher-level schedule that gets pushed into
// `KitchenStore.plans` a day at a time via `addRecipeToTodayPlan`/`addDayToTodayPlan`.

struct WeeklyMealPlanRecipe: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var ingredients: [String]
    var seasonings: [String]? = nil
    var steps: [String]
    var tags: [String]
    var cookingTime: Int?
    var difficulty: String?
    var reason: String?
    var source: RecommendationSource
    var existingRecipeID: String?
    var isSavedToLibrary = false
}

struct WeeklyMealPlanMeal: Identifiable, Codable, Hashable {
    var id = UUID()
    var mealIndex: Int
    var title: String?
    var recipes: [WeeklyMealPlanRecipe]
}

struct WeeklyMealPlanDay: Identifiable, Codable, Hashable {
    var id = UUID()
    var dayIndex: Int
    var meals: [WeeklyMealPlanMeal]
}

struct WeeklyMealPlanShoppingItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var quantityText: String?
    var unit: String?
    var reason: String?
}

struct WeeklyMealPlan: Codable, Hashable {
    var startDate: Date
    var days: [WeeklyMealPlanDay]
    var shoppingItems: [WeeklyMealPlanShoppingItem]
    var servings: Int
    var summary: String?
    var createdAt: Date
}

// MARK: - Request DTOs

struct WeeklyMenuInventoryPayload: Encodable {
    let name: String
    let quantity: Double
    let unit: String
    let remainingDays: Int?
    let isExpiringSoon: Bool
}

struct WeeklyMenuRecipeSummary: Encodable {
    let id: String
    let title: String
    let ingredients: [String]
    let tags: [String]
    let cookingTime: Int?
    let difficulty: String?
}

struct AIWeeklyMenuRequest: Encodable {
    let numberOfDays: Int
    let mealsPerDay: Int
    let dishesPerMeal: Int
    let servings: Int
    let cuisines: [String]
    let flavors: [String]
    let maxCookingTime: Int?
    let prioritizeExpiringIngredients: Bool
    let avoidRepeatedMainIngredients: Bool
    let excludedIngredients: [String]
    let allowNewAIRecipes: Bool
    let additionalRequest: String?
    let inventory: [WeeklyMenuInventoryPayload]
    let existingRecipes: [WeeklyMenuRecipeSummary]
    let excludedRecipeNames: [String]
}

// MARK: - Response DTOs
//
// Custom decoders tolerate the same kind of field-naming drift as the other AI
// DTOs in this project (AIGeneratedRecipeDTO, AIRecipeItem, ...).

struct AIWeeklyMenuRecipeDTO: Decodable {
    let existingRecipeID: String?
    let name: String
    let ingredients: [String]?
    let steps: [String]?
    let tags: [String]?
    let cookingTime: Int?
    let difficulty: String?
    let reason: String?
    let source: String?

    enum CodingKeys: String, CodingKey {
        case existingRecipeID, existingRecipeId, recipeId, recipeID
        case name, title
        case ingredients, steps, method, tags
        case cookingTime, cooking_time
        case difficulty, reason, source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        existingRecipeID = (try? container.decode(String.self, forKey: .existingRecipeID))
            ?? (try? container.decode(String.self, forKey: .existingRecipeId))
            ?? (try? container.decode(String.self, forKey: .recipeId))
            ?? (try? container.decode(String.self, forKey: .recipeID))
        name = (try? container.decode(String.self, forKey: .name))
            ?? (try? container.decode(String.self, forKey: .title))
            ?? ""
        ingredients = try? container.decode([String].self, forKey: .ingredients)
        tags = try? container.decode([String].self, forKey: .tags)
        difficulty = try? container.decode(String.self, forKey: .difficulty)
        reason = try? container.decode(String.self, forKey: .reason)
        source = try? container.decode(String.self, forKey: .source)

        if let value = try? container.decode(Int.self, forKey: .cookingTime) {
            cookingTime = value
        } else if let value = try? container.decode(Int.self, forKey: .cooking_time) {
            cookingTime = value
        } else {
            cookingTime = nil
        }

        if let value = try? container.decode([String].self, forKey: .steps) {
            steps = value
        } else if let value = try? container.decode([String].self, forKey: .method) {
            steps = value
        } else {
            steps = nil
        }
    }
}

struct AIWeeklyMealDTO: Decodable {
    let mealIndex: Int
    let title: String?
    let recipes: [AIWeeklyMenuRecipeDTO]

    enum CodingKeys: String, CodingKey { case mealIndex, meal_index, title, recipes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mealIndex = (try? container.decode(Int.self, forKey: .mealIndex))
            ?? (try? container.decode(Int.self, forKey: .meal_index))
            ?? 0
        title = try? container.decode(String.self, forKey: .title)
        recipes = (try? container.decode([AIWeeklyMenuRecipeDTO].self, forKey: .recipes)) ?? []
    }
}

struct AIWeeklyMenuDayDTO: Decodable {
    let dayIndex: Int
    let meals: [AIWeeklyMealDTO]

    enum CodingKeys: String, CodingKey { case dayIndex, day_index, meals }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dayIndex = (try? container.decode(Int.self, forKey: .dayIndex))
            ?? (try? container.decode(Int.self, forKey: .day_index))
            ?? 0
        meals = (try? container.decode([AIWeeklyMealDTO].self, forKey: .meals)) ?? []
    }
}

struct AIWeeklyShoppingItemDTO: Decodable {
    let name: String
    let quantityText: String?
    let unit: String?
    let reason: String?

    enum CodingKeys: String, CodingKey { case name, quantity, qty, unit, reason }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        unit = try? container.decode(String.self, forKey: .unit)
        reason = try? container.decode(String.self, forKey: .reason)

        if let number = try? container.decode(Double.self, forKey: .quantity) {
            quantityText = number.formatted(.number.precision(.fractionLength(0...2)))
        } else if let text = try? container.decode(String.self, forKey: .quantity) {
            quantityText = text
        } else if let number = try? container.decode(Double.self, forKey: .qty) {
            quantityText = number.formatted(.number.precision(.fractionLength(0...2)))
        } else {
            quantityText = try? container.decode(String.self, forKey: .qty)
        }
    }
}

struct AIWeeklyMenuResponse: Decodable {
    let days: [AIWeeklyMenuDayDTO]
    let shoppingItems: [AIWeeklyShoppingItemDTO]?
    let warnings: [String]?
}

enum WeeklyMenuPlannerError: LocalizedError {
    case invalidResponse
    case emptyPlan
    case noRecipesAvailable
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidResponse, .emptyPlan:
            return "暂时无法生成周菜单。请稍后重试，或者调整人数和偏好。"
        case .noRecipesAvailable:
            return "菜谱库是空的，请先添加几道菜谱，或者允许 AI 生成新菜。"
        case .cancelled:
            return "请求已取消。"
        }
    }
}

// MARK: - Service
//
// Reuses `AIChatService` (the same client every other AI feature in this app
// goes through) — there is no dedicated weekly-menu endpoint on the backend,
// and `/api/ai-chat` places no restriction on `taskType` values.

struct WeeklyMenuPlannerService {
    private let chatService = AIChatService()

    func generatePlan(request: AIWeeklyMenuRequest) async throws -> AIWeeklyMenuResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let requestData = try encoder.encode(request)
        guard let requestJSON = String(data: requestData, encoding: .utf8) else {
            throw WeeklyMenuPlannerError.invalidResponse
        }

        let prompt = """
        你是 Kitchen Manager 的一周菜单规划助手。请根据下面的条件生成菜单。

        条件 JSON：
        \(requestJSON)

        要求：
        - 恰好生成 numberOfDays 天，dayIndex 从 0 开始，不遗漏也不多余。
        - 每天恰好生成 mealsPerDay 顿，每顿恰好 dishesPerMeal 道菜，mealIndex 从 0 开始。
        - 每道菜必须标注 source："existing" 表示来自 existingRecipes（此时 existingRecipeID 必须是 existingRecipes 中真实存在的 id），"ai" 表示全新菜谱（此时必须给出完整 ingredients 和 steps）。
        - allowNewAIRecipes 为 false 时，只能使用 existingRecipes 里的菜，绝不能出现 source 为 ai 的菜；existingRecipes 为空时如实说明无法安排。
        - 优先使用 inventory 中的食材，尤其是 isExpiringSoon 为 true 的食材，可以安排在前几天。
        - 不要安排明显超出库存数量的菜。
        - 避免连续多顿使用同一主食材。
        - 同一天尽量荤素搭配。
        - 遵守 maxCookingTime、cuisines、flavors 和 excludedIngredients。
        - 不要出现重复菜名，也不要使用 excludedRecipeNames 中的菜。
        - 缺少的食材列在 shoppingItems 中，数量按 servings 估算，未知时可以省略数量或填“适量”。
        - 只返回 JSON 对象，不要 Markdown、代码围栏或额外解释。

        严格 JSON 格式：
        {
          "days": [
            {
              "dayIndex": 0,
              "meals": [
                {
                  "mealIndex": 0,
                  "title": "晚餐",
                  "recipes": [
                    {
                      "existingRecipeID": "已有菜谱的 id 或 null",
                      "name": "菜名",
                      "ingredients": ["食材 1"],
                      "steps": ["步骤 1"],
                      "tags": ["标签"],
                      "cookingTime": 30,
                      "difficulty": "简单",
                      "reason": "推荐原因",
                      "source": "existing"
                    }
                  ]
                }
              ]
            }
          ],
          "shoppingItems": [
            {"name": "鸡胸肉", "quantity": 2, "unit": "块", "reason": "还缺 1 块"}
          ],
          "warnings": []
        }
        """

        let content = try await chatService.request(
            prompt: prompt,
            taskType: "weekly-menu-plan",
            timeout: 100
        )
        guard let data = content.data(using: .utf8),
              let response = try? JSONDecoder().decode(AIWeeklyMenuResponse.self, from: data) else {
            throw WeeklyMenuPlannerError.invalidResponse
        }
        guard !response.days.isEmpty else {
            throw WeeklyMenuPlannerError.emptyPlan
        }
        return response
    }
}

// MARK: - Input state

struct WeeklyMenuPlannerInput {
    var numberOfDays = 7
    var mealsPerDay = 1
    var dishesPerMeal = 2
    var servings = 2
    var selectedCuisines: Set<String> = []
    var selectedFlavors: Set<String> = []
    var maxCookingTime: Int?
    var prioritizeExpiringIngredients = true
    var avoidRepeatedMainIngredients = true
    var excludedIngredientsText = ""
    var allowNewAIRecipes = true
    var additionalRequest = ""
}

// MARK: - Store

@MainActor
final class WeeklyMenuPlannerStore: ObservableObject {
    @Published var input = WeeklyMenuPlannerInput()
    @Published private(set) var isGenerating = false
    @Published var generatedPlan: WeeklyMealPlan?
    @Published var errorMessage: String?
    @Published private(set) var replacingRecipeID: String?
    @Published private(set) var hasUnsavedChanges = false

    private let service = WeeklyMenuPlannerService()
    private var generationTask: Task<AIWeeklyMenuResponse, Error>?
    private var activeRequestID: UUID?
    private var replaceTask: Task<AIWeeklyMenuResponse, Error>?
    private var activeReplaceRequestID: UUID?

    func loadSavedPlanIfNeeded(from kitchenStore: KitchenStore) {
        guard generatedPlan == nil else { return }
        generatedPlan = kitchenStore.weeklyPlan
        hasUnsavedChanges = false
    }

    func generatePlan(recipeStore: RecipeStore, kitchenStore: KitchenStore) async {
        guard !isGenerating else { return }
        guard input.allowNewAIRecipes || !recipeStore.recipes.isEmpty else {
            errorMessage = WeeklyMenuPlannerError.noRecipesAvailable.localizedDescription
            return
        }
        await run(excludedRecipeNames: [], recipeStore: recipeStore, kitchenStore: kitchenStore)
    }

    func regeneratePlan(recipeStore: RecipeStore, kitchenStore: KitchenStore) async {
        guard !isGenerating else { return }
        await run(
            excludedRecipeNames: Self.allRecipeNames(in: generatedPlan),
            recipeStore: recipeStore,
            kitchenStore: kitchenStore
        )
    }

    private func run(
        excludedRecipeNames: [String],
        recipeStore: RecipeStore,
        kitchenStore: KitchenStore
    ) async {
        cancelGeneration()
        let requestID = UUID()
        activeRequestID = requestID
        isGenerating = true
        errorMessage = nil
        let previousPlan = generatedPlan
        let existingStartDate = generatedPlan?.startDate

        let request = makeRequest(
            recipeStore: recipeStore,
            kitchenStore: kitchenStore,
            excludedRecipeNames: excludedRecipeNames
        )
        let task = Task { try await self.service.generatePlan(request: request) }
        generationTask = task

        do {
            let response = try await task.value
            guard activeRequestID == requestID, !Task.isCancelled else { return }
            generatedPlan = Self.makePlan(
                from: response,
                recipeStore: recipeStore,
                servings: input.servings,
                existingStartDate: existingStartDate
            )
            hasUnsavedChanges = true
        } catch is CancellationError {
        } catch {
            guard activeRequestID == requestID else { return }
            generatedPlan = previousPlan
            errorMessage = WeeklyMenuPlannerError.invalidResponse.localizedDescription
        }
        if activeRequestID == requestID {
            isGenerating = false
            activeRequestID = nil
            generationTask = nil
        }
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        activeRequestID = nil
        isGenerating = false
    }

    func replaceRecipe(
        dayIndex: Int,
        mealIndex: Int,
        recipeID: String,
        recipeStore: RecipeStore,
        kitchenStore: KitchenStore
    ) async {
        guard var plan = generatedPlan else { return }
        guard let dayIdx = plan.days.firstIndex(where: { $0.dayIndex == dayIndex }),
              let mealIdx = plan.days[dayIdx].meals.firstIndex(where: { $0.mealIndex == mealIndex }),
              let recipeIdx = plan.days[dayIdx].meals[mealIdx].recipes.firstIndex(where: { $0.id == recipeID }) else {
            return
        }

        replaceTask?.cancel()
        let requestID = UUID()
        activeReplaceRequestID = requestID
        replacingRecipeID = recipeID
        errorMessage = nil

        let excludedNames = Self.allRecipeNames(in: plan)
        let request = makeRequest(
            recipeStore: recipeStore,
            kitchenStore: kitchenStore,
            excludedRecipeNames: excludedNames,
            numberOfDaysOverride: 1,
            mealsPerDayOverride: 1,
            dishesPerMealOverride: 1
        )
        let task = Task { try await self.service.generatePlan(request: request) }
        replaceTask = task

        do {
            let response = try await task.value
            guard activeReplaceRequestID == requestID, !Task.isCancelled else { return }
            guard let newDTO = response.days.first?.meals.first?.recipes.first else {
                throw WeeklyMenuPlannerError.invalidResponse
            }
            plan.days[dayIdx].meals[mealIdx].recipes[recipeIdx] = Self.makeRecipe(from: newDTO, recipeStore: recipeStore)
            generatedPlan = plan
            hasUnsavedChanges = true
        } catch is CancellationError {
        } catch {
            guard activeReplaceRequestID == requestID else { return }
            errorMessage = "暂时无法替换这道菜，请稍后重试。"
        }
        if activeReplaceRequestID == requestID {
            replacingRecipeID = nil
            activeReplaceRequestID = nil
            replaceTask = nil
        }
    }

    func moveRecipe(_ recipeID: String, fromDay: Int, mealIndex: Int, toDay: Int) {
        guard var plan = generatedPlan else { return }
        guard let fromDayIdx = plan.days.firstIndex(where: { $0.dayIndex == fromDay }),
              let fromMealIdx = plan.days[fromDayIdx].meals.firstIndex(where: { $0.mealIndex == mealIndex }),
              let recipeIdx = plan.days[fromDayIdx].meals[fromMealIdx].recipes.firstIndex(where: { $0.id == recipeID }),
              let toDayIdx = plan.days.firstIndex(where: { $0.dayIndex == toDay }) else {
            return
        }
        let recipe = plan.days[fromDayIdx].meals[fromMealIdx].recipes.remove(at: recipeIdx)
        if plan.days[toDayIdx].meals.isEmpty {
            plan.days[toDayIdx].meals.append(WeeklyMealPlanMeal(mealIndex: 0, title: nil, recipes: [recipe]))
        } else {
            plan.days[toDayIdx].meals[0].recipes.append(recipe)
        }
        generatedPlan = plan
        hasUnsavedChanges = true
    }

    func removeRecipe(_ recipeID: String, dayIndex: Int, mealIndex: Int) {
        guard var plan = generatedPlan else { return }
        guard let dayIdx = plan.days.firstIndex(where: { $0.dayIndex == dayIndex }),
              let mealIdx = plan.days[dayIdx].meals.firstIndex(where: { $0.mealIndex == mealIndex }) else {
            return
        }
        plan.days[dayIdx].meals[mealIdx].recipes.removeAll { $0.id == recipeID }
        generatedPlan = plan
        hasUnsavedChanges = true
    }

    func removeShoppingItems(at offsets: IndexSet) {
        guard var plan = generatedPlan else { return }
        plan.shoppingItems.remove(atOffsets: offsets)
        generatedPlan = plan
        hasUnsavedChanges = true
    }

    func savePlan(kitchenStore: KitchenStore) {
        guard let generatedPlan else { return }
        kitchenStore.saveWeeklyPlan(generatedPlan)
        hasUnsavedChanges = false
    }

    func addRecipeToTodayPlan(_ recipe: WeeklyMealPlanRecipe, kitchenStore: KitchenStore) {
        kitchenStore.addPlan(recipe: Self.domainRecipe(from: recipe), servings: generatedPlan?.servings ?? 1)
    }

    func addDayToTodayPlan(dayIndex: Int, kitchenStore: KitchenStore) {
        guard let day = generatedPlan?.days.first(where: { $0.dayIndex == dayIndex }) else { return }
        let servings = generatedPlan?.servings ?? 1
        let additions = day.meals
            .flatMap(\.recipes)
            .map { (recipe: Self.domainRecipe(from: $0), servings: servings) }
        kitchenStore.addPlans(additions)
    }

    func saveRecipeToLibrary(_ recipe: WeeklyMealPlanRecipe, recipeStore: RecipeStore) throws {
        guard recipe.source == .ai else { return }
        try recipeStore.saveUserRecipe(Self.domainRecipe(from: recipe))
        markSaved(recipeID: recipe.id)
    }

    func addShoppingItems(_ items: [WeeklyMealPlanShoppingItem], kitchenStore: KitchenStore) {
        let additions = items.compactMap { item -> KitchenShoppingItem? in
            let normalized = Self.normalizedName(item.name)
            guard !normalized.isEmpty else { return nil }
            guard !kitchenStore.availableInventory.contains(where: { Self.normalizedName($0.name) == normalized }) else {
                return nil
            }
            let quantity = Double(item.quantityText ?? "") ?? 1
            let unit = item.unit?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "适量"
            return KitchenShoppingItem(
                name: item.name,
                quantity: quantity,
                unit: unit,
                source: "本周菜单"
            )
        }
        kitchenStore.addShoppingItems(additions)
    }

    private func markSaved(recipeID: String) {
        guard var plan = generatedPlan else { return }
        for dayIndex in plan.days.indices {
            for mealIndex in plan.days[dayIndex].meals.indices {
                for recipeIndex in plan.days[dayIndex].meals[mealIndex].recipes.indices
                where plan.days[dayIndex].meals[mealIndex].recipes[recipeIndex].id == recipeID {
                    plan.days[dayIndex].meals[mealIndex].recipes[recipeIndex].isSavedToLibrary = true
                }
            }
        }
        generatedPlan = plan
        hasUnsavedChanges = true
    }

    private func makeRequest(
        recipeStore: RecipeStore,
        kitchenStore: KitchenStore,
        excludedRecipeNames: [String],
        numberOfDaysOverride: Int? = nil,
        mealsPerDayOverride: Int? = nil,
        dishesPerMealOverride: Int? = nil
    ) -> AIWeeklyMenuRequest {
        let inventoryPayload = kitchenStore.availableInventory.map { item in
            WeeklyMenuInventoryPayload(
                name: item.name,
                quantity: item.quantity,
                unit: item.unit,
                remainingDays: item.remainingDays,
                isExpiringSoon: (item.remainingDays ?? 999) <= 3
            )
        }
        let recipeSummaries = recipeStore.recipes.prefix(60).map { recipe in
            WeeklyMenuRecipeSummary(
                id: recipe.id,
                title: recipe.title,
                ingredients: recipe.ingredients,
                tags: recipe.tags,
                cookingTime: recipe.cookingTime,
                difficulty: recipe.difficulty
            )
        }
        let excludedIngredients = input.excludedIngredientsText
            .components(separatedBy: CharacterSet(charactersIn: " ,，、\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return AIWeeklyMenuRequest(
            numberOfDays: numberOfDaysOverride ?? input.numberOfDays,
            mealsPerDay: mealsPerDayOverride ?? input.mealsPerDay,
            dishesPerMeal: dishesPerMealOverride ?? input.dishesPerMeal,
            servings: input.servings,
            cuisines: Array(input.selectedCuisines),
            flavors: Array(input.selectedFlavors),
            maxCookingTime: input.maxCookingTime,
            prioritizeExpiringIngredients: input.prioritizeExpiringIngredients,
            avoidRepeatedMainIngredients: input.avoidRepeatedMainIngredients,
            excludedIngredients: excludedIngredients,
            allowNewAIRecipes: input.allowNewAIRecipes,
            additionalRequest: input.additionalRequest.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            inventory: Array(inventoryPayload),
            existingRecipes: Array(recipeSummaries),
            excludedRecipeNames: excludedRecipeNames
        )
    }

    private static func allRecipeNames(in plan: WeeklyMealPlan?) -> [String] {
        guard let plan else { return [] }
        return plan.days.flatMap { $0.meals.flatMap { $0.recipes.map(\.title) } }
    }

    private static func makePlan(
        from response: AIWeeklyMenuResponse,
        recipeStore: RecipeStore,
        servings: Int,
        existingStartDate: Date?
    ) -> WeeklyMealPlan {
        let days = response.days
            .sorted { $0.dayIndex < $1.dayIndex }
            .map { dayDTO in
                WeeklyMealPlanDay(
                    dayIndex: dayDTO.dayIndex,
                    meals: dayDTO.meals
                        .sorted { $0.mealIndex < $1.mealIndex }
                        .map { mealDTO in
                            WeeklyMealPlanMeal(
                                mealIndex: mealDTO.mealIndex,
                                title: mealDTO.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                                recipes: mealDTO.recipes.map { makeRecipe(from: $0, recipeStore: recipeStore) }
                            )
                        }
                )
            }

        let shoppingItems: [WeeklyMealPlanShoppingItem] = (response.shoppingItems ?? []).compactMap { dto in
            let name = dto.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return WeeklyMealPlanShoppingItem(
                name: name,
                quantityText: dto.quantityText,
                unit: dto.unit,
                reason: dto.reason
            )
        }

        return WeeklyMealPlan(
            startDate: existingStartDate ?? Calendar.current.startOfDay(for: Date()),
            days: days,
            shoppingItems: shoppingItems,
            servings: servings,
            summary: response.warnings?.first,
            createdAt: Date()
        )
    }

    private static func makeRecipe(
        from dto: AIWeeklyMenuRecipeDTO,
        recipeStore: RecipeStore
    ) -> WeeklyMealPlanRecipe {
        let name = dto.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existingID = dto.existingRecipeID,
           dto.source?.lowercased() != "ai",
           let matched = recipeStore.recipes.first(where: { $0.id == existingID }) {
            return WeeklyMealPlanRecipe(
                id: matched.id,
                title: matched.title,
                ingredients: matched.ingredients,
                steps: matched.steps,
                tags: matched.tags,
                cookingTime: matched.cookingTime,
                difficulty: matched.difficulty,
                reason: dto.reason,
                source: .local,
                existingRecipeID: matched.id
            )
        }

        let ingredients = (dto.ingredients ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let steps = (dto.steps ?? []).map(EditableRecipeDraft.cleanStep).filter { !$0.isEmpty }
        return WeeklyMealPlanRecipe(
            id: "weekly-ai-\(UUID().uuidString.lowercased())",
            title: name.isEmpty ? "未命名菜谱" : name,
            ingredients: ingredients,
            steps: steps,
            tags: dto.tags ?? [],
            cookingTime: dto.cookingTime,
            difficulty: dto.difficulty,
            reason: dto.reason,
            source: .ai,
            existingRecipeID: nil
        )
    }

    private static func domainRecipe(from recipe: WeeklyMealPlanRecipe) -> Recipe {
        Recipe(
            id: recipe.existingRecipeID ?? recipe.id,
            title: recipe.title,
            cookingTime: recipe.cookingTime,
            difficulty: recipe.difficulty,
            tags: recipe.tags,
            ingredients: recipe.ingredients,
            seasonings: recipe.seasonings ?? [],
            steps: recipe.steps.isEmpty ? ["暂未提供详细步骤。"] : recipe.steps
        )
    }

    private static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Input view

struct WeeklyMenuPlannerView: View {
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @StateObject private var store = WeeklyMenuPlannerStore()
    @State private var isShowingResult = false

    var body: some View {
        Form {
            Section("规划天数与顿数") {
                Stepper("计划 \(store.input.numberOfDays) 天", value: $store.input.numberOfDays, in: 1...7)
                Stepper("每天 \(store.input.mealsPerDay) 顿", value: $store.input.mealsPerDay, in: 1...3)
                Stepper("每顿 \(store.input.dishesPerMeal) 道", value: $store.input.dishesPerMeal, in: 1...4)
                Stepper("\(store.input.servings) 人", value: $store.input.servings, in: 1...12)
            }

            Section("菜系与口味") {
                NavigationLink {
                    MultiSelectionListView(
                        title: "菜系偏好",
                        options: AIRecipeGeneratorStore.cuisineOptions,
                        selection: $store.input.selectedCuisines
                    )
                } label: {
                    LabeledContent("菜系偏好", value: summaryText(store.input.selectedCuisines, placeholder: "不限"))
                }
                NavigationLink {
                    MultiSelectionListView(
                        title: "口味偏好",
                        options: AIRecipeGeneratorStore.flavorOptions,
                        selection: $store.input.selectedFlavors
                    )
                } label: {
                    LabeledContent("口味偏好", value: summaryText(store.input.selectedFlavors, placeholder: "不限"))
                }
                Picker("最长烹饪时间", selection: $store.input.maxCookingTime) {
                    Text("不限").tag(Int?.none)
                    Text("15 分钟内").tag(Int?.some(15))
                    Text("30 分钟内").tag(Int?.some(30))
                    Text("45 分钟内").tag(Int?.some(45))
                    Text("60 分钟内").tag(Int?.some(60))
                }
            }

            Section("食材安排") {
                Toggle("优先消耗临期食材", isOn: $store.input.prioritizeExpiringIngredients)
                Toggle("避免连续重复主食材", isOn: $store.input.avoidRepeatedMainIngredients)
                TextField(
                    "忌口或排除食材，例如：花生、香菜",
                    text: $store.input.excludedIngredientsText,
                    axis: .vertical
                )
                .lineLimit(2...4)
            }

            Section {
                Toggle("允许 AI 生成新菜", isOn: $store.input.allowNewAIRecipes)
                if !store.input.allowNewAIRecipes && recipeStore.recipes.isEmpty {
                    Label("菜谱库是空的，建议先添加几道菜谱，或者允许 AI 生成新菜。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("菜谱来源")
            }

            Section("额外要求") {
                TextField(
                    "例如：适合带饭、周末想吃点特别的",
                    text: $store.input.additionalRequest,
                    axis: .vertical
                )
                .lineLimit(3...6)
            }

            Section {
                Button {
                    Task {
                        await store.generatePlan(recipeStore: recipeStore, kitchenStore: kitchenStore)
                        if store.generatedPlan != nil { isShowingResult = true }
                    }
                } label: {
                    HStack {
                        Spacer()
                        if store.isGenerating {
                            ProgressView().tint(.white)
                        } else {
                            Label("生成本周菜单", systemImage: "sparkles")
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .disabled(store.isGenerating)

                if kitchenStore.weeklyPlan != nil {
                    Button("查看已保存的本周计划") {
                        store.generatedPlan = kitchenStore.weeklyPlan
                        isShowingResult = true
                    }
                }
            }
        }
        .navigationTitle("规划本周菜单")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isShowingResult) {
            WeeklyMenuResultView(store: store)
        }
        .alert(
            "暂时无法生成周菜单",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "请稍后重试，或者调整人数和偏好。")
        }
        .onAppear {
            store.loadSavedPlanIfNeeded(from: kitchenStore)
        }
        .onDisappear {
            store.cancelGeneration()
        }
    }

    private func summaryText(_ selection: Set<String>, placeholder: String) -> String {
        selection.isEmpty ? placeholder : selection.sorted().joined(separator: "、")
    }
}

struct MultiSelectionListView: View {
    let title: String
    let options: [String]
    @Binding var selection: Set<String>

    var body: some View {
        List(options, id: \.self) { option in
            Button {
                if selection.contains(option) {
                    selection.remove(option)
                } else {
                    selection.insert(option)
                }
            } label: {
                HStack {
                    Text(option).foregroundStyle(.primary)
                    Spacer()
                    if selection.contains(option) {
                        Image(systemName: "checkmark").foregroundStyle(AppTheme.primary)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Result view

struct WeeklyMenuResultView: View {
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @ObservedObject var store: WeeklyMenuPlannerStore

    @State private var isShowingRegenerateConfirm = false
    @State private var isShowingDeleteConfirm = false
    @State private var isShowingShoppingGeneration = false
    @State private var viewingRecipe: Recipe?
    @State private var saveErrorMessage: String?
    @State private var toastMessage: String?

    var body: some View {
        List {
            if let plan = store.generatedPlan {
                overviewSection(plan)
                ForEach(plan.days) { day in
                    Section(dayTitle(day, startDate: plan.startDate)) {
                        ForEach(day.meals) { meal in
                            mealSection(meal, dayIndex: day.dayIndex, mealsPerDay: mealsPerDay(plan))
                        }
                    }
                }
                if !plan.shoppingItems.isEmpty {
                    shoppingSection(plan)
                }
            } else {
                ContentUnavailableView("还没有生成周菜单", systemImage: "calendar")
            }
        }
        .navigationTitle("本周菜单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("重新生成整周", systemImage: "arrow.clockwise") {
                        isShowingRegenerateConfirm = true
                    }
                    .disabled(store.isGenerating)
                    Button("保存本周计划", systemImage: "square.and.arrow.down") {
                        store.savePlan(kitchenStore: kitchenStore)
                        toastMessage = "已保存本周计划"
                    }
                    .disabled(store.generatedPlan == nil)
                    Button("生成本周购物清单", systemImage: "cart.badge.plus") {
                        isShowingShoppingGeneration = true
                    }
                    .disabled(store.generatedPlan == nil)
                    if kitchenStore.weeklyPlan != nil {
                        Button("复制为下一周", systemImage: "doc.on.doc") {
                            if let copy = kitchenStore.duplicateWeeklyPlanForNextWeek() {
                                store.generatedPlan = copy
                                toastMessage = "已复制为下一周计划"
                            }
                        }
                        Button("删除本周计划", systemImage: "trash", role: .destructive) {
                            isShowingDeleteConfirm = true
                        }
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
            }
        }
        .navigationDestination(item: $viewingRecipe) { recipe in
            RecipeDetailView(recipe: recipe)
        }
        .navigationDestination(isPresented: $isShowingShoppingGeneration) {
            if let plan = store.generatedPlan {
                ShoppingListGenerationView(source: .weeklyPlan(plan))
            }
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(.black.opacity(0.82), in: Capsule())
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toastMessage) {
                        try? await Task.sleep(for: .seconds(1.8))
                        self.toastMessage = nil
                    }
            }
        }
        .alert("重新生成整周菜单？", isPresented: $isShowingRegenerateConfirm) {
            Button("重新生成", role: .destructive) {
                Task { await store.regeneratePlan(recipeStore: recipeStore, kitchenStore: kitchenStore) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前未保存的计划会被新结果替换。")
        }
        .alert("删除本周计划？", isPresented: $isShowingDeleteConfirm) {
            Button("删除", role: .destructive) {
                kitchenStore.deleteWeeklyPlan()
                store.generatedPlan = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已保存的本周计划将被删除，此操作无法撤销。")
        }
        .alert(
            "暂时无法生成周菜单",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "请稍后重试，或者调整人数和偏好。")
        }
        .alert(
            "无法保存到菜谱库",
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? "请稍后重试。")
        }
        .onDisappear {
            store.cancelGeneration()
        }
    }

    private func overviewSection(_ plan: WeeklyMealPlan) -> some View {
        Section("本周概览") {
            LabeledContent("共计", value: "\(totalMeals(plan)) 顿")
            LabeledContent("菜品", value: "\(totalDishes(plan)) 道")
            LabeledContent("预计新增采购", value: "\(plan.shoppingItems.count) 项")
            if let todayIndex = dayIndexForToday(plan), plan.days.contains(where: { $0.dayIndex == todayIndex }) {
                Button("把今天加入计划") {
                    store.addDayToTodayPlan(dayIndex: todayIndex, kitchenStore: kitchenStore)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    toastMessage = "已加入今天的计划"
                }
            }
        }
    }

    private func mealSection(_ meal: WeeklyMealPlanMeal, dayIndex: Int, mealsPerDay: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mealTitle(meal, mealsPerDay: mealsPerDay))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(meal.recipes.enumerated()), id: \.element.id) { index, recipe in
                dishRow(recipe, dayIndex: dayIndex, mealIndex: meal.mealIndex)
                if index < meal.recipes.count - 1 { Divider() }
            }
        }
        .padding(.vertical, 2)
    }

    private func dishRow(_ recipe: WeeklyMealPlanRecipe, dayIndex: Int, mealIndex: Int) -> some View {
        let isAdded = kitchenStore.todayPlans.contains {
            $0.recipeID == (recipe.existingRecipeID ?? recipe.id)
        }
        let coverage = inventoryCoverage(for: recipe)

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(recipe.title).font(.subheadline.weight(.semibold))
                    if recipe.source == .ai {
                        Text("AI 新菜")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppTheme.success)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.success.opacity(0.12), in: Capsule())
                    }
                }
                if !recipe.tags.isEmpty {
                    Text(recipe.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                if let reason = recipe.reason, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if let time = recipe.cookingTime {
                        Label("\(time) 分钟", systemImage: "clock")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if coverage.uses > 0 {
                        Label("有 \(coverage.uses) 样在库", systemImage: "checkmark.circle")
                            .font(.caption2).foregroundStyle(AppTheme.success)
                    }
                    if coverage.missing > 0 {
                        Label("缺 \(coverage.missing) 样", systemImage: "cart.badge.plus")
                            .font(.caption2).foregroundStyle(AppTheme.warning)
                    }
                }
            }
            Spacer()
            if store.replacingRecipeID == recipe.id {
                ProgressView()
            } else {
                Menu {
                    Button("查看菜谱", systemImage: "book.pages") {
                        viewingRecipe = recipeForDetail(recipe)
                    }
                    Button("替换这道", systemImage: "arrow.triangle.2.circlepath") {
                        Task {
                            await store.replaceRecipe(
                                dayIndex: dayIndex,
                                mealIndex: mealIndex,
                                recipeID: recipe.id,
                                recipeStore: recipeStore,
                                kitchenStore: kitchenStore
                            )
                        }
                    }
                    let otherDays = otherDayIndices(excluding: dayIndex)
                    if !otherDays.isEmpty {
                        Menu("移到其他天") {
                            ForEach(otherDays, id: \.self) { targetDay in
                                Button("第 \(targetDay + 1) 天") {
                                    store.moveRecipe(recipe.id, fromDay: dayIndex, mealIndex: mealIndex, toDay: targetDay)
                                }
                            }
                        }
                    }
                    if recipe.source == .ai && !recipe.isSavedToLibrary {
                        Button("保存到菜谱库", systemImage: "square.and.arrow.down") {
                            attemptSaveToLibrary(recipe)
                        }
                    }
                    Button(isAdded ? "已在今天" : "加入今日计划", systemImage: "calendar.badge.plus") {
                        store.addRecipeToTodayPlan(recipe, kitchenStore: kitchenStore)
                        UINotificationFeedbackGenerator().notificationOccurred(isAdded ? .warning : .success)
                        toastMessage = isAdded ? "已在今天" : "已加入今天"
                    }
                    .disabled(isAdded)
                    Divider()
                    Button("从计划移除", systemImage: "trash", role: .destructive) {
                        store.removeRecipe(recipe.id, dayIndex: dayIndex, mealIndex: mealIndex)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.primary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func shoppingSection(_ plan: WeeklyMealPlan) -> some View {
        Section("需要购买") {
            ForEach(plan.shoppingItems) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        if let reason = item.reason, !reason.isEmpty {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text([item.quantityText, item.unit].compactMap { $0 }.joined(separator: " "))
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                store.removeShoppingItems(at: offsets)
            }

            Button("加入买菜清单（\(plan.shoppingItems.count)）") {
                store.addShoppingItems(plan.shoppingItems, kitchenStore: kitchenStore)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                toastMessage = "已加入买菜清单"
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.primary)
        }
    }

    private func attemptSaveToLibrary(_ recipe: WeeklyMealPlanRecipe) {
        do {
            try store.saveRecipeToLibrary(recipe, recipeStore: recipeStore)
            toastMessage = "已保存到菜谱库"
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    private func recipeForDetail(_ recipe: WeeklyMealPlanRecipe) -> Recipe {
        if let existingID = recipe.existingRecipeID,
           let matched = recipeStore.recipes.first(where: { $0.id == existingID }) {
            return matched
        }
        return Recipe(
            id: recipe.id,
            title: recipe.title,
            cookingTime: recipe.cookingTime,
            difficulty: recipe.difficulty,
            tags: recipe.tags,
            ingredients: recipe.ingredients,
            steps: recipe.steps.isEmpty ? ["暂未提供详细步骤。"] : recipe.steps
        )
    }

    private func inventoryCoverage(for recipe: WeeklyMealPlanRecipe) -> (uses: Int, missing: Int) {
        let names = kitchenStore.availableInventory.map(\.name)
        let uses = recipe.ingredients.filter { ingredient in
            names.contains { ingredient.localizedCaseInsensitiveContains($0) }
        }.count
        return (uses, max(0, recipe.ingredients.count - uses))
    }

    private func otherDayIndices(excluding dayIndex: Int) -> [Int] {
        (store.generatedPlan?.days.map(\.dayIndex) ?? []).filter { $0 != dayIndex }.sorted()
    }

    private func totalMeals(_ plan: WeeklyMealPlan) -> Int {
        plan.days.reduce(0) { $0 + $1.meals.count }
    }

    private func totalDishes(_ plan: WeeklyMealPlan) -> Int {
        plan.days.reduce(0) { $0 + $1.meals.reduce(0) { $0 + $1.recipes.count } }
    }

    private func mealsPerDay(_ plan: WeeklyMealPlan) -> Int {
        plan.days.first?.meals.count ?? 1
    }

    private func dayIndexForToday(_ plan: WeeklyMealPlan) -> Int? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: plan.startDate)
        return calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: Date())).day
    }

    private func dayTitle(_ day: WeeklyMealPlanDay, startDate: Date) -> String {
        let weekdaySymbols = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        guard let date = Calendar.current.date(byAdding: .day, value: day.dayIndex, to: startDate) else {
            return "第 \(day.dayIndex + 1) 天"
        }
        let weekday = Calendar.current.component(.weekday, from: date) - 1
        let symbol = weekdaySymbols.indices.contains(weekday) ? weekdaySymbols[weekday] : ""
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        let dateText = formatter.string(from: date)
        return symbol.isEmpty ? dateText : "\(symbol) · \(dateText)"
    }

    private func mealTitle(_ meal: WeeklyMealPlanMeal, mealsPerDay: Int) -> String {
        if let title = meal.title, !title.isEmpty { return title }
        if mealsPerDay <= 1 { return "今日安排" }
        let names = ["早餐", "午餐", "晚餐"]
        return names.indices.contains(meal.mealIndex) ? names[meal.mealIndex] : "第 \(meal.mealIndex + 1) 顿"
    }
}

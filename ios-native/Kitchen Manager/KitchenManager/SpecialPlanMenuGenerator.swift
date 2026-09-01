import Foundation

// MARK: - Special plan menu generation
//
// A thin adapter over the existing Weekly Menu AI stack. A special plan menu is
// the "one day / one meal / N dishes + event constraints" case of the same
// request, so this reuses `WeeklyMenuPlannerService`, `AIWeeklyMenuRequest` and the
// tolerant `AIWeeklyMenuResponse` decoding rather than standing up a second AI
// service, prompt, transport or DTO family.
//
// Nothing here writes canonical state: generation produces a transient draft
// that only the draft store holds until the user accepts it.

/// Sanity bounds for a generated menu. The AI decides the actual composition;
/// these only stop a malformed or runaway response from becoming a menu.
enum SpecialPlanMenuBounds {
    static let minimumDishes = 2
    static let maximumDishes = 10

    /// A starting suggestion for the model, not a computed portion figure —
    /// the repo has no canonical recipe yield to scale against.
    static func suggestedDishCount(peopleCount: Int) -> Int {
        switch peopleCount {
        case ..<3: return 3
        case 3...4: return 4
        case 5...6: return 5
        default: return 6
        }
    }
}

enum SpecialPlanMenuGeneratorError: LocalizedError, Equatable {
    case invalidResponse
    case emptyMenu
    case tooFewDishes

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "暂时无法生成菜单。请稍后重试，或调整人数与备注。"
        case .emptyMenu:
            return "这次没有生成可用的菜品，请重试。"
        case .tooFewDishes:
            return "这次生成的菜品太少，请重试。"
        }
    }
}

/// The one seam this feature adds over the weekly stack: it exists only so a
/// test can supply a canned response. `WeeklyMenuPlannerService` holds its
/// `AIChatService` privately, so injecting at that level would mean editing the
/// weekly planner; this keeps the weekly code untouched.
protocol SpecialPlanMenuRequesting {
    func generatePlan(request: AIWeeklyMenuRequest) async throws -> AIWeeklyMenuResponse
}

/// Production path: the existing weekly service, unchanged.
extension WeeklyMenuPlannerService: SpecialPlanMenuRequesting {}

/// Builds the request and maps the shared weekly response onto special plan
/// draft dishes. Pure translation plus validation — the network call itself
/// stays in `WeeklyMenuPlannerService`.
struct SpecialPlanMenuGenerator {
    var service: any SpecialPlanMenuRequesting = SpecialPlanMenuGenerator.defaultService()

    /// Production always returns the real weekly service. Only a UI-test launch
    /// argument swaps in the canned responder below, so a normal debug run and
    /// every release build behave identically to a plain `WeeklyMenuPlannerService()`.
    static func defaultService() -> any SpecialPlanMenuRequesting {
        #if DEBUG
        if let stub = SpecialPlanMenuUITestStub.make() { return stub }
        #endif
        return WeeklyMenuPlannerService()
    }

    func generateMenu(
        for plan: SpecialPlan,
        inventory: [InventoryItem],
        expiringItems: [InventoryItem],
        existingRecipes: [Recipe],
        excludedRecipeNames: [String] = []
    ) async throws -> [SpecialPlanMenuDraftDish] {
        let request = Self.makeRequest(
            for: plan,
            dishCount: SpecialPlanMenuBounds.suggestedDishCount(peopleCount: plan.peopleCount),
            inventory: inventory,
            expiringItems: expiringItems,
            existingRecipes: existingRecipes,
            excludedRecipeNames: excludedRecipeNames
        )
        let response = try await service.generatePlan(request: request)
        let dishes = Self.dishes(from: response, existingRecipes: existingRecipes)
        guard !dishes.isEmpty else { throw SpecialPlanMenuGeneratorError.emptyMenu }
        guard dishes.count >= SpecialPlanMenuBounds.minimumDishes else {
            throw SpecialPlanMenuGeneratorError.tooFewDishes
        }
        return Array(dishes.prefix(SpecialPlanMenuBounds.maximumDishes))
    }

    /// One replacement dish, using the same single-dish override shape the
    /// weekly planner uses for 替换这道: one day, one meal, one dish.
    func generateReplacement(
        for plan: SpecialPlan,
        inventory: [InventoryItem],
        expiringItems: [InventoryItem],
        existingRecipes: [Recipe],
        excludedRecipeNames: [String]
    ) async throws -> SpecialPlanMenuDraftDish {
        let request = Self.makeRequest(
            for: plan,
            dishCount: 1,
            inventory: inventory,
            expiringItems: expiringItems,
            existingRecipes: existingRecipes,
            excludedRecipeNames: excludedRecipeNames,
            additionalInstruction: "当前只替换菜单中的一道菜。请生成一道普通、可独立上桌的菜，不要生成整桌套餐、拼盘、盆菜、火锅或多菜合一，并保持与其余菜搭配。"
        )
        let response = try await service.generatePlan(request: request)
        guard let dish = Self.dishes(from: response, existingRecipes: existingRecipes).first else {
            throw SpecialPlanMenuGeneratorError.emptyMenu
        }
        return dish
    }

    // MARK: - Request construction

    /// Event constraints travel as `additionalRequest`, which the shared prompt
    /// already embeds verbatim in its condition JSON.
    static func makeRequest(
        for plan: SpecialPlan,
        dishCount: Int,
        inventory: [InventoryItem],
        expiringItems: [InventoryItem],
        existingRecipes: [Recipe],
        excludedRecipeNames: [String],
        additionalInstruction: String? = nil
    ) -> AIWeeklyMenuRequest {
        let inventoryPayload = inventory.map { item in
            WeeklyMenuInventoryPayload(
                name: item.name,
                quantity: item.quantity,
                unit: item.unit,
                remainingDays: item.remainingDays,
                isExpiringSoon: (item.remainingDays ?? 999) <= 3
            )
        }
        let recipeSummaries = existingRecipes.prefix(60).map { recipe in
            WeeklyMenuRecipeSummary(
                id: recipe.id,
                title: recipe.title,
                ingredients: recipe.ingredients,
                tags: recipe.tags,
                cookingTime: recipe.cookingTime,
                difficulty: recipe.difficulty
            )
        }
        let requestNotes = [eventBrief(for: plan), additionalInstruction]
            .compactMap { $0 }
            .joined(separator: " ")
        return AIWeeklyMenuRequest(
            numberOfDays: 1,
            mealsPerDay: 1,
            dishesPerMeal: max(1, min(dishCount, SpecialPlanMenuBounds.maximumDishes)),
            // The shared weekly prompt uses servings to estimate quantities.
            // Special Plans have no canonical recipe yield, so headcount stays
            // in the event brief and this field must remain neutral.
            servings: 1,
            cuisines: [],
            flavors: [],
            maxCookingTime: nil,
            prioritizeExpiringIngredients: true,
            avoidRepeatedMainIngredients: true,
            excludedIngredients: [],
            allowNewAIRecipes: true,
            additionalRequest: requestNotes,
            inventory: Array(inventoryPayload),
            existingRecipes: Array(recipeSummaries),
            excludedRecipeNames: excludedRecipeNames
        )
    }

    /// The canonical event state, rendered for the model. peopleCount shapes the
    /// menu's size and composition; it deliberately never asks for scaled
    /// ingredient quantities, because no recipe here carries a base yield.
    static func eventBrief(for plan: SpecialPlan) -> String {
        var parts: [String] = []
        parts.append("这是一次「\(plan.title)」，共 \(plan.peopleCount) 人一起吃。")
        parts.append("开饭时间：\(SpecialPlan.timeText(plan.scheduledAt))。")
        if !plan.constraintNotes.isEmpty {
            parts.append("必须遵守的忌口或要求：\(plan.constraintNotes.joined(separator: "；"))。")
        }
        if !plan.notes.isEmpty {
            parts.append("补充说明：\(plan.notes)。")
        }
        parts.append("请按聚餐场合安排菜品数量与荤素搭配，适合多人分享。")
        parts.append("只给出菜品与做法。ingredients 中的用量只能是普通菜谱自身的原始用量，禁止按人数推算，也不要出现与 \(plan.peopleCount) 人一一对应的数量模式；数量与单位之间留空格，无法确定时写“适量”。")
        return parts.joined(separator: " ")
    }

    // MARK: - Response mapping

    /// Flattens the weekly response's day/meal nesting into a dish list and
    /// drops entries that cannot become a valid recipe draft.
    static func dishes(
        from response: AIWeeklyMenuResponse,
        existingRecipes: [Recipe]
    ) -> [SpecialPlanMenuDraftDish] {
        var seenNames = Set<String>()
        var result: [SpecialPlanMenuDraftDish] = []

        for day in response.days.sorted(by: { $0.dayIndex < $1.dayIndex }) {
            for meal in day.meals.sorted(by: { $0.mealIndex < $1.mealIndex }) {
                for dto in meal.recipes {
                    guard let dish = draftDish(from: dto, existingRecipes: existingRecipes) else { continue }
                    let key = normalizedName(dish.title)
                    guard !key.isEmpty, seenNames.insert(key).inserted else { continue }
                    result.append(dish)
                }
            }
        }
        return result
    }

    /// Maps one response dish. An existing dish resolves to the real recipe so
    /// acceptance can reuse its id; an AI dish must carry enough content to
    /// satisfy the recipe draft schema or it is dropped.
    static func draftDish(
        from dto: AIWeeklyMenuRecipeDTO,
        existingRecipes: [Recipe]
    ) -> SpecialPlanMenuDraftDish? {
        let name = dto.name.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existingID = dto.existingRecipeID,
           dto.source?.lowercased() != "ai",
           let matched = existingRecipes.first(where: { $0.id == existingID }) {
            return SpecialPlanMenuDraftDish(
                title: matched.title,
                ingredients: matched.ingredients,
                seasonings: matched.seasonings,
                steps: matched.steps,
                tags: matched.tags,
                cookingTime: matched.cookingTime,
                difficulty: matched.difficulty,
                reason: dto.reason,
                existingRecipeID: matched.id
            )
        }

        let ingredients = (dto.ingredients ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let steps = (dto.steps ?? [])
            .map(EditableRecipeDraft.cleanStep)
            .filter { !$0.isEmpty }

        // Same floor the manual recipe editor enforces: a saveable recipe needs
        // a title, at least one ingredient and at least one step.
        guard !name.isEmpty, !ingredients.isEmpty, !steps.isEmpty else { return nil }

        return SpecialPlanMenuDraftDish(
            title: name,
            ingredients: ingredients,
            seasonings: [],
            steps: steps,
            tags: dto.tags ?? [],
            cookingTime: dto.cookingTime,
            difficulty: dto.difficulty,
            reason: dto.reason,
            existingRecipeID: nil
        )
    }

    static func normalizedName(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}

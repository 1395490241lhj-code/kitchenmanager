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
    static let maximumDishes = 10

    /// The fewest mapped dishes a menu may have to count as the menu that was
    /// asked for. One short is tolerated (a dropped course is easy to add);
    /// anything shorter is not the requested menu and is rejected rather than
    /// shown, so a 2-dish answer to a 6-dish request never becomes a draft.
    /// Never below 2: a single dish is not a menu whatever was requested.
    static func minimumDishes(requested: Int) -> Int {
        max(2, requested - 1)
    }

    /// Every recipe the AI writes for a Special Plan states its quantities for
    /// this many servings.
    ///
    /// A product convention, not a claim that Chinese dishes are inherently
    /// four-serving. Letting the model pick its own denominator would make the
    /// number and the quantities come from the same unreliable source: a
    /// response could say 4 while sizing for 2, and nothing downstream could
    /// tell. Fixing it makes the contract checkable — the response either
    /// declares this value or the generation is rejected.
    static let aiRecipeBaseServings = 4

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
    case hardConstraintViolation
    /// A dish did not declare the required base yield, so its quantities have
    /// no trustworthy denominator.
    case baseYieldContractViolation

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "暂时无法生成菜单。请稍后重试，或调整人数与备注。"
        case .emptyMenu:
            return "这次没有生成可用的菜品，请重试。"
        case .tooFewDishes:
            return "这次生成的菜品太少，请重试。"
        case .hardConstraintViolation:
            return "这次生成的菜单没有完全满足“不吃辣”的要求，请重新生成。"
        case .baseYieldContractViolation:
            return "这次生成的菜谱没有标注标准份量，请重新生成。"
        }
    }
}

/// A deliberately narrow policy derived from the user's canonical free-text
/// constraints. It is not a general dietary or allergen model.
struct SpecialPlanConstraintPolicy: Equatable {
    let requiresNonSpicyFood: Bool

    init(constraintNotes: [String]) {
        requiresNonSpicyFood = constraintNotes.contains { note in
            let normalized = Self.normalized(note)
            let compact = normalized.filter { !$0.isWhitespace }
            return ["不吃辣", "不能吃辣", "不要辣", "完全不辣"].contains { compact.contains($0) }
                || [
                    "no spicy food", "not spicy", "can't eat spicy", "cannot eat spicy",
                    "does not eat spicy", "doesn't eat spicy", "no chili", "no chilli"
                ].contains { normalized.contains($0) }
        }
    }

    func allows(_ dish: SpecialPlanMenuDraftDish) -> Bool {
        allows(
            title: dish.title,
            ingredients: dish.ingredients,
            seasonings: dish.seasonings,
            steps: dish.steps
        )
    }

    func allows(
        title: String,
        ingredients: [String],
        seasonings: [String],
        steps: [String]
    ) -> Bool {
        guard requiresNonSpicyFood else { return true }
        if title.contains("辣") { return false }

        let searchable = [title] + ingredients + seasonings + steps
        return !searchable.contains { value in
            let normalized = Self.normalized(value)
            return Self.spicyMarkers.contains { normalized.contains($0) }
        }
    }

    private static let spicyMarkers = [
        "辣椒", "小米辣", "辣椒油", "红油", "辣豆瓣酱", "老干妈", "麻辣", "香辣", "酸辣", "辣子",
        "chili", "chilli", "hot sauce", "sriracha", "gochujang", "jalapeño", "jalapeno", "cayenne",
        "red pepper flakes"
    ]

    private static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
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
        let requestedDishes = SpecialPlanMenuBounds.suggestedDishCount(peopleCount: plan.peopleCount)
        let request = Self.makeRequest(
            for: plan,
            dishCount: requestedDishes,
            inventory: inventory,
            expiringItems: expiringItems,
            existingRecipes: existingRecipes,
            excludedRecipeNames: excludedRecipeNames
        )
        let response = try await response(for: request, operation: "generate")
        let dishes = Self.dishes(from: response, existingRecipes: existingRecipes)
        guard !dishes.isEmpty else { throw SpecialPlanMenuGeneratorError.emptyMenu }
        guard dishes.count >= SpecialPlanMenuBounds.minimumDishes(requested: requestedDishes) else {
            throw SpecialPlanMenuGeneratorError.tooFewDishes
        }
        try Self.validateBaseYield(dishes)
        try Self.validateHardConstraints(dishes, for: plan)
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
        let response = try await response(for: request, operation: "replacement")
        guard let dish = Self.dishes(from: response, existingRecipes: existingRecipes).first else {
            throw SpecialPlanMenuGeneratorError.emptyMenu
        }
        try Self.validateBaseYield([dish])
        try Self.validateHardConstraints([dish], for: plan)
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
        let policy = SpecialPlanConstraintPolicy(constraintNotes: plan.constraintNotes)
        let compatibleRecipes = existingRecipes.lazy.filter { recipe in
            policy.allows(
                title: recipe.title,
                ingredients: recipe.ingredients,
                seasonings: recipe.seasonings,
                steps: recipe.steps
            )
        }
        // One event needs at most ten dishes. Keeping the first twenty compatible recipes
        // preserves every user recipe first (RecipeStore orders them ahead of
        // the remote library) without sending the weekly planner's 60-recipe
        // context for a single meal.
        let recipeSummaries = compatibleRecipes.prefix(20).map { recipe in
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
        if SpecialPlanConstraintPolicy(constraintNotes: plan.constraintNotes).requiresNonSpicyFood {
            parts.append("硬性约束：所有共享菜都必须完全不辣。不得生成辣、微辣、麻辣等辣味菜，不得把辣椒、辣椒油、辣酱或可选辣椒作为核心调味，也不要生成需要用户自行去辣才能满足约束的菜谱。")
        }
        if !plan.notes.isEmpty {
            parts.append("补充说明：\(plan.notes)。")
        }
        parts.append("请按聚餐场合安排菜品数量与荤素搭配，适合多人分享。")
        parts.append("只给出菜品与做法。每一道新菜谱都必须按 \(SpecialPlanMenuBounds.aiRecipeBaseServings) 人份的标准家常菜谱书写用量，并在该菜的 baseServings 字段里如实填写 \(SpecialPlanMenuBounds.aiRecipeBaseServings)。ingredients 与 seasonings 中的所有数量都要对应这份 \(SpecialPlanMenuBounds.aiRecipeBaseServings) 人份菜谱，禁止按 \(plan.peopleCount) 人推算，也不要出现与 \(plan.peopleCount) 人一一对应的数量模式（例如 \(plan.peopleCount) 只虾、每人一个）。\(plan.peopleCount) 人只用来决定上几道菜和荤素搭配，不影响单道菜的用量。数量与单位之间留空格，无法确定时写“适量”。")
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
            existingRecipeID: nil,
            // Carried verbatim from the response, including a wrong or missing
            // value: `validateBaseYield` rejects it rather than correcting it,
            // so a saved yield always reflects what the model actually said.
            baseServings: dto.baseServings
        )
    }

    static func normalizedName(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private static func validateHardConstraints(
        _ dishes: [SpecialPlanMenuDraftDish],
        for plan: SpecialPlan
    ) throws {
        let policy = SpecialPlanConstraintPolicy(constraintNotes: plan.constraintNotes)
        guard dishes.allSatisfy(policy.allows) else {
            throw SpecialPlanMenuGeneratorError.hardConstraintViolation
        }
    }

    /// Every newly written dish must declare the contracted base yield.
    ///
    /// Whole-draft, not per dish: accepting four correct dishes and dropping a
    /// fifth would leave the user a menu quietly missing a course. A wrong or
    /// absent value is a rejection, never a local correction — stamping the
    /// expected number onto a response that said something else would fabricate
    /// exactly the provenance this contract exists to establish.
    ///
    /// Dishes resolved to a recipe the user already owns are exempt: their yield
    /// is whatever that recipe already records, and this contract governs only
    /// recipes the AI writes.
    static func validateBaseYield(_ dishes: [SpecialPlanMenuDraftDish]) throws {
        let newlyWritten = dishes.filter { !$0.isExistingRecipe }
        guard newlyWritten.allSatisfy({ $0.baseServings == SpecialPlanMenuBounds.aiRecipeBaseServings }) else {
            throw SpecialPlanMenuGeneratorError.baseYieldContractViolation
        }
    }

    private func response(
        for request: AIWeeklyMenuRequest,
        operation: String
    ) async throws -> AIWeeklyMenuResponse {
        #if DEBUG
        let start = Date()
        print(
            "[SpecialPlanAI] operation=\(operation) stage=request-start "
                + "inventory=\(request.inventory.count) recipes=\(request.existingRecipes.count) "
                + "excluded=\(request.excludedRecipeNames.count) targetDishes=\(request.dishesPerMeal)"
        )
        #endif
        do {
            let result = try await service.generatePlan(request: request)
            #if DEBUG
            print(
                "[SpecialPlanAI] operation=\(operation) stage=structured-decode-succeeded "
                    + "elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
            )
            #endif
            return result
        } catch {
            #if DEBUG
            let nsError = error as NSError
            print(
                "[SpecialPlanAI] operation=\(operation) stage=request-failed "
                    + "elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000)) "
                    + "cancelled=\(Task.isCancelled) domain=\(nsError.domain) code=\(nsError.code)"
            )
            #endif
            throw error
        }
    }
}

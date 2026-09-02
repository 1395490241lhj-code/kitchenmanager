import Foundation

// MARK: - Special plan menu generation
//
// A thin adapter over the existing Weekly Menu AI stack. A special plan menu is
// the "one day / one meal / N dishes + event constraints" case of the same
// request, so this reuses `WeeklyMenuPlannerService`, `AIWeeklyMenuRequest` and the
// tolerant `AIWeeklyMenuResponse` decoding rather than standing up a second AI
// service, prompt, transport or DTO family.
//
// The user's input is one natural-language request. The same round trip that
// writes the menu also returns the model's reading of that request (title,
// date, headcount, constraints) as an `event` object, so composing a plan is
// one AI call, not an interpretation call followed by a menu call.
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
    /// `nil` means the request stated no count and the model chose one.
    static func minimumDishes(requested: Int?) -> Int {
        max(2, (requested ?? 0) - 1)
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

    /// A starting suggestion for the model when the request names a headcount
    /// but no dish count — not a computed portion figure.
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
            return "暂时无法生成菜单。请稍后重试，或换一种说法描述这次做饭。"
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

// MARK: - Deterministic request reading

/// The two numbers that have to be fixed *before* the model is asked, read
/// from the request text locally so they never depend on the model's own
/// account of what it was asked.
///
/// - A stated dish count ("6 道", "5–6 道菜") becomes the exact count the
///   request asks for and the floor the cardinality check enforces.
/// - A stated headcount ("7 个人") sizes the menu when no dish count is given.
/// - Neither stated: the model chooses, and only the absolute floor applies.
///
/// This is a reading of numbers, not an understanding of the sentence; the
/// model still interprets the request as a whole.
struct SpecialPlanRequestReading: Equatable {
    let requestedDishCount: Int?
    let peopleCount: Int?

    init(requestText: String) {
        requestedDishCount = Self.dishCount(in: requestText)
        peopleCount = Self.peopleCount(in: requestText)
    }

    /// The count sent as `dishesPerMeal`; `nil` lets the model decide.
    var dishesToRequest: Int? {
        if let requestedDishCount {
            return min(max(requestedDishCount, 1), SpecialPlanMenuBounds.maximumDishes)
        }
        if let peopleCount {
            return SpecialPlanMenuBounds.suggestedDishCount(peopleCount: peopleCount)
        }
        return nil
    }

    private static let numeral = #"(?<![\d第])(?<!第\s)(\d{1,2}|[一二两三四五六七八九十]{1,2})"#

    /// "6 道", "六道菜", "5-6 道", "5～6 个菜": a range reads as its upper bound.
    /// An ordinal ("第 2 道菜") is not a count.
    static func dishCount(in text: String) -> Int? {
        let pattern = numeral + #"(?:\s*[-–~～到至]\s*"# + numeral + #")?\s*(?:道|个\s*菜)"#
        guard let match = firstMatch(of: pattern, in: text) else { return nil }
        let upper = match.count > 2 && !match[2].isEmpty ? match[2] : nil
        return number(from: upper ?? match[1])
    }

    /// "7 个人", "七位", "3 口人". A count that describes a constraint rather
    /// than the table ("1 人不吃辣", "2 人忌口") is skipped; the largest
    /// remaining count is the table.
    static func peopleCount(in text: String) -> Int? {
        let pattern = numeral + #"\s*(?:个|位|口)?\s*人(?!不|忌|吃素|过敏|素食|是)"#
        let counts = allMatches(of: pattern, in: text).compactMap { number(from: $0[1]) }
        return counts.max()
    }

    private static func number(from token: String) -> Int? {
        if let value = Int(token) { return value }
        let digits: [Character: Int] = [
            "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9, "十": 10
        ]
        let chars = Array(token)
        switch chars.count {
        case 1: return digits[chars[0]]
        case 2 where chars[0] == "十": return digits[chars[1]].map { 10 + $0 }
        case 2 where chars[1] == "十": return digits[chars[0]].map { $0 * 10 }
        default: return nil
        }
    }

    private static func firstMatch(of pattern: String, in text: String) -> [String]? {
        allMatches(of: pattern, in: text).first
    }

    private static func allMatches(of pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: text) else { return "" }
                return String(text[range])
            }
        }
    }
}

// MARK: - Interpretation

/// What the model read out of the request, already parsed into app types.
/// Every field is optional except the constraint list: the caller decides the
/// fallback for a missing title or date, and the plan records that it was a
/// fallback by keeping the raw request beside it.
struct SpecialPlanInterpretation: Equatable {
    var title: String?
    var scheduledAt: Date?
    var peopleCount: Int?
    var constraintNotes: [String]
    var notes: String

    static let empty = SpecialPlanInterpretation(
        title: nil, scheduledAt: nil, peopleCount: nil, constraintNotes: [], notes: ""
    )

    init(title: String?, scheduledAt: Date?, peopleCount: Int?, constraintNotes: [String], notes: String) {
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.scheduledAt = scheduledAt
        self.peopleCount = peopleCount.flatMap { (1...99).contains($0) ? $0 : nil }
        self.constraintNotes = SpecialPlan.normalizedConstraintNotes(constraintNotes)
        self.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(event: AIWeeklyMenuEventDTO?, calendar: Calendar = .current) {
        self.init(
            title: event?.title,
            scheduledAt: event?.scheduledAt.flatMap { Self.date(from: $0, calendar: calendar) },
            peopleCount: event?.peopleCount,
            constraintNotes: event?.constraintNotes ?? [],
            notes: event?.notes ?? ""
        )
    }

    /// "yyyy-MM-dd HH:mm" in the user's calendar, with the ISO shapes a model
    /// tends to produce instead. A bare date means 18:00, matching the prompt.
    static func date(from text: String, calendar: Calendar = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return nil }
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        let dayOnly = DateFormatter()
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.calendar = calendar
        dayOnly.timeZone = calendar.timeZone
        dayOnly.dateFormat = "yyyy-MM-dd"
        if let day = dayOnly.date(from: trimmed) {
            return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day)
        }
        let iso = ISO8601DateFormatter()
        return iso.date(from: trimmed)
    }
}

/// One successful composition: the model's reading of the request plus the
/// menu it wrote for it.
struct SpecialPlanComposition: Equatable {
    var interpretation: SpecialPlanInterpretation
    var dishes: [SpecialPlanMenuDraftDish]
}

// MARK: - Constraint policy

/// A deliberately narrow policy derived from the user's words. It is not a
/// general dietary or allergen model.
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

    /// The raw request is always consulted alongside the derived notes, so a
    /// hard constraint the user typed holds even if the model's reading
    /// dropped it.
    init(requestText: String, constraintNotes: [String]) {
        self.init(constraintNotes: constraintNotes + [requestText])
    }

    init(plan: SpecialPlan) {
        self.init(requestText: plan.requestText, constraintNotes: plan.constraintNotes)
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

// MARK: - Generator

/// Builds the request and maps the shared weekly response onto special plan
/// draft dishes. Pure translation plus validation — the network call itself
/// stays in `WeeklyMenuPlannerService`.
struct SpecialPlanMenuGenerator {
    /// Everything a request needs besides the inventory pool. Built by the
    /// draft store from either a fresh composer input or an existing plan.
    struct Input: Equatable {
        /// The user's words. For a plan written before the composer, the
        /// legacy fields rendered as one sentence (`SpecialPlan.effectiveRequestText`).
        var requestText: String
        /// Derived notes already on the plan, if any. Only strengthens the
        /// hard-constraint check; the request text is always consulted too.
        var constraintNotes: [String] = []
        var usesHomeInventory: Bool
        /// A Planner day the composer was opened from, when the request itself
        /// may name no date.
        var contextDate: Date? = nil
    }

    var service: any SpecialPlanMenuRequesting = SpecialPlanMenuGenerator.defaultService()
    var calendar: Calendar = .current
    var now: () -> Date = Date.init

    /// Production always returns the real weekly service. Only a UI-test launch
    /// argument swaps in the canned responder below, so a normal debug run and
    /// every release build behave identically to a plain `WeeklyMenuPlannerService()`.
    static func defaultService() -> any SpecialPlanMenuRequesting {
        #if DEBUG
        if let stub = SpecialPlanMenuUITestStub.make() { return stub }
        #endif
        return WeeklyMenuPlannerService()
    }

    /// One round trip: the model reads the request and writes the menu.
    func composeMenu(
        _ input: Input,
        inventory: [InventoryItem],
        existingRecipes: [Recipe],
        excludedRecipeNames: [String] = []
    ) async throws -> SpecialPlanComposition {
        let reading = SpecialPlanRequestReading(requestText: input.requestText)
        let request = Self.makeRequest(
            input,
            dishCount: reading.dishesToRequest,
            inventory: inventory,
            existingRecipes: existingRecipes,
            excludedRecipeNames: excludedRecipeNames,
            calendar: calendar,
            now: now()
        )
        let response = try await response(for: request, operation: "compose")
        let dishes = Self.dishes(from: response, existingRecipes: existingRecipes)
        guard !dishes.isEmpty else { throw SpecialPlanMenuGeneratorError.emptyMenu }
        guard dishes.count >= SpecialPlanMenuBounds.minimumDishes(requested: reading.dishesToRequest) else {
            throw SpecialPlanMenuGeneratorError.tooFewDishes
        }
        let interpretation = SpecialPlanInterpretation(event: response.event, calendar: calendar)
        try Self.validateBaseYield(dishes)
        try Self.validateHardConstraints(
            dishes,
            policy: SpecialPlanConstraintPolicy(
                requestText: input.requestText,
                constraintNotes: input.constraintNotes + interpretation.constraintNotes
            )
        )
        return SpecialPlanComposition(
            interpretation: interpretation,
            dishes: Array(dishes.prefix(SpecialPlanMenuBounds.maximumDishes))
        )
    }

    /// One replacement dish, using the same single-dish override shape the
    /// weekly planner uses for 替换这道: one day, one meal, one dish. Starts
    /// from the plan's own request and constraints, never from a transcript.
    func generateReplacement(
        for plan: SpecialPlan,
        inventory: [InventoryItem],
        existingRecipes: [Recipe],
        excludedRecipeNames: [String]
    ) async throws -> SpecialPlanMenuDraftDish {
        let request = Self.makeRequest(
            Input(plan: plan),
            dishCount: 1,
            inventory: inventory,
            existingRecipes: existingRecipes,
            excludedRecipeNames: excludedRecipeNames,
            additionalInstruction: "当前只替换菜单中的一道菜。请生成一道普通、可独立上桌的菜，不要生成整桌套餐、拼盘、盆菜、火锅或多菜合一，并保持与其余菜搭配。event 对象仍需返回，但只用于核对。",
            calendar: calendar,
            now: now()
        )
        let response = try await response(for: request, operation: "replacement")
        guard let dish = Self.dishes(from: response, existingRecipes: existingRecipes).first else {
            throw SpecialPlanMenuGeneratorError.emptyMenu
        }
        try Self.validateBaseYield([dish])
        try Self.validateHardConstraints([dish], policy: SpecialPlanConstraintPolicy(plan: plan))
        return dish
    }

    // MARK: - Request construction

    /// Event instructions travel as `additionalRequest`, which the shared prompt
    /// already embeds verbatim in its condition JSON; the user's words travel
    /// separately and verbatim as `eventRequest`.
    ///
    /// `dishCount == nil` asks the model to choose (`dishesPerMeal: 0`).
    static func makeRequest(
        _ input: Input,
        dishCount: Int?,
        inventory: [InventoryItem],
        existingRecipes: [Recipe],
        excludedRecipeNames: [String],
        additionalInstruction: String? = nil,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> AIWeeklyMenuRequest {
        // The whole inventory gate for AI: a plan cooked away from home sends
        // nothing, so the model cannot prefer food that is not at the venue.
        let inventoryPayload: [WeeklyMenuInventoryPayload] = input.usesHomeInventory
            ? inventory.map { item in
                WeeklyMenuInventoryPayload(
                    name: item.name,
                    quantity: item.quantity,
                    unit: item.unit,
                    remainingDays: item.remainingDays,
                    isExpiringSoon: (item.remainingDays ?? 999) <= 3
                )
            }
            : []
        let policy = SpecialPlanConstraintPolicy(
            requestText: input.requestText,
            constraintNotes: input.constraintNotes
        )
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
        let requestNotes = [eventBrief(for: input, policy: policy), additionalInstruction]
            .compactMap { $0 }
            .joined(separator: " ")
        return AIWeeklyMenuRequest(
            numberOfDays: 1,
            mealsPerDay: 1,
            dishesPerMeal: dishCount.map { max(1, min($0, SpecialPlanMenuBounds.maximumDishes)) } ?? 0,
            // The shared weekly prompt uses servings to estimate quantities.
            // Special Plan recipes are written for a fixed base yield instead,
            // so this field must remain neutral.
            servings: 1,
            cuisines: [],
            flavors: [],
            maxCookingTime: nil,
            prioritizeExpiringIngredients: input.usesHomeInventory,
            avoidRepeatedMainIngredients: true,
            excludedIngredients: [],
            allowNewAIRecipes: true,
            additionalRequest: requestNotes,
            inventory: inventoryPayload,
            existingRecipes: Array(recipeSummaries),
            excludedRecipeNames: excludedRecipeNames,
            eventRequest: WeeklyMenuEventRequest(
                request: input.requestText,
                today: Self.dayText(now, calendar: calendar),
                fallbackDate: input.contextDate.map { Self.dayText($0, calendar: calendar) }
            )
        )
    }

    /// The standing rules for a Special Plan, rendered for the model. The
    /// request itself is not repeated here; it travels as `eventRequest`.
    static func eventBrief(for input: Input, policy: SpecialPlanConstraintPolicy) -> String {
        var parts: [String] = []
        parts.append("这是一次特殊安排（聚餐、宴客或某一顿的专门规划），用户的原话在 eventRequest.request 里，请以它为准安排菜单。")
        if !input.constraintNotes.isEmpty {
            parts.append("必须遵守的忌口或要求：\(input.constraintNotes.joined(separator: "；"))。")
        }
        if policy.requiresNonSpicyFood {
            parts.append("硬性约束：所有共享菜都必须完全不辣。不得生成辣、微辣、麻辣等辣味菜，不得把辣椒、辣椒油、辣酱或可选辣椒作为核心调味，也不要生成需要用户自行去辣才能满足约束的菜谱。")
        }
        if input.usesHomeInventory {
            parts.append("这次在家做饭：inventory 是家中现有食材，优先使用，尤其是 isExpiringSoon 为 true 的。")
        } else {
            parts.append("这次不参考家中库存（可能不在家做饭）：inventory 为空不代表没有食材，请自由选用合适的食材，缺的都可以购买，不要因为库存为空而缩减菜单或改用简陋的菜。")
        }
        parts.append("请按场合安排菜品数量与荤素搭配，适合多人分享。")
        parts.append("只给出菜品与做法。每一道新菜谱都必须按 \(SpecialPlanMenuBounds.aiRecipeBaseServings) 人份的标准家常菜谱书写用量，并在该菜的 baseServings 字段里如实填写 \(SpecialPlanMenuBounds.aiRecipeBaseServings)。ingredients 与 seasonings 中的所有数量都要对应这份 \(SpecialPlanMenuBounds.aiRecipeBaseServings) 人份菜谱，禁止按就餐人数推算，也不要出现与就餐人数一一对应的数量模式（例如每人一只虾）。就餐人数只用来决定上几道菜和荤素搭配，不影响单道菜的用量。数量与单位之间留空格，无法确定时写“适量”。")
        return parts.joined(separator: " ")
    }

    /// "2026-09-02 星期三" in the user's calendar; the anchor the model resolves
    /// relative dates against.
    static func dayText(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd EEEE"
        return formatter.string(from: date)
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
        policy: SpecialPlanConstraintPolicy
    ) throws {
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

extension SpecialPlanMenuGenerator.Input {
    /// Regeneration and replacement start from the plan as saved: its own
    /// words when it has them, otherwise the legacy fields rendered as one
    /// request so a plan from before the composer keeps generating the way it
    /// always did.
    init(plan: SpecialPlan) {
        self.init(
            requestText: plan.effectiveRequestText,
            constraintNotes: plan.constraintNotes,
            usesHomeInventory: plan.usesHomeInventory,
            contextDate: plan.scheduledAt
        )
    }
}

extension SpecialPlan {
    /// The request that regeneration reuses. A plan written before the
    /// composer has no `requestText`; its structured fields are its request.
    var effectiveRequestText: String {
        if !requestText.isEmpty { return requestText }
        var parts = ["这是一次「\(title)」，共 \(peopleCount) 人一起吃，开饭时间 \(Self.timeText(scheduledAt))。"]
        if !constraintNotes.isEmpty {
            parts.append("要求：\(constraintNotes.joined(separator: "；"))。")
        }
        if !notes.isEmpty {
            parts.append("补充说明：\(notes)。")
        }
        return parts.joined(separator: " ")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

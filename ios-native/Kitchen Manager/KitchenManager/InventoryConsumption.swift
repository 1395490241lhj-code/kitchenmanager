import Combine
import SwiftUI
import UserNotifications

// MARK: - Consumption record (persisted via KitchenStore)

struct InventoryConsumptionRecordItem: Codable, Hashable {
    var inventoryItemID: InventoryItem.ID
    var ingredientName: String
    var consumedQuantity: Double
    var unit: String
    var previousQuantity: Double
    var resultingQuantity: Double
}

struct InventoryConsumptionRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    var recipeID: String?
    var recipeName: String
    /// Every `MealPlanItem.id` this record marks as consumed (the plural exists for
    /// multi-meal confirmations and for records written before D-042) — no second record type.
    var planIDs: [UUID]
    /// Optional Special Plan identity. Invariants: when present, `planIDs` is empty;
    /// when absent/ordinary meal, these fields are nil.
    var specialPlanID: UUID? = nil
    var specialPlanDishID: UUID? = nil
    var specialPlanTitleSnapshot: String? = nil
    var items: [InventoryConsumptionRecordItem]
    var isUndone = false
}

// MARK: - Consumption draft (what the confirmation screen edits)

struct InventoryConsumptionDraft: Identifiable, Hashable {
    var id: String
    var ingredientName: String
    var normalizedName: String
    var requiredQuantity: Double?
    var requiredUnit: String?
    var matchedInventoryID: InventoryItem.ID?
    var currentQuantity: Double?
    var consumedQuantity: Double?
    var resultingQuantity: Double?
    var isSelected: Bool
    var warning: String?
    var sourceRecipeNames: [String]
    /// Stock that matched by name but whose unit cannot be converted to the
    /// recipe's, in the stock's own unit (for example "1 份"). Non-nil means
    /// this row deducts nothing.
    var unconvertibleStockText: String? = nil
}

// MARK: - Planner
//
// Reuses IngredientParser / IngredientNormalizer / UnitConverter from
// ShoppingListGenerator.swift — no second copy of ingredient parsing or unit math.

struct InventoryConsumptionPlanner {
    struct RecipeConsumptionInput {
        let recipe: Recipe
        /// The servings actually cooked, when someone stated them; `nil` is
        /// "as written". Quantities scale by servings ÷ `recipe.baseServings`,
        /// the factor the shopping list and cooking mode already use, so a
        /// meal bought and cooked for 4 is also deducted for 4.
        let servings: Int?
    }

    func plan(for inputs: [RecipeConsumptionInput], inventory: [InventoryItem]) -> [InventoryConsumptionDraft] {
        var merged: [String: InventoryConsumptionDraft] = [:]
        // Lines whose recipe was asked for another yield but states no base
        // yield to convert from. Only these are left as written with a warning.
        var baseYieldMissing: Set<String> = []

        for input in inputs {
            let factor = RecipeQuantityScaler.factor(
                baseServings: input.recipe.baseServings,
                targetServings: input.servings
            )
            let cannotScale = factor == nil && (input.servings ?? 1) != 1
            let lines = input.recipe.ingredients
            for line in lines {
                let parsed = IngredientParser.parse(line)
                let normalized = IngredientNormalizer.normalizedName(parsed.displayName)
                guard !normalized.isEmpty else { continue }

                let (canonicalQuantity, canonicalUnit) = Self.canonicalize(quantity: parsed.quantity, unit: parsed.unit)
                let key = "\(IngredientNormalizer.matchKey(normalized))|\(canonicalUnit ?? "none")"

                var draft = merged[key] ?? InventoryConsumptionDraft(
                    id: key,
                    ingredientName: normalized,
                    normalizedName: normalized,
                    requiredQuantity: nil,
                    requiredUnit: canonicalUnit,
                    matchedInventoryID: nil,
                    currentQuantity: nil,
                    consumedQuantity: nil,
                    resultingQuantity: nil,
                    isSelected: true,
                    warning: nil,
                    sourceRecipeNames: []
                )

                if let quantity = canonicalQuantity {
                    draft.requiredQuantity = (draft.requiredQuantity ?? 0)
                        + RecipeQuantityScaler.scale(quantity: quantity, factor: factor ?? 1)
                }
                if !draft.sourceRecipeNames.contains(input.recipe.title) {
                    draft.sourceRecipeNames.append(input.recipe.title)
                }
                if cannotScale { baseYieldMissing.insert(key) }
                merged[key] = draft
            }
        }

        for key in merged.keys {
            guard var draft = merged[key] else { continue }
            let matched = Self.matchingInventory(for: draft, in: inventory)

            if !matched.isEmpty {
                draft.matchedInventoryID = matched.first?.id
                draft.currentQuantity = Self.availableQuantity(for: draft, items: matched)
                if draft.currentQuantity == nil, draft.requiredUnit != nil {
                    draft.unconvertibleStockText = Self.stockText(matched)
                }
            }
            let untouchedBatches = draft.currentQuantity == nil ? [] : draft.requiredUnit.map { unit in
                matched.filter { UnitConverter.convert($0.quantity, from: $0.unit, to: unit) == nil }
            } ?? []

            if draft.requiredQuantity == nil {
                draft.warning = "用量不明确，请确认使用量"
            } else if baseYieldMissing.contains(key) {
                draft.warning = "菜谱没有标注份量，用量未按人数换算，请确认"
            }

            if draft.matchedInventoryID == nil {
                let notFound = "库存中没有找到「\(draft.ingredientName)」"
                draft.warning = draft.warning.map { "\($0)；\(notFound)" } ?? notFound
                draft.consumedQuantity = nil
            } else if let stock = draft.unconvertibleStockText {
                // A count of 个 says nothing about how much of 1 份 it is. The
                // row used to show 库存 - / 使用量 0 / 剩 0 and deduct nothing
                // without saying so; it now says so and stays out of the deduction.
                let mismatch = "库存是 \(stock)，和菜谱的单位不同，无法换算，未扣减；需要时请在库存中手动调整"
                draft.warning = draft.warning.map { "\($0)；\(mismatch)" } ?? mismatch
                draft.consumedQuantity = nil
                draft.resultingQuantity = nil
                draft.isSelected = false
            } else {
                let target = draft.requiredQuantity ?? 0
                let available = draft.currentQuantity ?? 0
                let consumed = max(0, min(target, available))
                draft.consumedQuantity = draft.requiredQuantity == nil ? nil : consumed
                draft.resultingQuantity = max(0, available - consumed)
                if !untouchedBatches.isEmpty {
                    // The deduction skips these batches too; say so instead of
                    // letting 库存 silently exclude a box the user can see.
                    let note = "另有 \(Self.stockText(untouchedBatches)) 单位不同，无法换算，不会扣减"
                    draft.warning = draft.warning.map { "\($0)；\(note)" } ?? note
                }
            }

            merged[key] = draft
        }

        return merged.values.sorted { $0.ingredientName.localizedCompare($1.ingredientName) == .orderedAscending }
    }

    private static func canonicalize(quantity: Double?, unit: String?) -> (Double?, String?) {
        guard let quantity, let unit else { return (quantity, unit) }
        if UnitConverter.isWeightUnit(unit) {
            return (UnitConverter.convert(quantity, from: unit, to: "克"), "克")
        }
        if UnitConverter.isVolumeUnit(unit) {
            return (UnitConverter.convert(quantity, from: unit, to: "毫升"), "毫升")
        }
        return (quantity, unit)
    }

    private static func matchingInventory(for draft: InventoryConsumptionDraft, in inventory: [InventoryItem]) -> [InventoryItem] {
        inventory
            .filter { RecipeStockMatch.item($0, matches: draft.ingredientName) }
            .sorted { ($0.remainingDays ?? 9999) < ($1.remainingDays ?? 9999) }
    }

    /// "1 份" or "1 份、200 克": each unit the matched stock is held in, summed.
    private static func stockText(_ items: [InventoryItem]) -> String {
        var units: [String] = []
        var totals: [String: Double] = [:]
        for item in items {
            if totals[item.unit] == nil { units.append(item.unit) }
            totals[item.unit, default: 0] += item.quantity
        }
        return units.map { unit in
            let amount = (totals[unit] ?? 0).formatted(.number.precision(.fractionLength(0...2)))
            return unit.isEmpty ? amount : "\(amount) \(unit)"
        }
        .joined(separator: "、")
    }

    private static func availableQuantity(for draft: InventoryConsumptionDraft, items: [InventoryItem]) -> Double? {
        guard !items.isEmpty else { return nil }
        guard let unit = draft.requiredUnit else {
            return items.reduce(0) { $0 + $1.quantity }
        }
        var total = 0.0
        var matchedAny = false
        for item in items {
            if let converted = UnitConverter.convert(item.quantity, from: item.unit, to: unit) {
                total += converted
                matchedAny = true
            }
        }
        return matchedAny ? total : nil
    }
}

// MARK: - Restock suggestions
//
// Deterministic rules only — no AI call. The scheduled-meal source reuses
// ShoppingListGenerator directly instead of a second ingredient-gap calculator.

enum RestockSuggestionSource: String {
    case lowStock
    case consumed
    /// Meals standing in `KitchenStore.plans`. Never the weekly generator's
    /// draft: a menu nobody added to the plan has not been scheduled.
    case plannedMeals
    case pantryStaple
}

struct RestockSuggestion: Identifiable {
    let id: String
    let name: String
    let suggestedQuantity: Double?
    let unit: String?
    let reason: String
    let source: RestockSuggestionSource
    /// The pending 买菜清单 already holds this, so 加入清单 would only add it twice.
    var isAlreadyOnShoppingList = false
}

struct RestockSuggestionEngine {
    /// A pending list row for the same ingredient in the same or a convertible
    /// unit. A row in an unrelated unit does not count: adding would not merge
    /// into it, and it says nothing about how much is already coming.
    static func isOnShoppingList(name: String, unit: String?, in shoppingItems: [KitchenShoppingItem]) -> Bool {
        let key = IngredientNormalizer.matchKey(name)
        return shoppingItems.contains { item in
            guard !item.isDone, IngredientNormalizer.matchKey(item.name) == key else { return false }
            guard let unit else { return true }
            return IngredientNormalizer.normalizedUnit(item.unit) == IngredientNormalizer.normalizedUnit(unit)
                || UnitConverter.areConvertible(item.unit, unit)
        }
    }

    func generate(
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore,
        justConsumed: [InventoryConsumptionRecordItem] = [],
        excludingPlanIDs: Set<UUID> = []
    ) -> [RestockSuggestion] {
        var suggestions: [String: RestockSuggestion] = [:]

        for item in kitchenStore.inventory where item.isStaple && item.autoSuggestRestock {
            guard item.stapleStatus == .low || item.stapleStatus == .outOfStock else { continue }
            let key = IngredientNormalizer.matchKey(item.name)
            let target = item.defaultRestockQuantity
                ?? item.lowStockThreshold.map { max(0, $0 - item.quantity) }
            suggestions[key] = RestockSuggestion(
                id: "staple-\(key)",
                name: item.name,
                suggestedQuantity: target.flatMap { $0 > 0 ? $0 : nil },
                unit: item.unit,
                reason: item.stapleStatus == .outOfStock ? "常备食材已缺货" : "库存低于常备阈值",
                source: .pantryStaple,
                isAlreadyOnShoppingList: Self.isOnShoppingList(name: item.name, unit: item.unit, in: kitchenStore.shoppingItems)
            )
        }

        for recordItem in justConsumed where recordItem.resultingQuantity <= 0 {
            let key = IngredientNormalizer.matchKey(recordItem.ingredientName)
            guard suggestions[key] == nil else { continue }
            suggestions[key] = RestockSuggestion(
                id: "consumed-\(key)", name: recordItem.ingredientName, suggestedQuantity: nil, unit: recordItem.unit,
                reason: "做饭后已用完", source: .consumed,
                isAlreadyOnShoppingList: Self.isOnShoppingList(
                    name: recordItem.ingredientName, unit: recordItem.unit, in: kitchenStore.shoppingItems
                )
            )
        }

        // Only what is actually scheduled. A generated menu sitting on the
        // result screen has not been added to anything, so it must not change
        // what the kitchen says it needs to buy; that screen's own
        // 生成购物清单 is where a draft turns into shopping, explicitly.
        //
        // `excludingPlanIDs` are the meals this cook just consumed. They are
        // marked cooked only after the confirmation returns, so without this
        // the meal on the stove would ask to be bought again.
        let upcoming = PlannedMealHorizon.upcoming(plans: kitchenStore.plans)
            .filter { !excludingPlanIDs.contains($0.id) }
        if !upcoming.isEmpty {
            let draft = ShoppingListGenerator().generate(
                source: .plannedMeals(upcoming),
                inventory: kitchenStore.inventory,
                existingShoppingItems: kitchenStore.shoppingItems,
                recipeStore: recipeStore,
                pendingList: .subtract
            )
            for item in draft.missingItems {
                let key = IngredientNormalizer.matchKey(item.displayName)
                guard suggestions[key] == nil else { continue }
                suggestions[key] = RestockSuggestion(
                    id: "planned-\(key)", name: item.displayName, suggestedQuantity: item.missingQuantity, unit: item.unit,
                    reason: "未来 7 天计划需要", source: .plannedMeals
                )
            }
            // The generator already subtracted the pending list; these are
            // covered by it in full.
            for item in draft.alreadyListedItems {
                let key = IngredientNormalizer.matchKey(item.displayName)
                guard suggestions[key] == nil else { continue }
                suggestions[key] = RestockSuggestion(
                    id: "planned-\(key)", name: item.displayName, suggestedQuantity: nil, unit: item.unit,
                    reason: "未来 7 天计划需要", source: .plannedMeals, isAlreadyOnShoppingList: true
                )
            }
        }

        return suggestions.values.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Optional local expiry notifications

enum ExpiryNotificationLeadTime: String, CaseIterable, Identifiable {
    case oneDayBefore
    case threeDaysBefore
    case dayOf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneDayBefore: return "到期前 1 天提醒"
        case .threeDaysBefore: return "到期前 3 天提醒"
        case .dayOf: return "当天到期提醒"
        }
    }

    var daysBeforeExpiry: Int {
        switch self {
        case .oneDayBefore: return 1
        case .threeDaysBefore: return 3
        case .dayOf: return 0
        }
    }

    /// The `@AppStorage` key SettingsView's toggle writes.
    var storageKey: String {
        switch self {
        case .oneDayBefore: return "notifyLeadTime1Day"
        case .threeDaysBefore: return "notifyLeadTime3Day"
        case .dayOf: return "notifyLeadTimeDayOf"
        }
    }

    /// SettingsView's `@AppStorage` default. That default lives only in memory
    /// until the user flips the toggle, so every other reader must apply it too —
    /// `defaults.bool(forKey:)` would read an untouched 1-day toggle as off.
    var isEnabledByDefault: Bool { self != .threeDaysBefore }

    static func enabled(in defaults: UserDefaults) -> Set<ExpiryNotificationLeadTime> {
        Set(allCases.filter { defaults.object(forKey: $0.storageKey) as? Bool ?? $0.isEnabledByDefault })
    }
}

@MainActor
enum ExpiryNotificationScheduler {
    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }

    static func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Clears every pending expiry notification and reschedules from the current
    /// inventory — the simplest way to satisfy "update on add/edit/merge, cancel on
    /// delete, never duplicate" all at once without per-item diffing.
    static func rescheduleAll(for inventory: [InventoryItem], leadTimes: Set<ExpiryNotificationLeadTime>) {
        let center = UNUserNotificationCenter.current()
        let defaults = UserDefaults.standard
        let scheduledKey = "native_km_expiry_notification_ids_v1"
        center.removePendingNotificationRequests(
            withIdentifiers: defaults.stringArray(forKey: scheduledKey) ?? []
        )
        guard !leadTimes.isEmpty else {
            defaults.set([], forKey: scheduledKey)
            return
        }

        var scheduledIDs: [String] = []
        for item in inventory where item.isAvailable {
            // R2: the *semantic* date, never the stored one. A pantry staple is
            // stock-tracked, so a date left behind by older data must not turn
            // into a 「快到期了」 push about a bottle of soy sauce.
            guard let expiryDate = item.effectiveExpiryDate else { continue }
            for leadTime in leadTimes {
                guard let dayStart = Calendar.current.date(
                    byAdding: .day,
                    value: -leadTime.daysBeforeExpiry,
                    to: Calendar.current.startOfDay(for: expiryDate)
                ), let fireDate = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: dayStart),
                fireDate > Date() else { continue }

                let content = UNMutableNotificationContent()
                content.title = "\(item.name)快到期了"
                content.body = "可以优先安排今天或明天使用。"
                content.sound = .default

                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let request = UNNotificationRequest(
                    identifier: "expiry-\(item.id.uuidString)-\(leadTime.rawValue)",
                    content: content,
                    trigger: trigger
                )
                center.add(request)
                scheduledIDs.append(request.identifier)
            }
        }
        defaults.set(scheduledIDs, forKey: scheduledKey)
    }
}

// MARK: - Confirmation flow store

enum CookConsumptionTarget: Equatable {
    case plannedMeals(planIDs: [UUID], recipe: Recipe?, servings: Int)
    case directRecipe(recipe: Recipe, servings: Int)
    case specialPlanDish(planID: UUID, dishID: UUID, planTitleSnapshot: String, recipe: Recipe?)
}

enum CookConsumptionCompletionOutcome: Equatable {
    case completed
    case dishStateSaveFailed(message: String)
}

@MainActor
final class CookConsumptionStore: ObservableObject {
    // Not private(set): the confirmation view binds directly to individual drafts
    // (Toggle/TextField edits) via `$store.drafts`.
    @Published var drafts: [InventoryConsumptionDraft] = []
    @Published private(set) var restockSuggestions: [RestockSuggestion] = []
    @Published private(set) var didConfirm = false
    @Published private(set) var completionOutcome: CookConsumptionCompletionOutcome? = nil
    @Published private(set) var unresolvedPlanNames: [String] = []

    private let planner = InventoryConsumptionPlanner()
    private let restockEngine = RestockSuggestionEngine()
    private var isDirectRecipeConsumption = false
    private var preparedPlanIDs: Set<UUID> = []
    private var preparedUnconsumedIDs: Set<UUID> = []
    private var currentTarget: CookConsumptionTarget? = nil

    func isTargetAlreadySatisfied(target: CookConsumptionTarget, kitchenStore: KitchenStore) -> Bool {
        switch target {
        case .plannedMeals(let planIDs, _, _):
            return allTargetsAlreadySatisfied(planIDs, kitchenStore: kitchenStore)
        case .directRecipe:
            return false
        case .specialPlanDish(let planID, let dishID, _, _):
            return kitchenStore.hasConsumedSpecialPlanDish(planID: planID, dishID: dishID)
        }
    }

    func targetAlreadySatisfiedTitle(target: CookConsumptionTarget, kitchenStore: KitchenStore) -> String? {
        guard isTargetAlreadySatisfied(target: target, kitchenStore: kitchenStore) else { return nil }
        switch target {
        case .plannedMeals(let planIDs, _, _):
            return Set(planIDs).count == 1 ? "确认完成这道菜" : "确认完成这些菜"
        case .directRecipe:
            return nil
        case .specialPlanDish:
            return "确认完成这道菜"
        }
    }

    /// A no-deduction confirmation is proved by exact, still-existing targets,
    /// never by an empty ingredient list or matching recipe names.
    func allTargetsAlreadySatisfied(_ planIDs: [UUID], kitchenStore: KitchenStore) -> Bool {
        !planIDs.isEmpty && planIDs.allSatisfy { id in
            kitchenStore.plans.contains { $0.id == id } && kitchenStore.hasConsumedPlan(id)
        }
    }

    func alreadySatisfiedTitle(_ planIDs: [UUID], kitchenStore: KitchenStore) -> String? {
        guard allTargetsAlreadySatisfied(planIDs, kitchenStore: kitchenStore) else { return nil }
        return Set(planIDs).count == 1 ? "确认完成这道菜" : "确认完成这些菜"
    }

    func buildDrafts(
        target: CookConsumptionTarget,
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore
    ) {
        currentTarget = target
        switch target {
        case .plannedMeals(let planIDs, let recipe, let servings):
            buildDrafts(
                planIDs: planIDs,
                recipe: recipe,
                servings: servings,
                kitchenStore: kitchenStore,
                recipeStore: recipeStore
            )
        case .directRecipe(let recipe, let servings):
            buildDrafts(
                planIDs: [],
                recipe: recipe,
                servings: servings,
                kitchenStore: kitchenStore,
                recipeStore: recipeStore
            )
        case .specialPlanDish(_, _, _, let recipe):
            preparedPlanIDs = []
            preparedUnconsumedIDs = []
            isDirectRecipeConsumption = false
            var inputs: [InventoryConsumptionPlanner.RecipeConsumptionInput] = []
            var unresolved: [String] = []
            if let recipe {
                // As written (D-047): a Special Plan dish is never scaled by headcount.
                inputs.append(.init(recipe: recipe, servings: nil))
            } else {
                unresolved.append("这道菜品")
            }
            unresolvedPlanNames = unresolved
            drafts = planner.plan(for: inputs, inventory: kitchenStore.inventory)
        }
    }

    func buildDrafts(
        planIDs: [UUID],
        recipe: Recipe? = nil,
        servings: Int = 1,
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore
    ) {
        if currentTarget == nil {
            if planIDs.isEmpty, let recipe {
                currentTarget = .directRecipe(recipe: recipe, servings: servings)
            } else {
                currentTarget = .plannedMeals(planIDs: planIDs, recipe: recipe, servings: servings)
            }
        }
        preparedPlanIDs = Set(planIDs)
        preparedUnconsumedIDs = Set(planIDs.filter { !kitchenStore.hasConsumedPlan($0) })
        var inputs: [InventoryConsumptionPlanner.RecipeConsumptionInput] = []
        var unresolved: [String] = []
        isDirectRecipeConsumption = recipe != nil && planIDs.isEmpty
        if let recipe, isDirectRecipeConsumption {
            inputs.append(.init(recipe: recipe, servings: servings))
        }
        for id in planIDs where preparedUnconsumedIDs.contains(id) {
            guard let plan = kitchenStore.plans.first(where: { $0.id == id }) else { continue }
            guard let recipe = recipeStore.recipe(id: plan.recipeID) else {
                unresolved.append(plan.recipeName)
                continue
            }
            // `nil` stays "as written"; a stated target scales like the
            // shopping list did for the same meal.
            inputs.append(.init(recipe: recipe, servings: plan.plannedServings))
        }
        unresolvedPlanNames = unresolved
        drafts = planner.plan(for: inputs, inventory: kitchenStore.inventory)
    }

    func toggleSelection(_ id: String) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].isSelected.toggle()
    }

    func updateDraft(_ draft: InventoryConsumptionDraft) {
        guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return }
        drafts[index] = draft
    }

    func ignoreUnmatched(_ id: String) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].isSelected = false
    }

    func addUnmatchedToShoppingList(_ id: String, kitchenStore: KitchenStore) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        let draft = drafts[index]
        kitchenStore.addShopping(
            name: draft.ingredientName,
            quantity: draft.requiredQuantity ?? 1,
            unit: draft.requiredUnit ?? "适量",
            source: "做饭缺货"
        )
        drafts[index].isSelected = false
    }

    @discardableResult
    func confirm(
        target: CookConsumptionTarget,
        recipeID: String?,
        recipeName: String,
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore
    ) -> Bool {
        switch target {
        case .plannedMeals(let planIDs, _, _):
            return confirm(
                planIDs: planIDs,
                recipeID: recipeID,
                recipeName: recipeName,
                kitchenStore: kitchenStore,
                recipeStore: recipeStore
            )
        case .directRecipe:
            return confirm(
                planIDs: [],
                recipeID: recipeID,
                recipeName: recipeName,
                kitchenStore: kitchenStore,
                recipeStore: recipeStore
            )
        case .specialPlanDish(let planID, let dishID, let titleSnapshot, _):
            if kitchenStore.hasConsumedSpecialPlanDish(planID: planID, dishID: dishID) {
                didConfirm = true
                return true
            }
            guard case .specialPlanDish(_, _, _, let recipe) = target, recipe != nil else {
                // A special plan dish without an existing active receipt must have a recipe
                // to compute consumption; cannot fabricate a zero-item consumption receipt.
                return false
            }
            let record = kitchenStore.applyConsumption(
                drafts,
                planIDs: [],
                recipeID: recipeID,
                recipeName: recipeName,
                specialPlanID: planID,
                specialPlanDishID: dishID,
                specialPlanTitleSnapshot: titleSnapshot
            )
            guard kitchenStore.consumptionRecords.contains(where: { $0.id == record.id }) else {
                return false
            }
            restockSuggestions = restockEngine.generate(
                kitchenStore: kitchenStore,
                recipeStore: recipeStore,
                justConsumed: record.items
            )
            didConfirm = true
            return true
        }
    }

    func setCompletionOutcome(_ outcome: CookConsumptionCompletionOutcome) {
        self.completionOutcome = outcome
    }

    @discardableResult
    func confirm(
        planIDs: [UUID],
        recipeID: String?,
        recipeName: String,
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore
    ) -> Bool {
        // Bool means semantic confirmation success. An existing receipt can
        // satisfy a valid exact target without another write; invalid targets
        // and failed persistence must never trigger the caller's completion.
        guard Set(planIDs) == preparedPlanIDs,
              planIDs.allSatisfy({ id in kitchenStore.plans.contains { $0.id == id } }) else { return false }
        if allTargetsAlreadySatisfied(planIDs, kitchenStore: kitchenStore) {
            didConfirm = true
            return true
        }
        let unconsumedPlanIDs = planIDs.filter { !kitchenStore.hasConsumedPlan($0) }
        guard isDirectRecipeConsumption || !unconsumedPlanIDs.isEmpty else { return false }
        // Re-evaluate at mutation time. The sheet may have been open while
        // another valid path consumed part of this request (or an undo
        // released a plan): stale merged drafts would deduct an
        // already-handled share again, so a changed target set is re-planned
        // fresh against the current inventory. Edited quantities are
        // discarded only in that divergent case, because their merged basis
        // no longer matches what is being consumed.
        if Set(unconsumedPlanIDs) != preparedUnconsumedIDs, !isDirectRecipeConsumption {
            buildDrafts(planIDs: unconsumedPlanIDs, kitchenStore: kitchenStore, recipeStore: recipeStore)
            // The request identity stays pinned to what the caller asked for,
            // so a retry after a persistence failure keeps working.
            preparedPlanIDs = Set(planIDs)
        }
        let record = kitchenStore.applyConsumption(
            drafts,
            planIDs: unconsumedPlanIDs,
            recipeID: recipeID,
            recipeName: recipeName
        )
        guard kitchenStore.consumptionRecords.contains(where: { $0.id == record.id }) else {
            return false
        }
        restockSuggestions = restockEngine.generate(
            kitchenStore: kitchenStore,
            recipeStore: recipeStore,
            justConsumed: record.items,
            excludingPlanIDs: Set(planIDs)
        )
        didConfirm = true
        return true
    }
}

// MARK: - Confirmation view
//
// Replaces the old CookCalibrationSheet, which just showed the first 6 inventory
// items with steppers unrelated to the actual recipe. This one is driven entirely by
// the recipe's real ingredients, merged and deducted through the shared planner.

struct CookConsumptionConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var kitchenStore: KitchenStore
    @EnvironmentObject private var recipeStore: RecipeStore
    @StateObject private var store = CookConsumptionStore()

    let title: String
    let planIDs: [UUID]
    let recipeID: String?
    let recipeName: String
    var recipe: Recipe? = nil
    var servings = 1
    var target: CookConsumptionTarget? = nil
    var onConfirmWithOutcome: (@MainActor (@escaping (CookConsumptionCompletionOutcome) -> Void) -> Void)? = nil
    var onConfirm: (() -> Void)? = nil

    init(
        title: String,
        planIDs: [UUID],
        recipeID: String?,
        recipeName: String,
        recipe: Recipe? = nil,
        servings: Int = 1,
        onConfirm: @escaping () -> Void
    ) {
        self.title = title
        self.planIDs = planIDs
        self.recipeID = recipeID
        self.recipeName = recipeName
        self.recipe = recipe
        self.servings = servings
        if planIDs.isEmpty, let recipe {
            self.target = .directRecipe(recipe: recipe, servings: servings)
        } else {
            self.target = .plannedMeals(planIDs: planIDs, recipe: recipe, servings: servings)
        }
        self.onConfirm = onConfirm
        self.onConfirmWithOutcome = nil
    }

    init(
        target: CookConsumptionTarget,
        title: String,
        recipeID: String?,
        recipeName: String,
        onConfirmWithOutcome: @escaping @MainActor (@escaping (CookConsumptionCompletionOutcome) -> Void) -> Void
    ) {
        self.title = title
        self.planIDs = []
        self.recipeID = recipeID
        self.recipeName = recipeName
        self.recipe = nil
        self.servings = 1
        self.target = target
        self.onConfirm = nil
        self.onConfirmWithOutcome = onConfirmWithOutcome
    }

    var body: some View {
        NavigationStack {
            List {
                if store.didConfirm {
                    confirmedSection
                } else if alreadySatisfiedTitle != nil {
                    Section {
                        Text("食材消耗已经记录，本次确认不会再次扣减库存。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        // States what confirming does and how a mistake is
                        // fixed. There is no undo for a deduction, but the
                        // quantities remain editable in Inventory afterwards —
                        // so the honest warning is "you will have to correct it
                        // by hand", not a claim of irreversible data loss.
                        Text("这道「\(title)」用到的食材已按菜谱用量预估。确认后将扣减库存，如有误需要手动调整库存。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !store.unresolvedPlanNames.isEmpty {
                        Section {
                            Label(
                                "「\(store.unresolvedPlanNames.joined(separator: "、"))」没有找到菜谱信息，将只标记完成，不扣减库存。",
                                systemImage: "info.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    if store.drafts.isEmpty {
                        Section {
                            ContentUnavailableView(
                                "没有可识别的食材",
                                systemImage: "list.bullet",
                                description: Text("这道菜谱没有可用的食材信息，确认后仍会标记为已完成。")
                            )
                        }
                    } else {
                        Section("食材消耗") {
                            ForEach($store.drafts) { $draft in
                                draftRow($draft)
                            }
                        }
                    }
                }
            }
            .navigationTitle(confirmedOrPendingTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if store.didConfirm {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(alreadySatisfiedTitle == nil ? "更新冰箱" : "确认完成") {
                            let resolvedTarget = target ?? .plannedMeals(planIDs: planIDs, recipe: recipe, servings: servings)
                            guard store.confirm(
                                target: resolvedTarget,
                                recipeID: recipeID,
                                recipeName: recipeName,
                                kitchenStore: kitchenStore,
                                recipeStore: recipeStore
                            ) else { return }
                            if let onConfirmWithOutcome {
                                onConfirmWithOutcome({ outcome in
                                    store.setCompletionOutcome(outcome)
                                })
                            } else if let onConfirm {
                                onConfirm()
                            }
                        }
                    }
                }
            }
            .task {
                let resolvedTarget = target ?? .plannedMeals(planIDs: planIDs, recipe: recipe, servings: servings)
                store.buildDrafts(
                    target: resolvedTarget,
                    kitchenStore: kitchenStore,
                    recipeStore: recipeStore
                )
            }
        }
    }

    private var alreadySatisfiedTitle: String? {
        if let target {
            return store.targetAlreadySatisfiedTitle(target: target, kitchenStore: kitchenStore)
        }
        return store.alreadySatisfiedTitle(planIDs, kitchenStore: kitchenStore)
    }

    private var confirmedOrPendingTitle: String {
        if store.didConfirm {
            if case .dishStateSaveFailed = store.completionOutcome {
                return "库存已更新"
            }
            return "已完成"
        }
        return alreadySatisfiedTitle ?? "确认本次食材消耗"
    }

    @ViewBuilder
    private func draftRow(_ draft: Binding<InventoryConsumptionDraft>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: draft.isSelected) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.wrappedValue.ingredientName)
                        .font(.subheadline.weight(.semibold))
                    if !draft.wrappedValue.sourceRecipeNames.isEmpty {
                        Text("来自：\(draft.wrappedValue.sourceRecipeNames.joined(separator: "、"))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Nothing to deduct in a unit the stock is not held in.
            .disabled(draft.wrappedValue.unconvertibleStockText != nil)

            if let stock = draft.wrappedValue.unconvertibleStockText {
                HStack {
                    Text("需要 \(quantityText(draft.wrappedValue.requiredQuantity)) \(draft.wrappedValue.requiredUnit ?? "")")
                    Spacer()
                    Text("库存 \(stock)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Label("单位不同，未扣减", systemImage: "minus.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("consumption.\(draft.wrappedValue.id).notDeducted")
            } else if draft.wrappedValue.matchedInventoryID != nil {
                HStack {
                    Text("需要 \(quantityText(draft.wrappedValue.requiredQuantity)) \(draft.wrappedValue.requiredUnit ?? "")")
                    Spacer()
                    Text("库存 \(quantityText(draft.wrappedValue.currentQuantity)) \(draft.wrappedValue.requiredUnit ?? "")")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Text("使用量")
                    ConsumedQuantityField(quantity: draft.consumedQuantity)
                        .frame(maxWidth: 80)
                    Text(draft.wrappedValue.requiredUnit ?? "")
                    Spacer()
                    if let remaining = draft.wrappedValue.remainingAfterDeduction {
                        Text("扣减后剩 \(quantityText(remaining))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("这一行不扣减")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Menu {
                    Button("忽略", systemImage: "xmark.circle") {
                        store.ignoreUnmatched(draft.wrappedValue.id)
                    }
                    Button("加入购物清单", systemImage: "cart.badge.plus") {
                        store.addUnmatchedToShoppingList(draft.wrappedValue.id, kitchenStore: kitchenStore)
                    }
                } label: {
                    Label("选择处理方式", systemImage: "questionmark.circle")
                        .font(.caption)
                }
            }

            if let warning = draft.wrappedValue.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var confirmedSection: some View {
        if case .dishStateSaveFailed(let message) = store.completionOutcome {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("库存已更新", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.successInk)
                        .font(.subheadline.weight(.medium))
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppTheme.warningInk)
                        .font(.footnote)
                }
                .padding(.vertical, 4)
            }
        } else {
            Section {
                Label("已记录消耗，库存已更新", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.successInk)
            }
        }
        if !store.restockSuggestions.isEmpty {
            Section("补货建议") {
                ForEach(store.restockSuggestions) { suggestion in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.name)
                            Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        // Read live: the suggestions are a snapshot taken at
                        // confirmation, and a second tap must not add it twice.
                        if suggestion.isAlreadyOnShoppingList
                            || RestockSuggestionEngine.isOnShoppingList(
                                name: suggestion.name, unit: suggestion.unit, in: kitchenStore.shoppingItems
                            ) {
                            Text("已在清单")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("加入清单") {
                                kitchenStore.addShopping(
                                    name: suggestion.name,
                                    quantity: suggestion.suggestedQuantity ?? 1,
                                    unit: suggestion.unit ?? "适量",
                                    source: "补货建议"
                                )
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    private func quantityText(_ value: Double?) -> String {
        guard let value else { return "-" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

}

extension InventoryConsumptionDraft {
    /// What the row leaves in stock, from the amount on screen. `nil` when the
    /// amount is cleared: that row deducts nothing, so it must not keep showing
    /// the remainder the planner originally estimated.
    var remainingAfterDeduction: Double? {
        guard let current = currentQuantity, let consumed = consumedQuantity else { return nil }
        return max(0, current - consumed)
    }

    /// Reads a typed 使用量. Empty or unreadable text is "no amount" (`nil`);
    /// a comma decimal separator is accepted as well as a point.
    static func enteredQuantity(from text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value.isFinite, value >= 0 else { return nil }
        return value
    }
}

/// The 使用量 field. A `TextField(value:format:)` commits only on return or
/// when focus leaves, and the decimal pad has no return key, so tapping
/// 更新冰箱 straight after typing could deduct the old amount. This writes the
/// amount through on every keystroke instead.
private struct ConsumedQuantityField: View {
    @Binding var quantity: Double?
    @State private var text: String

    init(quantity: Binding<Double?>) {
        _quantity = quantity
        _text = State(initialValue: quantity.wrappedValue.map {
            $0.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
        } ?? "")
    }

    var body: some View {
        TextField("数量", text: $text)
            .keyboardType(.decimalPad)
            .onChange(of: text) { _, typed in
                quantity = InventoryConsumptionDraft.enteredQuantity(from: typed)
            }
    }
}

// MARK: - Recent consumption (undo)

struct RecentConsumptionView: View {
    @EnvironmentObject private var kitchenStore: KitchenStore
    @State private var undoAlert: UndoAlert?

    private enum UndoAlert: String, Identifiable {
        case conflict
        case failed

        var id: String { rawValue }
    }

    var body: some View {
        List {
            if kitchenStore.consumptionRecords.isEmpty {
                ContentUnavailableView("还没有消耗记录", systemImage: "clock.arrow.circlepath")
            } else {
                ForEach(kitchenStore.consumptionRecords) { record in
                    Section {
                        ForEach(record.items, id: \.inventoryItemID) { item in
                            HStack {
                                Text(item.ingredientName)
                                Spacer()
                                Text("-\(item.consumedQuantity.formatted()) \(item.unit)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if record.isUndone {
                            Label("已撤销", systemImage: "arrow.uturn.backward.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("撤销这次扣减", role: .destructive) {
                                switch kitchenStore.undoConsumption(record) {
                                case .undone, .alreadyUndone:
                                    break
                                case .conflict:
                                    undoAlert = .conflict
                                case .failed:
                                    undoAlert = .failed
                                }
                            }
                        }
                    } header: {
                        if let specialTitle = record.specialPlanTitleSnapshot, !specialTitle.isEmpty {
                            Text("\(specialTitle) · \(record.recipeName)")
                        } else {
                            Text(record.recipeName)
                        }
                    } footer: {
                        Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
        }
        .navigationTitle("最近消耗")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $undoAlert) { alert in
            switch alert {
            case .conflict:
                Alert(
                    title: Text("无法安全撤销"),
                    message: Text("这笔记录之后，相关食材的库存已经发生变化。为避免覆盖当前数量，请回到食材详情手动核对并调整。"),
                    dismissButton: .default(Text("知道了"))
                )
            case .failed:
                Alert(
                    title: Text("撤销失败"),
                    message: Text(kitchenStore.consumptionNotice ?? "撤销消耗失败，库存未变更。"),
                    dismissButton: .default(Text("知道了"))
                )
            }
        }
    }
}

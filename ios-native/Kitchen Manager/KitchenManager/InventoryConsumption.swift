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
    /// Every `MealPlanItem.id` this record marks as consumed — supports both a single
    /// dish ("做好了") and a merged batch ("全部做完") without a second record type.
    var planIDs: [UUID]
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
}

// MARK: - Planner
//
// Reuses IngredientParser / IngredientNormalizer / UnitConverter from
// ShoppingListGenerator.swift — no second copy of ingredient parsing or unit math.

struct InventoryConsumptionPlanner {
    struct RecipeConsumptionInput {
        let recipe: Recipe
        let servings: Int
    }

    func plan(for inputs: [RecipeConsumptionInput], inventory: [InventoryItem]) -> [InventoryConsumptionDraft] {
        var merged: [String: InventoryConsumptionDraft] = [:]
        var servingsMismatch: Set<String> = []

        for input in inputs {
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
                    draft.requiredQuantity = (draft.requiredQuantity ?? 0) + quantity
                }
                if !draft.sourceRecipeNames.contains(input.recipe.title) {
                    draft.sourceRecipeNames.append(input.recipe.title)
                }
                if input.servings != 1 { servingsMismatch.insert(key) }
                merged[key] = draft
            }
        }

        for key in merged.keys {
            guard var draft = merged[key] else { continue }
            let matched = Self.matchingInventory(for: draft, in: inventory)

            if !matched.isEmpty {
                draft.matchedInventoryID = matched.first?.id
                draft.currentQuantity = Self.availableQuantity(for: draft, items: matched)
            }

            if draft.requiredQuantity == nil {
                draft.warning = "用量不明确，请确认使用量"
            } else if servingsMismatch.contains(key) {
                draft.warning = "菜谱没有标注份量，用量未按人数换算，请确认"
            }

            if draft.matchedInventoryID == nil {
                let notFound = "库存中没有找到「\(draft.ingredientName)」"
                draft.warning = draft.warning.map { "\($0)；\(notFound)" } ?? notFound
                draft.consumedQuantity = nil
            } else {
                let target = draft.requiredQuantity ?? 0
                let available = draft.currentQuantity ?? 0
                let consumed = max(0, min(target, available))
                draft.consumedQuantity = draft.requiredQuantity == nil ? nil : consumed
                draft.resultingQuantity = max(0, available - consumed)
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
            .filter { $0.isAvailable && IngredientNormalizer.matchKey($0.name) == IngredientNormalizer.matchKey(draft.ingredientName) }
            .sorted { ($0.remainingDays ?? 9999) < ($1.remainingDays ?? 9999) }
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
// Deterministic rules only — no AI call. The weekly-plan source reuses
// ShoppingListGenerator directly instead of a second ingredient-gap calculator.

enum RestockSuggestionSource: String, Codable {
    case lowStock
    case consumed
    case weeklyPlan
    case pantryStaple

    var label: String {
        switch self {
        case .lowStock: return "库存偏低"
        case .consumed: return "做饭后用完"
        case .weeklyPlan: return "本周计划需要"
        case .pantryStaple: return "常备已用完"
        }
    }
}

struct RestockSuggestion: Identifiable {
    let id: String
    let name: String
    let suggestedQuantity: Double?
    let unit: String?
    let reason: String
    let source: RestockSuggestionSource
}

struct RestockSuggestionEngine {
    func generate(
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore,
        justConsumed: [InventoryConsumptionRecordItem] = []
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
                source: .pantryStaple
            )
        }

        for recordItem in justConsumed where recordItem.resultingQuantity <= 0 {
            let key = IngredientNormalizer.matchKey(recordItem.ingredientName)
            guard suggestions[key] == nil else { continue }
            suggestions[key] = RestockSuggestion(
                id: "consumed-\(key)", name: recordItem.ingredientName, suggestedQuantity: nil, unit: recordItem.unit,
                reason: "做饭后已用完", source: .consumed
            )
        }

        if let plan = kitchenStore.weeklyPlan {
            let draft = ShoppingListGenerator().generate(
                source: .weeklyPlan(plan),
                inventory: kitchenStore.inventory,
                existingShoppingItems: kitchenStore.shoppingItems,
                recipeStore: recipeStore
            )
            for item in draft.missingItems {
                let key = IngredientNormalizer.matchKey(item.displayName)
                guard suggestions[key] == nil else { continue }
                suggestions[key] = RestockSuggestion(
                    id: "weekly-\(key)", name: item.displayName, suggestedQuantity: item.missingQuantity, unit: item.unit,
                    reason: "本周计划需要", source: .weeklyPlan
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
            guard let expiryDate = item.expiryDate else { continue }
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

@MainActor
final class CookConsumptionStore: ObservableObject {
    // Not private(set): the confirmation view binds directly to individual drafts
    // (Toggle/TextField edits) via `$store.drafts`.
    @Published var drafts: [InventoryConsumptionDraft] = []
    @Published private(set) var restockSuggestions: [RestockSuggestion] = []
    @Published private(set) var didConfirm = false
    @Published private(set) var unresolvedPlanNames: [String] = []

    private let planner = InventoryConsumptionPlanner()
    private let restockEngine = RestockSuggestionEngine()

    func buildDrafts(planIDs: [UUID], kitchenStore: KitchenStore, recipeStore: RecipeStore) {
        var inputs: [InventoryConsumptionPlanner.RecipeConsumptionInput] = []
        var unresolved: [String] = []
        for id in planIDs {
            guard let plan = kitchenStore.plans.first(where: { $0.id == id }) else { continue }
            guard let recipe = recipeStore.recipes.first(where: { $0.id == plan.recipeID }) else {
                unresolved.append(plan.recipeName)
                continue
            }
            inputs.append(.init(recipe: recipe, servings: plan.servings))
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

    func confirm(
        planIDs: [UUID],
        recipeID: String?,
        recipeName: String,
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore
    ) {
        let record = kitchenStore.applyConsumption(
            drafts,
            planIDs: planIDs,
            recipeID: recipeID,
            recipeName: recipeName
        )
        guard kitchenStore.consumptionRecords.contains(where: { $0.id == record.id }) else {
            return
        }
        restockSuggestions = restockEngine.generate(
            kitchenStore: kitchenStore,
            recipeStore: recipeStore,
            justConsumed: record.items
        )
        didConfirm = true
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
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if store.didConfirm {
                    confirmedSection
                } else {
                    Section {
                        Text("这道「\(title)」用到的食材已按菜谱用量预估，确认或修改后扣减库存。")
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
            .navigationTitle(store.didConfirm ? "已完成" : "确认本次食材消耗")
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
                        Button("更新冰箱") {
                            store.confirm(
                                planIDs: planIDs,
                                recipeID: recipeID,
                                recipeName: recipeName,
                                kitchenStore: kitchenStore,
                                recipeStore: recipeStore
                            )
                            onConfirm()
                        }
                    }
                }
            }
            .task {
                store.buildDrafts(planIDs: planIDs, kitchenStore: kitchenStore, recipeStore: recipeStore)
            }
        }
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

            if draft.wrappedValue.matchedInventoryID != nil {
                HStack {
                    Text("需要 \(quantityText(draft.wrappedValue.requiredQuantity)) \(draft.wrappedValue.requiredUnit ?? "")")
                    Spacer()
                    Text("库存 \(quantityText(draft.wrappedValue.currentQuantity)) \(draft.wrappedValue.requiredUnit ?? "")")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Text("使用量")
                    TextField("数量", value: draft.consumedQuantity, format: .number)
                        .keyboardType(.decimalPad)
                        .frame(maxWidth: 80)
                    Text(draft.wrappedValue.requiredUnit ?? "")
                    Spacer()
                    Text("扣减后剩 \(quantityText(resultingQuantity(draft.wrappedValue)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        Section {
            Label("已记录消耗，库存已更新", systemImage: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.success)
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

    private func quantityText(_ value: Double?) -> String {
        guard let value else { return "-" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func resultingQuantity(_ draft: InventoryConsumptionDraft) -> Double? {
        guard let current = draft.currentQuantity, let consumed = draft.consumedQuantity else {
            return draft.resultingQuantity
        }
        return max(0, current - consumed)
    }
}

// MARK: - Recent consumption (undo)

struct RecentConsumptionView: View {
    @EnvironmentObject private var kitchenStore: KitchenStore

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
                                kitchenStore.undoConsumption(record)
                            }
                        }
                    } header: {
                        Text(record.recipeName)
                    } footer: {
                        Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
        }
        .navigationTitle("最近消耗")
        .navigationBarTitleDisplayMode(.inline)
    }
}
